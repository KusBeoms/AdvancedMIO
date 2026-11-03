import Foundation

/// Pure helpers for the device-lag sliders and the latency watch (kept here so they are unit-tested on any OS).
public enum LagMath {
    /// Every value moved down by the smallest one, so the lowest becomes 0 and the differences between devices stay
    /// exactly as they were.
    public static func shiftedToZero(_ lags: [Double]) -> [Double] {
        guard let lo = lags.min() else { return lags }
        return lags.map { max(0, $0 - lo) }
    }
}

public enum LatencyWatch {
    /// A device's reported latency counts as "changed" once it moved by this much …
    public static let minChangeMs = 20.0
    /// … or by this share of where it was, whichever is larger.
    public static let minChangeFraction = 0.15

    public static func hasDrifted(from reference: Double, to now: Double) -> Bool {
        abs(now - reference) >= max(minChangeMs, reference * minChangeFraction)
    }
}

public enum NameMatch {
    /// Index of the best match for `query` among `names`: exact (case/width-insensitive), then prefix, then substring.
    public static func best(_ query: String, in names: [String]) -> Int? {
        let q = fold(query)
        guard !q.isEmpty else { return nil }
        let f = names.map(fold)
        return f.firstIndex(of: q) ?? f.firstIndex { $0.hasPrefix(q) } ?? f.firstIndex { $0.contains(q) }
    }
    private static func fold(_ s: String) -> String {
        s.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
    }
}

/// `advancedmio://preset/거실`, `advancedmio://start` … parsed into a command (the app decides what to do with it).
public enum ControlCommand: Equatable {
    case start, stop, toggle, zeroLag
    case preset(String)
    case openWindow

    public static func parse(_ url: URL) -> ControlCommand? {
        guard url.scheme?.lowercased() == "advancedmio", let host = url.host?.lowercased() else { return nil }
        let rest = url.pathComponents.dropFirst().joined(separator: "/")
        switch host {
        case "start": return .start
        case "stop": return .stop
        case "toggle": return .toggle
        case "zero": return .zeroLag
        case "open": return .openWindow
        case "preset": return rest.isEmpty ? nil : .preset(rest)
        default: return nil
        }
    }
}
