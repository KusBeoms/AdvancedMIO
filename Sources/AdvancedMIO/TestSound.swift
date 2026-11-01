import AVFoundation
import Foundation
import MIOCore

/// The bundled test track (looped) used to balance the speakers' volumes by ear.
enum TestSound {
    static let fileName = "TestSound"
    static let maxSeconds = 180.0

    static var url: URL? {
        if let u = Bundle.main.url(forResource: fileName, withExtension: "mp3") { return u }
        // `swift run` / development: next to the package.
        let dev = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("sounds/\(fileName).mp3")
        return FileManager.default.fileExists(atPath: dev.path) ? dev : nil
    }

    static func load() throws -> LoopSource {
        guard let url else { throw IOError(message: "테스트 음원(TestSound.mp3)을 찾을 수 없습니다") }
        let file = try AVAudioFile(forReading: url)
        let fmt = file.processingFormat
        let frames = AVAudioFrameCount(min(Double(file.length), maxSeconds * fmt.sampleRate))
        guard let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: frames) else { throw IOError(message: "테스트 음원을 읽을 수 없습니다") }
        try file.read(into: buf, frameCount: frames)
        guard let ch = buf.floatChannelData, buf.frameLength > 0 else { throw IOError(message: "테스트 음원이 비어 있습니다") }
        let n = Int(buf.frameLength)
        let l = Array(UnsafeBufferPointer(start: ch[0], count: n))
        let r = fmt.channelCount > 1 ? Array(UnsafeBufferPointer(start: ch[1], count: n)) : l
        return LoopSource(left: l, right: r, sampleRate: fmt.sampleRate)
    }
}

/// Feeds a stereo clip into a ring in real time, looping forever.
final class LoopSource: RingSource {
    let ring: StereoRing
    var level: Float = 0
    private let l: [Float], r: [Float]
    private let rate: Double
    var sampleRate: Double { rate }
    private var delivered = 0
    private var startedAt: UInt64 = 0
    private var timer: DispatchSourceTimer?
    private let queue = DispatchQueue(label: "advancedmio.loop", qos: .userInteractive)

    init(left: [Float], right: [Float], sampleRate: Double) {
        l = left; r = right; rate = sampleRate
        ring = StereoRing(sampleRate: sampleRate)
    }

    func startFeeding() {
        guard timer == nil else { return }
        delivered = 0
        startedAt = DispatchTime.now().uptimeNanoseconds
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now(), repeating: .milliseconds(3), leeway: .microseconds(300))
        t.setEventHandler { [weak self] in self?.pump() }
        timer = t
        t.resume()
    }

    func stopFeeding() {
        timer?.cancel(); timer = nil
        queue.sync {}
    }

    private func pump() {
        let target = Int(Double(DispatchTime.now().uptimeNanoseconds &- startedAt) / 1e9 * rate)
        var need = target - delivered
        var peak: Float = 0
        while need > 0 {
            let pos = delivered % l.count
            let n = min(need, l.count - pos)
            l.withUnsafeBufferPointer { lp in r.withUnsafeBufferPointer { rp in
                ring.write(left: lp.baseAddress! + pos, right: rp.baseAddress! + pos, frames: n)
                for i in 0..<n { peak = max(peak, abs(lp[pos + i]), abs(rp[pos + i])) }
            } }
            delivered += n; need -= n
        }
        if peak > 0 { level = peak }
    }

    /// `count` mono excerpts of `seconds` each, taken from the loudest parts of the clip (spread across it), normalised to a
    /// common level and faded at the edges, so every measurement slot plays different but equally strong material.
    func excerpts(count: Int, seconds: Double) -> [[Float]] {
        let len = Int(seconds * rate), hop = Int(rate)
        guard l.count > len, count > 0 else { return [] }
        let mono = (0..<l.count).map { 0.5 * (l[$0] + r[$0]) }
        var cands: [(start: Int, rms: Double)] = []
        var s = 0
        while s + len <= mono.count {
            var sum = 0.0
            for i in stride(from: s, to: s + len, by: 7) { sum += Double(mono[i] * mono[i]) }
            cands.append((s, (sum / Double(len / 7)).squareRoot()))
            s += hop
        }
        let median = cands.map(\.rms).sorted()[cands.count / 2]
        var good = cands.filter { $0.rms >= 0.7 * median }
        if good.count < count { good = cands }
        // Spread over the clip, keeping excerpts apart so they don't overlap.
        var picked: [Int] = []
        let step = Double(good.count) / Double(count)
        for k in 0..<count {
            var j = min(good.count - 1, Int(Double(k) * step))
            while picked.contains(good[j].start) || picked.contains(where: { abs($0 - good[j].start) < len }) {
                j = (j + 1) % good.count
                if picked.count >= good.count { break }
            }
            picked.append(good[j].start)
        }
        let fade = Int(0.02 * rate)
        return picked.map { st in
            var x = Array(mono[st..<st + len])
            var sum = 0.0, peak: Float = 0
            for v in x { sum += Double(v * v); peak = max(peak, abs(v)) }
            let rms = (sum / Double(len)).squareRoot()
            let g = Float(min(0.12 / max(rms, 1e-6), 0.9 / max(Double(peak), 1e-6)))
            for i in 0..<len {
                var w: Float = 1
                if i < fade { w = Float(i) / Float(fade) } else if i >= len - fade { w = Float(len - 1 - i) / Float(fade) }
                x[i] *= g * w
            }
            return x
        }
    }
}
