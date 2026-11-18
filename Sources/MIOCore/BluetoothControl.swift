import Foundation

public enum BluetoothControlAction: String, CaseIterable {
    case start, stop, zero

    public var command: ControlCommand {
        switch self {
        case .start: return .start
        case .stop: return .stop
        case .zero: return .zeroLag
        }
    }
}

/// A six-digit code optionally followed by one space and a command, encoded as UTF-8.
/// Every write carries the code, so authorization never outlives a code change or depends on a Bluetooth bond.
public struct BluetoothControlRequest: Equatable {
    public let code: String
    public let action: BluetoothControlAction?

    public init?(code: String, action: BluetoothControlAction? = nil) {
        guard code.utf8.count == 6, code.utf8.allSatisfy({ (48...57).contains($0) }) else { return nil }
        self.code = code
        self.action = action
    }

    public init?(data: Data) {
        guard (6...12).contains(data.count), let text = String(data: data, encoding: .utf8) else { return nil }
        let parts = text.split(separator: " ", omittingEmptySubsequences: false)
        if parts.count == 1 {
            self.init(code: text)
            return
        }
        guard parts.count == 2, let action = BluetoothControlAction(rawValue: String(parts[1])) else { return nil }
        self.init(code: String(parts[0]), action: action)
    }

    public var data: Data {
        Data((action.map { "\(code) \($0.rawValue)" } ?? code).utf8)
    }
}

public struct BluetoothAccessGate {
    public enum Result: Equatable { case allowed, wrongCode, rateLimited }

    public private(set) var code = Self.makeCode()
    private var failedAttempts = 0
    private var retryAfter: TimeInterval = 0
    private static let attemptLimit = 5
    private static let cooldown: TimeInterval = 30

    public init() {}

    public mutating func rotateCode() {
        var next = Self.makeCode()
        while next == code { next = Self.makeCode() }
        code = next
        failedAttempts = 0
        retryAfter = 0
    }

    /// `uptime` comes from a monotonic clock, so wall clock changes cannot shorten a lockout.
    public mutating func authorize(_ request: BluetoothControlRequest, uptime: TimeInterval) -> Result {
        guard uptime >= retryAfter else { return .rateLimited }
        guard request.code != code else { return .allowed }
        failedAttempts += 1
        if failedAttempts < Self.attemptLimit { return .wrongCode }
        rotateCode()
        retryAfter = uptime + Self.cooldown
        return .rateLimited
    }

    private static func makeCode() -> String {
        let digits = String(Int.random(in: 0...999_999))
        return String(repeating: "0", count: 6 - digits.count) + digits
    }
}
