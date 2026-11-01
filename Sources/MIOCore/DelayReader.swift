/// Reads a `StereoRing` at an adjustable delay, resampling input-rate → output-rate (linear interpolation),
/// and keeping the lag locked to `delay + safety margin` despite clock drift between devices.
public final class DelayReader {
    public static let maxDelayMs: Double = 1000

    public let ring: StereoRing
    public let outRate: Double
    private var inRate: Double { ring.sampleRate }

    // Control (written from the UI thread; plain loads/stores are fine for these word-sized values).
    private var delayFrames: Double = 0
    private var gainTarget: Float = 1

    // Audio-thread state.
    private var primed = false
    private var readPos: Double = 0
    private var oldPos: Double = 0
    private var xfadeLeft = 0
    private var gainNow: Float = 1
    private let xfadeLen = 256

    public private(set) var lagFrames: Double = 0      // diagnostics
    public private(set) var resyncCount = 0

    public init(ring: StereoRing, outputSampleRate: Double, delayMs: Double = 0) {
        self.ring = ring
        self.outRate = outputSampleRate
        setDelay(ms: delayMs)
    }

    public func setDelay(ms: Double) {
        let clamped = min(Self.maxDelayMs, max(0, ms))
        delayFrames = clamped * ring.sampleRate / 1000
    }
    public func setGain(_ g: Float) { gainTarget = max(0, g) }

    /// Adds `frames` of delayed audio into outL/outR. Returns the block's peak (post-gain, pre-sum).
    @discardableResult
    public func render(into outL: UnsafeMutablePointer<Float>, _ outR: UnsafeMutablePointer<Float>, frames: Int) -> Float {
        guard frames > 0 else { return 0 }
        let ratio = inRate / outRate
        let cap = Double(ring.capacity)
        let delay = delayFrames
        let g0 = gainNow, g1 = gainTarget
        gainNow = g1
        var peak: Float = 0

        ring.locked { w, chunk, l, r, mask in
            // Margin: this block's input span + one writer chunk + slack, so we never read unwritten data.
            let span = Double(frames) * ratio * 1.02
            let margin = span + Double(chunk) + 4
            let desired = margin + delay
            guard desired < cap - 64 else { return }

            if !primed {
                guard Double(w) >= desired else { return }
                readPos = Double(w) - desired
                xfadeLeft = 0
                primed = true
            }

            var lag = Double(w) - readPos
            var err = lag - desired
            let jump = max(0.02 * inRate, 512)
            if abs(err) > jump || lag > cap - 64 {
                // Large change (slider moved / resync): hop and crossfade from the old position.
                oldPos = readPos
                xfadeLeft = lag > cap - 64 ? 0 : xfadeLen
                readPos = Double(w) - desired
                resyncCount += 1
                lag = desired; err = 0
            }
            if lag < span + 2 {   // underrun: output silence this block and re-prime next time
                primed = false
                return
            }

            // Gentle proportional drift/slew correction (±1% speed max).
            let adj = max(-0.01, min(0.01, err / (inRate * 0.5)))
            let step = ratio * (1 + adj)

            @inline(__always) func sample(_ pos: Double) -> (Float, Float) {
                let i = Int(pos)                       // pos ≥ 0
                let f = Float(pos - Double(i))
                let a = i & mask, b = (i + 1) & mask
                return (l[a] + (l[b] - l[a]) * f, r[a] + (r[b] - r[a]) * f)
            }

            let invFrames = 1 / Float(frames)
            for n in 0..<frames {
                var (sl, sr) = sample(readPos)
                if xfadeLeft > 0 {
                    let t = 1 - Float(xfadeLeft) / Float(xfadeLen)
                    let (ol, or) = sample(max(0, oldPos))
                    sl = ol + (sl - ol) * t
                    sr = or + (sr - or) * t
                    xfadeLeft -= 1
                    oldPos += step
                }
                let g = g0 + (g1 - g0) * (Float(n) * invFrames)
                sl *= g; sr *= g
                outL[n] += sl; outR[n] += sr
                let m = max(abs(sl), abs(sr))
                if m > peak { peak = m }
                readPos += step
            }
            lagFrames = Double(w) - readPos
        }
        return peak
    }
}
