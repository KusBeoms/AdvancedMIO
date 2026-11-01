import CoreAudio
import Foundation
import MIOCore

private let maxFrames = 16384
private let maxBuffers = 64

/// Zeroes every buffer of an output list (an IOProc must not leave unused output uninitialised).
private func silence(_ list: UnsafeMutablePointer<AudioBufferList>) {
    for b in UnsafeMutableAudioBufferListPointer(list) {
        if let d = b.mData { memset(d, 0, Int(b.mDataByteSize)) }
    }
}

/// State shared with one input IOProc (audio thread) — captures a device into a ring buffer.
private final class InputState {
    let ring: StereoRing
    let l = UnsafeMutablePointer<Float>.allocate(capacity: maxFrames)
    let r = UnsafeMutablePointer<Float>.allocate(capacity: maxFrames)
    let refs = UnsafeMutablePointer<BufferRef>.allocate(capacity: maxBuffers)
    var level: Float = 0
    var callbacks = 0, framesCaptured = 0

    init(rate: Double) {
        ring = StereoRing(sampleRate: rate)
        l.initialize(repeating: 0, count: maxFrames); r.initialize(repeating: 0, count: maxFrames)
        refs.initialize(repeating: BufferRef(data: nil, channels: 1), count: maxBuffers)
    }
    deinit { l.deallocate(); r.deallocate(); refs.deallocate() }

    func process(_ abl: UnsafeMutableAudioBufferListPointer) {
        let count = min(abl.count, maxBuffers)
        var frames = 0
        for i in 0..<count {
            let b = abl[i]
            let ch = max(1, Int(b.mNumberChannels))
            refs[i] = BufferRef(data: b.mData?.assumingMemoryBound(to: Float.self), channels: ch)
            if frames == 0, b.mData != nil { frames = Int(b.mDataByteSize) / (MemoryLayout<Float>.size * ch) }
        }
        frames = min(frames, maxFrames)
        callbacks += 1
        guard frames > 0 else { level = 0; return }
        framesCaptured += frames
        ChannelMapping.extractStereo(UnsafeBufferPointer(start: refs, count: count), frames: frames, left: l, right: r)
        var peak: Float = 0
        for i in 0..<frames { peak = max(peak, abs(l[i]), abs(r[i])) }
        level = peak
        ring.write(left: l, right: r, frames: frames)
    }
}

/// State shared with one output IOProc — mixes delayed readers into the device.
private final class OutputState {
    let readers: [DelayReader]
    let l = UnsafeMutablePointer<Float>.allocate(capacity: maxFrames)
    let r = UnsafeMutablePointer<Float>.allocate(capacity: maxFrames)
    let refs = UnsafeMutablePointer<BufferRef>.allocate(capacity: maxBuffers)
    var level: Float = 0
    var callbacks = 0, framesRendered = 0

    init(readers: [DelayReader]) {
        self.readers = readers
        l.initialize(repeating: 0, count: maxFrames); r.initialize(repeating: 0, count: maxFrames)
        refs.initialize(repeating: BufferRef(data: nil, channels: 1), count: maxBuffers)
    }
    deinit { l.deallocate(); r.deallocate(); refs.deallocate() }

    func setDelay(ms: Double) { for rd in readers { rd.setDelay(ms: ms) } }
    func setGain(_ g: Float) { for rd in readers { rd.setGain(g) } }

    func process(_ abl: UnsafeMutableAudioBufferListPointer) {
        let count = min(abl.count, maxBuffers)
        var frames = 0
        for i in 0..<count {
            let b = abl[i]
            let ch = max(1, Int(b.mNumberChannels))
            refs[i] = BufferRef(data: b.mData?.assumingMemoryBound(to: Float.self), channels: ch)
            if frames == 0, b.mData != nil { frames = Int(b.mDataByteSize) / (MemoryLayout<Float>.size * ch) }
        }
        frames = min(frames, maxFrames)
        callbacks += 1
        guard frames > 0 else { level = 0; return }
        framesRendered += frames
        for i in 0..<frames { l[i] = 0; r[i] = 0 }
        for rd in readers { rd.render(into: l, r, frames: frames) }
        var peak: Float = 0
        for i in 0..<frames {
            l[i] = max(-1, min(1, l[i])); r[i] = max(-1, min(1, r[i]))   // hard safety clip after summing inputs
            peak = max(peak, abs(l[i]), abs(r[i]))
        }
        level = peak
        ChannelMapping.fillOutput(UnsafeBufferPointer(start: refs, count: count), frames: frames, left: l, right: r)
    }
}

/// Owns every IOProc. Create → `start()` → `stop()` (also on deinit).
final class RouterEngine {
    private struct In { let device: AudioDeviceInfo; let io: DeviceIO; let state: InputState }
    private struct Out { let device: AudioDeviceInfo; let io: DeviceIO; let state: OutputState }
    private var ins: [In] = []
    private var outs: [Out] = []

    init(inputs: [AudioDeviceInfo], outputs: [(AudioDeviceInfo, OutputConfig)]) throws {
        do {
            for d in inputs {
                let rate = try HAL.validateFloatIO(d.id, scope: kAudioObjectPropertyScopeInput)
                let state = InputState(rate: rate)
                let block: AudioDeviceIOBlock = { _, inData, _, outData, _ in
                    state.process(UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inData)))
                    silence(outData)   // duplex devices (BlackHole, USB interfaces): we only capture, so emit silence
                }
                ins.append(In(device: d, io: try DeviceIO(deviceID: d.id, block: block), state: state))
            }
            for (d, cfg) in outputs {
                let rate = try HAL.validateFloatIO(d.id, scope: kAudioObjectPropertyScopeOutput)
                let readers = ins.map { DelayReader(ring: $0.state.ring, outputSampleRate: rate, delayMs: cfg.delayMs) }
                readers.forEach { $0.setGain(Float(cfg.volume)) }
                let state = OutputState(readers: readers)
                let block: AudioDeviceIOBlock = { _, _, _, outData, _ in
                    state.process(UnsafeMutableAudioBufferListPointer(outData))
                }
                outs.append(Out(device: d, io: try DeviceIO(deviceID: d.id, block: block), state: state))
            }
        } catch {
            stop()
            throw error
        }
    }

    func start() throws {
        do {
            for i in ins { try i.io.start() }       // capture first so rings fill before playback begins
            for o in outs { try o.io.start() }
        } catch {
            stop()
            throw error
        }
    }

    func stop() {
        outs.forEach { $0.io.stop() }
        ins.forEach { $0.io.stop() }
        outs.removeAll(); ins.removeAll()
    }

    /// Human-readable counters for `--probe` / bug reports.
    func diagnostics() -> [String] {
        ins.map { "input  \($0.device.name): \($0.state.callbacks) callbacks, \($0.state.framesCaptured) frames @ \(Int($0.state.ring.sampleRate)) Hz" }
        + outs.map { o in
            let lag = o.state.readers.first.map { String(format: "%.1f ms lag", $0.lagFrames / $0.ring.sampleRate * 1000) } ?? "-"
            return "output \(o.device.name): \(o.state.callbacks) callbacks, \(o.state.framesRendered) frames, \(lag)"
        }
    }

    /// True when every IOProc has been called and moved audio.
    var isHealthy: Bool {
        ins.allSatisfy { $0.state.callbacks > 0 && $0.state.framesCaptured > 0 }
            && outs.allSatisfy { $0.state.callbacks > 0 && $0.state.framesRendered > 0 }
    }

    func setDelay(uid: String, ms: Double) { outs.first { $0.device.uid == uid }?.state.setDelay(ms: ms) }
    func setGain(uid: String, _ g: Float) { outs.first { $0.device.uid == uid }?.state.setGain(g) }
    func inputLevel(uid: String) -> Float { ins.first { $0.device.uid == uid }?.state.level ?? 0 }
    func outputLevel(uid: String) -> Float { outs.first { $0.device.uid == uid }?.state.level ?? 0 }

    deinit { stop() }
}
