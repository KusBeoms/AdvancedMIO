import Foundation

// Candidate definitions of the "울림 지수" (developer mode).
//
// All of them are computed from the room's combined impulse response h(t) as it really sounds at the microphone with every
// speaker playing (recovered live by deconvolving the microphone with the programme), counted from the first arrival.
// For every candidate lower = less 울림. They are deliberately different questions asked of the same response, so that
// moving the delays by hand shows which one follows what the ear hears.

public enum ResonanceMetric: String, CaseIterable, Identifiable, Sendable {
    case current, lateRatio, centerTime, decayTime, comb, echo
    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .current: return "기존 (대역 분산 + λ·늦은 에너지)"
        case .lateRatio: return "늦은/이른 에너지비"
        case .centerTime: return "에너지 중심 시간"
        case .decayTime: return "초기 감쇠 시간"
        case .comb: return "빗살(콤) 깊이"
        case .echo: return "가장 큰 반복음 레벨"
        }
    }
    public var unit: String {
        switch self {
        case .current: return ""
        case .lateRatio, .echo: return "dB"
        case .centerTime, .decayTime: return "ms"
        case .comb: return "dB"
        }
    }
    public var summary: String {
        switch self {
        case .current: return "지금 캘리브레이션이 쓰는 값: 1/6옥타브 대역 dB 분산 + λ × 50 ms 뒤 에너지 비율."
        case .lateRatio: return "첫 소리 뒤 50 ms 이후에 오는 에너지 ÷ 50 ms 안의 에너지 (dB). 반향·에코가 직접음보다 얼마나 센가."
        case .centerTime: return "에너지가 시간축에서 어디에 몰려 있나 (ms). 소리가 뭉개져 늦게까지 퍼질수록 큼."
        case .decayTime: return "에너지가 10 dB 줄어드는 데 걸리는 시간 ×6 (ms). 소리 꼬리가 얼마나 오래 남나."
        case .comb: return "100 Hz~8 kHz 주파수 특성의 들쭉날쭉함(표준편차, dB). 스피커 사이 지연이 어긋나면 빗살 모양으로 패임."
        case .echo: return "첫 소리 외에 가장 큰 되울림이 첫 소리보다 몇 dB 낮은가 (0에 가까울수록 또렷한 메아리)."
        }
    }
    /// Decimals worth showing.
    public var digits: Int { self == .current ? 1 : (unit == "ms" ? 0 : 1) }
}

public struct ResonanceReading: Sendable {
    public var values: [ResonanceMetric: Double]
}

public enum ResonanceMeter {
    /// The response at the listening position with every speaker playing at `delaysMs`, and the index of its first arrival.
    public static func combined(room: MicResponse, delaysMs: [Double]) -> (h: [Double], onset: Int)? {
        let sp = room.speakers.compactMap { $0 }
        guard sp.count == room.speakers.count, sp.count == delaysMs.count, !sp.isEmpty else { return nil }
        let fs = room.sampleRate
        let T = zip(sp, delaysMs).map { $0.arrival + $1 / 1000 }
        let t0 = T.min() ?? 0
        let shifts = T.map { Int((($0 - t0) * fs).rounded()) }
        let len = sp.map { $0.h.count }.max() ?? 0
        var c = [Double](repeating: 0, count: len + (shifts.max() ?? 0))
        var onset = Int.max
        for (i, s) in sp.enumerated() {
            for (t, v) in s.h.enumerated() { c[shifts[i] + t] += v }
            onset = min(onset, shifts[i] + s.pre)
        }
        return (c, onset)
    }

    /// All candidates for `room` played with `delaysMs`.
    public static func readings(room: MicResponse, delaysMs: [Double]) -> ResonanceReading? {
        guard let (h, onset) = combined(room: room, delaysMs: delaysMs) else { return nil }
        return readings(h: h, onset: onset, noisePower: 0, sampleRate: room.sampleRate)
    }

    /// The candidates for a response `h` whose first arrival is at index `onset`. `noisePower` is the per-sample power of the
    /// measurement noise, removed from the energies so that a quiet tail does not read as a long one.
    public static func readings(h: [Double], onset: Int, noisePower: Double, sampleRate fs: Double) -> ResonanceReading? {
        guard h.count > Int(0.2 * fs), onset >= 0, onset < h.count else { return nil }
        let e = h.map { max(0, $0 * $0 - noisePower) }
        let from = onset
        var total = 0.0
        for t in from..<e.count { total += e[t] }
        guard total > 0 else { return nil }
        var v: [ResonanceMetric: Double] = [:]

        // late / early energy (50 ms)
        let split = min(e.count, from + Int(0.05 * fs))
        var early = 0.0
        for t in from..<split { early += e[t] }
        let late = max(0, total - early)
        v[.lateRatio] = 10 * log10((late + 1e-9 * total) / (early + 1e-9 * total))

        // centre time
        var m1 = 0.0
        for t in from..<e.count { m1 += Double(t - from) * e[t] }
        v[.centerTime] = m1 / total / fs * 1000

        // early decay time: Schroeder curve, time to fall by 10 dB, ×6
        var remaining = total
        var edt = Double(e.count - from) / fs
        for t in from..<e.count {
            remaining -= e[t]
            if remaining <= total * 0.1 { edt = Double(t - from) / fs; break }
        }
        v[.decayTime] = edt * 6 * 1000

        // strongest repeat: smoothed envelope (2 ms), peaks later than 3 ms after the first arrival
        let win = max(1, Int(0.002 * fs))
        var env = [Double](repeating: 0, count: e.count)
        var acc = 0.0
        for t in 0..<e.count {
            acc += e[t]
            if t >= win { acc -= e[t - win] }
            env[t] = acc / Double(win)
        }
        var mainPeak = 0.0, mainAt = from
        for t in from..<min(e.count, from + Int(0.003 * fs) + win) where env[t] > mainPeak { mainPeak = env[t]; mainAt = t }
        var second = 0.0
        let skip = mainAt + max(win, Int(0.003 * fs))
        if skip < e.count { for t in skip..<e.count where env[t] > second { second = env[t] } }
        v[.echo] = 10 * log10((second + 1e-12 * mainPeak) / max(mainPeak, 1e-30))

        // spectrum: std of 1/6-octave band powers (dB), 100 Hz … 8 kHz
        let nfft = FFT.nextPowerOfTwo(h.count)
        var re = [Double](repeating: 0, count: nfft), im = re
        for t in from..<h.count { re[t - from] = h[t] }
        FFT(size: nfft).transform(&re, &im)
        let binHz = fs / Double(nfft)
        let top = min(nfft / 2 - 1, Int(min(8000, 0.45 * fs) / binHz))
        var bandDb: [Double] = []
        var f = 100.0
        while f < 8000 {
            let k0 = max(1, Int((f / binHz).rounded())), f2 = f * pow(2, 1.0 / 6)
            let k1 = min(top, max(k0 + 1, Int((f2 / binHz).rounded())))
            if k0 >= top { break }
            var p = 0.0
            for k in k0..<k1 { p += re[k] * re[k] + im[k] * im[k] }
            bandDb.append(10 * log10(p / Double(k1 - k0) + 1e-30))
            f = f2
        }
        if bandDb.count > 3 {
            let mean = bandDb.reduce(0, +) / Double(bandDb.count)
            v[.comb] = (bandDb.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(bandDb.count)).squareRoot()
        }

        // the definition in use today, on the same response
        let pre = min(onset, h.count)
        let cut = Array(h[(onset - pre)...])
        let ir = SpeakerIR(h: cut, pre: pre, arrival: 0, snr: 100, consistency: 1)
        if let s = RoomOptimizer.score(of: MicResponse(sampleRate: fs, speakers: [ir])) { v[.current] = s }

        return ResonanceReading(values: v)
    }
}
