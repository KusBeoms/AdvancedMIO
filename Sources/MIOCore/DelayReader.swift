import Foundation

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

    // Lag control. The writer delivers whole chunks, so the write index is a sawtooth; steering speed from it directly
    // (as an earlier version did) swings the playback speed by ±1 % and is heard as roughness. Instead the writer's
    // position is interpolated between chunk boundaries with the time of the last write, the result is averaged, and a
    // gentle PI loop steers toward the lag chosen at lock time (±0.3 % at most, normally ≪ 0.01 %).
    private var trackedDelay: Double = 0      // delay (frames) that `lagTarget` accounts for
    private var pendingSlew: Double = 0       // frames of lag still to add (+) or remove (−) for a small delay change
    private var lagAvg: Double = 0
    private var lagTarget: Double = 0
    private var driftTrim: Double = 0         // integral term: estimated clock-rate mismatch (fraction)
    private static let averageSeconds = 0.5, lockSeconds = 2.0, trimSeconds = 8.0
    private static let maxTrim = 0.003
    /// A writer silent for longer than this is treated as stalled: its position is not extrapolated any further.
    private static let maxExtrapolationSeconds = 0.1
    /// Extra frames kept ahead of the playhead so a steady rate mismatch never pulls the sawtooth into an underrun.
    private static let headroomFrames = 128.0

    // Resampling kernel: Kaiser-windowed sinc, `phases` fractional positions × `taps` input samples, each row normalised to
    // unit DC gain. Linear/cubic interpolation leaves strong images when a device runs at twice the source rate
    // (e.g. a 96 kHz MacBook speaker fed from 48 kHz) and is heard as "broken" sound; this keeps them ~70 dB down.
    private static let halfTaps = 16, taps = 32, phases = 256
    private let kernel: UnsafeMutablePointer<Float>

    public private(set) var lagFrames: Double = 0      // diagnostics
    public private(set) var resyncCount = 0

    public init(ring: StereoRing, outputSampleRate: Double, delayMs: Double = 0) {
        self.ring = ring
        self.outRate = outputSampleRate
        kernel = Self.makeKernel(cutoff: min(1, outputSampleRate / ring.sampleRate))
        setDelay(ms: delayMs)
    }
    deinit { kernel.deallocate() }

    /// `cutoff` is relative to the input Nyquist frequency: 1 when upsampling or equal rates, < 1 when downsampling
    /// (low-pass below the output's Nyquist so nothing aliases).
    private static func makeKernel(cutoff fc: Double) -> UnsafeMutablePointer<Float> {
        let beta = 7.0
        func i0(_ x: Double) -> Double {
            var sum = 1.0, term = 1.0, k = 1.0
            while term > 1e-12 * sum { term *= (x / (2 * k)) * (x / (2 * k)); sum += term; k += 1 }
            return sum
        }
        let norm = i0(beta), half = Double(halfTaps)
        let table = UnsafeMutablePointer<Float>.allocate(capacity: (phases + 1) * taps)
        for p in 0...phases {
            let frac = Double(p) / Double(phases)
            var row = [Double](repeating: 0, count: taps)
            for t in 0..<taps {
                let x = Double(t - halfTaps + 1) - frac           // input sample minus playhead
                let arg = fc * x
                let sinc = abs(arg) < 1e-12 ? 1 : sin(Double.pi * arg) / (Double.pi * arg)
                let u = x / half
                let window = abs(u) < 1 ? i0(beta * (1 - u * u).squareRoot()) / norm : 0
                row[t] = fc * sinc * window
            }
            let sum = row.reduce(0, +)
            for t in 0..<taps { table[p * taps + t] = Float(row[t] / sum) }
        }
        return table
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

        let now = ring.clock()
        ring.locked { w, chunk, l, r, mask, lastWrite in
            // Margin: this block's input span + one writer chunk + slack, so we never read unwritten data.
            let span = Double(frames) * ratio * 1.02
            let margin = span + Double(chunk) + 4 + Self.headroomFrames + Double(Self.halfTaps)
            let desired = margin + delay
            guard desired < cap - 64 else { return }
            let blockSeconds = Double(frames) / outRate
            let jump = max(0.02 * inRate, 512, 1.5 * Double(chunk))
            // Where the writer really is: the last chunk boundary plus what has been captured since.
            let wNow = Double(w) + inRate * max(0, min(now - lastWrite, Self.maxExtrapolationSeconds))

            /// (Re)start tracking from a fresh lock.
            func startTracking() {
                trackedDelay = delay
                pendingSlew = 0
                lagTarget = desired
                lagAvg = desired
            }

            if !primed {
                guard Double(w) >= desired else { return }
                readPos = wNow - desired
                xfadeLeft = 0
                primed = true
                startTracking()
            }

            var lag = wNow - readPos
            let delayChange = delay - trackedDelay
            if abs(delayChange) > jump || abs(lag - lagTarget) > jump || lag > cap - 64 {
                // Large change (slider moved / resync): hop and crossfade from the old position.
                oldPos = readPos
                xfadeLeft = lag > cap - 64 ? 0 : xfadeLen
                readPos = wNow - desired
                resyncCount += 1
                lag = desired
                startTracking()
            } else if delayChange != 0 {
                pendingSlew += delayChange      // small change: slide there at ≤ 1 % speed, no jump
                trackedDelay = delay
            }
            if Double(w) - readPos < span + Double(Self.halfTaps) + 3 {   // underrun: output silence this block and re-prime next time
                primed = false
                return
            }

            // Smooth the lag, then steer toward the target.
            lagAvg += (lag - lagAvg) * min(1, blockSeconds / Self.averageSeconds)
            let err = lagAvg - lagTarget
            driftTrim = max(-Self.maxTrim, min(Self.maxTrim,
                driftTrim + err / (inRate * Self.lockSeconds) * blockSeconds / Self.trimSeconds))
            let adj = max(-Self.maxTrim, min(Self.maxTrim, err / (inRate * Self.lockSeconds) + driftTrim))
            // Delay changes below the hop threshold: advance the playhead a little slower/faster until they are absorbed.
            let maxSlew = 0.01 * Double(frames) * ratio
            let slew = max(-maxSlew, min(maxSlew, pendingSlew))
            pendingSlew -= slew
            lagTarget += slew; lagAvg += slew
            let step = ratio * (1 + adj) - slew / Double(frames)

            @inline(__always) func sample(_ pos: Double) -> (Float, Float) {
                let i = Int(pos)                       // pos ≥ 0
                let ph = (pos - Double(i)) * Double(Self.phases)
                let p0 = Int(ph)
                let a = Float(ph - Double(p0))
                let k0 = kernel + p0 * Self.taps, k1 = k0 + Self.taps
                let base = i - Self.halfTaps + 1
                var sl: Float = 0, sr: Float = 0
                for t in 0..<Self.taps {
                    let h = k0[t] + (k1[t] - k0[t]) * a
                    let idx = (base + t) & mask
                    sl += h * l[idx]; sr += h * r[idx]
                }
                return (sl, sr)
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
