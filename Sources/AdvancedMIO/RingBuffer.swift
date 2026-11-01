import Foundation

/// Stereo float ring buffer: one writer (input tap), many readers (output render callbacks).
/// A tiny unfair lock keeps indices consistent; critical sections are a memcpy long.
final class StereoRing {
    let capacity: Int          // frames, power of two
    private let mask: Int
    private let l: UnsafeMutablePointer<Float>
    private let r: UnsafeMutablePointer<Float>
    private var lock = os_unfair_lock_s()
    private(set) var writeIndex: Int = 0

    init(capacityFrames: Int = 1 << 17) { // ~2.7 s @ 48 kHz
        capacity = capacityFrames
        mask = capacityFrames - 1
        l = .allocate(capacity: capacityFrames); l.initialize(repeating: 0, count: capacityFrames)
        r = .allocate(capacity: capacityFrames); r.initialize(repeating: 0, count: capacityFrames)
    }
    deinit { l.deallocate(); r.deallocate() }

    func write(left: UnsafePointer<Float>, right: UnsafePointer<Float>, frames: Int) {
        os_unfair_lock_lock(&lock)
        for i in 0..<frames {
            let p = (writeIndex + i) & mask
            l[p] = left[i]; r[p] = right[i]
        }
        writeIndex += frames
        os_unfair_lock_unlock(&lock)
    }

    /// Adds `gain * samples` into dst, reading `frames` frames that end `delayFrames` before the newest sample.
    func mix(into dl: UnsafeMutablePointer<Float>, _ dr: UnsafeMutablePointer<Float>,
             frames: Int, delayFrames: Int, gain: Float) {
        os_unfair_lock_lock(&lock)
        let start = writeIndex - delayFrames - frames
        if start >= 0 {
            for i in 0..<frames {
                let p = (start + i) & mask
                dl[i] += l[p] * gain; dr[i] += r[p] * gain
            }
        }
        os_unfair_lock_unlock(&lock)
    }
}
