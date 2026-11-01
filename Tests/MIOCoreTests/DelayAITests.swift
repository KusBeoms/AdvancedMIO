import XCTest
@testable import MIOCore

final class DelayAITests: XCTestCase {
    private struct LCG {
        var s: UInt64
        mutating func next() -> Double { s = s &* 6364136223846793005 &+ 1442695040888963407; return Double(s >> 11) / Double(1 << 52) - 1 }
    }

    /// n speakers with a direct arrival plus a decaying tail, as the identification step would hand them over.
    private func response(fs: Double, arrivals: [Double], seed: UInt64) -> MicResponse {
        let pre = max(1, Int(0.001 * fs)), len = Int(0.3 * fs)
        var rng = LCG(s: seed)
        let sp: [SpeakerIR?] = arrivals.enumerated().map { i, a in
            var h = [Double](repeating: 0, count: pre + len)
            h[pre] = 1.0 - 0.15 * Double(i)
            for t in (pre + Int(0.004 * fs))..<h.count { h[t] = 0.07 * rng.next() * exp(-Double(t - pre) / (0.08 * fs)) }
            return SpeakerIR(h: h, pre: pre, arrival: a, snr: 100, consistency: 1)
        }
        return MicResponse(sampleRate: fs, speakers: sp)
    }

    func testAnalyticGradientMatchesNumericalDifferences() throws {
        let fs = 8000.0
        let model = try XCTUnwrap(SmoothMicModel(response(fs: fs, arrivals: [0.010, 0.026, 0.043], seed: 4)))
        let ws = DelayAI.Workspace()
        let d = [3.2, 17.4, 9.1]
        var g = [Double](repeating: 0, count: 3), scratch = g
        _ = model.evaluate(d, &g, ws, wantGradient: true)
        for i in 0..<3 {
            var up = d, dn = d
            up[i] += 0.001; dn[i] -= 0.001
            let numeric = (model.evaluate(up, &scratch, ws, wantGradient: false) - model.evaluate(dn, &scratch, ws, wantGradient: false)) / 0.002
            XCTAssertEqual(g[i], numeric, accuracy: max(0.05, 0.01 * abs(numeric)), "gradient of delay \(i)")
        }
    }

    /// Gradient descent from many starts must reach (about) the best value a brute-force grid finds.
    func testGradientDescentMatchesBruteForceGrid() throws {
        let fs = 8000.0
        let mics = [response(fs: fs, arrivals: [0.010, 0.040, 0.024], seed: 1), response(fs: fs, arrivals: [0.012, 0.043, 0.026], seed: 2)]
        var config = DelayAIConfig()
        config.starts = 16; config.iterations = 120
        let r = try XCTUnwrap(DelayAI.optimize(mics: mics, seeds: [[0, 0, 0]], config: config))
        XCTAssertLessThan(r.score, r.seedScores[0] * 0.8, "the model-predicted index should fall clearly")
        XCTAssertEqual(r.delaysMs.min()!, 0, accuracy: 1e-9)

        var best = Double.infinity
        for d0 in stride(from: 0.0, through: 70, by: 5) {
            for d2 in stride(from: 0.0, through: 70, by: 5) {
                best = min(best, DelayAI.predictedScore(mics: mics, delaysMs: [d0, 0, d2])!)
            }
        }
        XCTAssertLessThanOrEqual(r.score, best * 1.03, "gradient descent should be as good as the brute-force grid (\(r.score) vs \(best))")
    }
}
