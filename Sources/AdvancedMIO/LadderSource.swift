import Foundation
import MIOCore

/// Plays one of several pre-rendered mono signals of equal length in a loop; `select` changes the signal at the same
/// position in the song with a ~30 ms crossfade. Used by the developer page's 울림 slider.
final class LadderSource: RingSource {
    let ring: StereoRing
    var level: Float = 0
    private let bufs: [[Float]]
    private let rate: Double
    private var delivered = 0
    private var startedAt: UInt64 = 0
    private var timer: DispatchSourceTimer?
    private let queue = DispatchQueue(label: "advancedmio.ladder", qos: .userInteractive)
    private let lock = AudioLock()
    private var target = 0
    private var from = 0, to = 0
    private var fade: Float = 1

    init(buffers: [[Float]], sampleRate: Double) {
        let n = buffers.map(\.count).min() ?? 0
        bufs = buffers.map { Array($0.prefix(n)) }; rate = sampleRate
        ring = StereoRing(sampleRate: sampleRate)
    }

    func select(_ i: Int) { lock.lock(); target = max(0, min(bufs.count - 1, i)); lock.unlock() }

    func startFeeding() {
        guard timer == nil, let n = bufs.first?.count, n > 0 else { return }
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
        let goal = Int(Double(DispatchTime.now().uptimeNanoseconds &- startedAt) / 1e9 * rate)
        var need = goal - delivered
        guard need > 0, let n = bufs.first?.count else { return }
        lock.lock(); let t = target; lock.unlock()
        if t != to { from = to; to = t; fade = 0 }        // a change mid-fade starts from the signal being faded in
        let step = Float(1 / (0.03 * rate))
        var buf = [Float](repeating: 0, count: 2048)
        var peak: Float = 0
        while need > 0 {
            let m = min(need, buf.count)
            for i in 0..<m {
                fade = min(1, fade + step)
                let k = (delivered + i) % n
                let v = fade >= 1 ? bufs[to][k] : bufs[from][k] * (1 - fade) + bufs[to][k] * fade
                buf[i] = v; peak = max(peak, abs(v))
            }
            buf.withUnsafeBufferPointer { p in ring.write(left: p.baseAddress!, right: p.baseAddress!, frames: m) }
            delivered += m; need -= m
        }
        level = peak
    }
}
