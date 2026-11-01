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

    /// How long each speaker's response is modelled and scored (reverb included).
    public static let responseSeconds = 2.0
    /// The weakest speaker's peak-to-noise ratio over all microphones; below `minReliableSNR` the arrival times found by the
    /// identification cannot be trusted (loud talking, a TV, a vacuum cleaner while measuring).
    public static func weakestSNR(_ responses: [MicResponse]) -> Double? {
        let all = responses.flatMap { $0.speakers.compactMap { $0?.snr } }
        return all.min()
    }
    public static let minReliableSNR = 15.0


    /// Boominess index of one recorded window (`pad` seconds of lead-in + one period of `probe`), as it really sounded.
    ///
    /// With `onsetSec` (the first arrival at this microphone, known from the identified model and the applied delays) the
    /// response is cut at that fixed point and is `responseSeconds + spreadSec` long (`spreadSec` = first-to-last arrival), so every
    /// speaker's tail is counted and a speaker pushed far out of step shows up as an echo instead of being cut off.
    /// Without it the first arrival is found from the response's peaks (less stable).
    public static func boominess(window: [Float], sampleRate fs: Double, probe: [Float], padSec: Double = 0.1,
                                 onsetSec: Double? = nil, spreadSec: Double = 0) -> Double? {
        guard let onsetSec else {
            return combinedResponse(recording: window, sampleRate: fs, probe: probe, startSec: padSec, padSec: padSec, tailSec: 2.0,
                                    irSec: 1.2, continuous: true, backSec: 0.6).flatMap { RoomOptimizer.score(of: $0) }
        }
        return measure(window: window, sampleRate: fs, probe: probe, padSec: padSec, onsetSec: onsetSec, spreadSec: spreadSec)?.score
    }

    /// Like `boominess` (with a known first arrival) but also returns the recovered combined response: index `pad + lag`
    /// holds the response `lag` samples after the programme's start. The model refiner compares this with its prediction.
    public static func measure(window: [Float], sampleRate fs: Double, probe: [Float], padSec: Double = 0.1,
                               onsetSec: Double, spreadSec: Double) -> (score: Double, ir: [Float], pad: Int)? {
        let pad = Int(padSec * fs), len = pad + probe.count
        guard window.count + 64 >= len else { return nil }                      // a few samples short is just rounding
        var w = Array(window.prefix(len))
        if w.count < len { w += [Float](repeating: 0, count: len - w.count) }
        let ir = Deconvolver.impulseResponse(recording: w, probe: probe, regularization: 1e-3)
        guard let score = cropScore(fs: fs, onsetIndex: pad + Int((onsetSec * fs).rounded()), cropSec: responseSeconds + spreadSec, at: {
            $0 >= 0 && $0 < ir.count ? Double(ir[$0]) : 0
        }) else { return nil }
        return (score, ir, pad)
    }

    /// Cuts `cropSec` of a combined response from a fixed onset and scores it. `at(i)` reads the response at index i
    /// (return 0 outside it).
    static func cropScore(fs: Double, onsetIndex: Int, cropSec: Double, at: (Int) -> Double) -> Double? {
        let pre = max(1, Int(0.001 * fs)), len = Int(cropSec * fs)
        var h = [Double](repeating: 0, count: pre + len)
        var energy = 0.0
        for t in 0..<(pre + len) { let v = at(onsetIndex - pre + t); h[t] = v; energy += v * v }
        guard energy > 1e-18 else { return nil }
        return RoomOptimizer.score(of: MicResponse(sampleRate: fs, speakers: [SpeakerIR(h: h, pre: pre, arrival: 0, snr: 100, consistency: 1)]))
    }

}

public enum TunerStep {
    case seed(Int, repeat: Int)             // measuring a starting point (tournament)
    case model(radiusMs: Double)            // the model's best small correction (trust region radius)
    case explore(radiusMs: Double)          // the model sees no further gain: a random nudge to test the model
    case confirm                            // measuring a promising candidate again before believing it
    case recheck                            // measuring the current best again (guards against measurement noise)
}

public struct TunerResult {
    public var best: [Double]
    public var bestScore: Double            // mean of the measurements of `best`
    public var startScore: Double?          // measured index of the original setting (first seed), mean of its measurements
    public var history: [Double]            // best measured index after every measurement
    public var evaluations: Int
    public var accepted: Int
    public var noise: Double                // estimated relative measurement noise (std / mean)
    public var finished: Bool               // converged or ran all iterations (not stopped from outside)
}

/// Closed loop with a very short feedback cycle: compute a correction on the room model, apply it, measure right away
/// (the programme keeps playing), keep it only if it measured *clearly* better, and go again — dozens of times.
///
/// Measurements of a real room are noisy (timing jitter alone moves the index by ±15 %), so:
///  • the starting candidates (original, aligned, the model's optimum and its runner-up minima) compete in a
///    tournament of repeated measurements, and the measurement noise is estimated from those repeats;
///  • a change is accepted only if it beats the incumbent by more than ~2σ *and* a second measurement confirms it;
///  • a trust region keeps every step small enough for the model to be believable (it grows while the model is right,
///    shrinks when wrong), so a wrong model can never walk the setting far away;
///  • when the model sees nothing left to gain and random probing finds nothing either, the loop ends early.
public enum ClosedLoopTuner {
    /// `preferred`: index (into `seeds`) of the model's own choice. It stays the incumbent unless a measurement beats it
    /// by more than the measurement noise — noise alone must not talk the loop out of the model's answer.
    public static func run(mics: [MicResponse], seeds: [[Double]], preferred: Int? = nil, maxIterations: Int = 40,
                           initialRadiusMs: Double = 30, seedRepeats: Int = 3, noiseHint: Double? = nil,
                           maxDelayMs: Double = 1000, rngSeed: UInt64 = 7, programme: Programme? = nil,
                           shouldStop: () -> Bool = { false },
                           evaluate: ([Double], TunerStep) async throws -> Double?) async throws -> TunerResult? {
        var rng = DelayAI.SplitMix(seed: rngSeed)
        var evaluations = 0, accepted = 0
        var history: [Double] = []
        func mean(_ a: [Double]) -> Double { a.reduce(0, +) / Double(a.count) }

        // distinct candidates, each with its list of measurements
        var cands: [(d: [Double], m: [Double])] = []
        for seed in seeds where !cands.contains(where: { zip($0.d, seed).allSatisfy { abs($0 - $1) < 0.5 } }) { cands.append((seed, [])) }
        guard !cands.isEmpty else { return nil }
        var stopped = false
        func measure(_ i: Int, _ step: TunerStep) async throws {
            evaluations += 1
            if let s = try await evaluate(cands[i].d, step) { cands[i].m.append(s) }
            let ok = cands.filter { !$0.m.isEmpty }
            if let b = ok.min(by: { mean($0.m) < mean($1.m) }) { history.append(mean(b.m)) }
        }

        // ---- tournament ----
        // With a model choice (`preferred`) only "original vs the model's choice" is measured, three times each: the
        // model already ranked its own candidates (and a noisy measurement must not talk the loop into a worse one);
        // the measurement is there to catch a wrong model, i.e. an answer that turns out worse than the original.
        var order0: [Int] = Array(cands.indices)
        if let p = preferred, p < seeds.count,
           let pi = cands.firstIndex(where: { zip($0.d, seeds[p]).allSatisfy { abs($0 - $1) < 0.5 } }) {
            order0 = pi == 0 ? [0] : [0, pi]
            for _ in 0..<seedRepeats {
                for i in order0 { if shouldStop() { stopped = true; break }; try await measure(i, .seed(i, repeat: 0)) }
            }
        } else {
            for i in cands.indices { if shouldStop() { stopped = true; break }; try await measure(i, .seed(i, repeat: 0)) }
            for (round, keep) in [3, 2].enumerated() where !stopped {
                let order = cands.indices.filter { !cands[$0].m.isEmpty }.sorted { mean(cands[$0].m) < mean(cands[$1].m) }
                for i in order.prefix(keep) { if shouldStop() { stopped = true; break }; try await measure(i, .seed(i, repeat: round + 1)) }
            }
        }
        let measured = cands.indices.filter { !cands[$0].m.isEmpty }
        guard let fastest = measured.min(by: { mean(cands[$0].m) < mean(cands[$1].m) }) else { return nil }
        let startScore = cands[0].m.isEmpty ? nil : mean(cands[0].m)

        // measurement noise: relative spread of repeated measurements (floor: 3 %)
        func relNoise() -> Double {
            var v = 0.0, cnt = 0
            for c in cands where c.m.count >= 2 {
                let mu = mean(c.m), var_ = c.m.map { ($0 - mu) * ($0 - mu) }.reduce(0, +) / Double(c.m.count - 1)
                v += var_ / max(mu * mu, 1e-12); cnt += 1
            }
            return max(noiseHint ?? 0.03, 0.03, cnt > 0 ? (v / Double(cnt)).squareRoot() : 0.06)
        }

        // The model's choice is the incumbent; the original replaces it only if it measured better, other candidates
        // only by clearly beating it (more than the measurement noise).
        var bi = fastest
        if let p = preferred, p < seeds.count,
           let pi = cands.firstIndex(where: { zip($0.d, seeds[p]).allSatisfy { abs($0 - $1) < 0.5 } }), !cands[pi].m.isEmpty {
            bi = pi
            if !cands[0].m.isEmpty, mean(cands[0].m) < mean(cands[pi].m) { bi = 0 }          // never worse than the original
            for c in measured where c != 0 && c != pi && mean(cands[c].m) < mean(cands[bi].m) * (1 - 2 * relNoise()) { bi = c }
        }
        var best = cands[bi].d
        var bestMeasures = cands[bi].m

        // ---- local loop: model correction → measure → confirm → accept / shrink ----
        var radius = initialRadiusMs
        var finished = !stopped
        var idleExplores = 0
        for it in 0..<maxIterations where !stopped {
            if shouldStop() { finished = false; break }
            if it > 0, it % 5 == 0 {                                  // measure the incumbent again
                evaluations += 1
                if let s = try await evaluate(best, .recheck) { bestMeasures.append(s); history.append(mean(bestMeasures)) }
                continue
            }
            var cand = best
            var step = TunerStep.model(radiusMs: radius)
            var fromModel = true
            if let c = DelayAI.descend(mics: mics, from: best, radiusMs: radius, maxDelayMs: maxDelayMs, programme: programme),
               zip(c, best).contains(where: { abs($0 - $1) > 0.3 }) {
                cand = c
            } else {                                                  // the model has nothing left to gain: probe around
                let r = max(radius, 2)
                cand = best.map { min(maxDelayMs, max(0, $0 + (rng.unit() * 2 - 1) * r)) }
                step = .explore(radiusMs: r)
                fromModel = false
            }
            evaluations += 1
            guard let s1 = try await evaluate(cand, step) else { radius = max(0.5, radius * 0.6); continue }
            let incumbent = mean(bestMeasures), sigma = relNoise()
            var improved = false
            if s1 < incumbent * (1 - 2 * sigma) {
                evaluations += 1
                if let s2 = try await evaluate(cand, .confirm), (s1 + s2) / 2 < incumbent * (1 - sigma) {
                    best = cand; bestMeasures = [s1, s2]; accepted += 1; improved = true
                }
            }
            if improved { radius = min(80, radius * 1.4); idleExplores = 0 }
            else {
                radius = max(0.5, radius * 0.6)
                if !fromModel { idleExplores += 1 } else { idleExplores = 0 }
                if idleExplores >= 3 { break }                        // converged: model and probing find nothing more
            }
            history.append(mean(bestMeasures))
        }
        let shift = best.min() ?? 0
        return TunerResult(best: best.map { $0 - shift }, bestScore: mean(bestMeasures), startScore: startScore, history: history,
                           evaluations: evaluations, accepted: accepted, noise: relNoise(), finished: finished)
    }
}

extension CalibrationAnalysis {
    /// The microphones' responses restricted to `active` speakers, keeping only microphones that identified all of them.
    public static func restrict(_ responses: [MicResponse], to active: [Int]) -> [MicResponse] {
        responses.filter { r in active.allSatisfy { $0 < r.speakers.count && r.speakers[$0] != nil } }
            .map { r in MicResponse(sampleRate: r.sampleRate, speakers: active.map { r.speakers[$0] }) }
    }
}
