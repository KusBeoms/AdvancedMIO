import XCTest
@testable import MIOCore

/// The calibration plays the whole song once while every speaker in turn is emphasised, then solves the arrival times from
/// the complete recording. This runs that against a simulated room.
final class WholeSongAlignmentTests: XCTestCase {
    private struct Rng {
        var s: UInt64
        mutating func next() -> UInt64 {
            s &+= 0x9E37_79B9_7F4A_7C15
            var z = s
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
        mutating func unit() -> Double { Double(next() >> 11) / Double(1 << 53) }
        mutating func normal() -> Double { (-2 * log(max(unit(), 1e-12))).squareRoot() * cos(2 * Double.pi * unit()) }
    }

    /// Harmonic notes with decay plus hi-hat like noise: a stand-in for music, `seconds` long.
    private func music(seconds: Double, fs: Double, seed: UInt64) -> [Float] {
        var rng = Rng(s: seed)
        let n = Int(seconds * fs)
        var out = [Double](repeating: 0, count: n)
        let notes = [110.0, 123.5, 146.8, 164.8, 196, 220, 247, 293.7, 329.6, 392, 440, 523, 587, 659, 784, 880]
        var t = 0.0
        while t < seconds {
            let f = notes[Int(rng.unit() * Double(notes.count)) % notes.count], amp = 0.4 + 0.6 * rng.unit()
            let onset = Int(t * fs), len = Int(0.45 * fs)
            for i in 0..<len where onset + i < n {
                var v = 0.0
                for h in 1...4 { v += sin(2 * Double.pi * f * Double(h) * Double(i) / fs) / Double(h) }
                out[onset + i] += amp * exp(-Double(i) / (0.12 * fs)) * v
            }
            t += 0.18 + 0.2 * rng.unit()
        }
        var hat = 0.0
        for k in 0..<Int(seconds / 0.25) {
            let onset = Int(Double(k) * 0.25 * fs)
            for i in 0..<Int(0.04 * fs) where onset + i < n {
                let w = rng.unit() * 2 - 1; let d = w - hat; hat = w
                out[onset + i] += 0.25 * d * exp(-Double(i) / (0.012 * fs))
            }
        }
        let rms = (out.reduce(0) { $0 + $1 * $1 } / Double(n)).squareRoot()
        return out.map { Float($0 / rms * 0.12) }
    }

    /// A speaker's response: a direct sound, a few early reflections and a decaying noise tail; `pre` samples before the direct sound.
    private func speaker(arrival: Double, fs: Double, seed: UInt64) -> SpeakerIR {
        var rng = Rng(s: seed)
        let pre = Int(0.001 * fs), len = Int(1.0 * fs)
        var h = [Double](repeating: 0, count: pre + len)
        h[pre] = 1
        for _ in 0..<5 { h[pre + Int((0.003 + 0.03 * rng.unit()) * fs)] += (rng.unit() < 0.5 ? -1 : 1) * (0.1 + 0.3 * rng.unit()) }
        for t in (pre + Int(0.01 * fs))..<h.count { h[t] += 0.1 * rng.normal() * exp(-Double(t - pre) / (0.12 * fs)) }
        return SpeakerIR(h: h, pre: pre, arrival: arrival, snr: 100, consistency: 1)
    }

    /// `x ⊛ h` (linear), computed in blocks.
    private func convolve(_ x: [Float], _ h: [Double]) -> [Double] {
        let block = 1 << 16, nfft = FFT.nextPowerOfTwo(block + h.count)
        let fft = FFT(size: nfft)
        var hr = [Double](repeating: 0, count: nfft), hi = hr
        for i in 0..<h.count { hr[i] = h[i] }
        fft.transform(&hr, &hi)
        var y = [Double](repeating: 0, count: x.count + h.count - 1)
        var xr = [Double](repeating: 0, count: nfft), xi = xr
        var start = 0
        while start < x.count {
            let m = min(block, x.count - start)
            for i in 0..<nfft { xr[i] = 0; xi[i] = 0 }
            for i in 0..<m { xr[i] = Double(x[start + i]) }
            fft.transform(&xr, &xi)
            for k in 0..<nfft { let a = xr[k] * hr[k] - xi[k] * hi[k], b = xr[k] * hi[k] + xi[k] * hr[k]; xr[k] = a; xi[k] = b }
            fft.transform(&xr, &xi, inverse: true)
            for i in 0..<(m + h.count - 1) { y[start + i] += xr[i] }
            start += m
        }
        return y
    }

    func testArrivalsFromAWholeSongRecording() {
        let fs = 24_000.0, n = 3, K = n + 1
        let arrivals = [0.0062, 0.0141, 0.0095]
        let room = MicResponse(sampleRate: fs, speakers: arrivals.enumerated().map { speaker(arrival: $1, fs: fs, seed: UInt64(21 + $0)) })
        let applied = [0.0, 35.0, 12.0]                                   // ms, what the router applies when measuring
        let song = music(seconds: 80, fs: fs, seed: 4)
        let Lseg = 4.0, ramp = 1.0, lead = 0.8, emphasis = 0.1
        let dMax = applied.max()! / 1000
        let period = Lseg + 2 * dMax + ramp + 0.3
        let P = ((Int((80 - 1 - lead - 2 * dMax - Lseg - 0.8) / period) + 1) / K) * K
        XCTAssertGreaterThanOrEqual(P, 2 * K)
        var trials: [JointTrial] = []
        for p in 0..<P {
            let k = p % K
            trials.append(JointTrial(startSec: lead + Double(p) * period + dMax,
                                     gains: (0..<n).map { k == 0 || $0 == k - 1 ? 1 : emphasis }, delaysMs: applied))
        }
        func plateau(_ p: Int) -> Double { lead + Double(p) * period }
        func gains(at t: Double) -> [Double] {
            var k = 0
            for j in 1..<P where t >= plateau(j) - ramp { k = j }
            if k == 0 { return trials[0].gains }
            let u = min(1, max(0, (t - (plateau(k) - ramp)) / ramp)), s = u * u * (3 - 2 * u)
            return (0..<n).map { trials[k - 1].gains[$0] + (trials[k].gains[$0] - trials[k - 1].gains[$0]) * s }
        }

        var rec = [Double](repeating: 0, count: song.count)
        var rng = Rng(s: 8)
        for i in 0..<n {
            let sp = room.speakers[i]!
            let x = (0..<song.count).map { Float(Double(song[$0]) * gains(at: Double($0) / fs)[i]) }
            let y = convolve(x, sp.h)
            let lag = Int(((sp.arrival + applied[i] / 1000) * fs).rounded()) - sp.pre
            for t in 0..<song.count where t - lag >= 0 && t - lag < y.count { rec[t] += y[t - lag] }
        }
        let recording = rec.map { Float($0 + 0.003 * rng.normal()) }
        let probes = trials.map { Array(song[Int($0.startSec * fs)..<Int(($0.startSec + Lseg) * fs)]) }
        let r = CalibrationAnalysis.identify(recording: recording, sampleRate: fs, trials: trials, probes: probes, speakerCount: n,
                                             irSec: CalibrationAnalysis.responseSeconds, continuous: true)
        let got = r.speakers.map { $0?.arrival }
        XCTAssertTrue(got.allSatisfy { $0 != nil }, "\(got)")
        // only differences between speakers mean anything
        for i in 1..<n {
            let want = (arrivals[i] - arrivals[0]) * 1000, have = ((got[i] ?? 0) - (got[0] ?? 0)) * 1000
            XCTAssertEqual(have, want, accuracy: 0.5, "speaker \(i)")
        }
        // the delays that align them
        let d = CalibrationAnalysis.alignedDelays([r])!
        let t = (0..<n).map { arrivals[$0] * 1000 + d[$0] }
        XCTAssertEqual(t.max()! - t.min()!, 0, accuracy: 0.5)
        XCTAssertEqual(d.min()!, 0, accuracy: 1e-9)
    }

    private func ir(arrival: Double) -> SpeakerIR { SpeakerIR(h: [1], pre: 0, arrival: arrival, snr: 40, consistency: 1) }

    func testAlignedDelaysAndSpread() {
        let a = MicResponse(sampleRate: 8000, speakers: [ir(arrival: 0.010), ir(arrival: 0.030), ir(arrival: 0.020)])
        let b = MicResponse(sampleRate: 8000, speakers: [ir(arrival: 0.012), ir(arrival: 0.028), ir(arrival: 0.022)])
        let d = CalibrationAnalysis.alignedDelays([a, b])!
        XCTAssertEqual(d[0], 18, accuracy: 1e-9)      // mean arrivals 11 / 29 / 21 ms
        XCTAssertEqual(d[1], 0, accuracy: 1e-9)
        XCTAssertEqual(d[2], 8, accuracy: 1e-9)
        XCTAssertEqual(CalibrationAnalysis.arrivalSpreadMs([a, b], delaysMs: [0, 0, 0])!, 18, accuracy: 1e-9)
        XCTAssertEqual(CalibrationAnalysis.arrivalSpreadMs([a, b], delaysMs: d)!, 2, accuracy: 1e-9)   // the two microphones disagree by ±1 ms
    }

    func testAlignedDelaysAreCappedAndNeedFullyIdentifiedMicrophone() {
        let far = MicResponse(sampleRate: 8000, speakers: [ir(arrival: 0.0), ir(arrival: 2.0)])
        XCTAssertEqual(CalibrationAnalysis.alignedDelays([far], maxDelayMs: 1000)!, [1000, 0])
        let partial = MicResponse(sampleRate: 8000, speakers: [ir(arrival: 0.0), nil])
        XCTAssertNil(CalibrationAnalysis.alignedDelays([partial]))
        XCTAssertNil(CalibrationAnalysis.alignedDelays([]))
    }
}
