import Foundation

/// A series of delay settings of one room whose value of one 울림 candidate rises from the smallest the search could find to
/// a clearly large one, in even steps — to be listened to one after the other.
public struct ResonanceLadder {
    public struct Step: Equatable {
        public var delaysMs: [Double]
        public var value: Double
    }
    public var metric: ResonanceMetric
    public var steps: [Step]
}

public enum ResonanceLadderBuilder {
    /// One random search serves all six candidates. For each, the smallest value found is polished by a small descent so that
    /// step 0 is really "as little 울림 as this definition can make"; the top step is the 85th percentile of the random
    /// settings (very large values are mostly absurd delays, not rooms anyone would set up).
    public static func build(room: MicResponse, samples: Int = 240, steps: Int = 9, maxDelayMs: Double = 60,
                             seed: UInt64 = 1) -> [ResonanceMetric: ResonanceLadder] {
        let n = room.speakers.count
        var rng = DelayAI.SplitMix(seed: seed)
        var pool: [(d: [Double], v: [ResonanceMetric: Double])] = []
        func add(_ d: [Double]) {
            if let r = ResonanceMeter.readings(room: room, delaysMs: d) { pool.append((d, r.values)) }
        }
        add([Double](repeating: 0, count: n))
        for _ in 0..<samples { add((0..<n).map { _ in rng.unit() * maxDelayMs }) }

        var out: [ResonanceMetric: ResonanceLadder] = [:]
        for m in ResonanceMetric.allCases {
            let ranked = pool.filter { $0.v[m] != nil }.sorted { $0.v[m]! < $1.v[m]! }
            guard ranked.count >= steps else { continue }
            // polish the minimum
            var best = (d: ranked[0].d, v: ranked[0].v[m]!)
            for radius in [8.0, 3.0, 1.0] {
                for _ in 0..<2 {
                    for i in 0..<n {
                        for delta in [-radius, radius] {
                            var d = best.d
                            d[i] = min(maxDelayMs, max(0, d[i] + delta))
                            if let v = ResonanceMeter.readings(room: room, delaysMs: d)?.values[m], v < best.v { best = (d, v) }
                        }
                    }
                }
            }
            let hiValue = ranked[Int(Double(ranked.count - 1) * 0.85)].v[m]!
            var chosen: [ResonanceLadder.Step] = [.init(delaysMs: best.d, value: best.v)]
            for k in 1..<steps {
                let target = best.v + (hiValue - best.v) * Double(k) / Double(steps - 1)
                let near = ranked.min { abs($0.v[m]! - target) < abs($1.v[m]! - target) }!
                chosen.append(.init(delaysMs: near.d, value: near.v[m]!))
            }
            out[m] = ResonanceLadder(metric: m, steps: chosen)
        }
        return out
    }
}
