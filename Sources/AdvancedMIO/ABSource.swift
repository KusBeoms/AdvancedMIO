import Foundation
import MIOCore

/// Plays two pre-rendered mono signals of equal length in a loop and switches between them without a gap: both run on the
/// same timeline, only the mix moves (over ~30 ms, so the switch does not click). Used by the developer page's listening test.
final class ABSource: RingSource {
    let ring: StereoRing
    var level: Float = 0
    private let a: [Float], b: [Float]
    private let rate: Double
    private var delivered = 0
    private var startedAt: UInt64 = 0
    private var timer: DispatchSourceTimer?
    private let queue = DispatchQueue(label: "advancedmio.ab", qos: .userInteractive)
    private let lock = AudioLock()
    private var target: Float = 0           // 0 = A, 1 = B
    private var mix: Float = 0

    init(a: [Float], b: [Float], sampleRate: Double) {
        let n = min(a.count, b.count)
        self.a = Array(a.prefix(n)); self.b = Array(b.prefix(n)); rate = sampleRate
        ring = StereoRing(sampleRate: sampleRate)
    }

    func select(b side: Bool) { lock.lock(); target = side ? 1 : 0; lock.unlock() }

    func startFeeding() {
        guard timer == nil, !a.isEmpty else { return }
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
        guard need > 0 else { return }
        lock.lock(); let t = target; lock.unlock()
        let step = Float(1 / (0.03 * rate))
        var buf = [Float](repeating: 0, count: 2048)
        var peak: Float = 0
        while need > 0 {
            let m = min(need, buf.count)
            for i in 0..<m {
                if mix < t { mix = min(t, mix + step) } else if mix > t { mix = max(t, mix - step) }
                let k = (delivered + i) % a.count
                let v = a[k] * (1 - mix) + b[k] * mix
                buf[i] = v; peak = max(peak, abs(v))
            }
            buf.withUnsafeBufferPointer { p in ring.write(left: p.baseAddress!, right: p.baseAddress!, frames: m) }
            delivered += m; need -= m
        }
        level = peak
    }
}
