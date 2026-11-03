import XCTest
@testable import MIOCore

final class ListeningTestTests: XCTestCase {
    func testNoVotesKeepsDefault() {
        let r = PreferenceFit.fit(votes: [])
        XCTAssertEqual(r.weight, 40)
        XCTAssertEqual(r.decisive, 0)
    }

    /// A simulated listener whose ears follow J = spectral + 120·late (with some inconsistency) → the fit finds a weight within
    /// a factor of ~2 of 120, and predicts the answers better than the default 40 does.
    func testFitRecoversTheListenersWeight() {
        let room = SyntheticRoom.make(speakers: 4, seed: 3, seconds: 0.6)
        var rng = DelayAI.SplitMix(seed: 11)
        let trueWeight = 120.0, beta = 12.0
        var votes: [ABVote] = []
        for _ in 0..<50 {
            guard let (a, b) = ListeningTest.makePair(room: room, weight: 40, rng: &rng) else { continue }
            let sa = a.score(weight: trueWeight), sb = b.score(weight: trueWeight)
            let z = beta * (sb - sa) / (0.5 * (sa + sb))
            let pA = 1 / (1 + exp(-z))
            votes.append(ABVote(date: 0, room: "synthetic", a: a, b: b, choice: rng.unit() < pA ? .a : .b))
        }
        XCTAssertGreaterThanOrEqual(votes.count, 40)
        let r = PreferenceFit.fit(votes: votes)
        // a listener who is not fully consistent leaves a factor ~2 of uncertainty with this many answers
        XCTAssertGreaterThan(r.weight, 50, "fitted \(r.weight)")
        XCTAssertLessThan(r.weight, 300, "fitted \(r.weight)")
        XCTAssertGreaterThanOrEqual(r.agreementAtFit, r.agreementAtDefault)
    }

    /// A listener who only hears the spectrum (never the tail) pushes the weight down.
    func testSpectrumOnlyListenerLowersWeight() {
        let room = SyntheticRoom.make(speakers: 4, seed: 5, seconds: 0.6)
        var rng = DelayAI.SplitMix(seed: 2)
        var votes: [ABVote] = []
        for _ in 0..<40 {
            guard let (a, b) = ListeningTest.makePair(room: room, weight: 40, rng: &rng) else { continue }
            votes.append(ABVote(date: 0, room: "synthetic", a: a, b: b, choice: a.spectral < b.spectral ? .a : .b))
        }
        XCTAssertLessThan(PreferenceFit.fit(votes: votes).weight, 20)
    }

    func testPairsAreInformativeAndDistinguishable() {
        let room = SyntheticRoom.make(speakers: 4, seed: 7, seconds: 0.6)
        var rng = DelayAI.SplitMix(seed: 1)
        var informative = 0
        for _ in 0..<30 {
            let (a, b) = ListeningTest.makePair(room: room, weight: 40, rng: &rng)!
            let sa = a.score(weight: 40), sb = b.score(weight: 40)
            XCTAssertGreaterThanOrEqual(abs(sa - sb) / (0.5 * (sa + sb)), 0.12 - 1e-9)
            let dv = b.spectral - a.spectral, dl = b.late - a.late
            if dv * dl < 0, -dv / dl >= 8, -dv / dl <= 200 { informative += 1 }
        }
        XCTAssertGreaterThan(informative, 10)
    }

    /// With a single speaker the rendering is the programme convolved with that speaker's response.
    func testRenderConvolvesWithTheRoom() {
        let h: [Double] = [0, 0, 1, 0, 0.5, 0, 0, -0.25, 0, 0, 0]
        let room = MicResponse(sampleRate: 24_000, speakers: [SpeakerIR(h: h, pre: 2, arrival: 0.01, snr: 100, consistency: 1)])
        var x = [Float](repeating: 0, count: 4000); x[100] = 1
        let y = ListeningTest.render(room: room, delaysMs: [0], programme: x)!
        XCTAssertEqual(y.count, x.count)
        let k = Double(y[102])
        for (i, v) in h.enumerated() { XCTAssertEqual(Double(y[100 + i]) / k, v, accuracy: 1e-4) }
    }

    func testRenderIsLoudnessMatchedAndLoops() {
        let room = SyntheticRoom.make(speakers: 3, seed: 4)
        var rng = DelayAI.SplitMix(seed: 9)
        let x = (0..<60_000).map { _ in Float(rng.normal()) * 0.2 }
        let a = ListeningTest.render(room: room, delaysMs: [0, 3, 9], programme: x)!
        let b = ListeningTest.render(room: room, delaysMs: [0, 20, 1], programme: x)!
        func rms(_ v: [Float]) -> Double { (v.reduce(0.0) { $0 + Double($1 * $1) } / Double(v.count)).squareRoot() }
        XCTAssertEqual(rms(a), rms(b), accuracy: 0.003)
        XCTAssertEqual(a.count, x.count)
        XCTAssertTrue(a.allSatisfy { abs($0) <= 1 })
    }

    func testRoomSurvivesJSON() throws {
        let room = SyntheticRoom.make(speakers: 2, seed: 8)
        let back = try JSONDecoder().decode(MicResponse.self, from: JSONEncoder().encode(room))
        XCTAssertEqual(back.speakers.count, 2)
        XCTAssertEqual(back.speakers[0]?.h.count, room.speakers[0]?.h.count)
        let d = [0.0, 5.0]
        let s1 = RoomOptimizer.components(of: room, delaysMs: d)!, s2 = RoomOptimizer.components(of: back, delaysMs: d)!
        XCTAssertEqual(s1.spectral, s2.spectral, accuracy: 1e-6 * max(1, s1.spectral))
        XCTAssertEqual(s1.late, s2.late, accuracy: 1e-9)
    }
}
