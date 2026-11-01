import Foundation

public enum SearchStep {
    case seed(Int)
    case move(speaker: Int, delayMs: Double, stepMs: Double, best: Double)
}

public struct SearchResult {
    public var best: [Double]
    public var bestScore: Double
    public var originalScore: Double?
    public var history: [Double]          // best score after the seeds and after each step size
    public var evaluations: Int
    public var finished: Bool             // every step size was tried before `shouldStop` fired
}

/// Bold, measured coordinate search over per-speaker delays. The score of a candidate is *measured* by `evaluate`
/// (lower = less boomy); a change is kept only if it measures clearly better.
public enum DelaySearch {
    public static let steps: [Double] = [200, 80, 30, 12, 5]
    public static let acceptRatio = 0.985

    /// `seeds[0]` is the original setting; the others are model-computed starting points (aligned arrivals, optimum).
    /// Returns nil when no seed could be measured.
    public static func run(seeds: [[Double]], steps: [Double] = DelaySearch.steps, acceptRatio: Double = DelaySearch.acceptRatio,
                           maxDelayMs: Double = 1000, shouldStop: () -> Bool = { false },
                           evaluate: ([Double], SearchStep) async throws -> Double?) async throws -> SearchResult? {
        guard let first = seeds.first else { return nil }
        var best = first, bestScore = Double.infinity
        var originalScore: Double?
        var evaluations = 0
        var history: [Double] = []

        for (si, seed) in seeds.enumerated() {
            if si > 0, seeds[..<si].contains(where: { zip($0, seed).allSatisfy { abs($0 - $1) < 1 } }) { continue }
            evaluations += 1
            if let s = try await evaluate(seed, .seed(si)) {
                if si == 0 { originalScore = s }
                if s < bestScore { bestScore = s; best = seed }
            }
        }
        guard bestScore.isFinite else { return nil }
        history.append(bestScore)

        var finished = true
        outer: for step in steps {
            for i in best.indices {
                for sign in [1.0, -1.0] {
                    if shouldStop() { finished = false; break outer }
                    var cand = best
                    cand[i] = min(maxDelayMs, max(0, best[i] + sign * step))
                    if abs(cand[i] - best[i]) < 0.5 { continue }
                    evaluations += 1
                    if let s = try await evaluate(cand, .move(speaker: i, delayMs: cand[i], stepMs: step, best: bestScore)),
                       s < bestScore * acceptRatio {
                        bestScore = s; best = cand
                        break                                    // improved this way: skip the opposite direction
                    }
                }
            }
            history.append(bestScore)
        }
        return SearchResult(best: best, bestScore: bestScore, originalScore: originalScore, history: history,
                            evaluations: evaluations, finished: finished)
    }
}

extension CalibrationAnalysis {
    /// Starting points for the search from the model measurement, over the `active` speakers:
    /// the original setting, the setting that makes every first arrival coincide, and the computed optimum.
    /// `original` has one entry per speaker (all of them); the result vectors have one entry per active speaker.
    public static func seeds(responses: [MicResponse], active: [Int], original: [Double]) -> [[Double]] {
        let m = active.count
        let start = active.map { original[$0] }
        var out: [[Double]] = [start]
        guard m >= 1 else { return out }
        // Mean arrival per speaker over the microphones that identified it (a speaker nobody identified keeps its delay).
        var mean = [Double?](repeating: nil, count: m)
        for (q, j) in active.enumerated() {
            let a = responses.compactMap { j < $0.speakers.count ? $0.speakers[j]?.arrival : nil }
            if !a.isEmpty { mean[q] = a.reduce(0, +) / Double(a.count) }
        }
        let known = mean.compactMap { $0 }
        if let latest = known.max(), known.count >= 2 {
            let aligned = (0..<m).map { q in mean[q].map { min(1000, max(0, (latest - $0) * 1000)) } ?? start[q] }
            out.append(aligned)
            let usable = responses.filter { r in active.allSatisfy { $0 < r.speakers.count && r.speakers[$0] != nil } }
            if !usable.isEmpty {
                let sub = usable.map { r in MicResponse(sampleRate: r.sampleRate, speakers: active.map { r.speakers[$0] }) }
                if let o = RoomOptimizer.optimize(mics: sub, baselineDelaysMs: aligned,
                                                  baselineGains: [Double](repeating: 1, count: m), optimizeGains: false) {
                    out.append(o.delaysMs)
                }
            }
        }
        return out
    }

    /// Boominess index of one recorded window (`pad` seconds of lead-in + one period of `probe`), as it really sounded.
    /// The impulse response is taken wide (from the earliest clear arrival, 1.2 s long) so that a speaker pushed far
    /// out of step is *counted as an echo* — not silently cut off — and the search cannot "win" by hiding a speaker.
    public static func boominess(window: [Float], sampleRate fs: Double, probe: [Float], padSec: Double = 0.1) -> Double? {
        combinedResponse(recording: window, sampleRate: fs, probe: probe, startSec: padSec, padSec: padSec, tailSec: 2.0,
                         irSec: 1.2, continuous: true, backSec: 0.6)
            .flatMap { RoomOptimizer.score(of: $0) }
    }
}
