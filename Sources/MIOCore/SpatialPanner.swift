import Foundation

/// 2×2 mix applied to an output's summed stereo signal: `L' = ll·L + lr·R`, `R' = rl·L + rr·R`.
public struct SpatialMix: Equatable {
    public var ll: Float, lr: Float, rl: Float, rr: Float
    public init(ll: Float, lr: Float, rl: Float, rr: Float) { self.ll = ll; self.lr = lr; self.rl = rl; self.rr = rr }
    public static let identity = SpatialMix(ll: 1, lr: 0, rl: 0, rr: 1)

    /// `(1 - t)·a + t·b`.
    static func blend(_ a: SpatialMix, _ b: SpatialMix, _ t: Float) -> SpatialMix {
        if t >= 1 { return b }
        if t <= 0 { return a }
        return SpatialMix(ll: a.ll + (b.ll - a.ll) * t, lr: a.lr + (b.lr - a.lr) * t,
                   rl: a.rl + (b.rl - a.rl) * t, rr: a.rr + (b.rr - a.rr) * t)
    }
}

/// Turns a speaker's place on a circle around the listener into the mix that speaker plays.
///
/// Angles are in degrees, 0 = top of the stage, increasing clockwise (so +90 = right). The listener sits in the
/// middle looking toward `headingDeg`. `radius` is the distance from the listener as a fraction of the stage
/// (0 = on top of the listener, 1 = the outer ring).
///
/// Each device is treated as one point source. On the ring it plays one mono feed: a speaker on the left carries
/// the left channel, one on the right the right channel, one in front the centre, and speakers behind the listener
/// play the same blend a little quieter (ambience). A speaker close to the listener cannot be told apart by
/// direction, so it fades into a full-range speaker that plays the whole stereo signal unchanged (radius 0).
public enum SpatialPanner {
    /// How much a speaker turned away from the listener loses (0 = nothing, 1 = silent when facing backwards).
    public static let directivity = 0.5
    /// Radius (fraction of the stage) from which a speaker is fully "placed"; closer ones blend toward full range.
    public static let fullPlacementRadius = 0.5
    /// The outer ring, in metres.
    public static let maxRadiusMeters = 3.0
    public static let speedOfSound = 343.0

    /// - Parameters:
    ///   - positionDeg: where the speaker stands on the circle.
    ///   - radius: distance from the listener, 0…1.
    ///   - aimOffsetDeg: how far the speaker is turned away from facing the listener (0 = pointing at the listener).
    ///   - headingDeg: the direction the listener faces.
    public static func mix(positionDeg: Double, radius: Double = 1, aimOffsetDeg: Double = 0, headingDeg: Double = 0) -> SpatialMix {
        let rel = (positionDeg - headingDeg) * .pi / 180
        let side = sin(rel)                        // -1 left … +1 right
        let front = cos(rel)                       // +1 in front … -1 behind
        let wl = (1 - side) / 2, wr = (1 + side) / 2          // linear pan: a mono signal keeps its level at any angle
        let depth = front >= 0 ? 1 : 0.65 + 0.35 * (1 + front)
        let facing = 0.5 + 0.5 * cos(aimOffsetDeg * .pi / 180)
        let g = Float(depth * (1 - directivity * (1 - facing)))
        let placed = SpatialMix(ll: Float(wl) * g, lr: Float(wr) * g, rl: Float(wl) * g, rr: Float(wr) * g)
        let t = Float(min(1, max(0, radius / fullPlacementRadius)))
        return .blend(.identity, placed, t)
    }

    public static func distanceMeters(radius: Double) -> Double { min(1, max(0, radius)) * maxRadiusMeters }

    /// Extra delay that makes a speaker `distance` metres away land together with the farthest one.
    public static func alignDelayMs(distance: Double, farthest: Double) -> Double {
        max(0, farthest - distance) / speedOfSound * 1000
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
