import Foundation

extension MicResponse {
    /// The same responses with every speaker's arrival moved by `ms[i]` (the model's timing, corrected).
    public func shifted(byMs ms: [Double]) -> MicResponse {
        let sp: [SpeakerIR?] = speakers.enumerated().map { i, s in
            guard var s, i < ms.count else { return s }
            s.arrival += ms[i] / 1000
            return s
        }
        return MicResponse(sampleRate: sampleRate, speakers: sp)
    }
}

/// One real measurement of "all speakers together" at known delays: the recovered combined response at one microphone.
public struct Observation {
    public var mic: Int
    public var delaysMs: [Double]
    public var ir: [Float]          // index `pad + lag` = response `lag` samples after the programme's start
    public var pad: Int
    public init(mic: Int, delaysMs: [Double], ir: [Float], pad: Int) { self.mic = mic; self.delaysMs = delaysMs; self.ir = ir; self.pad = pad }
}

/// Corrects the identified model with what the closed loop measures.
///
/// Identification (one speaker emphasised at a time) can be off — a weak speaker's arrival is the usual casualty. Every
/// closed-loop measurement is a second, independent look at the room: the combined response at known delays. Each speaker's
/// direct sound (its first ~10 ms, from the identified response) is a template; the measured combined response should be the
/// sum of the templates at (arrival + delay). If speaker i really arrives `b_i` later than modelled, its template belongs `b_i`
/// further along. `b` is found by exact least squares, one speaker at a time over a dense grid (±range, one sample apart) with
/// the other speakers' templates subtracted — so overlapping speakers are told apart — repeated until nothing changes. Using only
/// the direct sound keeps the random reverb tails out of the fit, and many observations (different delay settings, several
/// microphones) average the measurement jitter away.
public enum ModelRefiner {
    public struct Estimate {
        public var biasMs: [Double]
        public var costZero: Double             // relative residual with no correction
        public var costAfter: Double            // relative residual with the estimated correction
        public var confidence: [Double]         // per speaker: how much better the corrected position explains the data (≥ 0.5 = clear)
    }

    public static func estimate(model: [MicResponse], observations: [Observation], rangeMs: Double = 40, templateMs: Double = 10,
                                sweeps: Int = 4) -> Estimate? {
        guard let rate = model.first?.sampleRate, let n = model.first?.speakers.count, n > 0,
              model.allSatisfy({ $0.speakers.count == n && $0.speakers.allSatisfy { $0 != nil } }) else { return nil }
        let obs = observations.filter { $0.mic < model.count && $0.delaysMs.count == n }
        guard !obs.isEmpty else { return nil }
        let R = Int(rangeMs / 1000 * rate)
        let L = Int(templateMs / 1000 * rate)

        struct Tpl { var t: [Double]; var energy: Double; var base: Int }
        // template of speaker i at microphone m, and where (index into ir, minus pad) it sits for zero delay
        var tpl = [[Tpl]]()
        for m in model {
            tpl.append(m.speakers.map { s in
                let s = s!
                let len = min(s.h.count, s.pre + L)
                let t = Array(s.h.prefix(len))
                return Tpl(t: t, energy: t.reduce(0) { $0 + $1 * $1 }, base: Int((s.arrival * rate).rounded()) - s.pre)
            })
        }
        func start(_ o: Observation, _ i: Int) -> Int { o.pad + tpl[o.mic][i].base + Int((o.delaysMs[i] / 1000 * rate).rounded()) }

        // residual per observation = measured − Σ templates at the current shifts
        var shifts = [Int](repeating: 0, count: n)
        var res: [[Double]] = obs.map { o in o.ir.map(Double.init) }
        var energy = 0.0
        for r in res { energy += r.reduce(0) { $0 + $1 * $1 } }
        guard energy > 1e-18 else { return nil }
        func place(_ k: Int, _ i: Int, _ shift: Int, _ sign: Double) {
            let o = obs[k], T = tpl[o.mic][i].t, st = start(o, i) + shift
            for j in 0..<T.count { let idx = st + j; if idx >= 0 && idx < res[k].count { res[k][idx] += sign * T[j] } }
        }
        func resEnergy() -> Double { res.reduce(0) { $0 + $1.reduce(0) { $0 + $1 * $1 } } }
        for k in obs.indices { for i in 0..<n { place(k, i, 0, -1) } }
        let costZero = resEnergy() / energy

        for _ in 0..<sweeps {
            var changed = false
            for i in 0..<n {
                for k in obs.indices { place(k, i, shifts[i], +1) }               // take speaker i out
                var bestS = shifts[i], bestG = -Double.infinity
                var gains = [Double](repeating: 0, count: 2 * R + 1)
                DispatchQueue.concurrentPerform(iterations: 2 * R + 1) { g in
                    let s = g - R
                    var gain = 0.0
                    for k in obs.indices {
                        let o = obs[k], T = tpl[o.mic][i], st = start(o, i) + s
                        var c = 0.0
                        for j in 0..<T.t.count { let idx = st + j; if idx >= 0 && idx < res[k].count { c += res[k][idx] * T.t[j] } }
                        gain += 2 * c - T.energy
                    }
                    gains[g] = gain
                }
                for g in 0..<gains.count where gains[g] > bestG { bestG = gains[g]; bestS = g - R }
                if bestS != shifts[i] { changed = true }
                shifts[i] = bestS
                for k in obs.indices { place(k, i, shifts[i], -1) }                // put it back
            }
            if !changed { break }
        }
        // A shift only counts where it explains the data clearly better than leaving the speaker where the model put it:
        // the gain (squared-error reduction) must be at least half of the speaker's own direct-sound energy.
        var confidence = [Double](repeating: 0, count: n)
        for i in 0..<n {
            for k in obs.indices { place(k, i, shifts[i], +1) }
            func gain(_ s: Int) -> Double {
                var g = 0.0
                for k in obs.indices {
                    let o = obs[k], T = tpl[o.mic][i], st = start(o, i) + s
                    var c = 0.0
                    for j in 0..<T.t.count { let idx = st + j; if idx >= 0 && idx < res[k].count { c += res[k][idx] * T.t[j] } }
                    g += 2 * c - T.energy
                }
                return g
            }
            let own = obs.reduce(0.0) { $0 + tpl[$1.mic][i].energy }
            confidence[i] = own > 0 ? (gain(shifts[i]) - gain(0)) / own : 0
            if shifts[i] != 0, confidence[i] < 0.5 { shifts[i] = 0 }
            for k in obs.indices { place(k, i, shifts[i], -1) }
        }
        let costAfter = resEnergy() / energy
        return Estimate(biasMs: shifts.map { Double($0) / rate * 1000 }, costZero: costZero, costAfter: costAfter, confidence: confidence)
    }
}

/// Reference-only suggestion for even coverage: how much louder/quieter each speaker would have to be for every microphone
/// position to hear about the same level. The user's volumes are never changed by this.
public enum VolumeBalance {
    public struct Suggestion {
        public var gainsDb: [Double]            // per speaker, mean 0
        public var spreadBeforeDb: Double       // loudest − quietest microphone position
        public var spreadAfterDb: Double
        public var micLevelsDb: [Double]        // current level at every microphone, relative to their mean
    }

    /// `power[m][i]`: energy speaker i contributes at microphone m (measured at the user's volumes).
    public static func suggest(power: [[Double]], limitDb: Double = 6) -> Suggestion? {
        guard let n = power.first?.count, n >= 1, power.count >= 2, power.allSatisfy({ $0.count == n }),
              power.allSatisfy({ $0.reduce(0, +) > 0 }) else { return nil }
        func levels(_ g: [Double]) -> [Double] {
            power.map { row in 10 * log10(max(1e-18, (0..<n).reduce(0.0) { $0 + pow(10, g[$1] / 10) * row[$1] })) }
        }
        func spread(_ l: [Double]) -> Double { (l.max() ?? 0) - (l.min() ?? 0) }
        func variance(_ l: [Double]) -> Double { let m = l.reduce(0, +) / Double(l.count); return l.reduce(0) { $0 + ($1 - m) * ($1 - m) } / Double(l.count) }
        var g = [Double](repeating: 0, count: n)
        var best = variance(levels(g))
        for step in [2.0, 1.0, 0.5] {
            for _ in 0..<20 {
                var moved = false
                for i in 0..<n {
                    for sign in [1.0, -1.0] {
                        var c = g; c[i] = min(limitDb, max(-limitDb, c[i] + sign * step))
                        let v = variance(levels(c)) + 0.01 * c.reduce(0) { $0 + $1 * $1 }      // mild preference for small changes
                        if v < best - 1e-9 { best = v; g = c; moved = true }
                    }
                }
                if !moved { break }
            }
        }
        let mean = g.reduce(0, +) / Double(n)
        let centred = g.map { $0 - mean }
        let l0 = levels([Double](repeating: 0, count: n)), l1 = levels(g)
        let m0 = l0.reduce(0, +) / Double(l0.count)
        return Suggestion(gainsDb: centred, spreadBeforeDb: spread(l0), spreadAfterDb: spread(l1), micLevelsDb: l0.map { $0 - m0 })
    }

    /// Energy each speaker contributes at each microphone, from the identified responses (nil if one is missing).
    public static func power(from mics: [MicResponse]) -> [[Double]]? {
        let rows: [[Double]] = mics.compactMap { m in
            guard m.speakers.allSatisfy({ $0 != nil }) else { return nil }
            return m.speakers.map { $0!.h.reduce(0) { $0 + $1 * $1 } }
        }
        return rows.count == mics.count ? rows : nil
    }
}
