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
    /// Spatial placement: written from the UI thread, ramped across each block on the audio thread.
    var mixTarget = SpatialMix.identity
    private var mixNow = SpatialMix.identity

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
        let m0 = mixNow, m1 = mixTarget
        mixNow = m1
        if m0 != .identity || m1 != .identity {
            let inv = 1 / Float(frames)
            for i in 0..<frames {
                let k = Float(i) * inv
                let ll = m0.ll + (m1.ll - m0.ll) * k, lr = m0.lr + (m1.lr - m0.lr) * k
                let rl = m0.rl + (m1.rl - m0.rl) * k, rr = m0.rr + (m1.rr - m0.rr) * k
                let a = l[i], b = r[i]
                l[i] = ll * a + lr * b
                r[i] = rl * a + rr * b
            }
        }
        var peak: Float = 0
        for i in 0..<frames {
            l[i] = max(-1, min(1, l[i])); r[i] = max(-1, min(1, r[i]))   // hard safety clip after summing inputs
            peak = max(peak, abs(l[i]), abs(r[i]))
        }
        level = peak
        ChannelMapping.fillOutput(UnsafeBufferPointer(start: refs, count: count), frames: frames, left: l, right: r)
    }
}

/// Anything that continuously fills a `StereoRing` from a background thread (shared-memory driver feed, test probe).
protocol RingSource: AnyObject {
    var ring: StereoRing { get }
    var level: Float { get }
    func startFeeding()
    func stopFeeding()
}

/// Owns every IOProc. Create → `start()` → `stop()` (also on deinit).
final class RouterEngine {
    private struct In { let device: AudioDeviceInfo; let io: DeviceIO; let state: InputState }
    private struct Out { let device: AudioDeviceInfo; let io: DeviceIO; let state: OutputState }
    private var ins: [In] = []
    private var outs: [Out] = []
    /// Alternative to capturing an input device: audio arrives through the driver's shared memory (no mic indicator).
    private var shared: RingSource?
    /// Outputs that could not be set up or started. They are skipped so one bad device cannot silence the others.
    private(set) var failures: [(name: String, message: String)] = []

    init(inputs: [AudioDeviceInfo], shared: RingSource? = nil,
         outputs: [(device: AudioDeviceInfo, delayMs: Double, volume: Double)]) throws {
        self.shared = shared
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
            for (d, delayMs, volume) in outputs {
                do {
                let rate = try HAL.validateFloatIO(d.id, scope: kAudioObjectPropertyScopeOutput)
                let rings = ins.map { $0.state.ring } + (shared.map { [$0.ring] } ?? [])
                let readers = rings.map { DelayReader(ring: $0, outputSampleRate: rate, delayMs: delayMs) }
                readers.forEach { $0.setGain(Float(volume)) }
                let state = OutputState(readers: readers)
                let block: AudioDeviceIOBlock = { _, _, _, outData, _ in
                    state.process(UnsafeMutableAudioBufferListPointer(outData))
                }
                outs.append(Out(device: d, io: try DeviceIO(deviceID: d.id, block: block), state: state))
                } catch { failures.append((d.name, error.localizedDescription)) }
            }
            if outs.isEmpty, !outputs.isEmpty { throw IOError(message: failures.map { "\($0.name): \($0.message)" }.joined(separator: " · ")) }
        } catch {
            stop()
            throw error
        }
    }

    func start() throws {
        do {
            shared?.startFeeding()
            for i in ins { try i.io.start() }       // capture first so rings fill before playback begins
            for o in outs {
                do { try o.io.start() } catch {
                    o.io.stop()
                    failures.append((o.device.name, error.localizedDescription))
                    outs.removeAll { $0.device.uid == o.device.uid }
                }
            }
            if outs.isEmpty { throw IOError(message: failures.map { "\($0.name): \($0.message)" }.joined(separator: " · ")) }
        } catch {
            stop()
            throw error
        }
    }

    func stop() {
        outs.forEach { $0.io.stop() }
        ins.forEach { $0.io.stop() }
        shared?.stopFeeding(); shared = nil
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

    /// Current read lag of each output in ms (delay + safety margin); used by `--probe`.
    func outputLagsMs() -> [Double] {
        outs.compactMap { $0.state.readers.first.map { $0.lagFrames / $0.ring.sampleRate * 1000 } }
    }

    /// True when every IOProc has been called and moved audio.
    var isHealthy: Bool {
        ins.allSatisfy { $0.state.callbacks > 0 && $0.state.framesCaptured > 0 }
            && outs.allSatisfy { $0.state.callbacks > 0 && $0.state.framesRendered > 0 }
    }

    func setDelay(uid: String, ms: Double) { outs.first { $0.device.uid == uid }?.state.setDelay(ms: ms) }
    func setGain(uid: String, _ g: Float) { outs.first { $0.device.uid == uid }?.state.setGain(g) }
    func setMix(uid: String, _ m: SpatialMix) { outs.first { $0.device.uid == uid }?.state.mixTarget = m }
    func inputLevel(uid: String) -> Float { ins.first { $0.device.uid == uid }?.state.level ?? shared?.level ?? 0 }
    func outputLevel(uid: String) -> Float { outs.first { $0.device.uid == uid }?.state.level ?? 0 }

    deinit { stop() }
}
