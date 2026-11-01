import Foundation

/// 2×2 mix applied to an output's summed stereo signal: `L' = ll·L + lr·R`, `R' = rl·L + rr·R`.
public struct SpatialMix: Equatable {
    public var ll: Float, lr: Float, rl: Float, rr: Float
    public init(ll: Float, lr: Float, rl: Float, rr: Float) { self.ll = ll; self.lr = lr; self.rl = rl; self.rr = rr }
    public static let identity = SpatialMix(ll: 1, lr: 0, rl: 0, rr: 1)
}

/// Turns a speaker's place on a circle around the listener into the mix that speaker plays.
///
/// Angles are in degrees, 0 = top of the stage, increasing clockwise (so +90 = right). The listener sits in the
/// middle looking toward `headingDeg`. Each device is treated as one point source that plays one mono feed:
/// a speaker on the left carries the left channel, one on the right the right channel, one in front the centre,
/// and speakers behind the listener play the same blend a little quieter (ambience).
public enum SpatialPanner {
    /// How much a speaker turned away from the listener loses (0 = nothing, 1 = silent when facing backwards).
    public static let directivity = 0.5

    /// - Parameters:
    ///   - positionDeg: where the speaker stands on the circle.
    ///   - aimOffsetDeg: how far the speaker is turned away from facing the listener (0 = pointing at the listener).
    ///   - headingDeg: the direction the listener faces.
    public static func mix(positionDeg: Double, aimOffsetDeg: Double = 0, headingDeg: Double = 0) -> SpatialMix {
        let rel = (positionDeg - headingDeg) * .pi / 180
        let side = sin(rel)                        // -1 left … +1 right
        let front = cos(rel)                       // +1 in front … -1 behind
        let wl = (1 - side) / 2, wr = (1 + side) / 2          // linear pan: a mono signal keeps its level at any angle
        let depth = front >= 0 ? 1 : 0.65 + 0.35 * (1 + front)
        let facing = 0.5 + 0.5 * cos(aimOffsetDeg * .pi / 180)
        let g = Float(depth * (1 - directivity * (1 - facing)))
        return SpatialMix(ll: Float(wl) * g, lr: Float(wr) * g, rl: Float(wl) * g, rr: Float(wr) * g)
    }

    /// Default places for `count` enabled outputs: one in front, two as a front pair, more spread round the circle.
    public static func defaultAngles(count n: Int) -> [Double] {
        switch n {
        case ..<1: return []
        case 1: return [0]
        case 2: return [-45, 45]
        default: return (0..<n).map { normalized(-45 + 360 * Double($0) / Double(n)) }
        }
    }

    /// Wraps into (-180, 180].
    public static func normalized(_ deg: Double) -> Double {
        var d = deg.truncatingRemainder(dividingBy: 360)
        if d > 180 { d -= 360 } else if d <= -180 { d += 360 }
        return d
    }
}
