import Foundation

/// Stereo float ring buffer: one writer (input IOProc), many readers (output IOProcs).
/// Frame indices grow monotonically; `index & mask` addresses storage.
public final class StereoRing {
    public let capacity: Int            // frames, power of two
    public let sampleRate: Double
    private let mask: Int
    private let l: UnsafeMutablePointer<Float>
    private let r: UnsafeMutablePointer<Float>
    private let lock = AudioLock()
    private var written = 0
    private var biggestChunk = 0
    private var lastWriteTime = 0.0

    /// Seconds on a monotonic clock. Readers use it to place themselves *between* the writer's chunk boundaries (the writer
    /// delivers whole chunks, so the write index alone is a sawtooth). Tests replace it with simulated time.
    public var clock: () -> Double = StereoRing.hostSeconds
    public static func hostSeconds() -> Double { Double(DispatchTime.now().uptimeNanoseconds) / 1e9 }

    public init(sampleRate: Double, capacityFrames: Int = 1 << 19) {
        precondition(capacityFrames > 0 && capacityFrames & (capacityFrames - 1) == 0, "capacity must be a power of two")
        self.sampleRate = sampleRate
        capacity = capacityFrames
        mask = capacityFrames - 1
        l = .allocate(capacity: capacityFrames); l.initialize(repeating: 0, count: capacityFrames)
        r = .allocate(capacity: capacityFrames); r.initialize(repeating: 0, count: capacityFrames)
    }
    deinit { l.deallocate(); r.deallocate() }

    public var writeIndex: Int { lock.lock(); defer { lock.unlock() }; return written }
    /// Largest chunk the writer ever delivered; readers use it to size their safety margin.
    public var largestWriteChunk: Int { lock.lock(); defer { lock.unlock() }; return biggestChunk }

    public func write(left: UnsafePointer<Float>, right: UnsafePointer<Float>, frames: Int) {
        guard frames > 0 else { return }
        let n = min(frames, capacity)
        let skip = frames - n
        let now = clock()
        lock.lock()
        let start = (written + skip) & mask
        let first = min(n, capacity - start)
        (l + start).update(from: left + skip, count: first)
        (r + start).update(from: right + skip, count: first)
        if first < n {
            l.update(from: left + skip + first, count: n - first)
            r.update(from: right + skip + first, count: n - first)
        }
        written += frames
        if frames > biggestChunk { biggestChunk = frames }
        lastWriteTime = now
        lock.unlock()
    }

    /// Runs `body` with the lock held: (writeIndex, maxChunk, left, right, mask, time of the last write).
    @inline(__always)
    func locked<T>(_ body: (Int, Int, UnsafePointer<Float>, UnsafePointer<Float>, Int, Double) -> T) -> T {
        lock.lock(); defer { lock.unlock() }
        return body(written, biggestChunk, UnsafePointer(l), UnsafePointer(r), mask, lastWriteTime)
    }
}
