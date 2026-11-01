import Foundation
#if canImport(Accelerate)
import Accelerate
#endif

// "DelayAI": computes the best per-speaker delays directly on the identified room model — no sound, no measuring —
// by gradient descent (Adam) on a smooth version of the boominess objective, from many starting points in parallel.
//
//   J(d) = mean over microphones of  [ Var_bands( 10·log10 |Y(f)|² )  +  λ · E_late / E_total ]
//   Y(f) = Σ_i H_i(f) · e^{-j2πf(a_i + d_i)}        (H_i, a_i: identified response and arrival of speaker i)
//
// The spectral term has an exact analytic gradient (the delay only enters through the phase); the late-energy term
// (echo / reverb tail) is evaluated in the time domain with fractional delays and a smooth early/late window, also with
// an analytic gradient. Many random restarts handle the comb-filter landscape, which has lots of local minima.

/// The looping test programme (one period, power-of-two length) the room is measured with. The real measurement
/// recovers each response through a Wiener deconvolution whose weighting depends on the programme's spectrum; the model
/// applies the same weighting per band so that what it optimises is what will be measured.
public struct Programme {
    public var probe: [Float]
    public var rate: Double
    public init(probe: [Float], rate: Double) { self.probe = probe; self.rate = rate }
}

public struct DelayAIConfig {
    public var starts = 32                 // parallel starting points (the given seeds first, then jittered / random ones)
    public var iterations = 200
    public var coarseStep = 4              // spectral bins skipped during the first 70 % of the iterations (speed)
    public var initialRateMs = 8.0         // Adam step size, annealed (cosine) down to `finalRateMs`
    public var finalRateMs = 0.1
    public var maxDelayMs = 1000.0
    public var jitterMs = 12.0             // spread of jittered restarts around the seeds
    public var randomSpreadMs = 150.0      // spread of fully random restarts
    public var seed: UInt64 = 0x9E37_79B9_7F4A_7C15
    public init() {}
}

public struct DelayAIResult {
    public var delaysMs: [Double]          // best found, smallest = 0
    public var score: Double               // model-predicted boominess index of `delaysMs`
    public var seedScores: [Double]        // model-predicted index of each given seed, for comparison
    public var alternatives: [[Double]]    // other distinct good local minima (best first), for the measured tournament
    public var starts: Int
    public var iterations: Int
}

public enum DelayAI {
    public static func optimize(mics: [MicResponse], seeds: [[Double]], config: DelayAIConfig = DelayAIConfig(),
                                programme: Programme? = nil) -> DelayAIResult? {
        let models = mics.compactMap { SmoothMicModel($0, programme: programme) }
        guard let n = models.first?.n, models.allSatisfy({ $0.n == n }), !seeds.isEmpty, seeds.allSatisfy({ $0.count == n }) else { return nil }
        let ws = Workspace()
        let seedScores = seeds.map { score(models, $0, ws) }

        let starts = max(config.starts, seeds.count)
        var results = [(d: [Double], j: Double)](repeating: ([], .infinity), count: starts)
        results.withUnsafeMutableBufferPointer { out in
            let outPtr = out.baseAddress!
            DispatchQueue.concurrentPerform(iterations: starts) { s in
                var rng = SplitMix(seed: config.seed &+ UInt64(s) &* 0xD1B5_4A32_D192_ED03)
                var d: [Double]
                if s < seeds.count { d = seeds[s] }
                else if s % 3 == 0 { d = (0..<n).map { _ in rng.unit() * config.randomSpreadMs } }
                else { let base = seeds[s % seeds.count]; d = base.map { $0 + rng.normal() * config.jitterMs } }
                d = d.map { min(config.maxDelayMs, max(0, $0)) }
                let local = Workspace()
                let (best, j) = adam(models, &d, config, local)
                outPtr[s] = (best, j)
            }
        }
        guard let best = results.min(by: { $0.j < $1.j }), best.j.isFinite else { return nil }
        func normalised(_ d: [Double]) -> [Double] { let m = d.min() ?? 0; return d.map { $0 - m } }
        var alternatives: [[Double]] = []
        let bestN = normalised(best.d)
        for r in results.sorted(by: { $0.j < $1.j }) where r.j.isFinite && r.j < best.j * 1.35 {
            let d = normalised(r.d)
            if zip(d, bestN).allSatisfy({ abs($0 - $1) < 8 }) { continue }
            if alternatives.contains(where: { a in zip(a, d).allSatisfy { abs($0 - $1) < 8 } }) { continue }
            alternatives.append(d)
            if alternatives.count >= 3 { break }
        }
        return DelayAIResult(delaysMs: bestN, score: best.j, seedScores: seedScores, alternatives: alternatives,
                             starts: starts, iterations: config.iterations)
    }

    /// A short, local gradient descent from `from`, never leaving a box of ±`radiusMs` around it (a trust region):
    /// "what is the best small correction according to the model?". ~0.1 s, so it can run between two measurements.
    public static func descend(mics: [MicResponse], from d0: [Double], radiusMs: Double, iterations: Int = 40,
                               maxDelayMs: Double = 1000, programme: Programme? = nil) -> [Double]? {
        let models = mics.compactMap { SmoothMicModel($0, programme: programme) }
        guard !models.isEmpty, models.allSatisfy({ $0.n == d0.count }) else { return nil }
        let n = d0.count, ws = Workspace()
        var d = d0, best = d0, bestJ = Double.infinity
        var m = [Double](repeating: 0, count: n), v = m, g = m, gi = m
        for it in 0..<iterations {
            for i in 0..<n { g[i] = 0 }
            var j = 0.0
            for model in models { j += model.evaluate(d, &gi, ws, wantGradient: true); for i in 0..<n { g[i] += gi[i] } }
            j /= Double(models.count)
            if j < bestJ { bestJ = j; best = d }
            let t = Double(it) / Double(max(1, iterations - 1))
            let lr = radiusMs * (0.02 + 0.23 * 0.5 * (1 + cos(Double.pi * t)))
            for i in 0..<n {
                g[i] /= Double(models.count)
                m[i] = 0.9 * m[i] + 0.1 * g[i]; v[i] = 0.999 * v[i] + 0.001 * g[i] * g[i]
                let mh = m[i] / (1 - pow(0.9, Double(it + 1))), vh = v[i] / (1 - pow(0.999, Double(it + 1)))
                d[i] -= lr * mh / (vh.squareRoot() + 1e-12)
                d[i] = min(d0[i] + radiusMs, max(d0[i] - radiusMs, d[i]))
                d[i] = min(maxDelayMs, max(0, d[i]))
            }
        }
        return best
    }

    /// Model-predicted boominess index for a set of delays (mean over microphones).
    public static func predictedScore(mics: [MicResponse], delaysMs: [Double], programme: Programme? = nil) -> Double? {
        let models = mics.compactMap { SmoothMicModel($0, programme: programme) }
        guard !models.isEmpty, models.allSatisfy({ $0.n == delaysMs.count }) else { return nil }
        return score(models, delaysMs, Workspace())
    }

    // MARK: internals

    static func score(_ models: [SmoothMicModel], _ d: [Double], _ ws: Workspace) -> Double {
        var g = [Double](repeating: 0, count: d.count)
        var total = 0.0
        for m in models { total += m.evaluate(d, &g, ws, wantGradient: false) }
        return total / Double(models.count)
    }

    /// Adam with a cosine-annealed step; returns the best point seen (and its score).
    private static func adam(_ models: [SmoothMicModel], _ d: inout [Double], _ c: DelayAIConfig, _ ws: Workspace) -> ([Double], Double) {
        let n = d.count
        var m = [Double](repeating: 0, count: n), v = m, g = m, gi = m
        var best = d, bestJ = Double.infinity
        let b1 = 0.9, b2 = 0.999
        for it in 0..<c.iterations {
            for i in 0..<n { g[i] = 0 }
            var j = 0.0
            for model in models {
                j += model.evaluate(d, &gi, ws, wantGradient: true, coarse: it < c.iterations * 7 / 10 ? c.coarseStep : 1)
                for i in 0..<n { g[i] += gi[i] }
            }
            j /= Double(models.count)
            for i in 0..<n { g[i] /= Double(models.count) }
            if it >= c.iterations * 7 / 10, j < bestJ { bestJ = j; best = d }       // only exact evaluations compete for "best"
            let t = Double(it) / Double(max(1, c.iterations - 1))
            let lr = c.finalRateMs + 0.5 * (c.initialRateMs - c.finalRateMs) * (1 + cos(Double.pi * t))
            for i in 0..<n {
                m[i] = b1 * m[i] + (1 - b1) * g[i]
                v[i] = b2 * v[i] + (1 - b2) * g[i] * g[i]
                let mh = m[i] / (1 - pow(b1, Double(it + 1))), vh = v[i] / (1 - pow(b2, Double(it + 1)))
                d[i] -= lr * mh / (vh.squareRoot() + 1e-12)
                d[i] = min(c.maxDelayMs, max(0, d[i]))
            }
        }
        // the very last point too
        var gl = [Double](repeating: 0, count: n)
        var jl = 0.0
        for model in models { jl += model.evaluate(d, &gl, ws, wantGradient: false) }
        jl /= Double(models.count)
        if jl < bestJ { bestJ = jl; best = d }
        return (best, bestJ)
    }

    struct SplitMix {
        var s: UInt64
        init(seed: UInt64) { s = seed }
        mutating func next() -> UInt64 {
            s &+= 0x9E37_79B9_7F4A_7C15
            var z = s
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
        mutating func unit() -> Double { Double(next() >> 11) / Double(1 << 53) }
        mutating func normal() -> Double {
            let u1 = max(unit(), 1e-12), u2 = unit()
            return (-2 * log(u1)).squareRoot() * cos(2 * Double.pi * u2)
        }
    }

    /// Scratch memory for one thread.
    final class Workspace {
        var yir = [[Double]](), yii = [[Double]]()
        var y = [Double]()
        var tmp = [Double](), w = [Double]()
        var Yre = [Double](), Yim = [Double]()
        var tau = [Double](), q = [Double](), gs = [Double]()
        var bandSum = [Double](), bandDb = [Double]()
    }
}

/// Smooth, differentiable per-microphone model of the combined response.
final class SmoothMicModel {
    let fs: Double, n: Int, pre: Int, len: Int
    let nfft: Int, k0: Int, bins: Int
    let hre: [[Double]], him: [[Double]]       // spectra of each speaker's IR, bins k0 ..< k0+bins
    let h: [[Double]]
    let dh: [[Double]]                         // dh[i][j] = h[j] − h[j−1] (j = 0…len), for the gradient of the late-energy term
    let arrival: [Double]                      // seconds
    let bandOf: [Int], bandSize: [Double]
    let omega: [Double]                        // rad/sample per bin
    let early: Int
    let lateSigma: Double, softSigma: Double
    let lateTable: [Double]
    let bandDbW: [Double]                      // per band: deconvolution weighting of the programme, in dB (0 without one)
    static let lateWeight = RoomOptimizer.lateWeight

    init?(_ mic: MicResponse, programme: Programme? = nil) {
        guard !mic.speakers.isEmpty, mic.speakers.allSatisfy({ $0 != nil }) else { return nil }
        let sp = mic.speakers.map { $0! }
        fs = mic.sampleRate; n = sp.count
        let maxLen = sp.map { $0.h.count }.max() ?? 0
        len = maxLen
        pre = sp[0].pre
        let hs = sp.map { s in s.h + [Double](repeating: 0, count: maxLen - s.h.count) }
        h = hs
        dh = hs.map { hi in (0...maxLen).map { j in (j < maxLen ? hi[j] : 0) - (j >= 1 ? hi[j - 1] : 0) } }
        arrival = sp.map(\.arrival)
        nfft = FFT.nextPowerOfTwo(maxLen + 1)
        let fft = FFT(size: nfft)
        let binHz = fs / Double(nfft)
        let lo = max(1, Int((100 / binHz).rounded(.up)))
        let hi = min(nfft / 2 - 1, Int(min(8000, 0.45 * fs) / binHz))
        k0 = lo
        let k1 = max(lo + 1, hi)
        bins = k1 - k0
        var re = [[Double]](), im = [[Double]]()
        for s in 0..<n {
            var r = hs[s] + [Double](repeating: 0, count: nfft - maxLen), i = [Double](repeating: 0, count: nfft)
            fft.transform(&r, &i)
            re.append(Array(r[k0..<k1])); im.append(Array(i[k0..<k1]))
        }
        hre = re; him = im
        // 1/6-octave bands from 100 Hz (as in RoomOptimizer).
        var edges = [0]
        var f = 100.0 * pow(2, 1.0 / 6)
        while true {
            let k = Int((f / binHz).rounded())
            if k >= k1 { break }
            if k - k0 > edges.last! { edges.append(k - k0) }
            f *= pow(2, 1.0 / 6)
        }
        edges.append(bins)
        var bo = [Int](repeating: 0, count: bins), bs = [Double]()
        for b in 0..<(edges.count - 1) {
            for k in edges[b]..<edges[b + 1] { bo[k] = b }
            bs.append(Double(edges[b + 1] - edges[b]))
        }
        bandOf = bo; bandSize = bs
        var dbw = [Double](repeating: 0, count: bs.count)
        if let pr = programme, pr.probe.count >= 1024, pr.probe.count & (pr.probe.count - 1) == 0 {
            let np = pr.probe.count
            var xr = pr.probe.map(Double.init), xi = [Double](repeating: 0, count: np)
            FFT(size: np).transform(&xr, &xi)
            var power = [Double](repeating: 0, count: np / 2 + 1), mean = 0.0
            for j in 0...(np / 2) { power[j] = xr[j] * xr[j] + xi[j] * xi[j]; mean += power[j] }
            mean /= Double(np / 2 + 1)
            let eps = 1e-3 * mean, probeHz = pr.rate / Double(np)
            for b in 0..<bs.count {
                let j0 = min(np / 2, Int(Double(lo + edges[b]) * binHz / probeHz))
                let j1 = min(np / 2 + 1, max(j0 + 1, Int(Double(lo + edges[b + 1]) * binHz / probeHz)))
                var p = 0.0
                for j in j0..<j1 { p += power[j] }
                p /= Double(j1 - j0)
                dbw[b] = 20 * log10(max(p / (p + eps), 1e-6))
            }
        }
        bandDbW = dbw
        let firstBin = k0, size = nfft
        omega = (0..<bins).map { 2 * Double.pi * Double(firstBin + $0) / Double(size) }
        early = Int(RoomOptimizer.earlyWindowSec * fs)
        lateSigma = max(2, 0.002 * fs)
        softSigma = max(1, 0.001 * fs)
        let rate = mic.sampleRate, preSamples = sp[0].pre, earlySamples = Int(RoomOptimizer.earlyWindowSec * mic.sampleRate)
        let sigma = max(2, 0.002 * mic.sampleRate)
        let tableLen = maxLen + Int(2.5 * mic.sampleRate) + 16
        _ = rate
        lateTable = (0..<tableLen).map { m in 1 / (1 + exp(-Double(m - preSamples - earlySamples) / sigma)) }
    }

    /// J for this microphone and (if asked) its gradient w.r.t. every delay in ms.
    /// `coarse` > 1 evaluates the spectral term on every `coarse`-th bin only (a cheaper, still unbiased estimate of the band
    /// powers; the descent uses it early on and the full resolution at the end).
    func evaluate(_ d: [Double], _ grad: inout [Double], _ ws: DelayAI.Workspace, wantGradient: Bool, coarse: Int = 1) -> Double {
        if ws.yir.count != n || ws.yir[0].count != bins {
            ws.yir = [[Double]](repeating: [Double](repeating: 0, count: bins), count: n)
            ws.yii = ws.yir
            ws.tau = [Double](repeating: 0, count: n); ws.q = ws.tau; ws.gs = ws.tau
        }
        for i in 0..<n { ws.tau[i] = (arrival[i] + d[i] / 1000) * fs - Double(pre) }
        let step = (coarse > 1 && (bandSize.min() ?? 0) >= Double(8 * coarse)) ? coarse : 1

        // ---- spectral term ----
        if ws.Yre.count != bins { ws.Yre = [Double](repeating: 0, count: bins); ws.Yim = ws.Yre }
        let B = bandSize.count
        let dw = 2 * Double.pi / Double(nfft)
        var bandSum = [Double](repeating: 0, count: B), bandCnt = [Double](repeating: 0, count: B)
        var Yre = ws.Yre, Yim = ws.Yim               // moved out of the workspace so the loops can use raw pointers
        ws.Yre = []; ws.Yim = []
        Yre.withUnsafeMutableBufferPointer { YrP in Yim.withUnsafeMutableBufferPointer { YiP in
            for k in 0..<bins { YrP[k] = 0; YiP[k] = 0 }
            for i in 0..<n {
                let tau = ws.tau[i]
                let p0 = (-omega[0] * tau).truncatingRemainder(dividingBy: 2 * Double.pi)
                let st = (-dw * Double(step) * tau).truncatingRemainder(dividingBy: 2 * Double.pi)
                var cr = cos(p0), ci = sin(p0)
                let cs = cos(st), sn = sin(st)
                hre[i].withUnsafeBufferPointer { hrP in him[i].withUnsafeBufferPointer { hiP in
                    ws.yir[i].withUnsafeMutableBufferPointer { yrP in ws.yii[i].withUnsafeMutableBufferPointer { yiP in
                        var k = 0
                        while k < bins {
                            let a = hrP[k], b = hiP[k]
                            let tr = a * cr - b * ci, ti = a * ci + b * cr
                            yrP[k] = tr; yiP[k] = ti
                            YrP[k] += tr; YiP[k] += ti
                            let ncr = cr * cs - ci * sn
                            ci = cr * sn + ci * cs
                            cr = ncr
                            k += step
                        }
                    } }
                } }
            }
            bandOf.withUnsafeBufferPointer { bo in
                var k = 0
                while k < bins { bandSum[bo[k]] += YrP[k] * YrP[k] + YiP[k] * YiP[k]; bandCnt[bo[k]] += 1; k += step }
            }
        } }
        var db = [Double](repeating: 0, count: B), mean = 0.0, sq = 0.0
        let c10 = 10 / log(10.0)
        for b in 0..<B {
            let pbar = bandSum[b] / max(bandCnt[b], 1) + 1e-18
            db[b] = c10 * log(pbar) + bandDbW[b]
            mean += db[b]; sq += db[b] * db[b]
        }
        mean /= Double(B)
        let spectral = max(0, sq / Double(B) - mean * mean)

        var dSdTau = [Double](repeating: 0, count: n)
        if wantGradient {
            var gk = [Double](repeating: 0, count: B)
            for b in 0..<B {
                let cnt = max(bandCnt[b], 1)
                let pbar = bandSum[b] / cnt + 1e-18
                gk[b] = (2 / Double(B)) * (db[b] - mean) * c10 / (cnt * pbar)
            }
            // weight of bin k: gk[band(k)] · 2ω_k  (the same for every speaker)
            for i in 0..<n {
                var acc = 0.0
                Yre.withUnsafeBufferPointer { YrP in Yim.withUnsafeBufferPointer { YiP in
                    ws.yir[i].withUnsafeBufferPointer { yrP in ws.yii[i].withUnsafeBufferPointer { yiP in
                        bandOf.withUnsafeBufferPointer { bo in omega.withUnsafeBufferPointer { om in gk.withUnsafeBufferPointer { gp in
                            var k = 0
                            while k < bins {
                                // ∂P/∂τ_i = 2 ω Im( conj(Y) · Y_i )
                                acc += gp[bo[k]] * 2 * om[k] * (YrP[k] * yiP[k] - YiP[k] * yrP[k])
                                k += step
                            }
                        } } }
                    } }
                } }
                dSdTau[i] = acc
            }
        }
        ws.Yre = Yre; ws.Yim = Yim

        // ---- late-energy term (time domain, fractional delays, smooth window) ----
        let tmin = ws.tau.min()!
        var denom = 0.0
        for i in 0..<n { ws.q[i] = exp(-(ws.tau[i] - tmin) / softSigma); denom += ws.q[i] }
        for i in 0..<n { ws.q[i] /= denom }
        let t0 = tmin - softSigma * log(denom)
        var maxS = 0.0
        for i in 0..<n { maxS = max(maxS, ws.tau[i] - t0) }
        let M = min(lateTable.count, len + Int(maxS) + 3)
        if ws.y.count < M { ws.y = [Double](repeating: 0, count: M) }
        for m in 0..<M { ws.y[m] = 0 }
        var i0s = [Int](repeating: 0, count: n)
        for i in 0..<n {
            let s = max(0, ws.tau[i] - t0)
            let i0 = Int(s)
            i0s[i] = i0
        }
        var E = 0.0, L = 0.0
        #if canImport(Accelerate)
        if ws.tmp.count < M { ws.tmp = [Double](repeating: 0, count: M); ws.w = ws.tmp }
        for i in 0..<n {
            let s = max(0, ws.tau[i] - t0)
            let i0 = i0s[i], f = s - Double(i0)
            let top = min(len, M - i0 - 1)
            if top > 0 {
                var a = 1 - f, b = f
                h[i].withUnsafeBufferPointer { hp in
                    ws.y.withUnsafeMutableBufferPointer { yp in
                        vDSP_vsmaD(hp.baseAddress!, 1, &a, yp.baseAddress! + i0, 1, yp.baseAddress! + i0, 1, vDSP_Length(top))
                        vDSP_vsmaD(hp.baseAddress!, 1, &b, yp.baseAddress! + i0 + 1, 1, yp.baseAddress! + i0 + 1, 1, vDSP_Length(top))
                    }
                }
            }
        }
        ws.y.withUnsafeBufferPointer { yp in
            ws.tmp.withUnsafeMutableBufferPointer { tp in
                lateTable.withUnsafeBufferPointer { lp in
                    vDSP_dotprD(yp.baseAddress!, 1, yp.baseAddress!, 1, &E, vDSP_Length(M))
                    vDSP_vmulD(yp.baseAddress!, 1, lp.baseAddress!, 1, tp.baseAddress!, 1, vDSP_Length(M))
                    vDSP_dotprD(tp.baseAddress!, 1, yp.baseAddress!, 1, &L, vDSP_Length(M))
                }
            }
        }
        let late = E > 1e-18 ? L / E : 1
        var dLdTau = [Double](repeating: 0, count: n)
        if wantGradient && E > 1e-18 {
            var neg = -late
            ws.y.withUnsafeBufferPointer { yp in
                ws.tmp.withUnsafeBufferPointer { tp in
                    ws.w.withUnsafeMutableBufferPointer { wp in
                        vDSP_vsmaD(yp.baseAddress!, 1, &neg, tp.baseAddress!, 1, wp.baseAddress!, 1, vDSP_Length(M))   // y·(lateTable − late)
                    }
                }
            }
            var gsum = 0.0
            for i in 0..<n {
                let i0 = i0s[i], count = min(len + 1, M - i0)
                var dot = 0.0
                if count > 0 {
                    ws.w.withUnsafeBufferPointer { wp in dh[i].withUnsafeBufferPointer { dp in
                        vDSP_dotprD(wp.baseAddress! + i0, 1, dp.baseAddress!, 1, &dot, vDSP_Length(count))
                    } }
                }
                ws.gs[i] = -2 / E * dot; gsum += ws.gs[i]               // ∂y[m]/∂s_i = −(h[j] − h[j−1])
            }
            for i in 0..<n { dLdTau[i] = ws.gs[i] - ws.q[i] * gsum }
        }
        #else
        for i in 0..<n {
            let s = max(0, ws.tau[i] - t0)
            let i0 = i0s[i], f = s - Double(i0)
            let hi = h[i]
            let top = min(len, M - i0 - 1)
            if top > 0 {
                for j in 0..<top { let v = hi[j]; ws.y[j + i0] += v * (1 - f); ws.y[j + i0 + 1] += v * f }
            }
        }
        for m in 0..<M { let e = ws.y[m] * ws.y[m]; E += e; L += lateTable[m] * e }
        let late = E > 1e-18 ? L / E : 1
        var dLdTau = [Double](repeating: 0, count: n)
        if wantGradient && E > 1e-18 {
            var gsum = 0.0
            for i in 0..<n {
                let i0 = i0s[i]
                var acc = 0.0
                for j in 0...len {
                    let m = j + i0
                    if m >= M { break }
                    acc += 2 * ws.y[m] * (lateTable[m] - late) / E * (-dh[i][j])
                }
                ws.gs[i] = acc; gsum += acc
            }
            for i in 0..<n { dLdTau[i] = ws.gs[i] - ws.q[i] * gsum }
        }
        #endif

        if wantGradient {
            let toMs = fs / 1000
            for i in 0..<n { grad[i] = (dSdTau[i] + SmoothMicModel.lateWeight * dLdTau[i]) * toMs }
        }
        return spectral + SmoothMicModel.lateWeight * late
    }
}
