import Foundation

/// Per-device tone control: low shelf, mid peak, high shelf, each ±12 dB.
public struct EQSettings: Codable, Equatable {
    public static let maxGainDb = 12.0
    public static let lowHz = 150.0, midHz = 1000.0, highHz = 6000.0

    public var lowDb: Double, midDb: Double, highDb: Double
    public init(lowDb: Double = 0, midDb: Double = 0, highDb: Double = 0) {
        self.lowDb = Self.clamp(lowDb); self.midDb = Self.clamp(midDb); self.highDb = Self.clamp(highDb)
    }
    public static let flat = EQSettings()
    /// Under 0.05 dB everywhere: indistinguishable from bypass.
    public var isFlat: Bool { abs(lowDb) < 0.05 && abs(midDb) < 0.05 && abs(highDb) < 0.05 }
    private static func clamp(_ v: Double) -> Double { v.isFinite ? min(maxGainDb, max(-maxGainDb, v)) : 0 }
}

/// RBJ cookbook biquad, normalised so a0 = 1.
struct BiquadCoefficients: Equatable {
    var b0 = 1.0, b1 = 0.0, b2 = 0.0, a1 = 0.0, a2 = 0.0

    enum Kind { case lowShelf, peak, highShelf }

    static func design(_ kind: Kind, hz: Double, gainDb: Double, sampleRate: Double) -> BiquadCoefficients {
        guard abs(gainDb) >= 0.01, hz < sampleRate / 2 * 0.95 else { return BiquadCoefficients() }
        let a = pow(10, gainDb / 40)
        let w = 2 * Double.pi * hz / sampleRate
        let cw = cos(w), sw = sin(w)
        var b0, b1, b2, a0, a1, a2: Double
        switch kind {
        case .peak:
            let alpha = sw / (2 * 0.8)
            b0 = 1 + alpha * a; b1 = -2 * cw; b2 = 1 - alpha * a
            a0 = 1 + alpha / a; a1 = -2 * cw; a2 = 1 - alpha / a
        case .lowShelf, .highShelf:
            let alpha = sw / 2 * sqrt(2.0)              // shelf slope S = 1
            let tsa = 2 * sqrt(a) * alpha
            if kind == .lowShelf {
                b0 = a * ((a + 1) - (a - 1) * cw + tsa)
                b1 = 2 * a * ((a - 1) - (a + 1) * cw)
                b2 = a * ((a + 1) - (a - 1) * cw - tsa)
                a0 = (a + 1) + (a - 1) * cw + tsa
                a1 = -2 * ((a - 1) + (a + 1) * cw)
                a2 = (a + 1) + (a - 1) * cw - tsa
            } else {
                b0 = a * ((a + 1) + (a - 1) * cw + tsa)
                b1 = -2 * a * ((a - 1) + (a + 1) * cw)
                b2 = a * ((a + 1) + (a - 1) * cw - tsa)
                a0 = (a + 1) - (a - 1) * cw + tsa
                a1 = 2 * ((a - 1) - (a + 1) * cw)
                a2 = (a + 1) - (a - 1) * cw - tsa
            }
        }
        return BiquadCoefficients(b0: b0 / a0, b1: b1 / a0, b2: b2 / a0, a1: a1 / a0, a2: a2 / a0)
    }
}

/// Stereo three-band EQ for one output. `set` is called from the UI thread, `process` from the audio thread.
public final class ThreeBandEQ {
    private let sampleRate: Double
    private let lock = AudioLock()
    private var pending: [BiquadCoefficients]?
    private var pendingFlat = true

    // Audio-thread state.
    private var coef = [BiquadCoefficients](repeating: BiquadCoefficients(), count: 3)
    private var flat = true
    private var z1 = [Double](repeating: 0, count: 6), z2 = [Double](repeating: 0, count: 6)   // [band * 2 + channel]

    public init(sampleRate: Double) { self.sampleRate = sampleRate }

    public func set(_ s: EQSettings) {
        let c = [BiquadCoefficients.design(.lowShelf, hz: EQSettings.lowHz, gainDb: s.lowDb, sampleRate: sampleRate),
                 BiquadCoefficients.design(.peak, hz: EQSettings.midHz, gainDb: s.midDb, sampleRate: sampleRate),
                 BiquadCoefficients.design(.highShelf, hz: EQSettings.highHz, gainDb: s.highDb, sampleRate: sampleRate)]
        lock.lock(); pending = c; pendingFlat = s.isFlat; lock.unlock()
    }

    public func process(_ l: UnsafeMutablePointer<Float>, _ r: UnsafeMutablePointer<Float>, frames: Int) {
        lock.lock()
        if let p = pending { coef = p; flat = pendingFlat; pending = nil }
        lock.unlock()
        if flat {
            for i in 0..<z1.count { z1[i] = 0; z2[i] = 0 }
            return
        }
        for band in 0..<3 {
            let c = coef[band]
            for ch in 0..<2 {
                let buf = ch == 0 ? l : r
                var s1 = z1[band * 2 + ch], s2 = z2[band * 2 + ch]
                for n in 0..<frames {
                    let x = Double(buf[n])
                    let y = c.b0 * x + s1                  // transposed direct form II
                    s1 = c.b1 * x - c.a1 * y + s2
                    s2 = c.b2 * x - c.a2 * y
                    buf[n] = Float(y)
                }
                z1[band * 2 + ch] = s1; z2[band * 2 + ch] = s2
            }
        }
    }
}
