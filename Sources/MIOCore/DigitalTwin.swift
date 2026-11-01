import Foundation

extension MicResponse {
    /// The same responses at another sample rate (linear interpolation, box-filtered first when decimating).
    public func resampled(to rate: Double) -> MicResponse {
        guard abs(rate - sampleRate) > 0.5 else { return self }
        func conv(_ x: [Double]) -> [Double] {
            var y = x
            var r = sampleRate
            let f = max(1, Int(sampleRate / rate))
            if f > 1 {
                y = (0..<(x.count / f)).map { i in (0..<f).reduce(0.0) { $0 + x[i * f + $1] } / Double(f) }
                r = sampleRate / Double(f)
            }
            guard abs(r - rate) > 0.5, y.count > 1 else { return y }
            let n = Int(Double(y.count) * rate / r)
            return (0..<n).map { i in
                let p = Double(i) * r / rate, k = min(Int(p), y.count - 2), t = p - Double(k)
                return y[k] + (y[k + 1] - y[k]) * t
            }
        }
        let sp: [SpeakerIR?] = speakers.map { s in
            guard let s else { return nil }
            let pre = max(1, Int((Double(s.pre) * rate / sampleRate).rounded()))
            return SpeakerIR(h: conv(s.h), pre: pre, arrival: s.arrival, snr: s.snr, consistency: s.consistency)
        }
        return MicResponse(sampleRate: rate, speakers: sp)
    }
}

/// A software copy of the measurement: from the identified room model it synthesises what a microphone would record
/// of the *looping* test programme for any set of delays, runs it through the same analysis the real measurement uses
/// (deconvolution weighting, impulse-response extraction, boominess score) and returns the score — in milliseconds,
/// with no sound and no noise. Because the programme loops with an exact period, the steady-state recording is computed
/// exactly in the frequency domain, with fractional delays as phase factors.
public final class DigitalTwin {
    public let rate: Double
    public let period: Int                     // samples; power of two
    public let speakers: Int
    private let fft: FFT
    private struct Mic { var hre: [[Double]], him: [[Double]]; var weight: [Double]; var arrival: [Double] }
    private let mics: [Mic]

    /// `probe`: one period of the looping programme at `rate` (length a power of two). Microphone responses are resampled
    /// to `rate`. Returns nil unless every microphone identified every speaker.
    public init?(mics responses: [MicResponse], probe: [Float], rate: Double, regularization: Double = 1e-3) {
        let n = probe.count
        guard n >= 1024, n & (n - 1) == 0, !responses.isEmpty else { return nil }
        let rs = responses.map { $0.resampled(to: rate) }
        guard let count = rs.first?.speakers.count, count > 0,
              rs.allSatisfy({ $0.speakers.count == count && $0.speakers.allSatisfy { $0 != nil } }) else { return nil }
        self.rate = rate; period = n; speakers = count
        let f = FFT(size: n)
        fft = f
        var xr = probe.map(Double.init), xi = [Double](repeating: 0, count: n)
        f.transform(&xr, &xi)
        var mean = 0.0
        for k in 0..<n { mean += xr[k] * xr[k] + xi[k] * xi[k] }
        let eps = regularization * mean / Double(n)
        // Deconvolution weighting of the real measurement: the recovered response is H · |X|² / (|X|² + ε).
        let weight = (0..<n).map { k -> Double in let p = xr[k] * xr[k] + xi[k] * xi[k]; return p / (p + eps) }
        var built: [Mic] = []
        for r in rs {
            var hre: [[Double]] = [], him: [[Double]] = []
            for s in r.speakers {
                let s = s!
                var re = [Double](repeating: 0, count: n), im = re
                // place the response where it happens in time: its first sample is `arrival − pre/rate` after the source
                let start = Int(((s.arrival - Double(s.pre) / rate) * rate).rounded())
                for (j, v) in s.h.enumerated() { re[((start + j) % n + n) % n] += v }
                f.transform(&re, &im)
                hre.append(Array(re[0...(n / 2)])); him.append(Array(im[0...(n / 2)]))
            }
            built.append(Mic(hre: hre, him: him, weight: weight, arrival: r.speakers.map { $0!.arrival }))
        }
        mics = built
    }

    public var micCount: Int { mics.count }

    /// Identified arrival (s) of every speaker at microphone `mic`.
    public func arrivals(mic: Int) -> [Double] { mics[mic].arrival }

    /// The combined response at one microphone for the given delays, as a circular array indexed by lag (samples since the
    /// programme's start), with the measurement's deconvolution weighting applied — what the real measurement recovers.
    public func response(mic: Int, delaysMs: [Double]) -> [Double] {
        let n = period, half = n / 2
        let m = mics[mic]
        var re = [Double](repeating: 0, count: n), im = re
        for i in 0..<speakers {
            let d = delaysMs[i] / 1000 * rate
            let ang = (-2 * Double.pi * d / Double(n)).truncatingRemainder(dividingBy: 2 * Double.pi)
            let cs = cos(ang), sn = sin(ang)
            var cr = 1.0, ci = 0.0
            for k in 0...half {
                let a = m.hre[i][k], b = m.him[i][k]
                re[k] += a * cr - b * ci; im[k] += a * ci + b * cr
                let ncr = cr * cs - ci * sn
                ci = cr * sn + ci * cs
                cr = ncr
            }
        }
        for k in 0...half { re[k] *= m.weight[k]; im[k] *= m.weight[k] }
        for k in 1..<half { re[n - k] = re[k]; im[n - k] = -im[k] }
        im[0] = 0; im[half] = 0
        fft.transform(&re, &im, inverse: true)
        return re
    }

    /// Predicted boominess index for the given delays (ms), mean over microphones; nil if a microphone's response
    /// cannot be extracted (as the real measurement would fail).
    public func score(delaysMs: [Double]) -> Double? {
        guard delaysMs.count == speakers else { return nil }
        let n = period
        var total = 0.0
        for (mi, m) in mics.enumerated() {
            let re = response(mic: mi, delaysMs: delaysMs)
            // The same fixed-onset cut the real measurement uses (first arrival from the model and the delays).
            var first = Double.infinity, last = -Double.infinity
            for i in 0..<speakers { let t = m.arrival[i] + delaysMs[i] / 1000; first = min(first, t); last = max(last, t) }
            let onset = Int((first * rate).rounded())
            guard let s = CalibrationAnalysis.cropScore(fs: rate, onsetIndex: onset, cropSec: CalibrationAnalysis.responseSeconds + (last - first),
                                                    at: { $0 >= 0 && $0 < n ? re[$0] : 0 })
            else { return nil }
            total += s
        }
        return total / Double(mics.count)
    }
}

public enum TwinOptimizer {
    public struct Result {
        public var delaysMs: [Double]          // smallest = 0
        public var score: Double
        public var evaluations: Int
    }

    /// Pattern search on the twin's exact score from each start: try ± every step on every speaker (all neighbours
    /// evaluated in parallel), move to the best one, repeat until nothing improves, then halve the step.
    public static func polish(twin: DigitalTwin, starts: [[Double]], steps: [Double] = [24, 10, 4, 1.5, 0.5],
                              maxDelayMs: Double = 1000) -> Result? {
        var best: Result?
        var evaluations = 0
        for start in starts where start.count == twin.speakers {
            var cur = start.map { min(maxDelayMs, max(0, $0)) }
            guard var curScore = twin.score(delaysMs: cur) else { continue }
            evaluations += 1
            for step in steps {
                for _ in 0..<10 {
                    var cands: [[Double]] = []
                    for i in cur.indices {
                        for sign in [1.0, -1.0] {
                            var c = cur
                            c[i] = min(maxDelayMs, max(0, c[i] + sign * step))
                            if abs(c[i] - cur[i]) > 1e-9 { cands.append(c) }
                        }
                    }
                    var scores = [Double](repeating: .infinity, count: cands.count)
                    scores.withUnsafeMutableBufferPointer { out in
                        let p = out.baseAddress!
                        DispatchQueue.concurrentPerform(iterations: cands.count) { j in p[j] = twin.score(delaysMs: cands[j]) ?? .infinity }
                    }
                    evaluations += cands.count
                    guard let bi = scores.indices.min(by: { scores[$0] < scores[$1] }), scores[bi] < curScore * 0.999 else { break }
                    cur = cands[bi]; curScore = scores[bi]
                }
            }
            let shift = cur.min() ?? 0
            if best == nil || curScore < best!.score { best = Result(delaysMs: cur.map { $0 - shift }, score: curScore, evaluations: 0) }
        }
        best?.evaluations = evaluations
        return best
    }
}
