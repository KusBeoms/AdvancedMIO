/// One CoreAudio buffer: `channels` interleaved float channels, `frames` frames.
public struct BufferRef {
    public var data: UnsafeMutablePointer<Float>?
    public var channels: Int
    public init(data: UnsafeMutablePointer<Float>?, channels: Int) { self.data = data; self.channels = channels }
}

public enum ChannelMapping {
    /// Takes the first two channels (across buffers) of an input device as L/R. Mono is duplicated.
    public static func extractStereo(_ refs: UnsafeBufferPointer<BufferRef>, frames: Int,
                                     left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>) {
        var chans: [(UnsafeMutablePointer<Float>, Int)] = []   // (base, stride) — at most two entries
        chans.reserveCapacity(2)
        outer: for ref in refs {
            guard let base = ref.data, ref.channels > 0 else { continue }
            for c in 0..<ref.channels {
                chans.append((base + c, ref.channels))
                if chans.count == 2 { break outer }
            }
        }
        guard let first = chans.first else {
            for i in 0..<frames { left[i] = 0; right[i] = 0 }
            return
        }
        let second = chans.count > 1 ? chans[1] : first
        for i in 0..<frames {
            left[i] = first.0[i * first.1]
            right[i] = second.0[i * second.1]
        }
    }

    /// Writes L/R to every output channel: even channels get L, odd get R. A mono device gets (L+R)/2.
    public static func fillOutput(_ refs: UnsafeBufferPointer<BufferRef>, frames: Int,
                                  left: UnsafePointer<Float>, right: UnsafePointer<Float>) {
        var total = 0
        for ref in refs where ref.data != nil { total += ref.channels }
        var k = 0
        for ref in refs {
            guard let base = ref.data else { continue }
            for c in 0..<ref.channels {
                if total == 1 {
                    for i in 0..<frames { base[i * ref.channels + c] = 0.5 * (left[i] + right[i]) }
                } else {
                    let src = (k & 1 == 0) ? left : right
                    for i in 0..<frames { base[i * ref.channels + c] = src[i] }
                }
                k += 1
            }
        }
    }
}
