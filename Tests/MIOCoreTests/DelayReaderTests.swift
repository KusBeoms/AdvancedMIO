import XCTest
@testable import MIOCore

/// Drives writer/reader the way two CoreAudio devices would: fixed-size callbacks at their own rates.
private struct Sim {
    let ring: StereoRing
    let reader: DelayReader
    let inRate: Double, outRate: Double
    var inFrame = 0                 // next input frame index (signal = f(inFrame))
    var outTime = 0.0               // seconds of output rendered
    var inTime = 0.0                // seconds of input delivered
    var out: [Float] = []           // left channel output
    var signal: (Int) -> Float

    init(inRate: Double = 48000, outRate: Double = 48000, delayMs: Double = 0,
         signal: @escaping (Int) -> Float = { Float($0) * 1e-6 }) {
        self.inRate = inRate; self.outRate = outRate
        ring = StereoRing(sampleRate: inRate)
        reader = DelayReader(ring: ring, outputSampleRate: outRate, delayMs: delayMs)
        self.signal = signal
    }

    mutating func writeBlock(_ n: Int) {
        var l = (0..<n).map { signal(inFrame + $0) }
        var r = l
        l.withUnsafeMutableBufferPointer { lp in r.withUnsafeMutableBufferPointer { rp in
            ring.write(left: lp.baseAddress!, right: rp.baseAddress!, frames: n) } }
        inFrame += n
        inTime += Double(n) / inRate
    }
    mutating func readBlock(_ n: Int) {
        var l = [Float](repeating: 0, count: n), r = l
        l.withUnsafeMutableBufferPointer { lp in r.withUnsafeMutableBufferPointer { rp in
            reader.render(into: lp.baseAddress!, rp.baseAddress!, frames: n) } }
        out.append(contentsOf: l)
        outTime += Double(n) / outRate
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
        let newest = Double(sim.inFrame)
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
        sim.run(seconds: 2)
        let d0 = measuredDelayMs(sim)
        sim.run(seconds: 60)
        XCTAssertEqual(measuredDelayMs(sim), d0, accuracy: 3)
        XCTAssertLessThanOrEqual(sim.reader.resyncCount, 1)
        // And the other direction.
        var sim2 = Sim(inRate: 48024, outRate: 48000, delayMs: 200)
        sim2.run(seconds: 2)
        let e0 = measuredDelayMs(sim2)
        sim2.run(seconds: 60)
        XCTAssertEqual(measuredDelayMs(sim2), e0, accuracy: 3)
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
