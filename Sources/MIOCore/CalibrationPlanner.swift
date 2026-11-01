import Foundation

public enum PlanStep {
    case original(Int)                          // measuring the current setting
    case candidate(round: Int, repeat: Int)     // measuring a computed setting
    case local(TunerStep)                       // local closed-loop polishing
}

/// One real measurement of "all speakers together": the recovered combined response at every microphone. The planner
/// scores it itself, so every measurement is scored with the same, consistent definition.
public struct Measured {
    public var observations: [Observation]
    public init(observations: [Observation]) { self.observations = observations }
}

public struct PlanResult {
    public var best: [Double]                   // smallest = 0
    public var bestScore: Double
    public var startScore: Double?              // measured index of the original setting
    public var history: [Double]
    public var evaluations: Int
    public var biasMs: [Double]                 // how far the model's arrivals were corrected by the measurements
    public var rounds: Int
    public var noise: Double
    public var finished: Bool
}

/// The whole post-identification pipeline, shared by the app and the simulation:
///   measure the original → correct the model with it → compute the best delays on the corrected model → measure them →
///   correct the model again → … (a few rounds, each *computed*, none guessed) → short local closed-loop polish.
/// `compute` returns the best delays for a given model (the app runs DelayAI + the digital twin there).
public enum CalibrationPlanner {
    /// The best delays for a model, computed (no sound): DelayAI's gradient descent from many starts on all cores, then a
    /// pattern search on the digital twin's exact score. Used identically by the app and the simulation.
    public static func computeBest(model: [MicResponse], programme: Programme, original: [Double]) -> [Double]? {
        let n = original.count
        let active = Array(0..<n)
        let seeds = CalibrationAnalysis.seeds(responses: model, active: active, original: original)
        let t0 = Date()
        let ai = DelayAI.optimize(mics: model, seeds: seeds, programme: programme)
        let t1 = Date()
        var polished: [Double]?
        if let twin = DigitalTwin(mics: model, probe: programme.probe, rate: programme.rate) {
            var starts: [[Double]] = []
            if let ai { starts.append(ai.delaysMs); starts += ai.alternatives }
            if seeds.count > 2 { starts.append(seeds[2]) }
            if seeds.count > 1 { starts.append(seeds[1]) }
            polished = TwinOptimizer.polish(twin: twin, starts: Array(starts.prefix(5)))?.delaysMs
        }
        if ProcessInfo.processInfo.environment["AMIO_DEBUG"] != nil {
            print("PLAN compute: DelayAI \(String(format: "%.1f", t1.timeIntervalSince(t0))) s, twin polish \(String(format: "%.1f", Date().timeIntervalSince(t1))) s")
        }
        return polished ?? ai?.delaysMs
    }

    public static func run(model: [MicResponse], programme: Programme, original: [Double], maxRounds: Int = 3, repeats: Int = 2,
                           localIterations: Int = 16,
                           compute: ([MicResponse]) async -> [Double]?,
                           shouldStop: () -> Bool = { false },
                           onBest: (([Double], Double, Double?) -> Void)? = nil,
                           measure: ([Double], PlanStep) async throws -> Measured?) async throws -> PlanResult? {
        guard let twin = DigitalTwin(mics: model, probe: programme.probe, rate: programme.rate) else { return nil }
        let rate = programme.rate
        let dbg = ProcessInfo.processInfo.environment["AMIO_DEBUG"] != nil
        func mean(_ a: [Double]) -> Double { a.reduce(0, +) / Double(a.count) }
        let n = original.count
        var evaluations = 0
        var history: [Double] = []
        var observations: [Observation] = []
        var bias = [Double](repeating: 0, count: n)
        var commonMs = 0.0                      // timing offset common to all speakers; frozen after the first estimate
        var commonFrozen = false
        var rounds = 0
        var stopped = false

        /// Score of one measurement: crop each microphone's response from the first arrival (model + delays + common offset).
        func score(_ group: [Observation]) -> Double? {
            var s: [Double] = []
            for o in group where o.mic < twin.micCount {
                let arr = twin.arrivals(mic: o.mic)
                let t = (0..<n).map { arr[$0] + o.delaysMs[$0] / 1000 }
                let first = t.min() ?? 0, last = t.max() ?? 0
                let onset = o.pad + Int(((first + commonMs / 1000) * rate).rounded())
                guard let v = CalibrationAnalysis.cropScore(fs: rate, onsetIndex: onset,
                                                            cropSec: CalibrationAnalysis.responseSeconds + (last - first),
                                                            at: { $0 >= 0 && $0 < o.ir.count ? Double(o.ir[$0]) : 0 }) else { return nil }
                s.append(v)
            }
            return s.isEmpty ? nil : mean(s)
        }
        struct Cand { var d: [Double]; var groups: [[Observation]] }
        var cands: [Cand] = [Cand(d: original, groups: [])]
        func scores(_ c: Cand) -> [Double] { c.groups.compactMap(score) }
        func report() {
            let ok = cands.filter { !scores($0).isEmpty }
            guard let b = ok.min(by: { mean(scores($0)) < mean(scores($1)) }) else { return }
            history.append(mean(scores(b)))
            onBest?(b.d, mean(scores(b)), scores(cands[0]).isEmpty ? nil : mean(scores(cands[0])))
        }
        func take(_ idx: Int, _ step: PlanStep) async throws {
            evaluations += 1
            if let r = try await measure(cands[idx].d, step), !r.observations.isEmpty {
                cands[idx].groups.append(r.observations); observations += r.observations
            }
            report()
        }
        /// Correct the model from everything measured so far; the correction is kept only if it clearly explains the data better.
        func refine() {
            guard let e = ModelRefiner.estimate(model: model, observations: observations) else { if dbg { print("PLAN refine: nil") }; return }
            if dbg { print("PLAN refine: bias \(e.biasMs.map { String(format: "%.1f", $0) }) cost \(e.costZero) -> \(e.costAfter) confidence \(e.confidence.map { String(format: "%.2f", $0) })") }
            guard e.costAfter < e.costZero, e.biasMs.contains(where: { $0 != 0 }) else { return }
            bias = e.biasMs
            if !commonFrozen { commonMs = bias.sorted()[n / 2]; commonFrozen = true }
        }

        for r in 0..<repeats { if shouldStop() { stopped = true; break }; try await take(0, .original(r)) }
        guard !scores(cands[0]).isEmpty else { return nil }
        refine()                                                       // the original's own measurements already tell
        let startScore = mean(scores(cands[0]))

        var converged = false
        for round in 0..<maxRounds where !stopped && !converged {
            if shouldStop() { stopped = true; break }
            guard let d = await compute(model.map { $0.shifted(byMs: bias) }) else { if dbg { print("PLAN compute: nil") }; break }
            if dbg { print("PLAN candidate round \(round): \(d.map { Int($0) })") }
            let cand = d.map { min(1000, max(0, $0)) }
            if cands.contains(where: { zip($0.d, cand).allSatisfy { abs($0 - $1) < 1.0 } }) { converged = true; break }
            cands.append(Cand(d: cand, groups: []))
            let idx = cands.count - 1
            for r in 0..<repeats { if shouldStop() { stopped = true; break }; try await take(idx, .candidate(round: round, repeat: r)) }
            rounds += 1
            let before = bias
            refine()                                                   // learn from this measurement too
            if zip(bias, before).allSatisfy({ abs($0 - $1) < 0.5 }) && round > 0 { converged = true }
        }

        // noise estimate from repeats
        var v = 0.0, cnt = 0
        for c in cands { let sc = scores(c); if sc.count >= 2 {
            let mu = mean(sc), var_ = sc.map { ($0 - mu) * ($0 - mu) }.reduce(0, +) / Double(sc.count - 1)
            v += var_ / max(mu * mu, 1e-12); cnt += 1
        } }
        let noise = max(0.03, cnt > 0 ? (v / Double(cnt)).squareRoot() : 0.06)

        // Choice: the latest computed candidate that is as good as the best within the noise; never worse than the original.
        let measured = cands.indices.filter { !scores(cands[$0]).isEmpty }
        let bestMean = measured.map { mean(scores(cands[$0])) }.min() ?? startScore
        var chosen = 0
        for i in measured.reversed() where i != 0 && mean(scores(cands[i])) <= bestMean * (1 + 0.5 * noise) { chosen = i; break }
        if chosen != 0, mean(scores(cands[chosen])) > startScore { chosen = 0 }
        var best = cands[chosen].d
        var bestScore = mean(scores(cands[chosen]))

        // short local closed-loop polish around the chosen setting (model: corrected)
        if localIterations > 0, !stopped, chosen != 0 {
            let refined = model.map { $0.shifted(byMs: bias) }
            if let t = try await ClosedLoopTuner.run(
                mics: refined, seeds: [best], preferred: 0, maxIterations: localIterations,
                seedRepeats: 1, noiseHint: noise, programme: programme, shouldStop: shouldStop,
                evaluate: { d, step in
                    evaluations += 1
                    guard let r = try await measure(d, .local(step)), !r.observations.isEmpty else { return nil }
                    return score(r.observations)
                }) {
                // accept its answer only through the same noise-aware rule
                if t.accepted > 0, t.bestScore < bestScore * (1 - noise * 0.5) { best = t.best; bestScore = t.bestScore }
                history += t.history
                if !t.finished { stopped = true }
            }
        }
        let shift = best.min() ?? 0
        return PlanResult(best: best.map { $0 - shift }, bestScore: bestScore, startScore: startScore, history: history,
                          evaluations: evaluations, biasMs: bias, rounds: rounds, noise: noise, finished: !stopped)
    }
}
