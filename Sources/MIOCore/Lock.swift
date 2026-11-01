#if canImport(Darwin)
import Darwin

/// Small lock for audio threads (priority-donating on Apple platforms).
public final class AudioLock {
    private let p: UnsafeMutablePointer<os_unfair_lock>
    public init() { p = .allocate(capacity: 1); p.initialize(to: os_unfair_lock()) }
    deinit { p.deallocate() }
    @inline(__always) public func lock() { os_unfair_lock_lock(p) }
    @inline(__always) public func unlock() { os_unfair_lock_unlock(p) }
}
#else
import Glibc

public final class AudioLock {
    private let p: UnsafeMutablePointer<pthread_mutex_t>
    public init() { p = .allocate(capacity: 1); pthread_mutex_init(p, nil) }
    deinit { pthread_mutex_destroy(p); p.deallocate() }
    @inline(__always) public func lock() { pthread_mutex_lock(p) }
    @inline(__always) public func unlock() { pthread_mutex_unlock(p) }
}
#endif
