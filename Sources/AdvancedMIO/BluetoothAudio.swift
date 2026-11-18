@preconcurrency import CoreBluetooth
import Foundation
import MIOCore

private func monotonicMs() -> UInt32 {
    UInt32(truncatingIfNeeded: DispatchTime.now().uptimeNanoseconds / 1_000_000)
}

/// Audio that arrived over Bluetooth, as one more ring the router mixes into every enabled output
/// (next to the system audio coming from the AdvancedMIO virtual device).
final class RemoteAudioSource: RingSource, @unchecked Sendable {
    let ring = StereoRing(sampleRate: AudioFraming.sampleRate)
    private let lock = NSLock()
    private var peak: Float = 0
    private var lastWrite = -Double.infinity

    var level: Float { lock.lock(); defer { lock.unlock() }; return peak }
    /// True while blocks keep arriving; keeps the router running while only remote audio plays.
    var isActive: Bool { lock.lock(); defer { lock.unlock() }; return StereoRing.hostSeconds() - lastWrite < 1 }

    func startFeeding() {}      // fed by the playout clock below, not by a pump
    func stopFeeding() {}

    func write(left: UnsafePointer<Float>, right: UnsafePointer<Float>, frames: Int) {
        var p: Float = 0
        for i in 0..<frames { p = max(p, abs(left[i]), abs(right[i])) }
        lock.lock(); peak = p; lastWrite = StereoRing.hostSeconds(); lock.unlock()
        ring.write(left: left, right: right, frames: frames)
    }
}

/// Writes decoded blocks into the ring at a steady pace, whatever the arrival pattern. A jitter buffer holds a cushion;
/// the clock runs ±1 % fast or slow to keep the cushion constant (the two Macs' clocks never agree exactly).
final class RemotePlayout: @unchecked Sendable {
    private let sink: RemoteAudioSource
    private let lock = NSLock()
    private var jitter = JitterBuffer()
    private let queue = DispatchQueue(label: "advancedmio.remote-playout", qos: .userInteractive)
    private var timer: DispatchSourceTimer?
    private var clockRunning = false
    private var nextNs: UInt64 = 0
    private let silence = [Float](repeating: 0, count: AudioFraming.framesPerPacket)
    private static let blockNs = UInt64(AudioFraming.blockSeconds * 1e9)

    init(sink: RemoteAudioSource) { self.sink = sink }

    /// Returns true on the first block of a new burst, so the receiver can start its outputs while buffering.
    func push(left: UnsafePointer<Float>, right: UnsafePointer<Float>, frames: Int) -> Bool {
        let block = JitterBuffer.Block(left: Array(UnsafeBufferPointer(start: left, count: frames)),
                                       right: Array(UnsafeBufferPointer(start: right, count: frames)))
        lock.lock()
        let firstBlock = !clockRunning && jitter.depth == 0
        jitter.push(block)
        if !clockRunning, jitter.depth >= jitter.target, let timer {
            clockRunning = true
            nextNs = DispatchTime.now().uptimeNanoseconds
            timer.schedule(deadline: DispatchTime(uptimeNanoseconds: nextNs), leeway: .microseconds(500))
        }
        lock.unlock()
        return firstBlock
    }

    struct Snapshot { let bufferMs: Double; let targetMs: Double; let underruns: Int; let dropped: Int }
    var snapshot: Snapshot {
        lock.lock(); defer { lock.unlock() }
        return Snapshot(bufferMs: Double(jitter.depth) * AudioFraming.blockSeconds * 1000,
                        targetMs: Double(jitter.target) * AudioFraming.blockSeconds * 1000,
                        underruns: jitter.underruns, dropped: jitter.dropped)
    }

    func start() {
        guard timer == nil else { return }
        let t = DispatchSource.makeTimerSource(flags: .strict, queue: queue)
        t.setEventHandler { [weak self] in self?.tick(t) }      // `t` is released with the handler when cancelled
        timer = t
        t.resume()
    }

    func stop() {
        timer?.cancel(); timer = nil
        queue.sync {}
    }

    private func tick(_ t: DispatchSourceTimer) {
        lock.lock()
        let output = jitter.pop()
        if case .block = output {
            let period = UInt64(Double(Self.blockNs) / jitter.playoutRate)
            nextNs = max(nextNs + period, DispatchTime.now().uptimeNanoseconds)
            t.schedule(deadline: DispatchTime(uptimeNanoseconds: nextNs), leeway: .microseconds(500))
        } else {
            // This is a one-shot timer. The next full cushion restarts it after a pause.
            clockRunning = false
        }
        lock.unlock()
        switch output {
        case .block(let b):
            if !b.left.isEmpty, b.left.count == b.right.count {
                b.left.withUnsafeBufferPointer { l in
                    b.right.withUnsafeBufferPointer { r in sink.write(left: l.baseAddress!, right: r.baseAddress!, frames: b.left.count) }
                }
            }
        case .underrun:
            silence.withUnsafeBufferPointer { s in sink.write(left: s.baseAddress!, right: s.baseAddress!, frames: s.count) }
        case .priming:
            break
        }
    }
}

/// Receiving Mac: reads one L2CAP audio channel. The first frame must carry the six-digit code; only then is audio decoded.
/// Every packet is acknowledged so the sender can pace itself and estimate the latency.
@MainActor
final class BluetoothAudioReceiver: NSObject, StreamDelegate {
    private let channel: CBL2CAPChannel
    private let authorize: (String) -> Bool
    private let outputLagMs: @MainActor () -> Double
    private let onPlaybackStart: () -> Void
    private let onAccepted: () -> Void
    private let onClosed: (BluetoothAudioReceiver) -> Void
    private let playout: RemotePlayout
    private var parser = AudioFrameParser()
    private var decoder: AACDecoder?
    private var pendingAcks: [Data] = []
    private var finished = false

    init(channel: CBL2CAPChannel, sink: RemoteAudioSource, authorize: @escaping (String) -> Bool,
         outputLagMs: @escaping @MainActor () -> Double,
         onPlaybackStart: @escaping () -> Void, onAccepted: @escaping () -> Void, onClosed: @escaping (BluetoothAudioReceiver) -> Void) {
        self.channel = channel
        self.playout = RemotePlayout(sink: sink)
        self.authorize = authorize
        self.outputLagMs = outputLagMs
        self.onPlaybackStart = onPlaybackStart
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
        playout.stop()
        for stream in [channel.inputStream, channel.outputStream] {
            stream?.delegate = nil
            stream?.remove(from: .main, forMode: .common)
            stream?.close()
        }
        onClosed(self)
    }

    var statusText: String {
        let s = playout.snapshot
        return String(format: "버퍼 %.0f/%.0f ms · 끊김 %d · 버린 블록 %d", s.bufferMs, s.targetMs, s.underruns, s.dropped)
    }

    nonisolated func stream(_ aStream: Stream, handle eventCode: Stream.Event) {
        MainActor.assumeIsolated {
            guard !finished else { return }
            if eventCode.contains(.errorOccurred) || eventCode.contains(.endEncountered) { close(); return }
            if eventCode.contains(.hasSpaceAvailable) { flushAcks() }
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
                playout.start()
                onAccepted()
            } else if frame.type == .audio {
                guard let packet = AudioPacket(body: frame.body) else { close(); return }
                if let pcm = decoder?.decode(packet.payload),
                   playout.push(left: pcm.left, right: pcm.right, frames: pcm.frames) {
                    onPlaybackStart()
                }
                let snapshot = playout.snapshot
                let ack = AudioAck(sequence: packet.sequence, echoSendMs: packet.sendMs,
                                   bufferMs: UInt16(min(65_000, max(0, snapshot.bufferMs))),
                                   outputLagMs: UInt16(min(65_000, max(0, outputLagMs()))))
                // ACKs are cumulative. Preserve the head (possibly partially sent) and only the latest successor.
                if pendingAcks.count == 2 { pendingAcks[1] = ack.frame }
                else { pendingAcks.append(ack.frame) }
                flushAcks()
            } else {
                close()
            }
        }
    }

    private func flushAcks() {
        guard let output = channel.outputStream else { return }
        while output.hasSpaceAvailable, let ack = pendingAcks.first {
            let n = ack.withUnsafeBytes { output.write($0.bindMemory(to: UInt8.self).baseAddress!, maxLength: ack.count) }
            if n < 0 { close(); return }
            if n == 0 { break }
            if n < ack.count {
                pendingAcks[0] = Data(ack.suffix(from: ack.startIndex + n))      // finish this frame first: never split-and-skip
            } else {
                pendingAcks.removeFirst()
            }
        }
    }
}

/// Sending Mac: one open L2CAP channel to the receiving Mac. The router's remote output hands it 1024-frame blocks;
/// they are AAC-encoded and sent with a sequence number. At most `window` packets may be unacknowledged: when the
/// link cannot keep up, new packets are dropped instead of queueing, so the delay stays bounded.
final class BluetoothAudioSender: NSObject, StreamDelegate, @unchecked Sendable {
    private let channel: CBL2CAPChannel
    private let encoder: AACEncoder
    private let lock = NSLock()
    private var queue: [Data] = []          // frames not yet started
    private var current: Data?              // frame being written; may be partially sent
    private var closed = false
    private var parser = AudioFrameParser()
    private var nextSequence: UInt32 = 0
    private var oldestUnacknowledged: UInt32 = 0
    private var sentPackets = 0
    private var droppedPackets = 0
    private var rttMs = 0.0
    private var remoteBufferMs = 0.0
    private var remoteOutputLagMs = 0.0
    private var haveAck = false
    private let onClosed: @Sendable () -> Void

    /// About 0.2 s of audio in flight.
    private static let window = 10

    init?(channel: CBL2CAPChannel, code: String, bitRate: Int, onClosed: @escaping @Sendable () -> Void) {
        guard let encoder = AACEncoder(bitRate: bitRate), let hello = AudioFraming.hello(code: code, cookie: encoder.cookie) else { return nil }
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

    /// Estimated delay from handing audio to this sender until it is audible on the receiving Mac's speakers, in ms.
    /// nil until the first acknowledgement arrives.
    var estimatedLatencyMs: Double? {
        lock.lock(); defer { lock.unlock() }
        guard haveAck else { return nil }
        // one block being collected + half a round trip + the receiver's cushion + receiver router → speakers
        return AudioFraming.blockSeconds * 1000 + rttMs / 2 + remoteBufferMs + remoteOutputLagMs
    }

    var statusText: String {
        lock.lock(); defer { lock.unlock() }
        guard haveAck else { return sentPackets == 0 ? "첫 오디오 패킷 대기 중" : "상대 Mac의 수신 확인 대기 중" }
        let latency = AudioFraming.blockSeconds * 1000 + rttMs / 2 + remoteBufferMs + remoteOutputLagMs
        return String(format: "지연 약 %.0f ms (왕복 %.0f · 상대 버퍼 %.0f · 상대 출력 %.0f) · 버린 패킷 %d/%d",
                      latency, rttMs, remoteBufferMs, remoteOutputLagMs, droppedPackets, sentPackets + droppedPackets)
    }

    /// Called from the router's output timer thread with exactly `AudioFraming.framesPerPacket` frames.
    func push(left: UnsafePointer<Float>, right: UnsafePointer<Float>) {
        lock.lock()
        guard !closed else { lock.unlock(); return }
        if nextSequence &- oldestUnacknowledged >= Self.window {      // the link is behind: drop rather than add delay
            droppedPackets += 1
            lock.unlock()
            return
        }
        lock.unlock()

        // Only the serial render queue produces packets. ACKs can only free more space during encoding.
        guard let payload = encoder.encode(left: left, right: right) else { return }
        lock.lock()
        defer { lock.unlock() }
        guard !closed else { return }
        guard payload.count <= AudioFraming.maxBody - 8 else { droppedPackets += 1; return }
        let packet = AudioPacket(sequence: nextSequence, sendMs: monotonicMs(), payload: payload)
        nextSequence &+= 1
        sentPackets += 1
        queue.append(packet.frame)
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

    private func handleAcks(_ data: Data) {
        guard let frames = parser.feed(data) else { close(); return }
        let now = monotonicMs()
        lock.lock()
        for frame in frames where frame.type == .ack {
            guard let ack = AudioAck(body: frame.body) else { continue }
            guard ack.sequence &- oldestUnacknowledged < nextSequence &- oldestUnacknowledged else { continue }
            oldestUnacknowledged = ack.sequence &+ 1
            let rtt = Double(now &- ack.echoSendMs)
            if rtt >= 0, rtt < 10_000 { rttMs = haveAck ? rttMs * 0.9 + rtt * 0.1 : rtt }
            remoteBufferMs = Double(ack.bufferMs)
            remoteOutputLagMs = Double(ack.outputLagMs)
            haveAck = true
        }
        lock.unlock()
    }

    func stream(_ aStream: Stream, handle eventCode: Stream.Event) {
        if eventCode.contains(.errorOccurred) || eventCode.contains(.endEncountered) { close(); return }
        if eventCode.contains(.hasSpaceAvailable) { flush() }
        if eventCode.contains(.hasBytesAvailable), let input = aStream as? InputStream {
            var buffer = [UInt8](repeating: 0, count: 1024)
            while input.hasBytesAvailable {
                let n = input.read(&buffer, maxLength: buffer.count)
                if n <= 0 { break }
                handleAcks(Data(buffer[0..<n]))
            }
        }
    }
}
