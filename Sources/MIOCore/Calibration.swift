import Foundation

// Room auto-calibration math (platform independent; the hardware orchestration lives in the app target).
//
//  1. `SweepProbe.sweep`            exponential sine sweep played by one speaker at a time
//  2. `Deconvolver`                 recording ⊛ inverse(sweep) → impulse response (IR) of speaker → microphone
//  3. `CalibrationAnalysis.analyze` finds each speaker's slot in one recording, extracts its IR and arrival time
//  4. `RoomOptimizer.optimize`      chooses per-speaker delay and gain minimising a "boominess" index computed
//                                   from the IRs of every microphone

// MARK: - FFT

/// In-place radix-2 complex FFT.
public final class FFT {
    public let size: Int
    private let cosT: [Double]
    private let sinT: [Double]
    private let rev: [Int]

    public init(size: Int) {
        precondition(size >= 2 && size & (size - 1) == 0, "FFT size must be a power of two")
        self.size = size
        cosT = (0..<size / 2).map { cos(2 * Double.pi * Double($0) / Double(size)) }
        sinT = (0..<size / 2).map { sin(2 * Double.pi * Double($0) / Double(size)) }
        let bits = size.trailingZeroBitCount
        var r = [Int](repeating: 0, count: size)
        for i in 0..<size {
            var x = i, y = 0
            for _ in 0..<bits { y = (y << 1) | (x & 1); x >>= 1 }
            r[i] = y
        }
        rev = r
    }

    public func transform(_ re: inout [Double], _ im: inout [Double], inverse: Bool = false) {
        precondition(re.count == size && im.count == size)
        for i in 0..<size {
            let j = rev[i]
            if j > i { re.swapAt(i, j); im.swapAt(i, j) }
        }
        var len = 2
        while len <= size {
            let half = len / 2, step = size / len
            var start = 0
            while start < size {
                var k = 0
                for j in start..<start + half {
                    let wr = cosT[k], wi = inverse ? sinT[k] : -sinT[k]
                    let xr = re[j + half] * wr - im[j + half] * wi
                    let xi = re[j + half] * wi + im[j + half] * wr
                    re[j + half] = re[j] - xr; im[j + half] = im[j] - xi
                    re[j] += xr; im[j] += xi
                    k += step
                }
                start += len
            }
            len <<= 1
        }
        if inverse {
            let s = 1 / Double(size)
            for i in 0..<size { re[i] *= s; im[i] *= s }
        }
    }

    public static func nextPowerOfTwo(_ n: Int) -> Int {
        var p = 2
        while p < n { p <<= 1 }
        return p
    }
}

// MARK: - Probe signal and deconvolution

public enum SweepProbe {
    /// Exponential sine sweep (Farina) with short fades. `f2` defaults to min(16 kHz, 0.45·fs).
    public static func sweep(sampleRate fs: Double, seconds: Double = 1.0, f1: Double = 80,
                             f2: Double? = nil, amplitude: Float = 0.5) -> [Float] {
        let hi = f2 ?? min(16_000, 0.45 * fs)
        let n = Int(seconds * fs)
        let lnR = log(hi / f1)
        let fadeIn = Int(0.01 * fs), fadeOut = Int(0.02 * fs)
        var out = [Float](repeating: 0, count: n)
        for i in 0..<n {
            let t = Double(i) / fs
            var v = sin(2 * Double.pi * f1 * seconds / lnR * (exp(t * lnR / seconds) - 1))
            if i < fadeIn { v *= 0.5 - 0.5 * cos(Double.pi * Double(i) / Double(fadeIn)) }
            if i >= n - fadeOut { v *= 0.5 - 0.5 * cos(Double.pi * Double(n - 1 - i) / Double(fadeOut)) }
            out[i] = Float(v) * amplitude
        }
        return out
    }
}

public enum Deconvolver {
    /// Regularised spectral division: IR[n] such that recording ≈ probe ⊛ IR. Same length as `recording`;
    /// an IR peak at index n means the probe (placed at index 0) arrived n samples later.
    /// `regularization` is relative to the probe's mean spectral power: larger = less noise amplification in bins where
    /// the probe has little energy (music), smaller = sharper for flat probes (sweeps).
    public static func impulseResponse(recording: [Float], probe: [Float], regularization: Double = 1e-4) -> [Float] {
        guard !recording.isEmpty, !probe.isEmpty else { return [] }
        let n = FFT.nextPowerOfTwo(recording.count + probe.count)
        let fft = FFT(size: n)
        var xr = [Double](repeating: 0, count: n), xi = xr
        var yr = xr, yi = xr
        for i in 0..<probe.count { xr[i] = Double(probe[i]) }
        for i in 0..<recording.count { yr[i] = Double(recording[i]) }
        fft.transform(&xr, &xi)
        fft.transform(&yr, &yi)
        var mean = 0.0
        for k in 0..<n { mean += xr[k] * xr[k] + xi[k] * xi[k] }
        let eps = regularization * mean / Double(n)                     // keeps out-of-band bins from blowing up the noise
        for k in 0..<n {
            let p = xr[k] * xr[k] + xi[k] * xi[k] + eps
            // Y · conj(X) / (|X|² + ε)
            let re = (yr[k] * xr[k] + yi[k] * xi[k]) / p
            let im = (yi[k] * xr[k] - yr[k] * xi[k]) / p
            yr[k] = re; yi[k] = im
        }
        fft.transform(&yr, &yi, inverse: true)
        return (0..<recording.count).map { Float(yr[$0]) }
    }
}

// MARK: - Measurement → impulse responses

public enum Resampler {
    /// Linear-interpolation resampling (good enough for estimating a probe at another device's sample rate).
    public static func linear(_ x: [Float], from: Double, to: Double) -> [Float] {
        guard from != to, x.count > 1 else { return x }
        let n = Int(Double(x.count) * to / from)
        var out = [Float](repeating: 0, count: n)
        let step = from / to
        for i in 0..<n {
            let p = Double(i) * step
            let k = min(Int(p), x.count - 2)
            let f = Float(p - Double(k))
            out[i] = x[k] + (x[k + 1] - x[k]) * f
        }
        return out
    }
}

public enum SegmentPicker {
    /// Start indices of `count` non-overlapping blocks of `seconds` with the most energy (skips silent intros), in
    /// ascending order. Cycles through the blocks if the clip has fewer than `count`.
    public static func loudest(_ x: [Float], sampleRate: Double, seconds: Double, count: Int) -> [Int] {
        let len = Int(seconds * sampleRate)
        guard len > 0, x.count >= len, count > 0 else { return [] }
        let blocks = x.count / len
        var energy = [(Int, Double)]()
        for b in 0..<blocks {
            var e = 0.0
            for i in (b * len)..<((b + 1) * len) { e += Double(x[i]) * Double(x[i]) }
            energy.append((b * len, e))
        }
        energy.sort { $0.1 > $1.1 }
        let top = energy.prefix(min(count, blocks)).map(\.0).sorted()
        return (0..<count).map { top[$0 % top.count] }
    }

    /// Scales the segment to a fixed RMS (so every slot is equally loud before the user's volume).
    public static func normalized(_ x: ArraySlice<Float>, rms target: Float = 0.12, peakLimit: Float = 0.9) -> [Float] {
        var e: Float = 0, pk: Float = 0
        for v in x { e += v * v; pk = max(pk, abs(v)) }
        let rms = (e / Float(max(1, x.count))).squareRoot()
        guard rms > 1e-6 else { return Array(x) }
        let g = min(target / rms, peakLimit / max(pk, 1e-6))
        return x.map { $0 * g }
    }
}

/// One slot of the measurement schedule: `speaker` plays the probe starting `startSec` after the source started.
public struct SlotSpec {
    public var speaker: Int
    public var gain: Double              // amplitude the probe was played with (emphasis)
    public var startSec: Double          // source time the probe starts at, including any deliberate offset
    public var appliedDelayMs: Double    // delay the router applied to this speaker while measuring
    public init(speaker: Int, gain: Double, startSec: Double, appliedDelayMs: Double) {
        self.speaker = speaker; self.gain = gain; self.startSec = startSec; self.appliedDelayMs = appliedDelayMs
    }
}

public struct SpeakerIR {
    public var h: [Double]               // starts `pre` samples before the onset, gain-normalised
    public var pre: Int
    /// Onset time of this speaker at the microphone, in the router's source timeline with the applied delay removed.
    /// Only differences between speakers of the same microphone are meaningful (the mic's own latency is common).
    public var arrival: Double
    public var snr: Double
    public var consistency: Double       // correlation of the independent passes (1 when only one pass)
}

public struct MicResponse {
    public var sampleRate: Double
    public var speakers: [SpeakerIR?]    // nil = speaker not heard by this microphone
    public init(sampleRate: Double, speakers: [SpeakerIR?]) { self.sampleRate = sampleRate; self.speakers = speakers }
}

public enum CalibrationAnalysis {
    /// `probes[k]` is the (unit-gain) signal that slot `k` played. Each slot is deconvolved on its own recording window,
    /// so the probes may differ from slot to slot (sweeps, or different excerpts of a song).
    public static func analyze(recording: [Float], sampleRate fs: Double, probes: [[Float]], slots: [SlotSpec],
                               speakerCount: Int, windowSec: Double = 1.8, irSec: Double = 0.3,
                               minSNR: Double = 15, regularization: Double = 1e-3) -> MicResponse {
        precondition(probes.count == slots.count, "one probe per slot")
        let len = Int(irSec * fs), pre = max(1, Int(0.001 * fs)), back = Int(0.03 * fs)
        let searchLen = Int((windowSec + 0.1) * fs)
        struct Pass { var h: [Double]; var arrival: Double; var gain: Double; var snr: Double }
        var passes = [[Pass]](repeating: [], count: speakerCount)

        for (k, s) in slots.enumerated() where s.speaker >= 0 && s.speaker < speakerCount && s.gain > 0 {
            let probe = probes[k]
            let lo = max(0, Int((s.startSec + s.appliedDelayMs / 1000 - 0.1) * fs))
            let hi = min(recording.count, lo + probe.count + searchLen + len)
            guard !probe.isEmpty, hi - lo > probe.count else { continue }
            let ir = Deconvolver.impulseResponse(recording: Array(recording[lo..<hi]), probe: probe, regularization: regularization)

            var mags = [Float](); mags.reserveCapacity(ir.count / 5 + 1)
            for i in stride(from: 0, to: ir.count, by: 5) { mags.append(abs(ir[i])) }
            mags.sort()
            let floor = Double(mags[mags.count / 2]) + 1e-12

            let last = min(ir.count - 1, searchLen)
            var p = 0
            for i in 0...last where abs(ir[i]) > abs(ir[p]) { p = i }
            let peak = Double(abs(ir[p]))
            guard peak / floor >= minSNR else { continue }
            var onset = p
            for j in max(0, p - back)...p where Double(abs(ir[j])) >= 0.3 * peak { onset = j; break }
            var h = [Double](repeating: 0, count: pre + len)
            for t in 0..<(pre + len) {
                let idx = onset - pre + t
                if idx >= 0 && idx < ir.count { h[t] = Double(ir[idx]) / s.gain }
            }
            let arrival = Double(lo + onset) / fs - s.startSec - s.appliedDelayMs / 1000
            passes[s.speaker].append(Pass(h: h, arrival: arrival, gain: s.gain, snr: peak / floor))
        }

        let speakers: [SpeakerIR?] = passes.map { list in
            guard !list.isEmpty else { return nil }
            let w = list.map { $0.gain * $0.gain }
            let wsum = w.reduce(0, +)
            var h = [Double](repeating: 0, count: pre + len)
            var arrival = 0.0
            for (k, p) in list.enumerated() {
                arrival += w[k] * p.arrival / wsum
                for t in 0..<h.count { h[t] += w[k] * p.h[t] / wsum }
            }
            var consistency = 1.0
            if list.count >= 2 {
                let a = list[0].h, b = list[1].h
                var ab = 0.0, aa = 0.0, bb = 0.0
                for t in 0..<a.count { ab += a[t] * b[t]; aa += a[t] * a[t]; bb += b[t] * b[t] }
                consistency = ab / (sqrt(aa * bb) + 1e-18)
            }
            return SpeakerIR(h: h, pre: pre, arrival: arrival, snr: list.map(\.snr).min() ?? 0, consistency: consistency)
        }
        return MicResponse(sampleRate: fs, speakers: speakers)
    }

    /// Convenience: every slot played the same probe.
    public static func analyze(recording: [Float], sampleRate fs: Double, probe: [Float], slots: [SlotSpec],
                               speakerCount: Int, windowSec: Double = 1.8, irSec: Double = 0.3,
                               minSNR: Double = 15, regularization: Double = 1e-4) -> MicResponse {
        analyze(recording: recording, sampleRate: fs, probes: Array(repeating: probe, count: slots.count), slots: slots,
                speakerCount: speakerCount, windowSec: windowSec, irSec: irSec, minSNR: minSNR, regularization: regularization)
    }
}

// MARK: - Joint identification (all speakers playing together)

/// One trial of a simultaneous measurement: every speaker plays the same programme with its own gain and delay.
public struct JointTrial {
    public var startSec: Double          // source time at which this trial's probe excerpt starts
    public var gains: [Double]           // per speaker, relative to the user's volume (≤ 1: emphasis = others turned down)
    public var delaysMs: [Double]        // per speaker, delay applied during this trial
    public init(startSec: Double, gains: [Double], delaysMs: [Double]) {
        self.startSec = startSec; self.gains = gains; self.delaysMs = delaysMs
    }
}

extension CalibrationAnalysis {
    /// Pulls a speaker's impulse response out of a deconvolved/identified IR (index = lag + pad).
    static func extractIR(_ h: [Double], fs: Double, pad: Int, searchEnd: Int, irSec: Double, minSNR: Double,
                          backSec: Double = 0.03) -> (h: [Double], arrival: Double, snr: Double)? {
        let limit = min(h.count / 2, searchEnd)
        guard limit > 8 else { return nil }
        var mags = [Double](); mags.reserveCapacity(h.count / 14 + 1)
        for i in stride(from: 0, to: h.count / 2, by: 7) { mags.append(abs(h[i])) }
        mags.sort()
        let floor = mags[mags.count / 2] + 1e-12
        var p = 0
        for i in 0..<limit where abs(h[i]) > abs(h[p]) { p = i }
        let peak = abs(h[p])
        guard peak / floor >= minSNR else { return nil }
        let back = Int(backSec * fs), pre = max(1, Int(0.001 * fs)), len = Int(irSec * fs)
        var onset = p
        for j in max(0, p - back)...p where abs(h[j]) >= 0.3 * peak { onset = j; break }
        var out = [Double](repeating: 0, count: pre + len)
        for t in 0..<(pre + len) { let i = onset - pre + t; if i >= 0 && i < h.count { out[t] = h[i] } }
        return (out, Double(onset - pad) / fs, peak / floor)
    }

    /// Impulse response of "all speakers together" for a single trial (used to score a configuration as it really sounds).
    public static func combinedResponse(recording: [Float], sampleRate fs: Double, probe: [Float], startSec: Double,
                                        padSec: Double = 0.1, tailSec: Double = 1.2, irSec: Double = 0.3,
                                        minSNR: Double = 8, regularization: Double = 1e-3,
                                        continuous: Bool = false, backSec: Double = 0.03) -> MicResponse? {
        let pad = Int(padSec * fs)
        let lo = Int(startSec * fs) - pad
        // `continuous`: the programme keeps playing after the excerpt, so the window must end with it.
        let len = pad + probe.count + (continuous ? 0 : Int(tailSec * fs))
        var win = [Float](repeating: 0, count: len)
        for i in 0..<len { let j = lo + i; if j >= 0 && j < recording.count { win[i] = recording[j] } }
        let ir = Deconvolver.impulseResponse(recording: win, probe: probe, regularization: regularization).map(Double.init)
        guard let e = extractIR(ir, fs: fs, pad: pad, searchEnd: pad + Int(tailSec * fs), irSec: irSec, minSNR: minSNR,
                                 backSec: backSec) else { return nil }
        let pre = max(1, Int(0.001 * fs))
        return MicResponse(sampleRate: fs, speakers: [SpeakerIR(h: e.h, pre: pre, arrival: 0, snr: e.snr, consistency: 1)])
    }

    /// How much of the recorded window a plain "probe ⊛ short impulse response" model explains (0…1).
    /// Clean measurements score high; other sounds in the room (speech, TV) are not explained and pull it down.
    public static func fitQuality(recording: [Float], sampleRate fs: Double, probe: [Float], startSec: Double,
                                  padSec: Double = 0.1, tailSec: Double = 1.2, modelSec: Double = 0.8,
                                  regularization: Double = 1e-3, continuous: Bool = false) -> Double {
        let pad = Int(padSec * fs)
        let lo = Int(startSec * fs) - pad
        let len = pad + probe.count + (continuous ? 0 : Int(tailSec * fs))
        let n = FFT.nextPowerOfTwo(len + probe.count)
        let fft = FFT(size: n)
        var xr = [Double](repeating: 0, count: n), xi = xr, yr = xr, yi = xr
        for i in 0..<probe.count { xr[i] = Double(probe[i]) }
        for i in 0..<len { let j = lo + i; if j >= 0 && j < recording.count { yr[i] = Double(recording[j]) } }
        let yEnergy = yr.reduce(0) { $0 + $1 * $1 }
        guard yEnergy > 0 else { return 0 }
        fft.transform(&xr, &xi); fft.transform(&yr, &yi)
        var mean = 0.0
        for k in 0..<n { mean += xr[k] * xr[k] + xi[k] * xi[k] }
        let eps = regularization * mean / Double(n)
        var hr = [Double](repeating: 0, count: n), hi = hr
        for k in 0..<n {
            let p = xr[k] * xr[k] + xi[k] * xi[k] + eps
            hr[k] = (yr[k] * xr[k] + yi[k] * xi[k]) / p
            hi[k] = (yi[k] * xr[k] - yr[k] * xi[k]) / p
        }
        fft.transform(&hr, &hi, inverse: true)
        // Keep a causal, finite-length response only: lags −20 ms … modelSec.
        let a = max(0, pad - Int(0.02 * fs)), b = min(n, pad + Int(modelSec * fs))
        for i in 0..<n where i < a || i >= b { hr[i] = 0 }
        hi = [Double](repeating: 0, count: n)
        fft.transform(&hr, &hi)
        // Re-derive X (it was overwritten in place): rebuild and multiply.
        var xr2 = [Double](repeating: 0, count: n), xi2 = xr2
        for i in 0..<probe.count { xr2[i] = Double(probe[i]) }
        fft.transform(&xr2, &xi2)
        var pr = [Double](repeating: 0, count: n), pi = pr
        for k in 0..<n { pr[k] = xr2[k] * hr[k] - xi2[k] * hi[k]; pi[k] = xr2[k] * hi[k] + xi2[k] * hr[k] }
        fft.transform(&pr, &pi, inverse: true)
        var res = 0.0, ey = 0.0
        for i in 0..<len {
            let y = (lo + i >= 0 && lo + i < recording.count) ? Double(recording[lo + i]) : 0
            res += (y - pr[i]) * (y - pr[i]); ey += y * y
        }
        return max(0, min(1, 1 - res / max(ey, 1e-18)))
    }

    /// Which speakers does a microphone actually hear? From the recorded power in trials with different volume patterns
    /// (`levels[k]` = mean-square level of trial k, `gains[k][i]` = speaker i's gain), solves level_k ≈ Σ g_ik² · P_i and
    /// returns each speaker's share of the total power (0…1). A speaker the microphone cannot hear (a virtual device, a
    /// speaker in another room) gets a share near 0.
    public static func audibleShares(levels: [Double], gains: [[Double]]) -> [Double] {
        let K = levels.count, n = gains.first?.count ?? 0
        guard K > 0, n > 0, gains.count == K else { return [] }
        var m = [Double](repeating: 0, count: n * n), r = [Double](repeating: 0, count: n)
        for k in 0..<K {
            for i in 0..<n {
                let ai = gains[k][i] * gains[k][i]
                r[i] += ai * levels[k]
                for j in 0..<n { m[i * n + j] += ai * gains[k][j] * gains[k][j] }
            }
        }
        for i in 0..<n { m[i * n + i] += 1e-9 * m[i * n + i] + 1e-15 }
        for c in 0..<n {                                         // Gaussian elimination with partial pivoting
            var piv = c
            for q in (c + 1)..<max(n, c + 1) where abs(m[q * n + c]) > abs(m[piv * n + c]) { piv = q }
            if piv != c { for j in 0..<n { m.swapAt(c * n + j, piv * n + j) }; r.swapAt(c, piv) }
            let d = m[c * n + c]
            guard abs(d) > 1e-300 else { continue }
            for q in (c + 1)..<max(n, c + 1) {
                let f = m[q * n + c] / d
                for j in c..<n { m[q * n + j] -= f * m[c * n + j] }
                r[q] -= f * r[c]
            }
        }
        var p = [Double](repeating: 0, count: n)
        for i in stride(from: n - 1, through: 0, by: -1) {
            var v = r[i]
            for j in (i + 1)..<max(n, i + 1) { v -= m[i * n + j] * p[j] }
            p[i] = abs(m[i * n + i]) > 1e-300 ? max(0, v / m[i * n + i]) : 0
        }
        let total = p.reduce(0, +)
        return total > 0 ? p.map { $0 / total } : p
    }

    /// Separates every speaker's impulse response from trials in which all of them play together.
    ///
    /// Per trial k the recording satisfies  Y_k = X_k · Σ_i g_ik · e^{-jω d_ik} · H_i(ω)  (all speakers play the same
    /// excerpt X_k with gain g_ik and delay d_ik). Because gains (emphasis) and delays differ between trials, the
    /// per-frequency system is solvable for the n unknown H_i by weighted, regularised least squares.
    public static func identify(recording: [Float], sampleRate fs: Double, trials: [JointTrial], probes: [[Float]],
                                speakerCount n: Int, padSec: Double = 0.1, tailSec: Double = 1.2, irSec: Double = 0.3,
                                minSNR: Double = 8, regularization: Double = 1e-3,
                                continuous: Bool = false) -> MicResponse {
        let K = trials.count
        precondition(K == probes.count && K >= n && n >= 1, "need at least as many trials as speakers")
        let none = MicResponse(sampleRate: fs, speakers: Array(repeating: nil, count: n))
        guard let probeLen = probes.map(\.count).max(), probeLen > 0 else { return none }
        let pad = Int(padSec * fs)
        let maxD = trials.flatMap(\.delaysMs).max() ?? 0
        let winLen = pad + probeLen + (continuous ? 0 : Int((maxD / 1000 + tailSec) * fs))
        let N = FFT.nextPowerOfTwo(winLen + probeLen)
        let half = N / 2 + 1
        let fft = FFT(size: N)

        var gre = [[Double]](), gim = [[Double]](), wts = [[Double]]()
        for k in 0..<K {
            var xr = [Double](repeating: 0, count: N), xi = xr, yr = xr, yi = xr
            for i in 0..<probes[k].count { xr[i] = Double(probes[k][i]) }
            let lo = Int(trials[k].startSec * fs) - pad
            for i in 0..<winLen { let j = lo + i; if j >= 0 && j < recording.count { yr[i] = Double(recording[j]) } }
            fft.transform(&xr, &xi); fft.transform(&yr, &yi)
            var mean = 0.0
            for b in 0..<half { mean += xr[b] * xr[b] + xi[b] * xi[b] }
            let eps = regularization * mean / Double(half)
            var a = [Double](repeating: 0, count: half), c = a, w = a
            for b in 0..<half {
                let p = xr[b] * xr[b] + xi[b] * xi[b]
                a[b] = (yr[b] * xr[b] + yi[b] * xi[b]) / (p + eps)
                c[b] = (yi[b] * xr[b] - yr[b] * xi[b]) / (p + eps)
                w[b] = p / (p + eps)
            }
            gre.append(a); gim.append(c); wts.append(w)
        }

        var hre = [[Double]](repeating: [Double](repeating: 0, count: N), count: n)
        var him = hre
        var mr = [Double](repeating: 0, count: n * n), mi = mr
        var rr = [Double](repeating: 0, count: n), ri = rr
        var ar = rr, ai = rr
        var num = 0.0, den = 0.0
        let twoPiOverN = 2 * Double.pi / Double(N)
        for b in 0..<half {
            for i in 0..<(n * n) { mr[i] = 0; mi[i] = 0 }
            for i in 0..<n { rr[i] = 0; ri[i] = 0 }
            for k in 0..<K {
                let w = wts[k][b]
                if w < 1e-9 { continue }
                for i in 0..<n {
                    let ph = twoPiOverN * Double(b) * (trials[k].delaysMs[i] / 1000 * fs)
                    ar[i] = trials[k].gains[i] * cos(ph); ai[i] = -trials[k].gains[i] * sin(ph)
                }
                let gr = gre[k][b], gi = gim[k][b]
                for i in 0..<n {
                    for j in 0..<n {
                        mr[i * n + j] += w * (ar[i] * ar[j] + ai[i] * ai[j])
                        mi[i * n + j] += w * (ar[i] * ai[j] - ai[i] * ar[j])
                    }
                    rr[i] += w * (ar[i] * gr + ai[i] * gi)
                    ri[i] += w * (ar[i] * gi - ai[i] * gr)
                }
            }
            var tr = 0.0
            for i in 0..<n { tr += mr[i * n + i] }
            let lam = 1e-3 * tr / Double(n) + 1e-12
            for i in 0..<n { mr[i * n + i] += lam }
            let sol = solveComplex(&mr, &mi, &rr, &ri, n)
            for i in 0..<n { hre[i][b] = sol.0[i]; him[i][b] = sol.1[i] }
            // Fit quality: weighted residual of the model against the per-trial transfer functions.
            for k in 0..<K {
                let w = wts[k][b]
                if w < 1e-9 { continue }
                var pr = 0.0, pi = 0.0
                for i in 0..<n {
                    let ph = twoPiOverN * Double(b) * (trials[k].delaysMs[i] / 1000 * fs)
                    let cr = trials[k].gains[i] * cos(ph), ci = -trials[k].gains[i] * sin(ph)
                    pr += cr * sol.0[i] - ci * sol.1[i]; pi += cr * sol.1[i] + ci * sol.0[i]
                }
                let er = gre[k][b] - pr, ei = gim[k][b] - pi
                num += w * (er * er + ei * ei); den += w * (gre[k][b] * gre[k][b] + gim[k][b] * gim[k][b])
            }
        }
        let fit = max(0, min(1, 1 - num / max(den, 1e-18)))

        let pre = max(1, Int(0.001 * fs))
        let speakers: [SpeakerIR?] = (0..<n).map { i in
            var re = hre[i], im = him[i]
            for b in 1..<(N / 2) { re[N - b] = re[b]; im[N - b] = -im[b] }
            im[0] = 0; im[N / 2] = 0
            fft.transform(&re, &im, inverse: true)
            guard let e = extractIR(re, fs: fs, pad: pad, searchEnd: pad + Int(tailSec * fs), irSec: irSec, minSNR: minSNR)
            else { return nil }
            return SpeakerIR(h: e.h, pre: pre, arrival: e.arrival, snr: e.snr, consistency: fit)
        }
        return MicResponse(sampleRate: fs, speakers: speakers)
    }

    /// Solves A·x = b for a small dense complex system (Gaussian elimination with partial pivoting).
    private static func solveComplex(_ mr: inout [Double], _ mi: inout [Double], _ br: inout [Double], _ bi: inout [Double],
                                     _ n: Int) -> ([Double], [Double]) {
        for c in 0..<n {
            var piv = c, best = mr[c * n + c] * mr[c * n + c] + mi[c * n + c] * mi[c * n + c]
            for r in (c + 1)..<max(n, c + 1) {
                let v = mr[r * n + c] * mr[r * n + c] + mi[r * n + c] * mi[r * n + c]
                if v > best { best = v; piv = r }
            }
            if piv != c {
                for j in 0..<n { mr.swapAt(c * n + j, piv * n + j); mi.swapAt(c * n + j, piv * n + j) }
                br.swapAt(c, piv); bi.swapAt(c, piv)
            }
            let dr = mr[c * n + c], di = mi[c * n + c], dd = dr * dr + di * di + 1e-300
            for r in (c + 1)..<max(n, c + 1) {
                // f = M[r][c] / M[c][c]
                let fr = (mr[r * n + c] * dr + mi[r * n + c] * di) / dd
                let fi = (mi[r * n + c] * dr - mr[r * n + c] * di) / dd
                for j in c..<n {
                    mr[r * n + j] -= fr * mr[c * n + j] - fi * mi[c * n + j]
                    mi[r * n + j] -= fr * mi[c * n + j] + fi * mr[c * n + j]
                }
                br[r] -= fr * br[c] - fi * bi[c]
                bi[r] -= fr * bi[c] + fi * br[c]
            }
        }
        var xr = [Double](repeating: 0, count: n), xi = xr
        for r in stride(from: n - 1, through: 0, by: -1) {
            var sr = br[r], si = bi[r]
            for j in (r + 1)..<max(n, r + 1) {
                sr -= mr[r * n + j] * xr[j] - mi[r * n + j] * xi[j]
                si -= mr[r * n + j] * xi[j] + mi[r * n + j] * xr[j]
            }
            let dr = mr[r * n + r], di = mi[r * n + r], dd = dr * dr + di * di + 1e-300
            xr[r] = (sr * dr + si * di) / dd
            xi[r] = (si * dr - sr * di) / dd
        }
        return (xr, xi)
    }
}

// MARK: - Optimiser

public struct CalibrationOutcome {
    public var delaysMs: [Double]          // per speaker, smallest = 0
    public var gains: [Double]             // per speaker, 0.35…1
    public var scoreBefore: Double
    public var scoreAfter: Double
    public var micScoresBefore: [Double]
    public var micScoresAfter: [Double]
    public init(delaysMs: [Double], gains: [Double], scoreBefore: Double, scoreAfter: Double,
                micScoresBefore: [Double] = [], micScoresAfter: [Double] = []) {
        self.delaysMs = delaysMs; self.gains = gains; self.scoreBefore = scoreBefore; self.scoreAfter = scoreAfter
        self.micScoresBefore = micScoresBefore; self.micScoresAfter = micScoresAfter
    }
    /// Relative improvement of the boominess index, 0…1 (0 if nothing better was found).
    public var improvement: Double { scoreBefore > 0 ? max(0, (scoreBefore - scoreAfter) / scoreBefore) : 0 }
}

/// What is minimised, for one microphone, as a function of per-speaker delay d_i and gain g_i:
///
///     y(t) = Σ g_i · h_i(t − d_i)                              (all speakers play the same programme)
///     J    = Var_bands[ 10·log10 |Y(f)|² ]  +  λ · E_late / E_total
///
/// The first term is the spectral coloration (comb filtering / peaks and dips, in 1/6-octave bands between 100 Hz and
/// 8 kHz); the second is the share of energy arriving more than 50 ms after the first arrival (echo / reverb tail).
/// Both are what we hear as "울림". The score is averaged over all microphones.
public enum RoomOptimizer {
    public static let lateWeight = 40.0
    public static let minGain = 0.35
    static let earlyWindowSec = 0.05

    final class MicModel {
        let fs: Double, n: Int, len: Int, nfft: Int, pre: Int
        let h: [[Double]]
        let arrival: [Double]
        let k0: Int, k1: Int
        let hre: [[Double]], him: [[Double]]      // spectra for bins k0..<k1
        let bandStart: [Int]                      // indices into k0..<k1; last entry = k1 - k0
        var scratch: [Double]

        init?(_ mic: MicResponse) {
            guard !mic.speakers.isEmpty, mic.speakers.allSatisfy({ $0 != nil }) else { return nil }
            let sp = mic.speakers.map { $0! }
            fs = mic.sampleRate; n = sp.count
            let maxLen = sp.map { $0.h.count }.max() ?? 0
            len = maxLen
            pre = sp[0].pre
            h = sp.map { s in s.h + [Double](repeating: 0, count: maxLen - s.h.count) }
            arrival = sp.map(\.arrival)
            nfft = FFT.nextPowerOfTwo(maxLen + 1)
            let fft = FFT(size: nfft)
            var re = [[Double]](), im = [[Double]]()
            let binHz = fs / Double(nfft)
            let lo = max(1, Int((100 / binHz).rounded(.up)))
            let hi = min(nfft / 2 - 1, Int(min(8000, 0.45 * fs) / binHz))
            k0 = lo; k1 = max(lo + 1, hi)
            for s in 0..<n {
                var r = h[s] + [Double](repeating: 0, count: nfft - len), i = [Double](repeating: 0, count: nfft)
                fft.transform(&r, &i)
                re.append(Array(r[k0..<k1])); im.append(Array(i[k0..<k1]))
            }
            hre = re; him = im
            // 1/6-octave bands from 100 Hz.
            var edges = [0]
            var f = 100.0 * pow(2, 1.0 / 6)
            while true {
                let k = Int((f / binHz).rounded())
                if k >= k1 { break }
                if k - k0 > edges.last! { edges.append(k - k0) }
                f *= pow(2, 1.0 / 6)
            }
            edges.append(k1 - k0)
            bandStart = edges
            scratch = [Double](repeating: 0, count: len + Int(3 * fs))
        }

        /// (spectral variance in dB², late-energy ratio) for the given absolute delays (s) and gains.
        func score(delays: [Double], gains: [Double]) -> (Double, Double) {
            var T = [Double](repeating: 0, count: n)
            var t0 = Double.infinity
            for i in 0..<n { T[i] = arrival[i] + delays[i]; t0 = min(t0, T[i]) }
            var shifts = [Int](repeating: 0, count: n)
            var maxShift = 0
            for i in 0..<n { shifts[i] = Int(((T[i] - t0) * fs).rounded()); maxShift = max(maxShift, shifts[i]) }
            guard len + maxShift <= scratch.count else { return (1e6, 1) }

            // Time domain: total and early energy of the summed IR.
            let total = len + maxShift
            for t in 0..<total { scratch[t] = 0 }
            for i in 0..<n {
                let g = gains[i], s = shifts[i]
                h[i].withUnsafeBufferPointer { hp in
                    scratch.withUnsafeMutableBufferPointer { c in
                        for t in 0..<len { c[s + t] += g * hp[t] }
                    }
                }
            }
            var energy = 0.0, early = 0.0
            let earlyEnd = min(total, pre + Int(RoomOptimizer.earlyWindowSec * fs))
            for t in 0..<total {
                let e = scratch[t] * scratch[t]
                energy += e
                if t >= pre && t < earlyEnd { early += e }
            }
            let late = energy > 0 ? max(0, 1 - early / energy) : 1

            // Frequency domain: band powers of Σ g_i H_i(f) e^{-j2πf·shift_i}.
            let bins = k1 - k0
            var pw = [Double](repeating: 0, count: bins)
            var re = [Double](repeating: 0, count: bins), im = re
            for i in 0..<n {
                let theta = 2 * Double.pi * Double(shifts[i]) / Double(nfft)
                let stepC = cos(theta), stepS = -sin(theta)
                var cr = cos(Double(k0) * theta), ci = -sin(Double(k0) * theta)
                let g = gains[i]
                for k in 0..<bins {
                    let a = hre[i][k], b = him[i][k]
                    re[k] += g * (a * cr - b * ci)
                    im[k] += g * (a * ci + b * cr)
                    let ncr = cr * stepC - ci * stepS
                    ci = cr * stepS + ci * stepC
                    cr = ncr
                }
            }
            for k in 0..<bins { pw[k] = re[k] * re[k] + im[k] * im[k] }
            var sum = 0.0, sumSq = 0.0
            let bands = bandStart.count - 1
            for b in 0..<bands {
                let a = bandStart[b], e = bandStart[b + 1]
                var p = 0.0
                for k in a..<e { p += pw[k] }
                let db = 10 * log10(p / Double(e - a) + 1e-18)
                sum += db; sumSq += db * db
            }
            let mean = sum / Double(bands)
            return (max(0, sumSq / Double(bands) - mean * mean), late)
        }
    }

    /// Boominess index of a single measured response (e.g. all speakers together, as they really sounded).
    public static func score(of mic: MicResponse) -> Double? {
        guard let m = MicModel(mic) else { return nil }
        let (v, l) = m.score(delays: [Double](repeating: 0, count: m.n), gains: [Double](repeating: 1, count: m.n))
        return v + lateWeight * l
    }

    /// `optimizeGains: false` keeps every gain exactly as given (the user decides loudness); only delays are solved.
    public static func optimize(mics: [MicResponse], baselineDelaysMs: [Double], baselineGains: [Double],
                                optimizeGains: Bool = true,
                                searchRangeMs: Double = 20, stepMs: Double = 0.25) -> CalibrationOutcome? {
        let models = mics.compactMap { MicModel($0) }
        guard let n = models.first?.n, n >= 1, models.allSatisfy({ $0.n == n }),
              baselineDelaysMs.count == n, baselineGains.count == n else { return nil }

        func acoustic(_ d: [Double], _ g: [Double]) -> [Double] {
            models.map { m in let (v, l) = m.score(delays: d, gains: g); return v + lateWeight * l }
        }
        func objective(_ d: [Double], _ g: [Double]) -> Double {
            let a = acoustic(d, g)
            var pen = 0.0
            if optimizeGains { for x in g { pen += (1 - x) * (1 - x) } }
            return a.reduce(0, +) / Double(a.count) + 2 * pen        // mild preference for keeping volumes up
        }

        let gainGrid = stride(from: minGain, through: 1.0 + 1e-9, by: 0.05).map { ($0 * 100).rounded() / 100 }
        func descend(_ d0: [Double], _ g0: [Double]) -> (d: [Double], g: [Double], s: Double) {
            var d = d0, g = g0
            var best = objective(d, g)
            for sweep in 0..<4 {
                var improved = false
                let range = [searchRangeMs, 2.0, 0.75, 0.75][sweep]
                let step = sweep == 0 ? max(1.0, stepMs) : stepMs
                for i in 0..<n {
                    let base = d[i]
                    for dd in stride(from: -range, through: range + 1e-9, by: step) where abs(dd) > 1e-9 {
                        let v = base + dd / 1000
                        guard v >= 0, v <= 1.0 else { continue }
                        var c = d; c[i] = v
                        let s = objective(c, g)
                        if s < best - 1e-9 { best = s; d = c; improved = true }
                    }
                    for gv in (optimizeGains ? gainGrid : []) where abs(gv - g[i]) > 1e-9 {
                        var c = g; c[i] = gv
                        let s = objective(d, c)
                        if s < best - 1e-9 { best = s; g = c; improved = true }
                    }
                }
                if !improved && sweep >= 2 { break }
            }
            return (d, g, best)
        }

        // Start 1: what is applied now.  Start 2: all speakers' first arrivals aligned.
        let d0 = baselineDelaysMs.map { $0 / 1000 }
        let g0 = optimizeGains ? baselineGains.map { min(1, max(minGain, $0)) } : baselineGains
        var meanArrival = [Double](repeating: 0, count: n)
        for m in models {
            let lo = m.arrival.min() ?? 0
            for i in 0..<n { meanArrival[i] += (m.arrival[i] - lo) / Double(models.count) }
        }
        let latest = meanArrival.max() ?? 0
        let aligned = (0..<n).map { min(1.0, max(0, latest - meanArrival[$0])) }

        let r1 = descend(d0, g0), r2 = descend(aligned, g0)
        var best = r1.s <= r2.s ? r1 : r2
        let before = objective(d0, g0)
        if before <= best.s { best = (d0, g0, before) }           // never make things worse than the current setting

        let shift = best.d.min() ?? 0
        let finalD = best.d.map { ($0 - shift) * 1000 }
        let beforeAc = acoustic(d0, g0)
        let afterAc = acoustic(best.d, best.g)
        return CalibrationOutcome(delaysMs: finalD, gains: best.g,
                                  scoreBefore: beforeAc.reduce(0, +) / Double(beforeAc.count),
                                  scoreAfter: afterAc.reduce(0, +) / Double(afterAc.count),
                                  micScoresBefore: beforeAc, micScoresAfter: afterAc)
    }
}
