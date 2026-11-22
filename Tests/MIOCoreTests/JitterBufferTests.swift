import XCTest
@testable import MIOCore

final class JitterBufferTests: XCTestCase {
    private func block() -> JitterBuffer.Block { .init(left: [0], right: [0]) }

    func testUnderrunGrowsCushionByTwo() {
        var j = JitterBuffer(target: 3)
        for _ in 0..<3 { j.push(block()) }
        for _ in 0..<3 { _ = j.pop() }
        guard case .underrun = j.pop() else { return XCTFail("expected underrun") }
        XCTAssertEqual(j.target, 5)
    }

    func testBurstAfterStallIsAbsorbedUpToSlack() {
        var j = JitterBuffer(target: 3)
        for _ in 0..<3 { j.push(block()) }
        _ = j.pop()
        for _ in 0..<5 { j.push(block()) }
        XCTAssertEqual(j.dropped, 0)
        j.push(block()); j.push(block())
        XCTAssertGreaterThan(j.dropped, 0)
        XCTAssertLessThanOrEqual(j.depth, j.target + 4)
    }

    func testLearnedTargetIsRespectedAndCapped() {
        XCTAssertEqual(JitterBuffer(target: 7).target, 7)
        var j = JitterBuffer(target: 15)
        for _ in 0..<15 { j.push(block()) }
        for _ in 0..<16 { _ = j.pop() }
        XCTAssertEqual(j.target, 16)
    }
}
