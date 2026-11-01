import CoreAudio
import Foundation
import MIOCore

/// Plays a pre-rendered mono signal into a ring in real time (the router's own pipeline then delays and renders it).
final class ProbeSource: RingSource {
    let ring: StereoRing
    var level: Float = 0
    private let samples: [Float]
    private let rate: Double
    private var written = 0
    private var startedAt: UInt64 = 0
    private var timer: DispatchSourceTimer?
    private let queue = DispatchQueue(label: "advancedmio.probe", qos: .userInteractive)

    init(samples: [Float], sampleRate: Double) {
        self.samples = samples
        rate = sampleRate
        ring = StereoRing(sampleRate: sampleRate)
    }

    /// Seconds since feeding started (the source timeline that slot start times refer to).
    var elapsed: Double { startedAt == 0 ? 0 : Double(DispatchTime.now().uptimeNanoseconds &- startedAt) / 1e9 }

    func startFeeding() {
        guard timer == nil else { return }
        written = 0
        startedAt = DispatchTime.now().uptimeNanoseconds
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now(), repeating: .milliseconds(3), leeway: .microseconds(300))
        t.setEventHandler { [weak self] in self?.pump() }
        timer = t
        t.resume()
    }

    func stopFeeding() {
        timer?.cancel(); timer = nil
        queue.sync {}
    }

    private func pump() {
        let target = min(samples.count, Int(elapsed * rate))
        let n = target - written
        guard n > 0 else { return }
        samples.withUnsafeBufferPointer { p in
            let base = p.baseAddress! + written
            ring.write(left: base, right: base, frames: n)
        }
        written = target
    }
}

/// Records one channel of an input device into memory.
final class MicRecorder {
    private final class State {
        let buf: UnsafeMutablePointer<Float>
        let capacity: Int
        var count = 0
        init(capacity: Int) { self.capacity = capacity; buf = .allocate(capacity: capacity); buf.initialize(repeating: 0, count: capacity) }
        deinit { buf.deallocate() }
    }

    let device: AudioDeviceInfo
    let sampleRate: Double
    private let state: State
    private let io: DeviceIO

    init(device: AudioDeviceInfo, seconds: Double) throws {
        self.device = device
        sampleRate = try HAL.validateFloatIO(device.id, scope: kAudioObjectPropertyScopeInput)
        let st = State(capacity: Int((seconds + 1) * sampleRate))
        state = st
        let block: AudioDeviceIOBlock = { _, inData, _, outData, _ in
            let abl = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inData))
            if let b = abl.first, let d = b.mData?.assumingMemoryBound(to: Float.self) {
                let ch = max(1, Int(b.mNumberChannels))
                let frames = min(Int(b.mDataByteSize) / (MemoryLayout<Float>.size * ch), st.capacity - st.count)
                for i in 0..<max(0, frames) { st.buf[st.count + i] = d[i * ch] }
                st.count += max(0, frames)
            }
            for b in UnsafeMutableAudioBufferListPointer(outData) { if let d = b.mData { memset(d, 0, Int(b.mDataByteSize)) } }
        }
        io = try DeviceIO(deviceID: device.id, block: block)
    }

    func start() throws { try io.start() }
    func stop() { io.stop() }
    var samples: [Float] { Array(UnsafeBufferPointer(start: state.buf, count: state.count)) }
    /// A copy of samples [from, to) (clamped to what has been recorded).
    func samples(from a: Int, to b: Int) -> [Float] {
        let hi = min(b, state.count), lo = max(0, min(a, hi))
        return Array(UnsafeBufferPointer(start: state.buf + lo, count: hi - lo))
    }
    /// Samples recorded so far (read from another thread while recording: only used for live level checks).
    var count: Int { state.count }
    /// RMS of recorded samples [from, to); nil if that span has not been recorded yet.
    func rms(from a: Int, to b: Int) -> Double? {
        let n = state.count
        guard a >= 0, b > a, b <= n else { return nil }
        var sum = 0.0
        for i in a..<b { let v = Double(state.buf[i]); sum += v * v }
        return (sum / Double(b - a)).squareRoot()
    }
}

struct CalibrationSpeaker {
    let device: AudioDeviceInfo
    let appliedDelayMs: Double       // what the router applies to it right now
    let volume: Double
}

struct CalibrationReport {
    let outcome: CalibrationOutcome
    let speakerUIDs: [String]
    let speakerNames: [String]
    let micsUsed: [String]
    let warnings: [String]
    /// Speakers the microphones could not hear (virtual devices…): left exactly as they were.
    let excluded: [String]
    /// Boominess index measured with all speakers playing together: original settings, then the best found.
    let measuredBefore: Double?
    let measuredAfter: Double?
    /// Best measured index after each search step size (200, 80, 30, 12, 5 ms).
    let searchHistory: [Double]
    let evaluations: Int
    /// The search went through every step size within the time budget.
    let finished: Bool
    /// How much of the recordings the speaker model explained in the first (model) measurement, if any.
    let fit: Double?

    var measuredImprovement: Double? {
        guard let b = measuredBefore, let a = measuredAfter, b > 0 else { return nil }
        return (b - a) / b
    }
    /// A clear, measured improvement; anything smaller is within the noise of this kind of measurement.
    var reliable: Bool { (measuredImprovement ?? 0) >= 0.05 }
}

struct CalibrationFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// Finds the delays that make the room sound least boomy, by trying — and measuring — bold changes.
///
/// 1. Model measurement (≈25 s): the song plays continuously through all speakers at the user's volumes while one speaker
///    at a time is smoothly emphasised (the others fade to 40 %, never above the user's volume). From the recordings of
///    *all* selected microphones, each speaker's arrival time is separated mathematically, and speakers that no microphone
///    can hear (virtual devices) are dropped. This gives a starting point: aligned arrivals and a computed optimum.
/// 2. Search (≈2½ min): a short stretch of the song loops continuously through the audible speakers; every few seconds
///    the delays are changed — first drastically (±200 ms), then ever finer (±80, ±30, ±12, ±5 ms) — and the boominess is
///    *measured* from the recording of all microphones at once. A change is kept only if it measures better. The original
///    setting is measured with the same method, so the reported improvement is a like-for-like measurement.
final class CalibrationRunner {
    /// Analysed stretch of the song per volume setting (model measurement).
    static let segmentSeconds = 4.0
    static let lead = 0.8
    static let rampSeconds = 1.0
    static let searchBudgetSeconds = 150.0
    static let loopSeconds = 3.5
    static let settleSeconds = 0.8
    /// Speakers whose share of what a microphone hears stays below this for every microphone are treated as inaudible.
    static let minShare = 0.05
    private static let analysisRate = 24_000.0
    private static let emphasis = 0.4

    /// Rough duration of the whole measurement for the UI.
    static func estimatedSeconds(speakers: Int, mics: Int, maxDelayMs: Double = 250) -> Double {
        let d = maxDelayMs / 1000
        let period = segmentSeconds + 2 * d + rampSeconds + 0.3
        return lead + d + Double(speakers + 1) * period + 3 + searchBudgetSeconds
    }

    private struct Measurement {
        let response: MicResponse
        let fit: Double
        let shares: [Double]
    }

    /// Box-average down to about 24 kHz so the many analyses in the search stay fast.
    private static func reduce(_ x: [Float], rate: Double) -> [Float] {
        let f = max(1, Int(rate / analysisRate))
        var y = x
        if f > 1 {
            y = (0..<(x.count / f)).map { i in
                var s: Float = 0
                for k in 0..<f { s += x[i * f + k] }
                return s / Float(f)
            }
        }
        return Resample.linear(y, from: rate / Double(f), to: analysisRate)
    }

    func run(speakers: [CalibrationSpeaker], mics: [AudioDeviceInfo],
             progress: @escaping @Sendable (String, Double) -> Void) async throws -> CalibrationReport {
        guard speakers.count >= 2 else { throw CalibrationFailure(message: "출력 장치를 두 개 이상 켜세요") }
        guard !mics.isEmpty else { throw CalibrationFailure(message: "사용할 마이크를 하나 이상 선택하세요") }
        let n = speakers.count, K = n + 1, Lseg = Self.segmentSeconds, ramp = Self.rampSeconds
        let original = speakers.map(\.appliedDelayMs)
        let song = try TestSound.load()
        let fs = song.sampleRate
        let started = Date()
        let expected = Self.estimatedSeconds(speakers: n, mics: mics.count, maxDelayMs: (original.max() ?? 0) + 50)
        func tick(_ label: String) { progress(label, min(0.98, Date().timeIntervalSince(started) / expected)) }

        // MARK: 1. model measurement (all microphones at once)

        let dMax = (original.max() ?? 0) / 1000
        let period = Self.segmentSeconds + 2 * dMax + ramp + 0.3
        var trials = [JointTrial(startSec: 0, gains: [Double](repeating: 1, count: n), delaysMs: original)]
        for k in 1...n {
            trials.append(JointTrial(startSec: 0, gains: (0..<n).map { $0 == k - 1 ? 1 : Self.emphasis }, delaysMs: original))
        }
        func plateau(_ k: Int) -> Double { Self.lead + Double(k) * period }
        for k in trials.indices { trials[k].startSec = plateau(k) + dMax }
        let total = trials[K - 1].startSec + Lseg + dMax + 0.8
        guard let music = song.excerpts(count: 1, seconds: total + 1).first else { throw CalibrationFailure(message: "테스트 음원이 너무 짧습니다") }
        func slice(_ a: Double, _ b: Double) -> [Float] { Array(music[min(music.count, Int(a * fs))..<min(music.count, Int(b * fs))]) }
        func gains(at t: Double) -> [Double] {
            var k = 0
            for j in 1..<K where t >= plateau(j) - ramp { k = j }
            if k == 0 { return trials[0].gains }
            let u = min(1, max(0, (t - (plateau(k) - ramp)) / ramp)), s = u * u * (3 - 2 * u)   // smoothstep
            return (0..<n).map { trials[k - 1].gains[$0] + (trials[k].gains[$0] - trials[k - 1].gains[$0]) * s }
        }

        var measurements: [Measurement] = []
        do {
            let recorders = try mics.map { try MicRecorder(device: $0, seconds: total + 2) }
            let probe = ProbeSource(samples: slice(0, total + 1), sampleRate: fs)
            let engine = try RouterEngine(inputs: [], shared: probe, outputs: speakers.enumerated().map {
                ($1.device, original[$0], $1.volume * trials[0].gains[$0]) })
            defer { engine.stop(); recorders.forEach { $0.stop() } }
            for r in recorders { try r.start() }
            try await Task.sleep(nanoseconds: 300_000_000)
            let t0s = recorders.map(\.count)
            try engine.start()                                  // source time 0
            var last = trials[0].gains
            while probe.elapsed < total {
                try Task.checkCancellation()
                let g = gains(at: probe.elapsed)
                if zip(g, last).contains(where: { abs($0 - $1) > 0.002 }) {
                    last = g
                    for (i, sp) in speakers.enumerated() { engine.setGain(uid: sp.device.uid, Float(sp.volume * g[i])) }
                }
                tick("1/2 · 스피커 위치·시차 파악 중 (모든 기기 + 모든 마이크)")
                try await Task.sleep(nanoseconds: 20_000_000)
            }
            engine.stop(); recorders.forEach { $0.stop() }
            tick("녹음 분석 중…")
            let sources = trials.map { slice($0.startSec, $0.startSec + Lseg) }
            let trialsCopy = trials
            for (mi, r) in recorders.enumerated() {
                let rec = Array(r.samples.dropFirst(t0s[mi])), micRate = r.sampleRate
                measurements.append(await Task.detached(priority: .userInitiated) { () -> Measurement in
                    let probes = sources.map { Resample.linear($0, from: fs, to: micRate) }
                    let response = CalibrationAnalysis.identify(recording: rec, sampleRate: micRate, trials: trialsCopy,
                                                                probes: probes, speakerCount: n, continuous: true)
                    let fits = trialsCopy.indices.map {
                        CalibrationAnalysis.fitQuality(recording: rec, sampleRate: micRate, probe: probes[$0],
                                                       startSec: trialsCopy[$0].startSec, modelSec: 1.0, continuous: true)
                    }
                    // Power in the steady part of every trial → who does this microphone hear at all?
                    let levels = trialsCopy.map { t -> Double in
                        let a = Int((t.startSec + 0.6) * micRate), b = min(rec.count, Int((t.startSec + Lseg) * micRate))
                        guard b > a else { return 0 }
                        var sum = 0.0
                        for i in a..<b { sum += Double(rec[i]) * Double(rec[i]) }
                        return sum / Double(b - a)
                    }
                    let shares = CalibrationAnalysis.audibleShares(levels: levels, gains: trialsCopy.map(\.gains))
                    return Measurement(response: response, fit: fits.reduce(0, +) / Double(fits.count), shares: shares)
                }.value)
            }
        }

        // Every enabled speaker takes part (the user switched it on, so it makes sound). If no microphone hears one
        // well, its delay cannot be judged from the recordings: say so, and leave it where it is unless a measurement
        // shows a change helps.
        var warnings: [String] = []
        let active = Array(0..<n)
        let weak = (0..<n).filter { j in !measurements.contains { j < $0.shares.count && $0.shares[j] >= Self.minShare } }
            .map { speakers[$0].device.name }
        let excludedNames: [String] = []
        if !weak.isEmpty {
            warnings.append("마이크에 거의 잡히지 않은 기기: " + weak.joined(separator: ", ")
                            + " — 이 기기의 지연은 효과를 확인하기 어려워 원래 값에 가깝게 남습니다. 마이크를 가까이 두면 정확해집니다.")
        }
        let m = active.count
        let spk = active.map { speakers[$0] }
        let startOriginal = active.map { original[$0] }

        let seeds = CalibrationAnalysis.seeds(responses: measurements.map(\.response), active: active, original: original)

        // MARK: 2. search: bold changes, each one measured with all microphones

        let Lp = Self.loopSeconds
        guard let loop = song.excerpts(count: 1, seconds: Lp).first, !loop.isEmpty else { throw CalibrationFailure(message: "테스트 음원이 너무 짧습니다") }
        let budget = Self.searchBudgetSeconds
        let loopLen = loop.count
        var tiled = [Float](repeating: 0, count: Int((budget + 40) * fs))
        for i in 0..<tiled.count { tiled[i] = loop[i % loopLen] }

        let recorders = try mics.map { try MicRecorder(device: $0, seconds: budget + 60) }
        let probe = ProbeSource(samples: tiled, sampleRate: fs)
        let engine = try RouterEngine(inputs: [], shared: probe, outputs: spk.enumerated().map { ($1.device, startOriginal[$0], $1.volume) })
        defer { engine.stop(); recorders.forEach { $0.stop() } }
        for r in recorders { try r.start() }
        try await Task.sleep(nanoseconds: 300_000_000)
        let t0s = recorders.map(\.count)
        try engine.start()
        try await Task.sleep(nanoseconds: 1_200_000_000)        // let the loop settle in before the first measurement

        let searchStart = Date()
        var applied = startOriginal
        var evaluations = 0

        /// Applies `delays`, waits for them to take effect and measures the combined boominess (mean over microphones).
        func evaluate(_ delays: [Double], label: String) async throws -> Double? {
            for (i, sp) in spk.enumerated() where abs(applied[i] - delays[i]) > 1e-6 { engine.setDelay(uid: sp.device.uid, ms: delays[i]) }
            applied = delays
            let a = probe.elapsed + Self.settleSeconds                       // analysed stretch starts once the change has taken effect
            while probe.elapsed < a + Lp + 0.15 {
                try Task.checkCancellation()
                let frac = min(0.98, 0.17 + 0.8 * Date().timeIntervalSince(searchStart) / budget)
                progress(label, frac)
                try await Task.sleep(nanoseconds: 20_000_000)
            }
            evaluations += 1
            // The looped excerpt is periodic: whatever phase the window starts at, it holds one full period, rotated.
            let phase = Int((a.truncatingRemainder(dividingBy: Lp)) * fs) % loopLen
            let x = Self.reduce(Array(loop[phase...] + loop[..<phase]), rate: fs)
            var scores: [Double] = []
            for (mi, r) in recorders.enumerated() {
                let rate = r.sampleRate
                let y = Self.reduce(r.samples(from: t0s[mi] + Int((a - 0.1) * rate), to: t0s[mi] + Int((a + Lp) * rate)), rate: rate)
                let score = await Task.detached(priority: .userInitiated) {
                    CalibrationAnalysis.boominess(window: y, sampleRate: Self.analysisRate, probe: x)
                }.value
                guard let score else { return nil }
                scores.append(score)
            }
            return scores.reduce(0, +) / Double(scores.count)
        }

        func describe(_ step: SearchStep) -> String {
            switch step {
            case .seed(let k): return k == 0 ? "2/2 · 원래 설정 측정 중" : (k == 1 ? "2/2 · 정렬한 설정 시험 중" : "2/2 · 계산된 최적 설정 시험 중")
            case .move(let i, let d, let st, let best):
                return "2/2 · \(spk[i].device.name) 지연 \(Int(d)) ms 시험 중 (±\(Int(st)) ms 단계 · 최고 \(String(format: "%.1f", best)))"
            }
        }
        guard let found = try await DelaySearch.run(seeds: seeds, shouldStop: { Date().timeIntervalSince(searchStart) > budget },
                                                    evaluate: { delays, step in try await evaluate(delays, label: describe(step)) })
        else { throw CalibrationFailure(message: "마이크로 측정값을 얻지 못했습니다. 스피커 음량을 올리고 마이크를 스피커 가까이 두세요.") }
        let best = found.best, bestScore = found.bestScore, originalScore = found.originalScore
        let history = found.history, finished = found.finished
        evaluations = found.evaluations

        // Normalise (the least delayed speaker at 0) and map back onto all speakers; excluded ones keep their delay.
        let shift = best.min() ?? 0
        var delays = original
        for (q, j) in active.enumerated() { delays[j] = best[q] - shift }
        let before = originalScore ?? bestScore
        let outcome = CalibrationOutcome(delaysMs: delays, gains: speakers.map { _ in 1 }, scoreBefore: before, scoreAfter: bestScore)
        let fit = measurements.isEmpty ? nil : measurements.map(\.fit).reduce(0, +) / Double(measurements.count)
        return CalibrationReport(outcome: outcome, speakerUIDs: speakers.map(\.device.uid),
                                 speakerNames: speakers.map(\.device.name), micsUsed: mics.map(\.name), warnings: warnings,
                                 excluded: excludedNames, measuredBefore: originalScore, measuredAfter: bestScore,
                                 searchHistory: history, evaluations: evaluations, finished: finished, fit: fit)
    }
}

enum Resample {
    /// Linear-interpolation resampler (the excerpts only need to line up with the microphone's clock).
    static func linear(_ x: [Float], from a: Double, to b: Double) -> [Float] {
        guard a != b, x.count > 1 else { return x }
        let n = Int(Double(x.count) * b / a)
        return (0..<n).map { i in
            let p = Double(i) * a / b, k = min(Int(p), x.count - 2), f = Float(p - Double(k))
            return x[k] + (x[k + 1] - x[k]) * f
        }
    }
}
