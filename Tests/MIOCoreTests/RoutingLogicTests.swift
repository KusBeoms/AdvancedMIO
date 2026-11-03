import XCTest
@testable import MIOCore

final class RoutingLogicTests: XCTestCase {
    func testShiftedToZeroKeepsDifferences() {
        XCTAssertEqual(LagMath.shiftedToZero([292, 150, 80]), [212, 70, 0])
        XCTAssertEqual(LagMath.shiftedToZero([0, 40]), [0, 40])
        XCTAssertEqual(LagMath.shiftedToZero([55]), [0])
        XCTAssertEqual(LagMath.shiftedToZero([]), [])
    }

    func testLatencyDriftThreshold() {
        XCTAssertFalse(LatencyWatch.hasDrifted(from: 190, to: 205))     // 15 ms: below 20 ms and below 15 % (28.5)
        XCTAssertTrue(LatencyWatch.hasDrifted(from: 190, to: 230))      // 40 ms
        XCTAssertFalse(LatencyWatch.hasDrifted(from: 20, to: 35))       // small devices need ≥ 20 ms
        XCTAssertTrue(LatencyWatch.hasDrifted(from: 20, to: 41))
        XCTAssertTrue(LatencyWatch.hasDrifted(from: 400, to: 330))      // 17.5 % lower also counts
    }

    func testNameMatchPrefersExactThenPrefixThenSubstring() {
        let names = ["거실 TV", "거실", "Desk Setup", "desk"]
        XCTAssertEqual(NameMatch.best("거실", in: names), 1)
        XCTAssertEqual(NameMatch.best("DESK", in: names), 3)
        XCTAssertEqual(NameMatch.best("desk s", in: names), 2)
        XCTAssertEqual(NameMatch.best("tv", in: names), 0)
        XCTAssertNil(NameMatch.best("침실", in: names))
        XCTAssertNil(NameMatch.best("  ", in: names))
    }

    func testControlCommandParsing() {
        func p(_ s: String) -> ControlCommand? { ControlCommand.parse(URL(string: s)!) }
        XCTAssertEqual(p("advancedmio://start"), .start)
        XCTAssertEqual(p("AdvancedMIO://Toggle"), .toggle)
        XCTAssertEqual(p("advancedmio://zero"), .zeroLag)
        XCTAssertEqual(p("advancedmio://preset/%EA%B1%B0%EC%8B%A4"), .preset("거실"))
        XCTAssertEqual(p("advancedmio://preset/My%20Desk"), .preset("My Desk"))
        XCTAssertNil(p("advancedmio://preset"))
        XCTAssertNil(p("advancedmio://nope"))
        XCTAssertNil(p("https://example.com/start"))
    }
}
