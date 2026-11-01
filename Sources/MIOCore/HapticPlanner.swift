public enum HapticEvent: Equatable { case none, tick, major, edge }

public enum HapticPlanner {
    /// Which haptic to fire when the delay moves from `old` to `new` (ms):
    /// edge at the 0 / 1000 limits, strong at every 100 ms boundary, light at every 10 ms boundary.
    public static func event(from old: Double, to new: Double, limit: Double = 1000) -> HapticEvent {
        guard old != new else { return .none }
        if new <= 0 || new >= limit { return .edge }
        if Int((old / 100).rounded(.down)) != Int((new / 100).rounded(.down)) { return .major }
        if Int((old / 10).rounded(.down)) != Int((new / 10).rounded(.down)) { return .tick }
        return .none
    }

    public static func clamp(_ ms: Double, limit: Double = 1000) -> Double {
        min(limit, max(0, ms.rounded()))
    }
}
