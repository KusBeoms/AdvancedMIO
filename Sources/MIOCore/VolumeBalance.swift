import Foundation

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
