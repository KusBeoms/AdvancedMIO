import XCTest
@testable import MIOCore

final class ResonanceMeterTests: XCTestCase {
    private let fs = 24_000.0

    private func response(echoes: [(ms: Double, gain: Double)], tailMs: Double = 0) -> [Double] {
        var h = [Double](repeating: 0, count: Int(0.8 * fs))
        h[100] = 1
        for (ms, g) in echoes { h[100 + Int(ms / 1000 * fs)] += g }
        if tailMs > 0 {
            var rng = DelayAI.SplitMix(seed: 5)
            let tau = tailMs / 1000 * fs / 6.9
            for t in 150..<h.count { h[t] += 0.3 * (rng.unit() - 0.5) * exp(-Double(t - 100) / tau) }
        }
        return h
    }

    private func read(_ h: [Double]) throws -> [ResonanceMetric: Double] {
        try XCTUnwrap(ResonanceMeter.readings(h: h, onset: 100, noisePower: 0, sampleRate: fs)).values
    }

    func testEveryCandidateGetsWorseWithAnEcho() throws {
        let clean = try read(response(echoes: []))
        let echo = try read(response(echoes: [(120, 0.6)]))
        for m in [ResonanceMetric.lateRatio, .centerTime, .decayTime, .comb, .echo] {
            XCTAssertGreaterThan(try XCTUnwrap(echo[m]), try XCTUnwrap(clean[m]), "\(m)")
        }
    }

    func testLongTailRaisesDecayAndCenterTime() throws {
        let dry = try read(response(echoes: [], tailMs: 100))
        let wet = try read(response(echoes: [], tailMs: 600))
        XCTAssertGreaterThan(try XCTUnwrap(wet[.decayTime]), try XCTUnwrap(dry[.decayTime]))
        XCTAssertGreaterThan(try XCTUnwrap(wet[.centerTime]), try XCTUnwrap(dry[.centerTime]))
    }

    func testEchoLevelTracksTheEcho() throws {
        let v = try read(response(echoes: [(80, 0.5)]))
        XCTAssertEqual(try XCTUnwrap(v[.echo]), 20 * log10(0.5), accuracy: 1.0)
    }
}

final class ResonanceLadderTests: XCTestCase {
    func testLadderRisesForEveryCandidate() {
        let room = SyntheticRoom.make(speakers: 3, seed: 2, seconds: 0.6)
        let ladders = ResonanceLadderBuilder.build(room: room, samples: 60, steps: 5)
        XCTAssertEqual(ladders.count, ResonanceMetric.allCases.count)
        for (m, l) in ladders {
            XCTAssertEqual(l.steps.count, 5)
            XCTAssertLessThan(l.steps.first!.value, l.steps.last!.value, "\(m)")
            XCTAssertLessThanOrEqual(l.steps.first!.value, l.steps[2].value + 1e-9, "\(m)")
        }
    }
}
