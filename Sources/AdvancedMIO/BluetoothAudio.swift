@preconcurrency import CoreBluetooth
import Foundation
import MIOCore

/// Audio that arrived over Bluetooth, as one more ring the router mixes into every enabled output
/// (next to the system audio coming from the AdvancedMIO virtual device).
final class RemoteAudioSource: RingSource {
    let ring = StereoRing(sampleRate: AudioFraming.sampleRate)
    private(set) var level: Float = 0
    private var lastWrite = -Double.infinity

    /// True while packets keep arriving; keeps the router running while only remote audio plays.
    var isActive: Bool { StereoRing.hostSeconds() - lastWrite < 1 }

    func startFeeding() {}      // fed by the Bluetooth stream, not by a pump
    func stopFeeding() {}

    func write(left: UnsafePointer<Float>, right: UnsafePointer<Float>, frames: Int) {
        var peak: Float = 0
        for i in 0..<frames { peak = max(peak, abs(left[i]), abs(right[i])) }
        level = peak
        lastWrite = StereoRing.hostSeconds()
        ring.write(left: left, right: right, frames: frames)
    }
}

/// Receiving Mac: reads one L2CAP audio channel. The first frame must carry the six-digit code; only then is audio decoded.
@MainActor
final class BluetoothAudioReceiver: NSObject, StreamDelegate {
    private let channel: CBL2CAPChannel
    private let sink: RemoteAudioSource
    private let authorize: (String) -> Bool
    private let onAccepted: () -> Void
    private let onClosed: (BluetoothAudioReceiver) -> Void
    private var parser = AudioFrameParser()
    private var decoder: AACDecoder?
    private var finished = false

    init(channel: CBL2CAPChannel, sink: RemoteAudioSource, authorize: @escaping (String) -> Bool,
         onAccepted: @escaping () -> Void, onClosed: @escaping (BluetoothAudioReceiver) -> Void) {
        self.channel = channel
        self.sink = sink
        self.authorize = authorize
        self.onAccepted = onAccepted
        self.onClosed = onClosed
        super.init()
        for stream in [channel.inputStream, channel.outputStream] {
            stream?.delegate = self
            stream?.schedule(in: .main, forMode: .common)
            stream?.open()
        }
    }

    func close() {
        guard !finished else { return }
        finished = true
        for stream in [channel.inputStream, channel.outputStream] {
            stream?.delegate = nil
            stream?.remove(from: .main, forMode: .common)
            stream?.close()
        }
        onClosed(self)
    }

    nonisolated func stream(_ aStream: Stream, handle eventCode: Stream.Event) {
        MainActor.assumeIsolated {
            guard !finished else { return }
            if eventCode.contains(.errorOccurred) || eventCode.contains(.endEncountered) { close(); return }
            guard eventCode.contains(.hasBytesAvailable), let input = aStream as? InputStream else { return }
            var buffer = [UInt8](repeating: 0, count: 4096)
            while input.hasBytesAvailable, !finished {
                let n = input.read(&buffer, maxLength: buffer.count)
                if n <= 0 { break }
                handle(Data(buffer[0..<n]))
            }
        }
    }

    private func handle(_ data: Data) {
        guard let frames = parser.feed(data) else { close(); return }
        for frame in frames where !finished {
            if decoder == nil {
                // Anything but a valid hello with the right code ends the connection.
                guard frame.type == .hello, let hello = AudioFraming.parseHello(frame.body), authorize(hello.code),
                      let decoder = AACDecoder(cookie: hello.cookie) else { close(); return }
                self.decoder = decoder
                onAccepted()
            } else if frame.type == .audio {
                if let pcm = decoder?.decode(frame.body) { sink.write(left: pcm.left, right: pcm.right, frames: pcm.frames) }
            } else {
                close()
            }
        }
    }
}

/// Sending Mac: one open L2CAP channel to the receiving Mac. The router's remote output hands it 1024-frame blocks;
/// they are AAC-encoded and queued for the Bluetooth stream.
final class BluetoothAudioSender: NSObject, StreamDelegate, @unchecked Sendable {
    private let channel: CBL2CAPChannel
    private let encoder: AACEncoder
    private let lock = NSLock()
    private var queue: [Data] = []          // whole frames not yet started
    private var current: Data?              // frame being written; may be partially sent
    private var closed = false
    private let onClosed: @Sendable () -> Void
    /// Roughly half a second of audio; beyond that the oldest packets are dropped so latency cannot grow without bound.
    private static let maxQueued = 24

    init?(channel: CBL2CAPChannel, code: String, onClosed: @escaping @Sendable () -> Void) {
        guard let encoder = AACEncoder(), let hello = AudioFraming.hello(code: code, cookie: encoder.cookie) else { return nil }
        self.channel = channel
        self.encoder = encoder
        self.onClosed = onClosed
        super.init()
        queue = [hello]
        DispatchQueue.main.async { [self] in
            for stream in [channel.inputStream, channel.outputStream] {
                stream?.delegate = self
                stream?.schedule(in: .main, forMode: .common)
                stream?.open()
            }
        }
    }

    var isOpen: Bool { lock.lock(); defer { lock.unlock() }; return !closed }

    /// Called from the router's output timer thread with exactly `AudioFraming.framesPerPacket` frames.
    func push(left: UnsafePointer<Float>, right: UnsafePointer<Float>) {
        guard isOpen, let packet = encoder.encode(left: left, right: right) else { return }
        lock.lock()
        queue.append(AudioFraming.encode(.audio, packet))
        if queue.count > Self.maxQueued { queue.removeFirst(queue.count - Self.maxQueued / 2) }
        lock.unlock()
        DispatchQueue.main.async { [self] in flush() }
    }

    func close() {
        lock.lock()
        let wasClosed = closed
        closed = true
        queue = []; current = nil
        lock.unlock()
        guard !wasClosed else { return }
        DispatchQueue.main.async { [self] in
            for stream in [channel.inputStream, channel.outputStream] {
                stream?.delegate = nil
                stream?.remove(from: .main, forMode: .common)
                stream?.close()
            }
        }
        onClosed()
    }

    private func flush() {
        guard let output = channel.outputStream else { return }
        while output.hasSpaceAvailable {
            lock.lock()
            if current == nil, !queue.isEmpty { current = queue.removeFirst() }
            let data = current
            lock.unlock()
            guard let data else { return }
            let written = data.withUnsafeBytes { output.write($0.bindMemory(to: UInt8.self).baseAddress!, maxLength: data.count) }
            if written < 0 { close(); return }
            lock.lock()
            current = written >= data.count ? nil : data.suffix(from: data.startIndex + written)
            lock.unlock()
            if written == 0 { return }
        }
    }

    func stream(_ aStream: Stream, handle eventCode: Stream.Event) {
        if eventCode.contains(.errorOccurred) || eventCode.contains(.endEncountered) { close(); return }
        if eventCode.contains(.hasSpaceAvailable) { flush() }
    }
}
