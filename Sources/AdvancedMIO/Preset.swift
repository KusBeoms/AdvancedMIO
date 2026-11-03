import Foundation

/// A named snapshot of the whole routing setup: which devices are on and, per device, lag / volume / EQ / placement.
struct Preset: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var outputs: [String: OutputConfig]
    var spatialOn: Bool
    var listenerHeadingDeg: Double
}

/// One finished room calibration, kept to compare before / after and to tell when it is probably out of date.
struct CalibrationRecord: Codable, Identifiable, Equatable {
    var id = UUID()
    var date: Date
    var roomName: String
    var speakerUIDs: [String]
    var speakerNames: [String]
    var originalDelaysMs: [Double]
    var calibratedDelaysMs: [Double]
    var measuredBefore: Double?
    var measuredAfter: Double?
    /// What `measuredBefore/After` are: "ms" = spread of the speakers' arrival times; nil = the old boominess index.
    var unit: String?
    /// Hardware-reported latency of each speaker at the time (to notice Bluetooth devices drifting later).
    var hwLatencyMs: [String: Double]
    var applied: Bool

    var improvement: Double? {
        guard let b = measuredBefore, let a = measuredAfter, b > 0 else { return nil }
        return (b - a) / b
    }
}

/// Small UserDefaults-backed stores for the lists above.
enum Store {
    private static let presetsKey = "presets.v1", historyKey = "calibration.history.v1"
    static let maxHistory = 30

    static func loadPresets() -> [Preset] { load(presetsKey) ?? [] }
    static func savePresets(_ p: [Preset]) { save(p, presetsKey) }
    static func loadHistory() -> [CalibrationRecord] { load(historyKey) ?? [] }
    static func saveHistory(_ h: [CalibrationRecord]) { save(Array(h.suffix(maxHistory)), historyKey) }

    private static func load<T: Decodable>(_ key: String) -> T? {
        UserDefaults.standard.data(forKey: key).flatMap { try? JSONDecoder().decode(T.self, from: $0) }
    }
    private static func save<T: Encodable>(_ value: T, _ key: String) {
        if let d = try? JSONEncoder().encode(value) { UserDefaults.standard.set(d, forKey: key) }
    }
}
