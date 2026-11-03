import MIOCore

/// Everything remembered about one output device (keyed by its UID in `AppModel.outputs`).
struct OutputConfig: Codable, Equatable {
    var enabled = false
    /// On: this device's lag is the hardware-reported latency. Off: `manualLagMs` is used instead.
    var auto = true
    var manualLagMs: Double = 0
    var volume: Double = 1
    /// Spatial audio: place on the circle (nil = the default slot for this device) and how far the speaker is
    /// turned away from facing the listener.
    var angleDeg: Double?
    var aimOffsetDeg: Double = 0
    /// Distance from the listener, 0 (on top of them: plays everything) … 1 (outer ring).
    var radius: Double = 1
    /// Tone control for this device (low shelf / mid / high shelf).
    var eq = EQSettings.flat
    /// The hardware-reported latency this manual lag was set against; a later change means the lag may no longer fit.
    var hwBaselineMs: Double?

    init(enabled: Bool = false, auto: Bool = true, manualLagMs: Double = 0, volume: Double = 1,
         angleDeg: Double? = nil, aimOffsetDeg: Double = 0, radius: Double = 1,
         eq: EQSettings = .flat, hwBaselineMs: Double? = nil) {
        self.enabled = enabled; self.auto = auto; self.manualLagMs = manualLagMs; self.volume = volume
        self.angleDeg = angleDeg; self.aimOffsetDeg = aimOffsetDeg; self.radius = radius
        self.eq = eq; self.hwBaselineMs = hwBaselineMs
    }

    // Tolerant of older saves (which stored a differently-meaning `delayMs`/`lagMs`; those are dropped).
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        auto = try c.decodeIfPresent(Bool.self, forKey: .auto) ?? true
        manualLagMs = try c.decodeIfPresent(Double.self, forKey: .manualLagMs) ?? 0
        volume = min(1, max(0, try c.decodeIfPresent(Double.self, forKey: .volume) ?? 1))   // old saves went up to 200 %
        angleDeg = try c.decodeIfPresent(Double.self, forKey: .angleDeg)
        aimOffsetDeg = try c.decodeIfPresent(Double.self, forKey: .aimOffsetDeg) ?? 0
        radius = min(1, max(0, try c.decodeIfPresent(Double.self, forKey: .radius) ?? 1))
        eq = try c.decodeIfPresent(EQSettings.self, forKey: .eq) ?? .flat
        hwBaselineMs = try c.decodeIfPresent(Double.self, forKey: .hwBaselineMs)
    }
}
