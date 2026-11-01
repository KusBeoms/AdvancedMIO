import Darwin
import Foundation
import MIOCore

// shm_open is variadic (the mode argument only matters with O_CREAT), which Swift doesn't import.
@_silgen_name("shm_open") private func c_shm_open(_ name: UnsafePointer<CChar>, _ oflag: Int32) -> Int32

/// Reads the loopback ring that the AdvancedMIO driver publishes in shared memory (see driver/AdvancedMIODriver.c).
/// Unlike capturing the virtual device's input stream, this never shows the macOS microphone indicator and needs no
/// microphone permission. `open()` returns nil when the installed driver doesn't publish it (older driver).
final class SharedRingSource: RingSource {
    private struct Header {
        var magic: UInt32, version: UInt32, sampleRate: UInt32, ringFrames: UInt32
        var writeEnd: Int64
    }
    private static let name = "/AdvancedMIO.ring"
    private static let magic: UInt32 = 0x414D_494F
    private static let channels = 2

    let ring: StereoRing
    private let base: UnsafeMutableRawPointer
    private let mapSize: Int
    private let ringFrames: Int
    private let data: UnsafePointer<Float>
    private let l: UnsafeMutablePointer<Float>
    private let r: UnsafeMutablePointer<Float>
    private var readPos: Int64 = 0
    private var lastSeenEnd: Int64 = -1
    private var timer: DispatchSourceTimer?
    private let queue = DispatchQueue(label: "advancedmio.shm", qos: .userInteractive)
    var level: Float = 0
    var framesRead = 0

    private var writeEnd: Int64 { base.load(fromByteOffset: 16, as: Int64.self) }

    static func open() -> SharedRingSource? {
        let fd = c_shm_open(name, O_RDONLY)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var st = stat()
        guard fstat(fd, &st) == 0, st.st_size >= MemoryLayout<Header>.size else { return nil }
        let size = Int(st.st_size)
        guard let m = mmap(nil, size, PROT_READ, MAP_SHARED, fd, 0), m != MAP_FAILED else { return nil }
        let h = m.load(as: Header.self)
        guard h.magic == magic, h.version == 1, h.ringFrames > 0, h.ringFrames & (h.ringFrames - 1) == 0,
              size >= MemoryLayout<Header>.size + Int(h.ringFrames) * channels * 4 else { munmap(m, size); return nil }
        return SharedRingSource(base: m, size: size, header: h)
    }

    private init(base: UnsafeMutableRawPointer, size: Int, header: Header) {
        self.base = base; mapSize = size
        ringFrames = Int(header.ringFrames)
        data = UnsafePointer((base + 24).assumingMemoryBound(to: Float.self))   // header is 24 bytes (4×u32 + i64, aligned)
        ring = StereoRing(sampleRate: Double(header.sampleRate))
        l = .allocate(capacity: ringFrames); r = .allocate(capacity: ringFrames)
        l.initialize(repeating: 0, count: ringFrames); r.initialize(repeating: 0, count: ringFrames)
    }

    deinit {
        stopFeeding()
        l.deallocate(); r.deallocate()
        munmap(base, mapSize)
    }

    /// True when the driver wrote new audio since the last call (i.e. something is playing to the device).
    func pollActivity() -> Bool {
        let end = writeEnd
        defer { lastSeenEnd = end }
        return end != lastSeenEnd
    }

    func startFeeding() {
        guard timer == nil else { return }
        readPos = writeEnd                                 // don't replay what was already in the ring
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now(), repeating: .milliseconds(2), leeway: .microseconds(200))
        t.setEventHandler { [weak self] in self?.pump() }
        timer = t
        t.resume()
    }

    func stopFeeding() {
        timer?.cancel(); timer = nil
        queue.sync {}      // wait for an in-flight pump
    }

    private func pump() {
        let end = writeEnd
        if end < readPos || end - readPos > Int64(ringFrames) - 2048 { readPos = max(0, end - 512) }   // restarted or fell behind
        let n = Int(end - readPos)
        guard n > 0 else { level *= 0.9; return }
        let mask = ringFrames - 1
        var peak: Float = 0
        for i in 0..<n {
            let slot = (Int(readPos) + i) & mask
            let a = data[slot * 2], b = data[slot * 2 + 1]
            l[i] = a; r[i] = b
            peak = max(peak, abs(a), abs(b))
        }
        readPos = end
        level = peak
        framesRead += n
        ring.write(left: l, right: r, frames: n)
    }
}
