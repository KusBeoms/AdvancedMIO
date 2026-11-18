import Foundation

/// Wire format of the Bluetooth audio channel: a stream of frames `[u16 LE length][type][body]`
/// where `length` counts the type byte plus the body.
public enum AudioFrameType: UInt8 {
    /// First frame from the sender: magic, six-digit access code, AAC magic cookie.
    case hello = 1
    /// Sender → receiver: one AAC packet (1024 frames of 48 kHz stereo) with a sequence number and send time.
    case audio = 2
    /// Receiver → sender: acknowledges a packet; carries what the sender needs for flow control and latency estimation.
    case ack = 3
}

public struct AudioFrame: Equatable {
    public let type: AudioFrameType
    public let body: Data
}

public enum AudioFraming {
    public static let sampleRate = 48_000.0
    public static let framesPerPacket = 1024
    public static let maxBody = 2048
    public static let blockSeconds = Double(framesPerPacket) / sampleRate
    // "AMI2": the sequence/ack protocol. Older builds ("AMIO") are rejected cleanly instead of decoding garbage.
    private static let magic = Array("AMI2".utf8)

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

    static func le32(_ v: UInt32) -> [UInt8] { [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8(v >> 24)] }
    static func le16(_ v: UInt16) -> [UInt8] { [UInt8(v & 0xFF), UInt8(v >> 8)] }
    static func read32(_ b: [UInt8], _ i: Int) -> UInt32 {
        UInt32(b[i]) | UInt32(b[i + 1]) << 8 | UInt32(b[i + 2]) << 16 | UInt32(b[i + 3]) << 24
    }
    static func read16(_ b: [UInt8], _ i: Int) -> UInt16 { UInt16(b[i]) | UInt16(b[i + 1]) << 8 }
}

/// One AAC packet on the wire. `sendMs` is the sender's monotonic clock; only the sender interprets it (the receiver echoes it).
public struct AudioPacket: Equatable {
    public let sequence: UInt32
    public let sendMs: UInt32
    public let payload: Data

    public init(sequence: UInt32, sendMs: UInt32, payload: Data) {
        self.sequence = sequence; self.sendMs = sendMs; self.payload = payload
    }

    public init?(body: Data) {
        let b = [UInt8](body)
        guard b.count > 8 else { return nil }
        sequence = AudioFraming.read32(b, 0)
        sendMs = AudioFraming.read32(b, 4)
        payload = Data(b[8...])
    }

    public var frame: Data {
        AudioFraming.encode(.audio, Data(AudioFraming.le32(sequence) + AudioFraming.le32(sendMs)) + payload)
    }
}

/// Receiver → sender. Sent for every packet, so the sender knows how much is still in flight and how long a round trip takes.
public struct AudioAck: Equatable {
    public let sequence: UInt32          // the packet being acknowledged
    public let echoSendMs: UInt32        // that packet's `sendMs`, returned unchanged
    public let bufferMs: UInt16          // audio waiting in the receiver's jitter buffer
    public let outputLagMs: UInt16       // delay from the receiver's router to its speakers (laggiest enabled output)

    public init(sequence: UInt32, echoSendMs: UInt32, bufferMs: UInt16, outputLagMs: UInt16) {
        self.sequence = sequence; self.echoSendMs = echoSendMs; self.bufferMs = bufferMs; self.outputLagMs = outputLagMs
    }

    public init?(body: Data) {
        let b = [UInt8](body)
        guard b.count == 12 else { return nil }
        sequence = AudioFraming.read32(b, 0)
        echoSendMs = AudioFraming.read32(b, 4)
        bufferMs = AudioFraming.read16(b, 8)
        outputLagMs = AudioFraming.read16(b, 10)
    }

    public var frame: Data {
        AudioFraming.encode(.ack, Data(AudioFraming.le32(sequence) + AudioFraming.le32(echoSendMs)
                                       + AudioFraming.le16(bufferMs) + AudioFraming.le16(outputLagMs)))
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
