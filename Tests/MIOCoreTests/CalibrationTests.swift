import XCTest
@testable import MIOCore

final class CalibrationTests: XCTestCase {
    private struct LCG {
        var s: UInt64
        mutating func next() -> Double {            // uniform in [-1, 1)
            s = s &* 6364136223846793005 &+ 1442695040888963407
            return Double(s >> 11) / Double(1 << 52) - 1
        }
    }

    /// Direct path at `arrival` seconds plus a decaying noise tail.
    private func room(fs: Double, arrival: Double, direct: Double, tail: Double, seed: UInt64, length: Int) -> [Double] {
        var rng = LCG(s: seed)
        var h = [Double](repeating: 0, count: length)
        let a = Int(arrival * fs)
        h[a] = direct
        for i in (a + Int(0.004 * fs))..<length {
            h[i] = tail * rng.next() * exp(-Double(i - a) / (0.08 * fs))
        }
        return h
    }

    private func convolve(_ x: [Float], _ h: [Double], into y: inout [Float], at offset: Int, gain: Double) {
        for (k, hv) in h.enumerated() where hv != 0 {
            for (i, xv) in x.enumerated() {
                let idx = offset + i + k
                if idx < y.count { y[idx] += Float(gain * hv) * xv }
            }
        }
    }

    func testFFTRoundTrip() {
        let fft = FFT(size: 64)
        var re = (0..<64).map { sin(Double($0) * 0.3) }, im = [Double](repeating: 0, count: 64)
        let orig = re
        fft.transform(&re, &im); fft.transform(&re, &im, inverse: true)
        for i in 0..<64 { XCTAssertEqual(re[i], orig[i], accuracy: 1e-9) }
    }

    func testDeconvolutionRecoversDelayAndAmplitude() {
        let fs = 8000.0
        let probe = SweepProbe.sweep(sampleRate: fs, seconds: 0.5, f1: 100)
        var h = [Double](repeating: 0, count: 600)
        h[25] = 0.8; h[400] = 0.3
        var y = [Float](repeating: 0, count: Int(fs * 1.5))
        convolve(probe, h, into: &y, at: 100, gain: 1)
        let ir = Deconvolver.impulseResponse(recording: y, probe: probe)
        let peak = ir.indices.max { abs(ir[$0]) < abs(ir[$1]) }!
        XCTAssertEqual(peak, 125)
        XCTAssertEqual(Double(ir[peak]), 0.8, accuracy: 0.12)
        XCTAssertEqual(Double(ir[500]), 0.3, accuracy: 0.12)
    }

    func testAnalysisFindsRelativeArrivalAcrossSlotsAndPasses() {
        let fs = 8000.0
        let probe = SweepProbe.sweep(sampleRate: fs, seconds: 0.5, f1: 100)
        let delta = 0.12                                   // unknown start offset between source and recording
        let applied = [0.0, 30.0]                          // ms the router applied to each speaker
        let hs = [room(fs: fs, arrival: 0.010, direct: 1.0, tail: 0.05, seed: 1, length: 2400),
                  room(fs: fs, arrival: 0.022, direct: 0.9, tail: 0.05, seed: 2, length: 2400)]
        let slots = [SlotSpec(speaker: 0, gain: 1.0, startSec: 0.3, appliedDelayMs: applied[0]),
                     SlotSpec(speaker: 1, gain: 1.0, startSec: 2.5, appliedDelayMs: applied[1]),
                     SlotSpec(speaker: 0, gain: 0.6, startSec: 4.702, appliedDelayMs: applied[0]),
                     SlotSpec(speaker: 1, gain: 0.6, startSec: 6.902, appliedDelayMs: applied[1])]
        var y = [Float](repeating: 0, count: Int(fs * 9.5))
        var rng = LCG(s: 99)
        for s in slots {
            convolve(probe, hs[s.speaker], into: &y, at: Int((s.startSec + s.appliedDelayMs / 1000 + delta) * fs), gain: s.gain)
        }
        for i in 0..<y.count { y[i] += Float(0.002 * rng.next()) }

        let m = CalibrationAnalysis.analyze(recording: y, sampleRate: fs, probe: probe, slots: slots, speakerCount: 2)
        guard let a = m.speakers[0], let b = m.speakers[1] else { return XCTFail("a speaker was not detected") }
        XCTAssertEqual(a.arrival, delta + 0.010, accuracy: 2 / fs)
        XCTAssertEqual(b.arrival - a.arrival, 0.012, accuracy: 2 / fs)
        XCTAssertGreaterThan(a.consistency, 0.9)
    }

    /// Music-like programme: decaying tone bursts over coloured noise, different in every slot.
    private func music(fs: Double, seconds: Double, seed: UInt64) -> [Float] {
        var rng = LCG(s: seed)
        let n = Int(seconds * fs)
        var x = [Float](repeating: 0, count: n)
        var lp = 0.0
        for i in 0..<n { lp = 0.7 * lp + 0.3 * rng.next(); x[i] = Float(0.15 * lp) }
        for _ in 0..<40 {
            let f = 150 + 3000 * (rng.next() + 1) / 2, start = Int((rng.next() + 1) / 2 * Double(n - 1200)), amp = 0.3 * (rng.next() + 1) / 2
            for i in 0..<1200 { x[start + i] += Float(amp * sin(2 * Double.pi * f * Double(i) / fs) * exp(-Double(i) / 300)) }
        }
        return x
    }

    func testAnalysisWorksWithMusicAsTheProbe() {
        let fs = 8000.0
        let delta = 0.2
        let hs = [room(fs: fs, arrival: 0.012, direct: 1.0, tail: 0.05, seed: 21, length: 2400),
                  room(fs: fs, arrival: 0.030, direct: 0.8, tail: 0.05, seed: 22, length: 2400)]
        let slots = [SlotSpec(speaker: 0, gain: 1.0, startSec: 0.3, appliedDelayMs: 0),
                     SlotSpec(speaker: 1, gain: 1.0, startSec: 3.3, appliedDelayMs: 40),
                     SlotSpec(speaker: 0, gain: 0.6, startSec: 6.3, appliedDelayMs: 0),
                     SlotSpec(speaker: 1, gain: 0.6, startSec: 9.3, appliedDelayMs: 40)]
        let probes = slots.indices.map { music(fs: fs, seconds: 1.5, seed: UInt64(100 + $0)) }      // a different excerpt per slot
        var y = [Float](repeating: 0, count: Int(fs * 12.5))
        var rng = LCG(s: 7)
        for (k, s) in slots.enumerated() {
            convolve(probes[k], hs[s.speaker], into: &y, at: Int((s.startSec + s.appliedDelayMs / 1000 + delta) * fs), gain: s.gain)
        }
        for i in 0..<y.count { y[i] += Float(0.003 * rng.next()) }
        let m = CalibrationAnalysis.analyze(recording: y, sampleRate: fs, probes: probes.map { $0 }, slots: slots, speakerCount: 2)
        guard let a = m.speakers[0], let b = m.speakers[1] else { return XCTFail("a speaker was not detected") }
        XCTAssertEqual(a.arrival, delta + 0.012, accuracy: 2 / fs)
        XCTAssertEqual(b.arrival - a.arrival, 0.018, accuracy: 2 / fs)
        XCTAssertGreaterThan(a.consistency, 0.7)       // the two passes used different excerpts, yet agree
    }

    func testSegmentPickerSkipsQuietPartsAndResamplerKeepsDuration() {
        var x = [Float](repeating: 0, count: 8000 * 10)
        for i in (8000 * 4)..<(8000 * 6) { x[i] = 0.5 }
        let picks = SegmentPicker.loudest(x, sampleRate: 8000, seconds: 1, count: 2)
        XCTAssertEqual(picks, [8000 * 4, 8000 * 5])
        XCTAssertEqual(Resampler.linear([Float](repeating: 1, count: 4800), from: 48000, to: 44100).count, 4410)
        XCTAssertEqual(SegmentPicker.normalized(x[(8000 * 4)..<(8000 * 5)], rms: 0.1).max()!, 0.1, accuracy: 1e-5)
    }

    func testAnalysisReportsSilentSpeaker() {
        let fs = 8000.0
        let probe = SweepProbe.sweep(sampleRate: fs, seconds: 0.5, f1: 100)
        var y = [Float](repeating: 0, count: Int(fs * 6))
        var rng = LCG(s: 5)
        var h = [Double](repeating: 0, count: 200); h[10] = 1
        convolve(probe, h, into: &y, at: Int(0.4 * fs), gain: 1)         // only speaker 0 is audible
        for i in 0..<y.count { y[i] += Float(0.002 * rng.next()) }
        let slots = [SlotSpec(speaker: 0, gain: 1, startSec: 0.3, appliedDelayMs: 0),
                     SlotSpec(speaker: 1, gain: 1, startSec: 2.5, appliedDelayMs: 0)]
        let m = CalibrationAnalysis.analyze(recording: y, sampleRate: fs, probe: probe, slots: slots, speakerCount: 2)
        XCTAssertNotNil(m.speakers[0])
        XCTAssertNil(m.speakers[1])
    }

    private func response(fs: Double, arrivals: [Double], directs: [Double], seeds: [UInt64]) -> MicResponse {
        let pre = Int(0.001 * fs), len = Int(0.3 * fs)
        let sp: [SpeakerIR?] = arrivals.indices.map { i in
            var rng = LCG(s: seeds[i])
            var h = [Double](repeating: 0, count: pre + len)
            h[pre] = directs[i]
            for t in (pre + Int(0.004 * fs))..<h.count { h[t] = 0.08 * rng.next() * exp(-Double(t - pre) / (0.08 * fs)) }
            return SpeakerIR(h: h, pre: pre, arrival: arrivals[i], snr: 100, consistency: 1)
        }
        return MicResponse(sampleRate: fs, speakers: sp)
    }

    func testOptimizerAlignsSpeakersAndImprovesScore() {
        let fs = 8000.0
        // Speaker 1 is 12 ms further from the microphone → arrives later; with equal delays the two comb-filter.
        let mic = response(fs: fs, arrivals: [0.010, 0.022], directs: [1.0, 0.9], seeds: [11, 12])
        let out = RoomOptimizer.optimize(mics: [mic], baselineDelaysMs: [0, 0], baselineGains: [1, 1])!
        XCTAssertLessThan(out.scoreAfter, out.scoreBefore)
        XCTAssertGreaterThan(out.improvement, 0.1)
        XCTAssertEqual(out.delaysMs[0] - out.delaysMs[1], 12, accuracy: 3)     // the nearer speaker is held back
        XCTAssertEqual(out.delaysMs.min()!, 0, accuracy: 1e-9)
        XCTAssertTrue(out.gains.allSatisfy { $0 >= RoomOptimizer.minGain && $0 <= 1 })
    }

    func testOptimizerNeverWorsensAnAlreadyGoodSetting() {
        let fs = 8000.0
        let mic = response(fs: fs, arrivals: [0.010, 0.022], directs: [1.0, 0.9], seeds: [11, 12])
        let first = RoomOptimizer.optimize(mics: [mic], baselineDelaysMs: [0, 0], baselineGains: [1, 1])!
        let again = RoomOptimizer.optimize(mics: [mic], baselineDelaysMs: first.delaysMs, baselineGains: first.gains)!
        XCTAssertLessThanOrEqual(again.scoreAfter, again.scoreBefore + 1e-9)
        XCTAssertLessThan(abs(again.scoreAfter - first.scoreAfter), 0.5)
    }

    func testOptimizerKeepsUserGainsWhenAskedTo() {
        let fs = 8000.0
        let mic = response(fs: fs, arrivals: [0.010, 0.022], directs: [1.0, 0.9], seeds: [11, 12])
        let out = RoomOptimizer.optimize(mics: [mic], baselineDelaysMs: [0, 0], baselineGains: [1.7, 0.2], optimizeGains: false)!
        XCTAssertEqual(out.gains, [1.7, 0.2])
        XCTAssertLessThan(out.scoreAfter, out.scoreBefore)
        XCTAssertEqual(out.delaysMs[0] - out.delaysMs[1], 12, accuracy: 3)
    }

    func testOptimizerUsesAllMicrophones() {
        let fs = 8000.0
        let a = response(fs: fs, arrivals: [0.010, 0.022], directs: [1.0, 0.9], seeds: [11, 12])
        let b = response(fs: fs, arrivals: [0.012, 0.020], directs: [0.9, 1.0], seeds: [13, 14])
        let out = RoomOptimizer.optimize(mics: [a, b], baselineDelaysMs: [0, 0], baselineGains: [1, 1])!
        XCTAssertEqual(out.micScoresBefore.count, 2)
        XCTAssertLessThan(out.scoreAfter, out.scoreBefore)
        XCTAssertNil(RoomOptimizer.optimize(mics: [MicResponse(sampleRate: fs, speakers: [nil, nil])],
                                            baselineDelaysMs: [0, 0], baselineGains: [1, 1]))
    }

    // MARK: Simultaneous (joint) measurement

    /// Colour noise standing in for music: low-passed white noise with a slow envelope.
    private func music(seconds: Double, fs: Double, seed: UInt64) -> [Float] {
        var rng = LCG(s: seed)
        var lp = 0.0
        return (0..<Int(seconds * fs)).map { i in
            lp = 0.9 * lp + 0.1 * rng.next()
            return Float(lp * 2.5 * (0.6 + 0.4 * sin(Double(i) / fs * 3)))
        }
    }

    private func jointScenario(noise: Double) -> (MicResponse, [Double], [JointTrial], [[Float]], [Float]) {
        let fs = 8000.0, n = 2
        let arrivals = [0.010, 0.022]
        let base = [0.0, 20.0]
        var trials = [JointTrial(startSec: 0, gains: [1, 1], delaysMs: base)]
        for k in 1...n {
            trials.append(JointTrial(startSec: 0, gains: (0..<n).map { $0 == k - 1 ? 1 : 0.4 },
                                     delaysMs: (0..<n).map { base[$0] + Double(($0 + k) % n) * 1.5 }))
        }
        trials.append(JointTrial(startSec: 0, gains: [1, 1], delaysMs: (0..<n).map { base[$0] + Double($0) * 2.5 }))
        var y = [Float](repeating: 0, count: Int(fs * 24))
        var probes: [[Float]] = []
        var rng = LCG(s: 77)
        for k in trials.indices {
            trials[k].startSec = 0.5 + Double(k) * 5
            let x = music(seconds: 1.5, fs: fs, seed: UInt64(100 + k)); probes.append(x)
            for i in 0..<n {
                let h = room(fs: fs, arrival: arrivals[i] + 0.1, direct: 1.0 - 0.1 * Double(i), tail: 0.04, seed: UInt64(5 + i), length: 1600)
                convolve(x, h, into: &y, at: Int((trials[k].startSec + trials[k].delaysMs[i] / 1000) * fs), gain: trials[k].gains[i])
            }
        }
        for i in 0..<y.count { y[i] += Float(0.002 * rng.next()) }
        if noise > 0 {
            for i in Int(5.6 * fs)..<Int(7.0 * fs) { y[i] += Float(noise * rng.next()) }     // burst 1 is disturbed
        }
        let m = CalibrationAnalysis.identify(recording: y, sampleRate: fs, trials: trials, probes: probes, speakerCount: n)
        return (m, arrivals, trials, probes, y)
    }

    func testJointIdentificationSeparatesSpeakersPlayingTogether() {
        let (m, arrivals, _, _, _) = jointScenario(noise: 0)
        let fs = 8000.0
        guard let a = m.speakers[0], let b = m.speakers[1] else { return XCTFail("speaker not identified") }
        XCTAssertEqual(b.arrival - a.arrival, arrivals[1] - arrivals[0], accuracy: 2 / fs)
        XCTAssertGreaterThan(a.consistency, 0.9)
    }

    func testFitQualityDropsWhenOtherSoundsAreMixedIn() {
        let fs = 8000.0
        let clean = jointScenario(noise: 0), noisy = jointScenario(noise: 3)
        let q0 = CalibrationAnalysis.fitQuality(recording: clean.4, sampleRate: fs, probe: clean.3[1], startSec: clean.2[1].startSec)
        let q1 = CalibrationAnalysis.fitQuality(recording: noisy.4, sampleRate: fs, probe: noisy.3[1], startSec: noisy.2[1].startSec)
        XCTAssertGreaterThan(q0, 0.95)
        XCTAssertLessThan(q1, 0.8)
    }

    func testAudibleSharesFindsASpeakerTheMicrophoneCannotHear() {
        // Three speakers; speaker 2 (e.g. a virtual device) contributes nothing to what the microphone records.
        let power = [1.0, 0.6, 0.0]
        let gains: [[Double]] = [[1, 1, 1], [1, 0.4, 0.4], [0.4, 1, 0.4], [0.4, 0.4, 1]]
        let levels = gains.map { g in zip(g, power).reduce(0) { $0 + $1.0 * $1.0 * $1.1 } }
        let s = CalibrationAnalysis.audibleShares(levels: levels, gains: gains)
        XCTAssertEqual(s[0], 1.0 / 1.6, accuracy: 0.01)
        XCTAssertEqual(s[1], 0.6 / 1.6, accuracy: 0.01)
        XCTAssertLessThan(s[2], 0.01)
    }

    #if canImport(Accelerate)
    func testAcceleratedFFTMatchesThePortableOne() {
        for size in [64, 1024, 65536] {
            var rng = LCG(s: UInt64(size))
            let re0 = (0..<size).map { _ in rng.next() }, im0 = (0..<size).map { _ in rng.next() }
            let fft = FFT(size: size)
            FFT.useAccelerate = false
            var ar = re0, ai = im0
            fft.transform(&ar, &ai); let fr = ar, fi = ai
            fft.transform(&ar, &ai, inverse: true)
            FFT.useAccelerate = true
            var br = re0, bi = im0
            fft.transform(&br, &bi)
            for i in 0..<size { XCTAssertEqual(br[i], fr[i], accuracy: 1e-8 * Double(size)); XCTAssertEqual(bi[i], fi[i], accuracy: 1e-8 * Double(size)) }
            fft.transform(&br, &bi, inverse: true)
            for i in 0..<size { XCTAssertEqual(br[i], re0[i], accuracy: 1e-9); XCTAssertEqual(ar[i], re0[i], accuracy: 1e-9) }
        }
    }

    func testAcceleratedFFTIsSafeFromSeveralThreadsAndFaster() {
        let size = 131072
        let fft = FFT(size: size)
        var rng = LCG(s: 5)
        let re0 = (0..<size).map { _ in rng.next() }
        var ref = re0, refI = [Double](repeating: 0, count: size)
        fft.transform(&ref, &refI)
        var bad = 0
        let lock = NSLock()
        DispatchQueue.concurrentPerform(iterations: 16) { _ in
            var r = re0, i = [Double](repeating: 0, count: size)
            for _ in 0..<5 { r = re0; i = [Double](repeating: 0, count: size); fft.transform(&r, &i) }
            if abs(r[1234] - ref[1234]) > 1e-6 || abs(i[777] - refI[777]) > 1e-6 { lock.lock(); bad += 1; lock.unlock() }
        }
        XCTAssertEqual(bad, 0)
        func time(_ acc: Bool) -> Double {
            FFT.useAccelerate = acc
            var r = re0, i = [Double](repeating: 0, count: size)
            let t = Date()
            for _ in 0..<20 { r = re0; i = [Double](repeating: 0, count: size); fft.transform(&r, &i) }
            return Date().timeIntervalSince(t) / 20
        }
        let slow = time(false), fast = time(true)
        FFT.useAccelerate = true
        print("FFTBENCH 131072-point: portable \(slow * 1000) ms, accelerate \(fast * 1000) ms (\(slow / fast)x)")
    }
    #endif

    // MARK: Model refinement and volume balance

    func testVolumeBalanceSuggestsLoudeningTheSpeakerThatIsQuietAtAMicrophone() {
        // Two microphones, two speakers. Mic 0 is next to speaker 0, mic 1 next to speaker 1, but speaker 1 is 8 dB quieter.
        let power: [[Double]] = [[1.0, 0.1], [0.05, 0.16]]
        let s = try! XCTUnwrap(VolumeBalance.suggest(power: power))
        XCTAssertLessThan(s.spreadAfterDb, s.spreadBeforeDb)
        XCTAssertGreaterThan(s.gainsDb[1], s.gainsDb[0], "the quiet speaker should be raised relative to the loud one")
        XCTAssertEqual(s.gainsDb.reduce(0, +), 0, accuracy: 1e-9)
        XCTAssertNil(VolumeBalance.suggest(power: [[1, 1]]), "one microphone cannot say anything about evenness")
    }

    func testVolumeBalanceLeavesAnEvenRoomAlone() {
        let s = try! XCTUnwrap(VolumeBalance.suggest(power: [[1, 1], [1, 1], [1, 1]]))
        XCTAssertTrue(s.gainsDb.allSatisfy { abs($0) < 0.51 })
        XCTAssertLessThan(s.spreadBeforeDb, 0.01)
    }

    /// A model whose speaker 1 arrival is 9 ms off; the measured combined response has it where it really is.
    func testModelRefinerFindsAMisTimedSpeakerAndLeavesTheCorrectOnesAlone() throws {
        let fs = 8000.0
        func model(_ arrivals: [Double]) -> MicResponse {
            let pre = max(1, Int(0.001 * fs)), len = Int(0.2 * fs)
            return MicResponse(sampleRate: fs, speakers: arrivals.enumerated().map { i, a in
                var h = [Double](repeating: 0, count: pre + len)
                h[pre] = 1.0; h[pre + 1] = -0.5 + 0.1 * Double(i); h[pre + 2] = 0.3
                return SpeakerIR(h: h, pre: pre, arrival: a, snr: 100, consistency: 1)
            })
        }
        let truth = model([0.030, 0.071, 0.120]), assumed = model([0.030, 0.062, 0.120])
        let delays = [40.0, 0.0, 15.0]
        let n = 8192, pad = 800
        var ir = [Float](repeating: 0, count: pad + n)
        var rng = LCG(s: 4)
        for (i, sp) in truth.speakers.enumerated() {
            let start = pad + Int(((sp!.arrival + delays[i] / 1000) * fs).rounded()) - sp!.pre
            for (j, v) in sp!.h.prefix(sp!.pre + 80).enumerated() { ir[start + j] += Float(v) }
        }
        for t in 0..<ir.count { ir[t] += Float(0.02 * rng.next()) }           // noise / tails
        let obs = [Observation(mic: 0, delaysMs: delays, ir: ir, pad: pad)]
        let e = try XCTUnwrap(ModelRefiner.estimate(model: [assumed], observations: obs))
        XCTAssertEqual(e.biasMs[1], 9, accuracy: 0.6)
        XCTAssertEqual(e.biasMs[0], 0, accuracy: 0.3)
        XCTAssertEqual(e.biasMs[2], 0, accuracy: 0.3)
        XCTAssertLessThan(e.costAfter, e.costZero)
        // A correct model: no correction.
        let ok = try XCTUnwrap(ModelRefiner.estimate(model: [truth], observations: obs))
        XCTAssertTrue(ok.biasMs.allSatisfy { abs($0) < 0.3 })
    }
}
