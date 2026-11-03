import XCTest
@testable import MIOCore

final class ResponseViewTests: XCTestCase {
    private func mic(arrivals: [Double]) -> MicResponse {
        let fs = 24_000.0
        let ir = SpeakerIR(h: [0, 1] + [Double](repeating: 0, count: 2000), pre: 1, arrival: 0, snr: 100, consistency: 1)
        return MicResponse(sampleRate: fs, speakers: arrivals.map { var s = ir; s.arrival = $0; return s })
    }

    func testArrivalsAreRelativeToTheEarliestAndIncludeDelays() throws {
        let m = mic(arrivals: [0.010, 0.004])
        let v = try XCTUnwrap(RoomOptimizer.view(of: m, delaysMs: [0, 0]))
        XCTAssertEqual(v.arrivalsMs[0], 6, accuracy: 1e-9)
        XCTAssertEqual(v.arrivalsMs[1], 0, accuracy: 1e-9)
        let aligned = try XCTUnwrap(RoomOptimizer.view(of: m, delaysMs: [0, 6]))
        XCTAssertEqual(aligned.arrivalsMs[0], 0, accuracy: 1e-9)
        XCTAssertEqual(aligned.arrivalsMs[1], 0, accuracy: 1e-9)
    }

    func testAlignedIdenticalSpeakersAreFlatAndMisalignedOnesComb() throws {
        let m = mic(arrivals: [0, 0])
        func spread(_ d: [Double]) throws -> Double {
            let v = try XCTUnwrap(RoomOptimizer.view(of: m, delaysMs: d))
            return (v.deviationDb.max() ?? 0) - (v.deviationDb.min() ?? 0)
        }
        XCTAssertLessThan(try spread([0, 0]), 0.01)
        XCTAssertGreaterThan(try spread([0, 3]), 6)       // 3 ms offset → comb filter notches
    }

    func testBandCentersAreAscendingAndInRange() throws {
        let v = try XCTUnwrap(RoomOptimizer.view(of: mic(arrivals: [0]), delaysMs: [0]))
        XCTAssertEqual(v.centersHz.count, v.deviationDb.count)
        XCTAssertTrue(zip(v.centersHz, v.centersHz.dropFirst()).allSatisfy { $0 < $1 })
        XCTAssertGreaterThan(v.centersHz.first!, 90)
        XCTAssertLessThan(v.centersHz.last!, 8500)
    }

    func testWrongDelayCountIsRejected() {
        XCTAssertNil(RoomOptimizer.view(of: mic(arrivals: [0, 0]), delaysMs: [0]))
    }
}
