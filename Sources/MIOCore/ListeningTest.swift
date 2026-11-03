import Foundation

// Listening test for the boominess index (developer mode).
//
// The index J = spectral + λ · late has one free number, λ (`RoomOptimizer.lateWeight`). It cannot be derived — it is a
// statement about what sounds "boomy" — so it is fitted to a listener's judgements:
//
//  1. `ListeningTest.makePair` picks two delay settings of a room model whose indices disagree about which is better for
//     some λ in a plausible range (otherwise the answer says nothing about λ),
//  2. `ListeningTest.render` makes what a microphone at the listening position would hear with each setting
//     (the programme convolved with the summed speaker responses) — this can be played on headphones,
//  3. `PreferenceFit.fit` finds the λ under which the listener's choices are most likely.

extension RoomOptimizer {
    /// The two parts of the index for one microphone: (spectral variance in dB², late-energy ratio). J = spectral + λ·late.
    public static func components(of mic: MicResponse, delaysMs: [Double], gains: [Double]? = nil) -> (spectral: Double, late: Double)? {
        guard let m = MicModel(mic), delaysMs.count == m.n else { return nil }
        let g = gains ?? [Double](repeating: 1, count: m.n)
        guard g.count == m.n else { return nil }
        return m.score(delays: delaysMs.map { $0 / 1000 }, gains: g)
    }
}

/// One setting shown in a listening trial, with the two parts of its index at the time.
public struct ABStimulus: Codable, Equatable {
    public var delaysMs: [Double]
    public var spectral: Double
    public var late: Double
    public init(delaysMs: [Double], spectral: Double, late: Double) { self.delaysMs = delaysMs; self.spectral = spectral; self.late = late }
    public func score(weight: Double) -> Double { spectral + weight * late }
}

public enum ABChoice: String, Codable { case a, b, same }

/// A listener's judgement: which of the two sounded less boomy.
public struct ABVote: Codable, Equatable {
    public var date: Double
    public var room: String
    public var a: ABStimulus
    public var b: ABStimulus
    public var choice: ABChoice
    public init(date: Double, room: String, a: ABStimulus, b: ABStimulus, choice: ABChoice) {
        self.date = date; self.room = room; self.a = a; self.b = b; self.choice = choice
    }
}

public enum ListeningTest {
    /// Two settings to compare. Pairs whose parts disagree (one has the flatter spectrum, the other the shorter tail) and
    /// whose crossover λ lies in 8…200 are the ones that move the fitted weight, so they are preferred; the two must also
    /// differ clearly under the current weight, or the listener could not tell them apart.
    public static func makePair(room: MicResponse, weight: Double, maxDelayMs: Double = 40,
                                rng: inout DelayAI.SplitMix) -> (ABStimulus, ABStimulus)? {
        guard let model = RoomOptimizer.MicModel(room) else { return nil }
        let n = model.n
        var cands: [ABStimulus] = []
        for _ in 0..<48 {
            let d = (0..<n).map { _ in rng.unit() * maxDelayMs }
            let (v, l) = model.score(delays: d.map { $0 / 1000 }, gains: [Double](repeating: 1, count: n))
            guard v < 1e5 else { continue }
            cands.append(ABStimulus(delaysMs: d, spectral: v, late: l))
        }
        // A pair says something about λ only if the two parts disagree; its "crossover" λ (where the two indices tie) is
        // where the listener's answer flips. Aim at crossovers spread evenly (on a log scale) over 10…300 so that every
        // plausible λ is tested, not just the ones near the default.
        var informative: [(pair: (ABStimulus, ABStimulus), crossover: Double)] = [], plain: [(ABStimulus, ABStimulus)] = []
        for i in cands.indices {
            for j in (i + 1)..<max(i + 1, cands.count) {
                let a = cands[i], b = cands[j]
                let sa = a.score(weight: weight), sb = b.score(weight: weight)
                let rel = abs(sa - sb) / max(1e-9, 0.5 * (sa + sb))
                guard rel >= 0.12, rel <= 0.8 else { continue }
                plain.append((a, b))
                let dv = b.spectral - a.spectral, dl = b.late - a.late
                if dv * dl < 0 {
                    let crossover = -dv / dl
                    if crossover >= 5 && crossover <= 600 { informative.append(((a, b), crossover)) }
                }
            }
        }
        let pool: [(ABStimulus, ABStimulus)]
        if !informative.isEmpty && rng.unit() < 0.85 {
            let target = exp(log(10.0) + rng.unit() * (log(300.0) - log(10.0)))
            let best = informative.min { abs(log($0.crossover / target)) < abs(log($1.crossover / target)) }!
            pool = [best.pair]
        } else {
            pool = plain.isEmpty ? informative.map(\.pair) : plain
        }
        guard !pool.isEmpty else { return nil }
        var pair = pool[Int(rng.unit() * Double(pool.count)) % pool.count]
        if rng.unit() < 0.5 { pair = (pair.1, pair.0) }       // the listener must not learn which side tends to be better
        return pair
    }

    /// `x ⊛ c` by overlap-add in blocks (a whole song costs no more memory than one block). With `wrap` the result has the
    /// length of `x` and the tail wraps around to the start, so that it can loop; otherwise it is `x.count + c.count − 1` long.
    static func convolve(_ x: [Float], with c: [Double], wrap: Bool) -> [Double] {
        let n = x.count
        let block = 1 << 16
        let nfft = FFT.nextPowerOfTwo(block + c.count)
        let fft = FFT(size: nfft)
        var cr = [Double](repeating: 0, count: nfft), ci = cr
        for i in 0..<c.count { cr[i] = c[i] }
        fft.transform(&cr, &ci)
        var y = [Double](repeating: 0, count: wrap ? n : n + c.count - 1)
        var xr = [Double](repeating: 0, count: nfft), xi = xr
        var start = 0
        while start < n {
            let m = min(block, n - start)
            for i in 0..<nfft { xr[i] = 0; xi[i] = 0 }
            for i in 0..<m { xr[i] = Double(x[start + i]) }
            fft.transform(&xr, &xi)
            for k in 0..<nfft {
                let a = xr[k] * cr[k] - xi[k] * ci[k], b = xr[k] * ci[k] + xi[k] * cr[k]
                xr[k] = a; xi[k] = b
            }
            fft.transform(&xr, &xi, inverse: true)
            for i in 0..<(m + c.count - 1) { y[wrap ? (start + i) % n : start + i] += xr[i] }
            start += m
        }
        return y
    }

    /// What a microphone at the listening position would hear: the programme through all speakers with `delaysMs`
    /// (circular, so that it can loop), scaled to a fixed loudness so that the level gives no hint.
    public static func render(room: MicResponse, delaysMs: [Double], programme: [Float], loudness: Double = 0.08) -> [Float]? {
        let sp = room.speakers.compactMap { $0 }
        guard sp.count == room.speakers.count, sp.count == delaysMs.count, !programme.isEmpty else { return nil }
        let fs = room.sampleRate
        let T = zip(sp, delaysMs).map { $0.arrival + $1 / 1000 }
        let t0 = T.min() ?? 0
        let shifts = T.map { Int((($0 - t0) * fs).rounded()) }
        let len = sp.map { $0.h.count }.max() ?? 0
        var c = [Double](repeating: 0, count: len + (shifts.max() ?? 0))
        for (i, s) in sp.enumerated() { for (t, v) in s.h.enumerated() { c[shifts[i] + t] += v } }

        let y = convolve(programme, with: c, wrap: true)
        let n = programme.count

        var sum = 0.0, peak = 0.0
        for v in y { sum += v * v; peak = max(peak, abs(v)) }
        let rms = (sum / Double(n)).squareRoot()
        guard rms > 1e-12 else { return nil }
        let g = min(loudness / rms, 0.98 / max(peak, 1e-12))
        return y.map { Float($0 * g) }
    }
}

/// Fits λ to a listener's choices. P(A judged less boomy) = σ(β · (J_B − J_A) / mean(J_A, J_B)), with J = spectral + λ·late;
/// λ and the sharpness β are chosen to maximise the likelihood, with a weak preference for the default so that a handful
/// of answers cannot swing the weight to an extreme.
public enum PreferenceFit {
    public struct Result {
        public var weight: Double
        public var decisive: Int                    // votes that named a side
        public var same: Int
        public var agreementAtFit: Double           // share of decisive votes the fitted weight predicts correctly
        public var agreementAtDefault: Double
        public var defaultWeight: Double
    }

    public static let candidates: [Double] = [0, 2.5, 5, 10, 15, 20, 30, 40, 60, 80, 120, 160, 240, 320, 480, 640]

    public static func fit(votes: [ABVote], defaultWeight: Double = 40) -> Result {
        let decisive = votes.filter { $0.choice != .same }
        let same = votes.count - decisive.count
        func relDiff(_ v: ABVote, _ w: Double) -> Double {
            let sa = v.a.score(weight: w), sb = v.b.score(weight: w)
            return (sb - sa) / max(1e-9, 0.5 * (sa + sb))            // > 0: A has the lower (better) index
        }
        func agreement(_ w: Double) -> Double {
            guard !decisive.isEmpty else { return 0 }
            let ok = decisive.filter { v in let d = relDiff(v, w); return (v.choice == .a) == (d > 0) && d != 0 }.count
            return Double(ok) / Double(decisive.count)
        }
        var best = (w: defaultWeight, ll: -Double.infinity)
        if !decisive.isEmpty {
            for w in candidates {
                for beta in [3.0, 6.0, 12.0, 25.0] {
                    var ll = 0.0
                    for v in decisive {
                        let z = beta * relDiff(v, w) * (v.choice == .a ? 1 : -1)
                        ll += -log(1 + exp(-max(-30, min(30, z))))
                    }
                    let prior = log((w + 1) / (defaultWeight + 1)) / log(4.0)
                    ll -= 0.5 * prior * prior
                    if ll > best.ll { best = (w, ll) }
                }
            }
        }
        return Result(weight: best.w, decisive: decisive.count, same: same, agreementAtFit: agreement(best.w),
                      agreementAtDefault: agreement(defaultWeight), defaultWeight: defaultWeight)
    }
}

/// A made-up room for trying the listening test without having calibrated: speakers at slightly different distances, each
/// with a few early reflections and an exponentially decaying noise tail, and a different tone.
public enum SyntheticRoom {
    public static func make(speakers n: Int = 4, seed: UInt64 = 1, sampleRate fs: Double = 24_000, seconds: Double = 2.0) -> MicResponse {
        var rng = DelayAI.SplitMix(seed: seed)
        let len = Int(seconds * fs), pre = max(1, Int(0.001 * fs))
        var irs: [SpeakerIR?] = []
        let rt60 = 0.45 + 0.4 * rng.unit()
        let tau = rt60 / 6.9
        for _ in 0..<n {
            var h = [Double](repeating: 0, count: pre + len)
            let arrival = 0.004 + 0.012 * rng.unit()
            h[pre] = 1
            for _ in 0..<6 {
                let t = pre + Int((0.003 + 0.037 * rng.unit()) * fs)
                h[t] += (rng.unit() < 0.5 ? -1 : 1) * (0.15 + 0.35 * rng.unit())
            }
            let start = pre + Int(0.012 * fs)
            for t in start..<(pre + len) {
                let e = exp(-Double(t - start) / (tau * fs))
                h[t] += 0.14 * e * rng.normal()
            }
            let a = 0.5 * rng.unit()                                  // one-pole lowpass: a duller or brighter speaker
            var y = 0.0
            for t in 0..<h.count { y = a * y + (1 - a) * h[t]; h[t] = y }
            let peak = h.map { abs($0) }.max() ?? 1
            irs.append(SpeakerIR(h: h.map { $0 / peak }, pre: pre, arrival: arrival, snr: 100, consistency: 1))
        }
        return MicResponse(sampleRate: fs, speakers: irs)
    }
}
