import Foundation

/// Wire format of the Bluetooth audio channel: a stream of frames `[u16 LE length][type][body]`
/// where `length` counts the type byte plus the body.
public enum AudioFrameType: UInt8 {
    /// First frame from the sender: magic, six-digit access code, AAC magic cookie.
    case hello = 1
    /// One AAC packet (1024 frames of 48 kHz stereo).
    case audio = 2
}

public struct AudioFrame: Equatable {
    public let type: AudioFrameType
    public let body: Data
}

public enum AudioFraming {
    public static let sampleRate = 48_000.0
    public static let framesPerPacket = 1024
    public static let maxBody = 2048
    private static let magic = Array("AMIO".utf8)

    public static func encode(_ type: AudioFrameType, _ body: Data) -> Data {
        precondition(body.count <= maxBody, "frame body too large")
        let length = UInt16(body.count + 1)
        var out = Data(capacity: body.count + 3)
        out.append(UInt8(length & 0xFF)); out.append(UInt8(length >> 8))
        out.append(type.rawValue)
        out.append(body)
        return out
    }

    public static func hello(code: String, cookie: Data) -> Data? {
        guard BluetoothControlRequest(code: code) != nil, cookie.count <= 255 else { return nil }
        var body = Data(magic)
        body.append(Data(code.utf8))
        body.append(UInt8(cookie.count))
        body.append(cookie)
        return encode(.hello, body)
    }

    public static func parseHello(_ body: Data) -> (code: String, cookie: Data)? {
        let b = [UInt8](body)
        guard b.count >= 11, Array(b[0..<4]) == magic,
              let code = String(bytes: b[4..<10], encoding: .utf8), BluetoothControlRequest(code: code) != nil else { return nil }
        let n = Int(b[10])
        guard b.count == 11 + n else { return nil }
        return (code, Data(b[11...]))
    }
}

/// Splits an arbitrarily chunked byte stream back into frames.
public struct AudioFrameParser {
    private var buffer: [UInt8] = []

    public init() {}

    /// Returns the complete frames now available, or nil when the stream is invalid (the caller should close it).
    public mutating func feed(_ data: Data) -> [AudioFrame]? {
        buffer.append(contentsOf: data)
        var frames: [AudioFrame] = []
        var offset = 0
        while buffer.count - offset >= 2 {
            let length = Int(buffer[offset]) | Int(buffer[offset + 1]) << 8
            guard length >= 1, length <= AudioFraming.maxBody + 1 else { return nil }
            guard buffer.count - offset >= 2 + length else { break }
            guard let type = AudioFrameType(rawValue: buffer[offset + 2]) else { return nil }
            frames.append(AudioFrame(type: type, body: Data(buffer[(offset + 3)..<(offset + 2 + length)])))
            offset += 2 + length
        }
        buffer.removeFirst(offset)
        return frames
    }
}
