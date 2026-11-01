import AVFoundation
import CoreAudio

private func setDevice(_ unit: AudioUnit?, _ id: AudioDeviceID) {
    guard let unit else { return }
    var dev = id
    AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                         &dev, UInt32(MemoryLayout<AudioDeviceID>.size))
}

/// Captures one input device into a ring buffer.
final class InputCapture {
    let engine = AVAudioEngine()
    let ring = StereoRing()
    private(set) var sampleRate: Double = 48000

    init(deviceID: AudioDeviceID) throws {
        setDevice(engine.inputNode.audioUnit, deviceID)
        let format = engine.inputNode.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw NSError(domain: "AdvancedMIO", code: 1, userInfo: [NSLocalizedDescriptionKey: "입력 장치를 열 수 없습니다"])
        }
        sampleRate = format.sampleRate
        let ring = self.ring
        engine.inputNode.installTap(onBus: 0, bufferSize: 512, format: format) { buf, _ in
            guard let ch = buf.floatChannelData else { return }
            let n = Int(buf.frameLength)
            let left = ch[0]
            let right = buf.format.channelCount > 1 ? ch[1] : ch[0]
            ring.write(left: left, right: right, frames: n)
        }
        engine.prepare()
        try engine.start()
    }

    func stop() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
    }
}

/// Per-(output,input) delayed reader.
private final class DelayedReader {
    let ring: StereoRing
    let rate: Double
    var targetFrames: Int
    var currentFrames: Int
    init(ring: StereoRing, rate: Double, delayMs: Double) {
        self.ring = ring; self.rate = rate
        targetFrames = Int(delayMs * rate / 1000)
        currentFrames = targetFrames
    }
    static let baseFrames = 256
}

/// Plays all inputs (each delayed by the same per-device amount) to one output device.
final class OutputRenderer {
    private let engine = AVAudioEngine()
    private var readers: [DelayedReader] = []
    private var gain: Float = 1

    init(deviceID: AudioDeviceID, inputs: [InputCapture], delayMs: Double) throws {
        setDevice(engine.outputNode.audioUnit, deviceID)
        for input in inputs {
            let reader = DelayedReader(ring: input.ring, rate: input.sampleRate, delayMs: delayMs)
            readers.append(reader)
            let format = AVAudioFormat(standardFormatWithSampleRate: input.sampleRate, channels: 2)!
            let node = AVAudioSourceNode(format: format) { [weak self] _, _, frameCount, abl in
                let list = UnsafeMutableAudioBufferListPointer(abl)
                guard list.count >= 2,
                      let l = list[0].mData?.assumingMemoryBound(to: Float.self),
                      let r = list[1].mData?.assumingMemoryBound(to: Float.self) else { return noErr }
                let n = Int(frameCount)
                for i in 0..<n { l[i] = 0; r[i] = 0 }
                // Slew toward the target so dragging the slider doesn't click.
                let step = max(1, n / 8)
                let diff = reader.targetFrames - reader.currentFrames
                reader.currentFrames += max(-step, min(step, diff))
                reader.ring.mix(into: l, r, frames: n,
                                delayFrames: reader.currentFrames + DelayedReader.baseFrames,
                                gain: self?.gain ?? 1)
                return noErr
            }
            engine.attach(node)
            engine.connect(node, to: engine.mainMixerNode, format: format)
        }
        engine.prepare()
        try engine.start()
    }

    func setDelay(ms: Double) {
        for r in readers {
            let maxFrames = r.ring.capacity - 4096
            r.targetFrames = min(maxFrames, max(0, Int(ms * r.rate / 1000)))
        }
    }
    func setGain(_ g: Float) { gain = g }
    func stop() { engine.stop() }
}
