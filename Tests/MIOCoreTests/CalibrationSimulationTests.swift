import XCTest
@testable import MIOCore

/// End-to-end simulation of the calibration with the same algorithm the app runs (model measurement → gradient-descent
/// "DelayAI" on the identified room model → short closed loop of fix / measure / fix …), against synthetic rooms with
/// different timbre, volume, hardware latency and distance per speaker, several microphones, noisy recordings and
/// timing jitter. Slow in a debug build, so it only runs when AMIO_SIM is set:
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
        static func lowShelf(_ fc: Double, db: Double, fs: Double) -> Biquad {
            let w = 2 * Double.pi * fc / fs, c = cos(w), A = pow(10, db / 40), al = sin(w) / 2 * (2.0).squareRoot()
            let k = 2 * A.squareRoot() * al
            return Biquad(b0: A * ((A + 1) - (A - 1) * c + k), b1: 2 * A * ((A - 1) - (A + 1) * c), b2: A * ((A + 1) - (A - 1) * c - k),
                          a0: (A + 1) + (A - 1) * c + k, a1: -2 * ((A - 1) + (A + 1) * c), a2: (A + 1) + (A - 1) * c - k)
        }
        static func highShelf(_ fc: Double, db: Double, fs: Double) -> Biquad {
            let w = 2 * Double.pi * fc / fs, c = cos(w), A = pow(10, db / 40), al = sin(w) / 2 * (2.0).squareRoot()
            let k = 2 * A.squareRoot() * al
            return Biquad(b0: A * ((A + 1) + (A - 1) * c + k), b1: -2 * A * ((A - 1) + (A + 1) * c), b2: A * ((A + 1) + (A - 1) * c - k),
                          a0: (A + 1) - (A - 1) * c + k, a1: 2 * ((A - 1) - (A + 1) * c), a2: (A + 1) - (A - 1) * c - k)
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

    struct RoomSpec {
        var hw: [Double]                   // true hardware latency per speaker (s)
        var reported: [Double]             // what the devices claim (so the original alignment is off)
        var dist: [[Double]]               // [mic][speaker] acoustic distance delay (s)
        var volume: [Double]
        var polarity: [Double]
        var hp: [Double], lp: [Double]     // timbre: band limits
        var tailAmp: Double, tailTau: Double
        var noise: Double                  // microphone noise
        var jitterMs: Double               // per-measurement timing jitter of every speaker (Bluetooth-like)
        var irSeconds: Double
        var periodSamples = 65536          // loop period: must exceed the longest lag + response, or the window cuts the response
        // Disturbances in the room (all relative to the microphone signal: music at a microphone is about 0.1 rms)
        var hvac = 0.0                     // ventilation: low-frequency rumble (rms)
        var hvacTone = 0.0                 // ventilation / mains hum: tones at 120, 240, 360 Hz
        var speech = 0.0                   // someone talking: speech-like bursts, ~1.2 s every ~5 s
        var thump = 0.0                    // doors / footsteps: low-frequency impulses every ~8 s
        var eq: [[Double]]? = nil          // per speaker: [low shelf dB @200 Hz, high shelf dB @4 kHz, mid Hz, mid dB]

        /// Everything that is not the programme, for `count` samples at `fs`: mic noise, ventilation, hum, talking, thumps.
        func disturbance(count: Int, fs: Double, rng: inout RNG) -> [Float] {
            var y = [Double](repeating: 0, count: count)
            if noise > 0 { for i in 0..<count { y[i] += noise * rng.next() } }
            func scaled(_ x: [Double], to rms: Double) -> [Double] {
                let e = (x.reduce(0) { $0 + $1 * $1 } / Double(max(1, x.count))).squareRoot()
                return e > 0 ? x.map { $0 * rms / e } : x
            }
            if hvac > 0 {
                let w = (0..<count).map { _ in rng.next() }
                let lo = Biquad.lowpass(140, q: 0.7, fs: fs).apply(Biquad.lowpass(140, q: 0.7, fs: fs).apply(w))
                let r = scaled(lo, to: hvac)
                for i in 0..<count { y[i] += r[i] }
            }
            if hvacTone > 0 {
                let p = (0..<3).map { _ in rng.unit() * 2 * Double.pi }
                for i in 0..<count {
                    let t = Double(i) / fs
                    y[i] += hvacTone * (sin(2 * Double.pi * 120 * t + p[0]) + 0.5 * sin(2 * Double.pi * 240 * t + p[1]) + 0.3 * sin(2 * Double.pi * 360 * t + p[2]))
                }
            }
            if speech > 0 {
                var t = rng.unit() * 3
                while t < Double(count) / fs {
                    let len = Int(1.2 * fs), start = Int(t * fs)
                    if start + len < count {
                        let w = (0..<len).map { _ in rng.next() }
                        let band = Biquad.lowpass(3500, q: 0.7, fs: fs).apply(Biquad.highpass(200, q: 0.7, fs: fs).apply(w))
                        let f0 = 3.5 + 2 * rng.unit()                                  // syllable rate
                        let env = (0..<len).map { i -> Double in
                            let u = Double(i) / Double(len)
                            return sin(Double.pi * u) * abs(sin(Double.pi * f0 * Double(i) / fs)).squareRoot()
                        }
                        let r = scaled(zip(band, env).map { $0 * $1 }, to: speech)
                        for i in 0..<len { y[start + i] += r[i] }
                    }
                    t += 3.5 + 5 * rng.unit()
                }
            }
            if thump > 0 {
                var t = 1 + rng.unit() * 6
                while t < Double(count) / fs {
                    let start = Int(t * fs), len = Int(0.4 * fs), f = 45 + 40 * rng.unit()
                    if start + len < count {
                        for i in 0..<len { y[start + i] += thump * sin(2 * Double.pi * f * Double(i) / fs) * exp(-Double(i) / (0.06 * fs)) }
                    }
                    t += 5 + 6 * rng.unit()
                }
            }
            return y.map { Float($0) }
        }

        static let standard = RoomSpec(
            hw: [0.019, 0.215, 0.207, 0.060, 0.120], reported: [0.019, 0.180, 0.227, 0.085, 0.075],
            dist: [[0.004, 0.008, 0.012, 0.006, 0.010], [0.011, 0.005, 0.007, 0.013, 0.009],
                   [0.015, 0.010, 0.004, 0.009, 0.013], [0.007, 0.014, 0.010, 0.003, 0.006]],
            volume: [1.0, 0.85, 0.7, 0.95, 0.6], polarity: [1, 1, 1, 1, 1],
            hp: [60, 90, 140, 200, 120], lp: [7000, 5500, 6500, 4500, 6000],
            tailAmp: 0.07, tailTau: 0.12, noise: 0.002, jitterMs: 0.8, irSeconds: 0.9)

        /// Six speakers, latencies from 20 to 655 ms, one polarity-inverted, two almost on top of each other (comb
        /// filter), very different levels, a long reverb tail (T60 ≈ 2 s), three microphones, noisy and jittery.
        static let hard = RoomSpec(
            hw: [0.020, 0.420, 0.655, 0.075, 0.250, 0.2515], reported: [0.020, 0.330, 0.725, 0.125, 0.170, 0.3115],
            dist: [[0.003, 0.011, 0.020, 0.008, 0.014, 0.015], [0.019, 0.004, 0.009, 0.017, 0.006, 0.007],
                   [0.010, 0.013, 0.005, 0.012, 0.022, 0.021]],
            volume: [1.0, 0.4, 0.9, 0.15, 1.0, 0.8], polarity: [1, 1, -1, 1, 1, 1],
            hp: [60, 120, 90, 250, 70, 70], lp: [7500, 4000, 6000, 3500, 7000, 7000],
            tailAmp: 0.12, tailTau: 0.30, noise: 0.004, jitterMs: 1.5, irSeconds: 2.0, periodSamples: 131072)
    }

    struct Room {
        let fs: Double, n: Int                 // n = loop period in samples
        let spec: RoomSpec
        let speakers: Int, mics: Int
        let h: [[[Double]]]                    // [mic][speaker] impulse response (volume, polarity, timbre, arrival, reverb)
        let hRe: [[[Double]]], hIm: [[[Double]]]

        init(fs: Double, n: Int, spec: RoomSpec) {
            self.fs = fs; self.n = n; self.spec = spec
            speakers = spec.hw.count; mics = spec.dist.count
            let length = Int(spec.irSeconds * fs)
            var hh = [[[Double]]](), re = [[[Double]]](), im = [[[Double]]]()
            let fft = FFT(size: n)
            for m in 0..<mics {
                var hm = [[Double]](), rm = [[Double]](), imm = [[Double]]()
                for i in 0..<speakers {
                    var rng = RNG(s: UInt64(1000 + 17 * i + 3 * m))
                    var imp = [Double](repeating: 0, count: 4000); imp[0] = 1
                    imp = Biquad.highpass(spec.hp[i], q: 0.7, fs: fs).apply(imp)
                    imp = Biquad.lowpass(spec.lp[i], q: 0.7, fs: fs).apply(imp)
                    for _ in 0..<2 {
                        imp = Biquad.peaking(300 + 3700 * rng.unit(), q: 1 + 2 * rng.unit(), db: 10 * rng.next(), fs: fs).apply(imp)
                    }
                    if let e = spec.eq, i < e.count, e[i].count == 4 {                  // the speaker's own equaliser setting
                        imp = Biquad.lowShelf(200, db: e[i][0], fs: fs).apply(imp)
                        imp = Biquad.highShelf(4000, db: e[i][1], fs: fs).apply(imp)
                        imp = Biquad.peaking(e[i][2], q: 1.2, db: e[i][3], fs: fs).apply(imp)
                    }
                    var ir = [Double](repeating: 0, count: length)
                    let arrival = Int((spec.hw[i] + spec.dist[m][i]) * fs)
                    let gain = spec.polarity[i] * spec.volume[i] / (1 + spec.dist[m][i] * 100)
                    for t in 0..<imp.count where arrival + t < length { ir[arrival + t] += gain * imp[t] }
                    for t in (arrival + Int(0.004 * fs))..<length {
                        ir[t] += gain * spec.tailAmp * rng.next() * exp(-Double(t - arrival) / (spec.tailTau * fs))
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

    func testStandardFiveSpeakers() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["AMIO_SIM"] != nil, "set AMIO_SIM=1 to run the (slow) simulation")
        var spec = RoomSpec.standard
        let k = Int(ProcessInfo.processInfo.environment["AMIO_MICS"] ?? "") ?? 2
        spec.dist = Array(spec.dist.prefix(4))
        let r = try simulate(name: "standard (5 speakers, calibrated with \(k) of 4 mics, judged at all 4 positions)", spec: spec, iterations: 30, calibrationMics: k)
        XCTAssertLessThan(r.tuned, r.original * 0.75)
        XCTAssertLessThanOrEqual(r.tuned, r.oracle * 1.08, "should be as good as the oracle that knows the true responses")
    }

    func testHardSixSpeakersWithLongLatencyPolarityCombAndJitter() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["AMIO_SIM"] != nil, "set AMIO_SIM=1 to run the (slow) simulation")
        let r = try simulate(name: "HARD (6 speakers, 3 mics, 20–655 ms, polarity, comb, long reverb, jitter)", spec: .hard, iterations: 40)
        XCTAssertLessThan(r.tuned, r.original * 0.85)
        XCTAssertLessThanOrEqual(r.tuned, r.oracle * 1.08, "should be as good as the oracle that knows the true responses")
    }

    /// The identified model is deliberately mis-timed (two speakers' arrivals 13 ms early / 21 ms late, as a poor identification
    /// would leave them). Measurements of the real room must show it and the model correction must repair it.
    func testMisTimedModelIsRepairedByMeasurements() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["AMIO_SIM"] != nil, "set AMIO_SIM=1 to run the (slow) simulation")
        let r = try simulate(name: "HARD with a MIS-TIMED model (speaker 1: −13 ms, speaker 3: +21 ms)", spec: .hard, iterations: 30,
                             mistimeMs: [0, -13, 0, 21, 0, 0])
        XCTAssertLessThan(r.tuned, r.original * 0.88)
        XCTAssertLessThanOrEqual(r.tuned, r.oracle * 1.12)
    }

    /// Identification made deliberately poor (the other speakers only 8 dB down while one is emphasised): the model is
    /// unreliable for the weak speakers. The measured loop must at least never leave the room worse than it was.
    func testPoorIdentificationIsRepairedByModelCorrection() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["AMIO_SIM"] != nil, "set AMIO_SIM=1 to run the (slow) simulation")
        let r = try simulate(name: "HARD with POOR identification (emphasis only 0.4)", spec: .hard, iterations: 30, emphasis: 0.4)
        XCTAssertLessThanOrEqual(r.tuned, r.original * 1.03, "a poor model must never make the room worse than the original")
    }

    // MARK: Gauntlet: nasty rooms (every speaker with its own timbre, equaliser, level and latency; plus real-world noise)

    static let gauntletFan = RoomSpec(
        hw: [0.012, 0.140, 0.085, 0.310], reported: [0.012, 0.100, 0.130, 0.250],
        dist: [[0.005, 0.009, 0.013, 0.007], [0.012, 0.006, 0.008, 0.014]],
        volume: [0.9, 0.75, 1.0, 0.55], polarity: [1, 1, 1, 1],
        hp: [70, 110, 160, 90], lp: [6800, 5200, 6100, 4300],
        tailAmp: 0.08, tailTau: 0.15, noise: 0.005, jitterMs: 1.0, irSeconds: 1.0,
        hvac: 0.03, hvacTone: 0.015,
        eq: [[2, -3, 900, 3], [-3, 2, 1800, -4], [1, -1, 500, 2], [-2, 4, 2600, -3]])

    static let gauntletTalking = RoomSpec(
        hw: [0.025, 0.190, 0.340, 0.070, 0.510], reported: [0.025, 0.250, 0.300, 0.040, 0.420],
        dist: [[0.006, 0.010, 0.004, 0.012, 0.009], [0.013, 0.005, 0.011, 0.007, 0.015]],
        volume: [1.0, 0.65, 0.8, 0.9, 0.5], polarity: [1, 1, 1, -1, 1],
        hp: [80, 60, 130, 180, 100], lp: [7200, 4800, 6400, 5600, 3900],
        tailAmp: 0.10, tailTau: 0.20, noise: 0.004, jitterMs: 1.5, irSeconds: 1.2,
        hvac: 0.02, hvacTone: 0.008, speech: 0.12,
        eq: [[0, 0, 1200, 2], [3, -2, 700, -3], [-2, 3, 2200, 3], [1, 2, 400, -2], [-3, -1, 3000, 4]])

    static let gauntletEverything = RoomSpec(
        hw: [0.008, 0.095, 0.260, 0.430, 0.150, 0.152], reported: [0.008, 0.130, 0.190, 0.500, 0.100, 0.230],
        dist: [[0.004, 0.010, 0.017, 0.007, 0.012, 0.013], [0.015, 0.005, 0.009, 0.016, 0.006, 0.007],
               [0.009, 0.014, 0.004, 0.010, 0.019, 0.018]],
        volume: [0.8, 1.0, 0.45, 0.7, 0.95, 0.9], polarity: [1, 1, 1, 1, -1, 1],
        hp: [65, 100, 85, 210, 70, 70], lp: [7400, 5000, 6200, 3800, 6900, 6900],
        tailAmp: 0.12, tailTau: 0.28, noise: 0.01, jitterMs: 2.5, irSeconds: 1.6, periodSamples: 131072,
        hvac: 0.05, hvacTone: 0.03, speech: 0.10, thump: 0.5,
        eq: [[1, -2, 1000, 2], [-2, 3, 2000, -3], [3, 1, 600, 3], [-3, -3, 2800, 2], [2, 2, 1500, -4], [0, 4, 800, 3]])

    static let gauntletNoisyMic = RoomSpec(
        hw: [0.015, 0.075, 0.180, 0.260, 0.105], reported: [0.015, 0.110, 0.150, 0.190, 0.140],
        dist: [[0.005, 0.011, 0.008, 0.013, 0.006], [0.012, 0.004, 0.010, 0.006, 0.014]],
        volume: [0.85, 0.95, 0.6, 1.0, 0.7], polarity: [1, 1, 1, 1, 1],
        hp: [75, 95, 120, 150, 85], lp: [6600, 5400, 6000, 4700, 6300],
        tailAmp: 0.09, tailTau: 0.16, noise: 0.03, jitterMs: 1.2, irSeconds: 1.0,
        hvac: 0.03,
        eq: [[1, 1, 1100, 2], [-1, -2, 1900, -3], [2, 0, 650, 3], [0, 3, 2400, -2], [-2, 1, 3200, 3]])

    /// `expectImprovement: false` is for rooms so disturbed that nothing can be learned: the app must then be *safe* (never
    /// worse than before) and must *say so* (the weak-against-noise warning).
    private func gauntlet(_ name: String, _ spec: RoomSpec, mics: Int? = nil, expectImprovement: Bool = true) throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["AMIO_SIM"] != nil, "set AMIO_SIM=1 to run the (slow) simulation")
        let r = try simulate(name: "GAUNTLET · " + name, spec: spec, iterations: 24, calibrationMics: mics)
        XCTAssertTrue(r.identified, "no microphone identified every speaker")
        guard r.identified else { return }
        XCTAssertLessThanOrEqual(r.tuned, r.original * 1.03, "must never leave the room worse than it was")
        if expectImprovement {
            XCTAssertLessThan(r.tuned, r.original * 0.92, "must clearly improve")
            XCTAssertLessThanOrEqual(r.tuned, r.oracle * 1.12 + 0.01, "close to the oracle that knows the true responses")
        } else {
            XCTAssertTrue(r.warned, "a measurement with speakers drowned in noise must be reported to the user")
        }
    }

    func testGauntletVentilationRumbleAndHum() throws { try gauntlet("ventilation rumble + 120 Hz hum, 4 speakers, own EQs", Self.gauntletFan) }
    func testGauntletSomeoneTalking() throws { try gauntlet("someone talking + ventilation, 5 speakers, one inverted, latency to 510 ms", Self.gauntletTalking) }
    func testGauntletEverythingAtOnce() throws {
        var spec = Self.gauntletEverything
        let off = ProcessInfo.processInfo.environment["AMIO_OFF"] ?? ""          // debugging aid: switch features of this room off
        if off.contains("h") { spec.hvac = 0 }; if off.contains("t") { spec.hvacTone = 0 }; if off.contains("s") { spec.speech = 0 }
        if off.contains("k") { spec.thump = 0 }; if off.contains("n") { spec.noise = 0.001 }; if off.contains("j") { spec.jitterMs = 0.5 }
        if off.contains("e") { spec.eq = nil }
        if let v = Double(ProcessInfo.processInfo.environment["AMIO_SPEECH"] ?? "") { spec.speech = v }
        try gauntlet("rumble + hum + talking + thumps + mic noise, 6 speakers, jitter 2.5 ms [off: \(off)]", spec)
    }
    /// Talking louder than the music itself, plus everything else: nothing reliable can be learned. Safe fallback + warning.
    func testGauntletDeafeningRoomIsSafeAndReported() throws {
        var spec = Self.gauntletEverything
        spec.speech = 0.15
        try gauntlet("EXTREME: talking louder than the music + everything else", spec, expectImprovement: false)
    }
    func testGauntletVeryNoisyMicrophone() throws { try gauntlet("very noisy microphone (SNR ≈ 14 dB) + rumble", Self.gauntletNoisyMic) }

    struct SimResult { var original: Double; var tuned: Double; var oracle: Double; var identified = true; var warned = false }

    private func simulate(name: String, spec: RoomSpec, iterations: Int, calibrationMics: Int? = nil, emphasis: Double? = nil,
                          mistimeMs: [Double]? = nil) throws -> SimResult {
        let fs = 16000.0, N = spec.periodSamples, n = spec.hw.count
        let room = Room(fs: fs, n: N, spec: spec)
        let calMics = calibrationMics ?? room.mics          // microphones the calibration uses; the score is judged at all of them
        let music = Self.musicLoop(period: N, fs: fs, seed: 5)
        let fft = FFT(size: N)
        var noise = RNG(s: 2024)

        let worst = spec.reported.max()!
        let original = spec.reported.map { (worst - $0) * 1000 }          // aligned to the (inaccurate) reported latencies
        let trueArrival = (0..<n).map { i in (spec.hw[i] + (0..<room.mics).map { spec.dist[$0][i] }.reduce(0, +) / Double(room.mics)) * 1000 }

        /// Expected boominess a listener experiences: the average over several draws of the speakers' timing jitter.
        func jitteredBoominess(_ delays: [Double], draws: Int = 6) -> Double {
            var rng = RNG(s: 31337)
            var sum = 0.0
            for _ in 0..<draws { sum += trueBoominess(delays.map { max(0, $0 + rng.next() * spec.jitterMs) }) }
            return sum / Double(draws)
        }
        func trueBoominess(_ delays: [Double]) -> Double {
            let y = room.steadyState(music: music, delaysMs: delays, fft: fft)
            let scores = y.enumerated().map { (m, ym) -> Double in
                let win = (0..<(1600 + N)).map { Float(ym[($0 - 1600 + N) % N]) }
                let t = (0..<n).map { spec.hw[$0] + spec.dist[m][$0] + delays[$0] / 1000 }
                return CalibrationAnalysis.boominess(window: win, sampleRate: fs, probe: music, onsetSec: t.min()!,
                                                     spreadSec: t.max()! - t.min()!) ?? 99
            }
            return scores.reduce(0, +) / Double(scores.count)
        }

        // ---- Phase A: model measurement (continuous music, smooth emphasis, all microphones) ----
        let K = n + 1, Lseg = 4.0, ramp = 1.0, lead = 0.8
        let dMax = original.max()! / 1000
        let period = Lseg + 2 * dMax + ramp + 0.3
        func plateau(_ k: Int) -> Double { lead + Double(k) * period }
        var trials = [JointTrial(startSec: 0, gains: [Double](repeating: 1, count: n), delaysMs: original)]
        let emph = emphasis ?? 0.1
        for k in 1...n { trials.append(JointTrial(startSec: 0, gains: (0..<n).map { $0 == k - 1 ? 1 : emph }, delaysMs: original)) }
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
        for m in 0..<calMics {
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
            let dist = spec.disturbance(count: T, fs: fs, rng: &noise)
            recordings.append((0..<T).map { Float(yr[$0]) + dist[$0] })
        }
        let probes = trials.map { t in Array(source[Int(t.startSec * fs)..<Int((t.startSec + Lseg) * fs)]) }
        let responses = recordings.map { rec in
            CalibrationAnalysis.identify(recording: rec, sampleRate: fs, trials: trials, probes: probes, speakerCount: n,
                                         irSec: CalibrationAnalysis.responseSeconds, continuous: true,
                                         lsRegularization: Double(ProcessInfo.processInfo.environment["AMIO_LSREG"] ?? "") ?? 1e-3)
        }
        if ProcessInfo.processInfo.environment["AMIO_PROFILE"] != nil, let sp = responses[0].speakers[0] {
            let mx = sp.h.map { abs($0) }.max() ?? 1
            let line = (0..<min(sp.h.count, Int(0.06 * fs)) ).filter { $0 % 16 == 0 }.map { String(format: "%.2f", abs(sp.h[$0]) / mx) }.joined(separator: " ")
            print("SIM profile spk0 mic0 (1 ms steps, pre=\(sp.pre), snr \(sp.snr)): \(line)")
        }
        let weakest = CalibrationAnalysis.weakestSNR(responses) ?? 0
        let warned = weakest < CalibrationAnalysis.minReliableSNR
        let est = (0..<n).map { i -> Double in
            let a = responses.compactMap { $0.speakers[i]?.arrival }
            return a.isEmpty ? .nan : a.reduce(0, +) / Double(a.count) * 1000
        }

        if ProcessInfo.processInfo.environment["AMIO_ID_ONLY"] != nil {
            print("SIM[id] emph=\(emph) true: \(trueArrival.map { String(format: "%.0f", $0) }) identified: \(est.map { String(format: "%.0f", $0) }) snr: \(responses[0].speakers.map { String(format: "%.0f", $0?.snr ?? 0) })")
            return SimResult(original: 1, tuned: 1, oracle: 1)
        }
        // ---- DelayAI: global gradient descent on the identified model (many starts, all cores) ----
        let active = Array(0..<n)
        // the app only listens with microphones that identified every speaker; q indexes those, m the physical microphone
        let usableMics = responses.indices.filter { m in active.allSatisfy { responses[m].speakers[$0] != nil } }
        var modelMics = CalibrationAnalysis.restrict(responses, to: active)
        if modelMics.isEmpty {       // the app would say "no microphone identified every speaker" and ask to retry
            print("SIM ===== \(name)\nSIM identification FAILED: no microphone identified every speaker (snr \(responses.map { $0.speakers.map { String(format: "%.0f", $0?.snr ?? 0) } }))")
            return SimResult(original: 1, tuned: 1, oracle: 1, identified: false)
        }
        if let mt = mistimeMs { modelMics = modelMics.map { $0.shifted(byMs: mt) } }      // a deliberately mis-timed model
        let programme = Programme(probe: music, rate: fs)

        // ---- the same pipeline the app runs: measure the original → correct the model → compute → measure → … ----
        let pad = Int(0.1 * fs)
        var evals = 0
        var computeSeconds: [Double] = []
        let tuned = try awaitResult {
            try await CalibrationPlanner.run(
                model: modelMics, programme: programme, original: original, maxRounds: 3, repeats: 2, localIterations: iterations / 2,
                compute: { model in
                    let t = Date()
                    let d = CalibrationPlanner.computeBest(model: model, programme: programme, original: original)
                    computeSeconds.append(Date().timeIntervalSince(t))
                    return d
                },
                measure: { delays, _ in
                    evals += 1
                    let jittered = delays.map { $0 + noise.next() * spec.jitterMs }
                    let y = room.steadyState(music: music, delaysMs: jittered.map { max(0, $0) }, fft: fft)
                    let phase = Int(noise.unit() * Double(N))
                    let x = (0..<N).map { music[(phase + $0) % N] }
                    var obs: [Observation] = []
                    for (q, m) in usableMics.enumerated() {
                        let ym = y[m]
                        let dist = spec.disturbance(count: pad + N, fs: fs, rng: &noise)
                        let win = (0..<(pad + N)).map { Float(ym[(phase - pad + $0 + 2 * N) % N]) + dist[$0] }
                        // first arrival / spread from the identified model and the delays we applied (as the app does)
                        let arr = modelMics[q].speakers.enumerated().map { $0.element!.arrival + delays[$0.offset] / 1000 }
                        guard let r = CalibrationAnalysis.measure(window: win, sampleRate: fs, probe: x, onsetSec: arr.min()!,
                                                                  spreadSec: arr.max()! - arr.min()! ) else { return nil }
                        obs.append(Observation(mic: q, delaysMs: delays, ir: r.ir, pad: r.pad))
                    }
                    return Measured(observations: obs)
                })
        }
        let tr = try XCTUnwrap(tuned)

        // ---- oracle: the same gradient descent on the TRUE impulse responses (the best a model could ever do) ----
        let oracleMics: [MicResponse] = (0..<calMics).map { m in
            let pre = max(1, Int(0.001 * fs)), len = Int(CalibrationAnalysis.responseSeconds * fs)
            let sp: [SpeakerIR?] = (0..<n).map { i in
                let a = Int((spec.hw[i] + spec.dist[m][i]) * fs)
                var hh = [Double](repeating: 0, count: pre + len)
                for t in 0..<(pre + len) where a - pre + t < room.h[m][i].count { hh[t] = room.h[m][i][a - pre + t] }
                return SpeakerIR(h: hh, pre: pre, arrival: Double(a) / fs, snr: 100, consistency: 1)
            }
            return MicResponse(sampleRate: fs, speakers: sp)
        }
        let oracleSeed = CalibrationAnalysis.seeds(responses: oracleMics, active: active, original: original)
        let oracle = DelayAI.optimize(mics: oracleMics, seeds: oracleSeed, programme: programme)
        let truthAligned = trueArrival.map { trueArrival.max()! - $0 }
        // twin fidelity: does the software copy predict the (noise-free) measured score? (on the TRUE room)
        var fidelity = ""
        if let twinO = DigitalTwin(mics: oracleMics, probe: music, rate: fs) {
            var rng = RNG(s: 77)
            var xs: [Double] = [], ys: [Double] = []
            for _ in 0..<10 {
                let d = truthAligned.map { max(0, $0 + rng.next() * 40) }
                if let a = twinO.score(delaysMs: d) { xs.append(a); ys.append(trueBoominess(d)) }
            }
            let mx = xs.reduce(0, +) / Double(xs.count), my = ys.reduce(0, +) / Double(ys.count)
            var sxy = 0.0, sxx = 0.0, syy = 0.0, rel = 0.0
            for i in xs.indices { sxy += (xs[i] - mx) * (ys[i] - my); sxx += (xs[i] - mx) * (xs[i] - mx); syy += (ys[i] - my) * (ys[i] - my); rel += abs(xs[i] - ys[i]) / ys[i] }
            fidelity = String(format: "correlation %.3f, mean |error| %.1f%%", sxy / (sxx * syy).squareRoot(), 100 * rel / Double(xs.count))
        }
        let oracleTwin = DigitalTwin(mics: oracleMics, probe: music, rate: fs)
        let oraclePolished = oracleTwin.flatMap { TwinOptimizer.polish(twin: $0, starts: [oracle?.delaysMs ?? truthAligned, truthAligned]) }

        let tOrig = jitteredBoominess(original), tAligned = jitteredBoominess(truthAligned)
        let tTuned = jitteredBoominess(tr.best)
        let tOracle = oraclePolished.map { jitteredBoominess($0.delaysMs) } ?? oracle.map { jitteredBoominess($0.delaysMs) } ?? .nan
        func f(_ v: [Double]) -> String { v.map { String(format: "%.0f", $0) }.joined(separator: ",") }
        print("SIM ===== \(name)")
        print("SIM true arrival ms : \(f(trueArrival))")
        print("SIM identified      : \(f(est))")
        print("SIM [boominess = expected value under timing jitter] original delays : \(f(original))     true boominess \(String(format: "%.2f", tOrig))")
        print("SIM aligned by truth: \(f(truthAligned))     true boominess \(String(format: "%.2f", tAligned))")
        print("SIM twin fidelity   : \(fidelity)")
        print("SIM pipeline result : \(f(tr.best))     true boominess \(String(format: "%.2f", tTuned))   [\(tr.evaluations) measurements, \(tr.rounds) model rounds]")
        print("SIM model correction (ms): \(f(tr.biasMs))   [true identification error: \(f((0..<n).map { trueArrival[$0] - (est[$0].isNaN ? trueArrival[$0] : est[$0]) }))]")
        print("SIM oracle (twin on TRUE IR): \(f(oraclePolished?.delaysMs ?? oracle?.delaysMs ?? []))     true boominess \(String(format: "%.2f", tOracle))")
        print("SIM compute time per round (s): \(computeSeconds.map { String(format: "%.1f", $0) }.joined(separator: ", "))")
        print("SIM measurement noise estimate: \(Int(tr.noise * 100))%")
        print("SIM measured history: \(tr.history.map { String(format: "%.1f", $0) }.joined(separator: " "))")
        print("SIM improvement: tuned \(Int((1 - tTuned / tOrig) * 100))%, oracle \(Int((1 - tOracle / tOrig) * 100))%")
        print("SIM identification: weakest speaker SNR \(String(format: "%.0f", weakest)) → \(warned ? "the app WARNS that a speaker was weak against the noise" : "measurement judged reliable")")
        return SimResult(original: tOrig, tuned: tTuned, oracle: tOracle, warned: warned)
    }

    /// Runs an async body from a synchronous test.
    private func awaitResult<T>(_ body: @escaping () async throws -> T) throws -> T {
        let exp = expectation(description: "async")
        var out: Result<T, Error>?
        Task { out = await Result { try await body() }; exp.fulfill() }
        wait(for: [exp], timeout: 1800)
        return try XCTUnwrap(out).get()
    }
}
