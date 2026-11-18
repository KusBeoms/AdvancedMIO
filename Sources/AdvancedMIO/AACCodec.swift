import AVFoundation
import MIOCore

/// AAC-LC encoder for the Bluetooth audio channel: 1024 frames of 48 kHz stereo in, one packet out (≈16 KB/s at 128 kbps).
final class AACEncoder {
    private let converter: AVAudioConverter
    private let input: AVAudioPCMBuffer
    private let output: AVAudioCompressedBuffer

    /// Decoder setup data (AudioSpecificConfig); sent once in the hello frame.
    let cookie: Data

    init?(bitRate: Int = 128_000) {
        let rate = AudioFraming.sampleRate
        guard let pcm = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 2, interleaved: false),
              let aac = AVAudioFormat(settings: [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: rate,
                                                 AVNumberOfChannelsKey: 2, AVEncoderBitRateKey: bitRate]),
              let converter = AVAudioConverter(from: pcm, to: aac),
              let input = AVAudioPCMBuffer(pcmFormat: pcm, frameCapacity: AVAudioFrameCount(AudioFraming.framesPerPacket)) else { return nil }
        self.converter = converter
        self.input = input
        output = AVAudioCompressedBuffer(format: aac, packetCapacity: 1, maximumPacketSize: converter.maximumOutputPacketSize)
        cookie = converter.outputFormat.magicCookie ?? Data()
        input.frameLength = AVAudioFrameCount(AudioFraming.framesPerPacket)
    }

    /// Encodes exactly `framesPerPacket` frames. Returns nil while the encoder is still priming.
    func encode(left: UnsafePointer<Float>, right: UnsafePointer<Float>) -> Data? {
        guard let channels = input.floatChannelData else { return nil }
        let n = AudioFraming.framesPerPacket
        channels[0].update(from: left, count: n)
        channels[1].update(from: right, count: n)
        var supplied = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, inputStatus in
            if supplied { inputStatus.pointee = .noDataNow; return nil }
            supplied = true
            inputStatus.pointee = .haveData
            return self.input
        }
        guard error == nil, status != .error, output.byteLength > 0 else { return nil }
        return Data(bytes: output.data, count: Int(output.byteLength))
    }
}

/// Matching decoder: one AAC packet in, 1024 frames of float stereo out.
final class AACDecoder {
    private let converter: AVAudioConverter
    private let input: AVAudioCompressedBuffer
    private let output: AVAudioPCMBuffer

    init?(cookie: Data) {
        let rate = AudioFraming.sampleRate
        guard let pcm = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 2, interleaved: false),
              let aac = AVAudioFormat(settings: [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: rate,
                                                 AVNumberOfChannelsKey: 2]) else { return nil }
        if !cookie.isEmpty { aac.magicCookie = cookie }
        guard let converter = AVAudioConverter(from: aac, to: pcm),
              let output = AVAudioPCMBuffer(pcmFormat: pcm, frameCapacity: AVAudioFrameCount(AudioFraming.framesPerPacket)) else { return nil }
        self.converter = converter
        self.output = output
        input = AVAudioCompressedBuffer(format: aac, packetCapacity: 1, maximumPacketSize: AudioFraming.maxBody)
    }

    /// Decodes one packet. The returned pointers stay valid until the next call.
    func decode(_ packet: Data) -> (left: UnsafePointer<Float>, right: UnsafePointer<Float>, frames: Int)? {
        guard !packet.isEmpty, packet.count <= AudioFraming.maxBody, let descriptions = input.packetDescriptions else { return nil }
        packet.withUnsafeBytes { input.data.copyMemory(from: $0.baseAddress!, byteCount: packet.count) }
        input.packetCount = 1
        input.byteLength = UInt32(packet.count)
        descriptions[0] = AudioStreamPacketDescription(mStartOffset: 0, mVariableFramesInPacket: 0, mDataByteSize: UInt32(packet.count))
        output.frameLength = 0
        var supplied = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, inputStatus in
            if supplied { inputStatus.pointee = .noDataNow; return nil }
            supplied = true
            inputStatus.pointee = .haveData
            return self.input
        }
        guard error == nil, status != .error, output.frameLength > 0, let channels = output.floatChannelData else { return nil }
        return (UnsafePointer(channels[0]), UnsafePointer(channels[1]), Int(output.frameLength))
    }
}
