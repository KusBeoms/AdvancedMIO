import XCTest
@testable import MIOCore

final class ThreeBandEQTests: XCTestCase {
    /// Gain in dB the EQ applies to a sine of `hz`.
    private func gainDb(_ s: EQSettings, hz: Double, rate: Double = 48000) -> Double {
        let eq = ThreeBandEQ(sampleRate: rate)
        eq.set(s)
        let n = 48000
        var l = (0..<n).map { Float(sin(Double($0) * 2 * .pi * hz / rate)) }
        var r = l
        l.withUnsafeMutableBufferPointer { lp in r.withUnsafeMutableBufferPointer { rp in
            eq.process(lp.baseAddress!, rp.baseAddress!, frames: n) } }
        let tail = l.suffix(8000)
        let rms = sqrt(tail.reduce(0) { $0 + Double($1 * $1) } / Double(tail.count))
        return 20 * log10(rms / (1 / 2.0.squareRoot()))
    }

    func testFlatIsBitExactBypass() {
        let eq = ThreeBandEQ(sampleRate: 48000)
        eq.set(.flat)
        var l: [Float] = [0.1, -0.5, 0.9], r = l
        l.withUnsafeMutableBufferPointer { lp in r.withUnsafeMutableBufferPointer { rp in
            eq.process(lp.baseAddress!, rp.baseAddress!, frames: 3) } }
        XCTAssertEqual(l, [0.1, -0.5, 0.9])
    }

    func testEachBandBoostsItsRegionAndLeavesTheRest() {
        XCTAssertEqual(gainDb(EQSettings(lowDb: 8), hz: 40), 8, accuracy: 0.6)
        XCTAssertEqual(gainDb(EQSettings(lowDb: 8), hz: 5000), 0, accuracy: 0.3)
        XCTAssertEqual(gainDb(EQSettings(midDb: -6), hz: 1000), -6, accuracy: 0.3)
        XCTAssertEqual(gainDb(EQSettings(midDb: -6), hz: 60), 0, accuracy: 0.3)
        XCTAssertEqual(gainDb(EQSettings(highDb: 10), hz: 16000), 10, accuracy: 0.8)
        XCTAssertEqual(gainDb(EQSettings(highDb: 10), hz: 200), 0, accuracy: 0.3)
    }

    func testGainsAreClampedAndWorkAtOtherRates() {
        XCTAssertEqual(EQSettings(lowDb: 40, midDb: -40, highDb: .nan).lowDb, 12)
        XCTAssertEqual(EQSettings(midDb: -40).midDb, -12)
        XCTAssertEqual(EQSettings(highDb: .nan).highDb, 0)
        XCTAssertEqual(gainDb(EQSettings(midDb: 6), hz: 1000, rate: 44100), 6, accuracy: 0.3)
        XCTAssertEqual(gainDb(EQSettings(midDb: 6), hz: 1000, rate: 96000), 6, accuracy: 0.3)
    }

    func testSwitchingBackToFlatIsClean() {
        let eq = ThreeBandEQ(sampleRate: 48000)
        eq.set(EQSettings(lowDb: 12, midDb: 12, highDb: 12))
        var l = [Float](repeating: 0.3, count: 512), r = l
        l.withUnsafeMutableBufferPointer { lp in r.withUnsafeMutableBufferPointer { rp in
            eq.process(lp.baseAddress!, rp.baseAddress!, frames: 512) } }
        eq.set(.flat)
        l = [Float](repeating: 0.3, count: 512); r = l
        l.withUnsafeMutableBufferPointer { lp in r.withUnsafeMutableBufferPointer { rp in
            eq.process(lp.baseAddress!, rp.baseAddress!, frames: 512) } }
        XCTAssertTrue(l.allSatisfy { $0 == 0.3 })
    }
}
