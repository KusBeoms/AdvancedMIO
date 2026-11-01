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
        lock.lock()
        for i in 0..<n {
            let p = (written + i) & mask
            l[p] = left[skip + i]; r[p] = right[skip + i]
        }
        written += frames
        if frames > biggestChunk { biggestChunk = frames }
        lock.unlock()
    }

    /// Runs `body` with the lock held: (writeIndex, maxChunk, left, right, mask).
    @inline(__always)
    func locked<T>(_ body: (Int, Int, UnsafePointer<Float>, UnsafePointer<Float>, Int) -> T) -> T {
        lock.lock(); defer { lock.unlock() }
        return body(written, biggestChunk, UnsafePointer(l), UnsafePointer(r), mask)
    }
}
