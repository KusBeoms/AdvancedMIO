import XCTest
@testable import MIOCore

private final class SimClock { var t = 0.0 }

/// Drives writer/reader the way two CoreAudio devices would: fixed-size callbacks at their own rates.
private struct Sim {
    let clock = SimClock()
    let ring: StereoRing
    let reader: DelayReader
    let inRate: Double, outRate: Double
    /// The rate the output device really runs at, when it differs from the nominal `outRate` the reader is told (clock drift).
    let outClock: Double
    var inFrame = 0                 // next input frame index (signal = f(inFrame))
    var outTime = 0.0               // seconds of output rendered
    var inTime = 0.0                // seconds of input delivered
    var out: [Float] = []           // left channel output
    var signal: (Int) -> Float

    init(inRate: Double = 48000, outRate: Double = 48000, outClock: Double? = nil, delayMs: Double = 0,
         signal: @escaping (Int) -> Float = { Float($0) * 1e-6 }) {
        self.inRate = inRate; self.outRate = outRate; self.outClock = outClock ?? outRate
        ring = StereoRing(sampleRate: inRate)
        let c = clock
        ring.clock = { c.t }
        reader = DelayReader(ring: ring, outputSampleRate: outRate, delayMs: delayMs)
        self.signal = signal
    }

    mutating func writeBlock(_ n: Int) {
        clock.t = inTime
        var l = (0..<n).map { signal(inFrame + $0) }
        var r = l
        l.withUnsafeMutableBufferPointer { lp in r.withUnsafeMutableBufferPointer { rp in
            ring.write(left: lp.baseAddress!, right: rp.baseAddress!, frames: n) } }
        inFrame += n
        inTime += Double(n) / inRate
    }
    mutating func readBlock(_ n: Int) {
        clock.t = outTime
        var l = [Float](repeating: 0, count: n), r = l
        l.withUnsafeMutableBufferPointer { lp in r.withUnsafeMutableBufferPointer { rp in
            reader.render(into: lp.baseAddress!, rp.baseAddress!, frames: n) } }
        out.append(contentsOf: l)
        outTime += Double(n) / outClock
    }
    /// Run for `seconds` with writer chunk `wChunk` and reader chunk `rChunk`, scheduling by time.
    mutating func run(seconds: Double, wChunk: Int = 512, rChunk: Int = 512) {
        let end = max(inTime, outTime) + seconds
        while inTime < end || outTime < end {
            if inTime <= outTime { writeBlock(wChunk) } else { readBlock(rChunk) }
        }
    }
}

final class DelayReaderTests: XCTestCase {
    /// Delay between the newest input and the sample being played, in ms, via the ramp signal.
    private func measuredDelayMs(_ sim: Sim, tail: Int = 256) -> Double {
        let last = sim.out.suffix(tail)
        let avg = last.reduce(0, +) / Float(last.count)
        let playedFrame = Double(avg) / 1e-6 + 0     // input-frame index being played (averaged window)
        let newest = sim.outTime * sim.inRate     // where the input is *now* (inFrame itself jumps in whole chunks)
        return (newest - playedFrame) / sim.inRate * 1000
    }

    func testSilenceBeforePrimed() {
        var sim = Sim()
        sim.readBlock(512)
        XCTAssertTrue(sim.out.allSatisfy { $0 == 0 })
    }

    func testZeroDelayHasSmallLatency() {
        var sim = Sim(delayMs: 0)
        sim.run(seconds: 1)
        let d = measuredDelayMs(sim)
        XCTAssertLessThan(d, 40, "zero delay should stay under ~40 ms with 512-frame buffers, got \(d)")
        XCTAssertGreaterThan(d, 0)
    }

    func testDelayIsAddedPrecisely() {
        for ms in [0.0, 1, 10, 100, 250, 500, 999, 1000] {
            var base = Sim(delayMs: 0); base.run(seconds: 2)
            var sim = Sim(delayMs: ms); sim.run(seconds: 3)
            let diff = measuredDelayMs(sim) - measuredDelayMs(base)
            XCTAssertEqual(diff, ms, accuracy: 1.5, "delay \(ms) ms measured as \(diff)")
        }
    }

    func testOutputIsContinuousRampAtSteadyState() {
        var sim = Sim(delayMs: 123); sim.run(seconds: 2)
        let tail = Array(sim.out.suffix(20000))
        // Ramp slope per output frame is 1e-6 (same rate, adj≈0) – no jumps allowed.
        var maxJump: Float = 0
        for i in 1..<tail.count { maxJump = max(maxJump, abs(tail[i] - tail[i - 1])) }
        XCTAssertLessThan(maxJump, 2e-6)
    }

    func testChangingDelayWhilePlayingConverges() {
        var sim = Sim(delayMs: 0); sim.run(seconds: 1)
        let d0 = measuredDelayMs(sim)
        sim.reader.setDelay(ms: 700)
        sim.run(seconds: 1)
        XCTAssertEqual(measuredDelayMs(sim) - d0, 700, accuracy: 2)
        sim.reader.setDelay(ms: 40)
        sim.run(seconds: 1)
        XCTAssertEqual(measuredDelayMs(sim) - d0, 40, accuracy: 2)
    }

    func testSmallDelayChangeSlewsWithoutJump() {
        var sim = Sim(delayMs: 100); sim.run(seconds: 1)
        sim.reader.setDelay(ms: 105)    // 5 ms: below jump threshold → slewed, not hopped
        let before = sim.reader.resyncCount
        sim.run(seconds: 2)
        XCTAssertEqual(sim.reader.resyncCount, before)
    }

    func testBigDelayChangeHopsWithCrossfadeNoHugeClick() {
        // A sine's natural max sample step is ≈0.0576. Delays are ≈ (k+½) periods of 440 Hz so the
        // hop is a ~180° phase jump; whole periods would hide a missing crossfade.
        for ms in [228.409, 455.68, 682.95, 909.09] {   // ≈ k + ½ periods → worst-case phase jump
            var sim = Sim(delayMs: 0, signal: { Float(sin(Double($0) * 2 * .pi * 440 / 48000)) })
            sim.run(seconds: 1)
            let mark = sim.out.count
            sim.reader.setDelay(ms: ms)
            sim.run(seconds: 1.5)
            XCTAssertGreaterThanOrEqual(sim.reader.resyncCount, 1)
            let seg = Array(sim.out[(mark - 1)...])   // include the sample just before the hop
            var maxStep: Float = 0
            for i in 1..<seg.count { maxStep = max(maxStep, abs(seg[i] - seg[i - 1])) }
            XCTAssertLessThan(maxStep, 0.075, "hop to \(ms) ms produced a click: \(maxStep)")
        }
    }

    func testDriftCompensationKeepsLagBounded() {
        // Output clock 0.05% faster than input (≈ 24 frames/s) for 60 s.
        var sim = Sim(inRate: 48000, outRate: 48024, delayMs: 200)
        sim.run(seconds: 6)
        let d0 = measuredDelayMs(sim)
        sim.run(seconds: 60)
        XCTAssertEqual(measuredDelayMs(sim), d0, accuracy: 3)
        XCTAssertLessThanOrEqual(sim.reader.resyncCount, 1)
        // And the other direction.
        var sim2 = Sim(inRate: 48024, outRate: 48000, delayMs: 200)
        sim2.run(seconds: 6)
        let e0 = measuredDelayMs(sim2)
        sim2.run(seconds: 60)
        XCTAssertEqual(measuredDelayMs(sim2), e0, accuracy: 3)
    }

    func testRealClockDriftIsAbsorbedWithoutWobble() {
        // The device claims 48000 Hz but its clock runs 500 ppm fast (and, in the other run, slow): the reader is not
        // told, so the lag control has to find and follow the mismatch on its own.
        for clock in [48024.0, 47976.0] {
            var sim = Sim(inRate: 48000, outRate: 48000, outClock: clock, delayMs: 100)
            sim.run(seconds: 8)
            let d0 = measuredDelayMs(sim)
            sim.run(seconds: 40)
            XCTAssertEqual(measuredDelayMs(sim), d0, accuracy: 3, "clock \(clock)")
            XCTAssertLessThanOrEqual(sim.reader.resyncCount, 1, "clock \(clock)")
            let x = Array(sim.out.suffix(96000))
            var worst = 0.0
            // 2048-frame windows: by now the ramp has grown large enough that Float resolution blurs shorter ones.
            for i in stride(from: 0, to: x.count - 2048, by: 101) {
                let slope = Double(x[i + 2048] - x[i]) / 2048 / 1e-6
                worst = max(worst, abs(slope - 1))
            }
            XCTAssertLessThan(worst, 0.003, "clock \(clock): speed deviation \(worst * 100) %")
        }
    }

    /// Playback speed must not wobble: a ramp (slope 1e-6/frame) read at the same rate must keep its slope within
    /// 0.2 % over every 256-frame window (shorter windows hit the ramp's Float resolution). Chunked writers used to make the drift correction swing speed by ±1 %,
    /// which is audible as roughness / "broken" sound.
    func testPlaybackSpeedIsStable() {
        for (w, r) in [(512, 512), (480, 512), (256, 1024), (1024, 256)] {
            var sim = Sim(delayMs: 40); sim.run(seconds: 4, wChunk: w, rChunk: r)
            let x = Array(sim.out.suffix(96000))
            var worst = 0.0
            for i in stride(from: 0, to: x.count - 256, by: 17) {
                let slope = Double(x[i + 256] - x[i]) / 256 / 1e-6
                worst = max(worst, abs(slope - 1))
            }
            XCTAssertLessThan(worst, 0.002, "speed wobbled by \(worst * 100) % with writer \(w) / reader \(r)")
        }
    }

    func testSampleRateConversionPreservesPitch() {
        let f = 1000.0
        var sim = Sim(inRate: 44100, outRate: 48000, delayMs: 50,
                      signal: { Float(sin(Double($0) * 2 * .pi * 1000 / 44100)) })
        sim.run(seconds: 2)
        let x = Array(sim.out.suffix(48000))
        var crossings = 0
        for i in 1..<x.count where x[i - 1] < 0 && x[i] >= 0 { crossings += 1 }
        XCTAssertEqual(Double(crossings), f, accuracy: 3)    // 1 s window → ~1000 zero crossings
        XCTAssertLessThan(x.map { abs($0) }.max()! , 1.01)
    }

    func testPlaybackSpeedStaysStableWithClockDrift() {
        // Output clock 0.05 % fast: speed may follow the drift (≤ 0.1 %) but not wobble.
        var sim = Sim(inRate: 48000, outRate: 48024, delayMs: 60)
        sim.run(seconds: 6)
        let x = Array(sim.out.suffix(96000))
        var worst = 0.0
        for i in stride(from: 0, to: x.count - 256, by: 23) {
            let slope = Double(x[i + 256] - x[i]) / 256 / 1e-6
            worst = max(worst, abs(slope - 48000.0 / 48024.0))
        }
        XCTAssertLessThan(worst, 0.002)
    }

    func testResamplingKeepsHighFrequencyLevel() {
        // 5 kHz tone 44.1 → 48 kHz: linear interpolation would droop by up to ~6 %; cubic stays within ~1 %.
        var sim = Sim(inRate: 44100, outRate: 48000, delayMs: 20,
                      signal: { Float(sin(Double($0) * 2 * .pi * 5000 / 44100)) })
        sim.run(seconds: 2)
        let peak = sim.out.suffix(24000).map { abs($0) }.max()!
        XCTAssertGreaterThan(peak, 0.985)
        XCTAssertLessThan(peak, 1.015)
    }

    /// Share of the output that is *not* the expected pure tone (images, aliasing, distortion), in dB.
    private func residualDb(_ x: [Float], hz: Double, rate: Double) -> Double {
        var a = 0.0, b = 0.0, power = 0.0
        for (n, v) in x.enumerated() {
            let w = 2 * Double.pi * hz * Double(n) / rate
            a += Double(v) * cos(w); b += Double(v) * sin(w); power += Double(v) * Double(v)
        }
        let N = Double(x.count)
        a *= 2 / N; b *= 2 / N
        let signal = (a * a + b * b) / 2 * N
        return 10 * log10(max(1e-20, power - signal) / signal)
    }

    func testUpsamplingTo96kStaysClean() {
        // A 96 kHz speaker fed from the 48 kHz virtual device. 15 kHz is where cheap interpolation images the worst.
        var sim = Sim(inRate: 48000, outRate: 96000, delayMs: 30,
                      signal: { Float(0.5 * sin(Double($0) * 2 * .pi * 15000 / 48000)) })
        sim.run(seconds: 2)      // inside the settle period: no speed trim yet, so only the resampler is measured
        let x = Array(sim.out.suffix(2400))
        XCTAssertLessThan(residualDb(x, hz: 15000, rate: 96000), -55)
    }

    func testDownsamplingDoesNotAlias() {
        // 96 kHz → 48 kHz of a 30 kHz tone: it is above the output's Nyquist and must vanish, not fold down to 18 kHz.
        var sim = Sim(inRate: 96000, outRate: 48000, delayMs: 30,
                      signal: { Float(0.5 * sin(Double($0) * 2 * .pi * 30000 / 96000)) })
        sim.run(seconds: 3)
        let peak = sim.out.suffix(9600).map { abs($0) }.max()!
        XCTAssertLessThan(peak, 0.01)
    }

    func testSameRateIsTransparent() {
        var sim = Sim(inRate: 48000, outRate: 48000, delayMs: 30,
                      signal: { Float(0.5 * sin(Double($0) * 2 * .pi * 12000 / 48000)) })
        sim.run(seconds: 2)
        XCTAssertLessThan(residualDb(Array(sim.out.suffix(1200)), hz: 12000, rate: 48000), -60)
    }

    func testMismatchedBufferSizesStayStable() {
        var sim = Sim(delayMs: 0)
        sim.run(seconds: 5, wChunk: 128, rChunk: 1024)
        XCTAssertTrue(sim.out.suffix(20000).allSatisfy { $0 > 0 })
        var sim2 = Sim(delayMs: 0)
        sim2.run(seconds: 5, wChunk: 2048, rChunk: 64)
        XCTAssertTrue(sim2.out.suffix(20000).allSatisfy { $0 > 0 })
    }

    func testRecoversFromInputStall() {
        var sim = Sim(delayMs: 10)
        sim.run(seconds: 1)
        // Reader runs 1 s with no new input (device paused) – then input resumes.
        for _ in 0..<94 { sim.readBlock(512) }
        sim.inTime = sim.outTime
        sim.run(seconds: 2)
        let tail = sim.out.suffix(10000)
        XCTAssertTrue(tail.allSatisfy { $0 > 0 }, "should be playing again")
    }

    func testGainRampsAndSums() {
        var sim = Sim(delayMs: 0, signal: { _ in 0.5 })
        sim.run(seconds: 1)
        XCTAssertEqual(sim.out.last!, 0.5, accuracy: 1e-4)
        sim.reader.setGain(0)
        sim.run(seconds: 0.2)
        XCTAssertEqual(sim.out.last!, 0, accuracy: 1e-6)
        // Ramp: no single-step cliff.
        var maxStep: Float = 0
        let seg = Array(sim.out.suffix(9600 + 512))
        for i in 1..<seg.count { maxStep = max(maxStep, abs(seg[i] - seg[i - 1])) }
        XCTAssertLessThan(maxStep, 0.01)
    }

    func testTwoInputsAreSummed() {
        let a = StereoRing(sampleRate: 48000), b = StereoRing(sampleRate: 48000)
        let ra = DelayReader(ring: a, outputSampleRate: 48000), rb = DelayReader(ring: b, outputSampleRate: 48000)
        var x = [Float](repeating: 0.25, count: 512), y = [Float](repeating: 0.5, count: 512)
        var l = [Float](repeating: 0, count: 512), r = l
        for _ in 0..<10 {
            x.withUnsafeBufferPointer { p in a.write(left: p.baseAddress!, right: p.baseAddress!, frames: 512) }
            y.withUnsafeBufferPointer { p in b.write(left: p.baseAddress!, right: p.baseAddress!, frames: 512) }
            l = [Float](repeating: 0, count: 512); r = l
            l.withUnsafeMutableBufferPointer { lp in r.withUnsafeMutableBufferPointer { rp in
                ra.render(into: lp.baseAddress!, rp.baseAddress!, frames: 512)
                rb.render(into: lp.baseAddress!, rp.baseAddress!, frames: 512) } }
        }
        XCTAssertEqual(l[100], 0.75, accuracy: 1e-5)
        _ = (x, y)
        x[0] = 0; y[0] = 0
    }

    func testPeakReported() {
        var sim = Sim(delayMs: 0, signal: { _ in 0.4 })
        sim.run(seconds: 0.5)
        var l = [Float](repeating: 0, count: 512), r = l
        let p: Float = l.withUnsafeMutableBufferPointer { lp in r.withUnsafeMutableBufferPointer { rp in
            sim.reader.render(into: lp.baseAddress!, rp.baseAddress!, frames: 512) } }
        XCTAssertEqual(p, 0.4, accuracy: 1e-4)
    }

    func testRingOverflowWriteKeepsNewest() {
        let ring = StereoRing(sampleRate: 48000, capacityFrames: 1024)
        var s = (0..<3000).map { Float($0) }
        s.withUnsafeMutableBufferPointer { p in ring.write(left: p.baseAddress!, right: p.baseAddress!, frames: 3000) }
        XCTAssertEqual(ring.writeIndex, 3000)
    }

    func testExtremeDelayWithSmallRingDoesNotCrash() {
        let ring = StereoRing(sampleRate: 192000, capacityFrames: 1 << 14)
        let rd = DelayReader(ring: ring, outputSampleRate: 48000, delayMs: 1000)
        var z = [Float](repeating: 0.1, count: 512)
        var l = z, r = z
        for _ in 0..<100 {
            z.withUnsafeMutableBufferPointer { p in ring.write(left: p.baseAddress!, right: p.baseAddress!, frames: 512) }
            l.withUnsafeMutableBufferPointer { lp in r.withUnsafeMutableBufferPointer { rp in
                rd.render(into: lp.baseAddress!, rp.baseAddress!, frames: 512) } }
        }
    }
}
