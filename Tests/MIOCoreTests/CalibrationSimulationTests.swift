import XCTest
@testable import MIOCore

/// End-to-end simulation of the calibration with the same algorithm the app runs (model measurement → seeds → bold
/// measured search), against a synthetic room: 5 speakers with different timbre, volume, hardware latency and distance,
/// 2 microphones, noisy recordings. Slow in a debug build, so it only runs when AMIO_SIM is set:
///   AMIO_SIM=1 swift test -c release -Xswiftc -enable-testing --filter CalibrationSimulationTests
final class CalibrationSimulationTests: XCTestCase {
    struct RNG {
        var s: UInt64
        mutating func next() -> Double { s = s &* 6364136223846793005 &+ 1442695040888963407; return Double(s >> 11) / Double(1 << 52) - 1 }
        mutating func unit() -> Double { (next() + 1) / 2 }
    }

    // MARK: building blocks

    struct Biquad {
        var b0 = 1.0, b1 = 0.0, b2 = 0.0, a1 = 0.0, a2 = 0.0
        init(b0: Double, b1: Double, b2: Double, a0: Double, a1: Double, a2: Double) {
            self.b0 = b0 / a0; self.b1 = b1 / a0; self.b2 = b2 / a0; self.a1 = a1 / a0; self.a2 = a2 / a0
        }
        static func lowpass(_ fc: Double, q: Double, fs: Double) -> Biquad {
            let w = 2 * Double.pi * fc / fs, c = cos(w), al = sin(w) / (2 * q)
            return Biquad(b0: (1 - c) / 2, b1: 1 - c, b2: (1 - c) / 2, a0: 1 + al, a1: -2 * c, a2: 1 - al)
        }
        static func highpass(_ fc: Double, q: Double, fs: Double) -> Biquad {
            let w = 2 * Double.pi * fc / fs, c = cos(w), al = sin(w) / (2 * q)
            return Biquad(b0: (1 + c) / 2, b1: -(1 + c), b2: (1 + c) / 2, a0: 1 + al, a1: -2 * c, a2: 1 - al)
        }
        static func peaking(_ fc: Double, q: Double, db: Double, fs: Double) -> Biquad {
            let w = 2 * Double.pi * fc / fs, c = cos(w), al = sin(w) / (2 * q), A = pow(10, db / 40)
            return Biquad(b0: 1 + al * A, b1: -2 * c, b2: 1 - al * A, a0: 1 + al / A, a1: -2 * c, a2: 1 - al / A)
        }
        func apply(_ x: [Double]) -> [Double] {
            var y = [Double](repeating: 0, count: x.count)
            var x1 = 0.0, x2 = 0.0, y1 = 0.0, y2 = 0.0
            for i in 0..<x.count {
                let o = b0 * x[i] + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2
                x2 = x1; x1 = x[i]; y2 = y1; y1 = o; y[i] = o
                _ = i
            }
            return y
        }
    }

    /// Exactly periodic "music": harmonic notes with decay plus hi-hat like noise, wrapping around the period.
    static func musicLoop(period n: Int, fs: Double, seed: UInt64) -> [Float] {
        var rng = RNG(s: seed)
        var out = [Double](repeating: 0, count: n)
        let notes = [110.0, 123.5, 146.8, 164.8, 196, 220, 247, 293.7, 329.6, 392, 440, 523, 587, 659, 784, 880, 1047]
        var t = 0.0
        while t < Double(n) / fs {
            let f = notes[Int(rng.unit() * Double(notes.count)) % notes.count], amp = 0.4 + 0.6 * rng.unit()
            let onset = Int(t * fs), len = Int(0.45 * fs)
            for i in 0..<len {
                let env = amp * exp(-Double(i) / (0.12 * fs))
                var v = 0.0
                for h in 1...4 { v += sin(2 * Double.pi * f * Double(h) * Double(i) / fs) / Double(h) }
                out[(onset + i) % n] += env * v
            }
            t += 0.18 + 0.2 * rng.unit()
        }
        var hat = 0.0
        for k in 0..<Int(Double(n) / fs / 0.25) {
            let onset = Int(Double(k) * 0.25 * fs)
            for i in 0..<Int(0.04 * fs) {
                let w = rng.next(); let d = w - hat; hat = w
                out[(onset + i) % n] += 0.25 * d * exp(-Double(i) / (0.012 * fs))
            }
        }
        let rms = (out.reduce(0) { $0 + $1 * $1 } / Double(n)).squareRoot()
        return out.map { Float($0 / rms * 0.12) }
    }

    struct Room {
        let fs: Double, n: Int                 // n = loop period in samples
        let speakers = 5, mics = 2
        let hw: [Double]                       // true hardware latency of each speaker, seconds
        let reported: [Double]                 // what the devices *claim* (so the original alignment is off)
        let dist: [[Double]]                   // [mic][speaker] acoustic distance delay, seconds
        let volume: [Double]
        let h: [[[Double]]]                    // [mic][speaker] impulse response (volume, timbre, arrival, reverb included)
        let hRe: [[[Double]]], hIm: [[[Double]]]

        init(fs: Double, n: Int) {
            self.fs = fs; self.n = n
            hw = [0.019, 0.215, 0.207, 0.060, 0.120]
            reported = [0.019, 0.180, 0.227, 0.085, 0.075]
            dist = [[0.004, 0.008, 0.012, 0.006, 0.010], [0.011, 0.005, 0.007, 0.013, 0.009]]
            volume = [1.0, 0.85, 0.7, 0.95, 0.6]
            let hpF = [60.0, 90, 140, 200, 120], lpF = [7000.0, 5500, 6500, 4500, 6000]
            let length = Int(0.9 * fs)
            var hh = [[[Double]]](), re = [[[Double]]](), im = [[[Double]]]()
            let fft = FFT(size: n)
            for m in 0..<2 {
                var hm = [[Double]](), rm = [[Double]](), imm = [[Double]]()
                for i in 0..<5 {
                    var rng = RNG(s: UInt64(1000 + 17 * i + 3 * m))
                    // timbre: band limits + two random resonances/dips
                    var imp = [Double](repeating: 0, count: 4000); imp[0] = 1
                    imp = Biquad.highpass(hpF[i], q: 0.7, fs: fs).apply(imp)
                    imp = Biquad.lowpass(lpF[i], q: 0.7, fs: fs).apply(imp)
                    for _ in 0..<2 {
                        imp = Biquad.peaking(300 + 3700 * rng.unit(), q: 1 + 2 * rng.unit(), db: 10 * rng.next(), fs: fs).apply(imp)
                    }
                    var ir = [Double](repeating: 0, count: length)
                    let arrival = Int((hw[i] + dist[m][i]) * fs)
                    let gain = volume[i] / (1 + dist[m][i] * 100)
                    for t in 0..<imp.count where arrival + t < length { ir[arrival + t] += gain * imp[t] }
                    for t in (arrival + Int(0.004 * fs))..<length {          // room: decaying reverb
                        ir[t] += gain * 0.07 * rng.next() * exp(-Double(t - arrival) / (0.12 * fs))
                    }
                    var r = [Double](repeating: 0, count: n), q = r
                    for t in 0..<min(length, n) { r[t] = ir[t] }
                    fft.transform(&r, &q)
                    hm.append(ir); rm.append(r); imm.append(q)
                }
                hh.append(hm); re.append(rm); im.append(imm)
            }
            h = hh; hRe = re; hIm = im
        }

        /// Steady-state recording of the looped programme with the given per-speaker delays (ms), noise-free.
        func steadyState(music: [Float], delaysMs: [Double], fft: FFT) -> [[Double]] {
            var sr = music.map(Double.init), si = [Double](repeating: 0, count: n)
            fft.transform(&sr, &si)
            return (0..<mics).map { m in
                var yr = [Double](repeating: 0, count: n), yi = yr
                for i in 0..<speakers {
                    let d = delaysMs[i] / 1000 * fs
                    for k in 0..<n {
                        let kk = k <= n / 2 ? k : k - n
                        let ph = -2 * Double.pi * Double(kk) * d / Double(n)
                        let pr = cos(ph), pi = sin(ph)
                        let ar = sr[k] * hRe[m][i][k] - si[k] * hIm[m][i][k], ai = sr[k] * hIm[m][i][k] + si[k] * hRe[m][i][k]
                        yr[k] += ar * pr - ai * pi; yi[k] += ar * pi + ai * pr
                    }
                }
                fft.transform(&yr, &yi, inverse: true)
                return yr
            }
        }
    }

    func testFiveSpeakersWithDifferentTimbreVolumeAndLatency() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["AMIO_SIM"] != nil, "set AMIO_SIM=1 to run the (slow) simulation")
        try simulate(useModelSeeds: true, maxEvals: 34)
    }

    /// The model's starting points are thrown away: the bold measured search alone has to find its way from the original.
    func testSearchAloneFindsGoodDelaysWithoutTheModel() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["AMIO_SIM"] != nil, "set AMIO_SIM=1 to run the (slow) simulation")
        try simulate(useModelSeeds: false, maxEvals: 90)
    }

    private func simulate(useModelSeeds: Bool, maxEvals: Int) throws {
        let fs = 16000.0, N = 65536, n = 5
        let room = Room(fs: fs, n: N)
        let music = Self.musicLoop(period: N, fs: fs, seed: 5)
        let fft = FFT(size: N)
        var noise = RNG(s: 2024)

        // What the app would have applied before calibration: align to the (inaccurate) reported latencies.
        let worst = room.reported.max()!
        let original = room.reported.map { (worst - $0) * 1000 }
        let trueArrival = (0..<n).map { i in (room.hw[i] + (room.dist[0][i] + room.dist[1][i]) / 2) * 1000 }

        func trueBoominess(_ delays: [Double]) -> Double {
            let y = room.steadyState(music: music, delaysMs: delays, fft: fft)
            let scores = y.map { ym -> Double in
                let win = (0..<(1600 + N)).map { Float(ym[($0 - 1600 + N) % N]) }
                return CalibrationAnalysis.boominess(window: win, sampleRate: fs, probe: music) ?? 99
            }
            return scores.reduce(0, +) / Double(scores.count)
        }
        func spread(_ delays: [Double]) -> Double {                    // how far apart the speakers land at the microphones
            let t = (0..<n).map { trueArrival[$0] + delays[$0] }
            return t.max()! - t.min()!
        }

        // ---- Phase A: model measurement (continuous music, smooth emphasis, all microphones) ----
        let K = n + 1, Lseg = 4.0, ramp = 1.0, lead = 0.8
        let dMax = original.max()! / 1000
        let period = Lseg + 2 * dMax + ramp + 0.3
        func plateau(_ k: Int) -> Double { lead + Double(k) * period }
        var trials = [JointTrial(startSec: 0, gains: [Double](repeating: 1, count: n), delaysMs: original)]
        for k in 1...n { trials.append(JointTrial(startSec: 0, gains: (0..<n).map { $0 == k - 1 ? 1 : 0.4 }, delaysMs: original)) }
        for k in 0..<K { trials[k].startSec = plateau(k) + dMax }
        let total = trials[K - 1].startSec + Lseg + dMax + 0.8
        let T = Int((total + 1.5) * fs)
        let source = (0..<T).map { music[$0 % N] }
        func gains(at t: Double) -> [Double] {
            var k = 0
            for j in 1..<K where t >= plateau(j) - ramp { k = j }
            if k == 0 { return trials[0].gains }
            let u = min(1, max(0, (t - (plateau(k) - ramp)) / ramp)), s = u * u * (3 - 2 * u)
            return (0..<n).map { trials[k - 1].gains[$0] + (trials[k].gains[$0] - trials[k - 1].gains[$0]) * s }
        }
        let M = FFT.nextPowerOfTwo(T + room.h[0][0].count)
        let bigFFT = FFT(size: M)
        var recordings = [[Float]]()
        for m in 0..<room.mics {
            var yr = [Double](repeating: 0, count: M), yi = yr
            for i in 0..<n {
                var xr = [Double](repeating: 0, count: M), xi = xr, hr = xr, hi = xr
                let D = Int(original[i] / 1000 * fs)
                for t in 0..<T where t >= D { xr[t] = Double(source[t - D]) * gains(at: Double(t) / fs)[i] }
                for t in 0..<room.h[m][i].count { hr[t] = room.h[m][i][t] }
                bigFFT.transform(&xr, &xi); bigFFT.transform(&hr, &hi)
                for k in 0..<M { yr[k] += xr[k] * hr[k] - xi[k] * hi[k]; yi[k] += xr[k] * hi[k] + xi[k] * hr[k] }
            }
            bigFFT.transform(&yr, &yi, inverse: true)
            recordings.append((0..<T).map { Float(yr[$0] + 0.001 * noise.next()) })
        }
        let probes = trials.map { t in Array(source[Int(t.startSec * fs)..<Int((t.startSec + Lseg) * fs)]) }
        var responses: [MicResponse] = [], sharesAll: [[Double]] = []
        for rec in recordings {
            responses.append(CalibrationAnalysis.identify(recording: rec, sampleRate: fs, trials: trials, probes: probes,
                                                          speakerCount: n, continuous: true))
            let levels = trials.map { t -> Double in
                let a = Int((t.startSec + 0.6) * fs), b = Int((t.startSec + Lseg) * fs)
                return rec[a..<b].reduce(0.0) { $0 + Double($1) * Double($1) } / Double(b - a)
            }
            sharesAll.append(CalibrationAnalysis.audibleShares(levels: levels, gains: trials.map(\.gains)))
        }
        let est = (0..<n).map { i in responses.compactMap { $0.speakers[i]?.arrival }.reduce(0, +) / Double(max(1, responses.compactMap { $0.speakers[i]?.arrival }.count)) * 1000 }
        print("SIM true arrival ms (mic mean): \(trueArrival.map { String(format: "%.1f", $0) })")
        print("SIM estimated arrival ms      : \(est.map { String(format: "%.1f", $0) })")
        print("SIM audible shares mic0: \(sharesAll[0].map { String(format: "%.2f", $0) })")

        // ---- Phase B: the same seeds + bold measured search as the app ----
        let allSeeds = CalibrationAnalysis.seeds(responses: responses, active: Array(0..<n), original: original)
        let seeds = useModelSeeds ? allSeeds : [allSeeds[0]]
        var evals = 0
        let pad = Int(0.1 * fs)
        let result = try awaitResult {
            try await DelaySearch.run(seeds: seeds, shouldStop: { evals >= maxEvals }) { delays, _ in
                evals += 1
                let y = room.steadyState(music: music, delaysMs: delays, fft: fft)
                let phase = Int(noise.unit() * Double(N))
                let x = (0..<N).map { music[(phase + $0) % N] }
                var scores: [Double] = []
                for ym in y {
                    let win = (0..<(pad + N)).map { Float(ym[(phase - pad + $0 + 2 * N) % N] + 0.002 * noise.next()) }
                    guard let s = CalibrationAnalysis.boominess(window: win, sampleRate: fs, probe: x) else { return nil }
                    scores.append(s)
                }
                return scores.reduce(0, +) / Double(scores.count)
            }
        }
        let r = try XCTUnwrap(result)
        let shift = r.best.min()!
        let found = r.best.map { $0 - shift }

        let truthAligned = trueArrival.map { trueArrival.max()! - $0 }
        let tOrig = trueBoominess(original), tFound = trueBoominess(found), tAligned = trueBoominess(truthAligned)
        print("SIM [model seeds: \(useModelSeeds), budget \(maxEvals) evals] seeds: \(seeds.map { $0.map { Int($0) } })")
        print("SIM original delays \(original.map { Int($0) }) → arrival spread \(String(format: "%.1f", spread(original))) ms, true boominess \(String(format: "%.2f", tOrig))")
        print("SIM found    delays \(found.map { Int($0) }) → arrival spread \(String(format: "%.1f", spread(found))) ms, true boominess \(String(format: "%.2f", tFound))")
        print("SIM oracle-aligned (truth) delays \(truthAligned.map { Int($0) }) → true boominess \(String(format: "%.2f", tAligned))")
        print("SIM measured: before \(String(format: "%.2f", r.originalScore ?? -1)) → after \(String(format: "%.2f", r.bestScore)); history \(r.history.map { String(format: "%.1f", $0) }); \(r.evaluations) evaluations, finished=\(r.finished)")
        print("SIM true improvement \(Int((1 - tFound / tOrig) * 100))%")

        for i in 0..<n { XCTAssertEqual(est[i] - est[0], trueArrival[i] - trueArrival[0], accuracy: 3, "arrival of speaker \(i)") }
        if useModelSeeds {
            XCTAssertLessThan(tFound, tOrig * 0.7, "model start + measured search should clearly reduce the true boominess")
            XCTAssertLessThan(spread(found), spread(original))
        } else {
            // One-speaker-at-a-time moves from a bad start cannot re-align five speakers; it must still help, never hurt,
            // and must not "win" by pushing a speaker out of the analysis window (which the wide impulse response prevents).
            XCTAssertLessThan(tFound, tOrig * 0.9)
        }
    }

    /// Runs an async body from a synchronous test.
    private func awaitResult<T>(_ body: @escaping () async throws -> T) throws -> T {
        let exp = expectation(description: "async")
        var out: Result<T, Error>?
        Task { out = await Result { try await body() }; exp.fulfill() }
        wait(for: [exp], timeout: 900)
        return try XCTUnwrap(out).get()
    }
}
