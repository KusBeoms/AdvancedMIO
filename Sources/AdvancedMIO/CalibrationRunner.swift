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
    /// The delays every speaker had before (same order as `speakerUIDs`) — for listening to before / after.
    let originalDelaysMs: [Double]
    /// Reference only: how the speakers' levels would have to change for every microphone position to hear the same level.
    let balance: VolumeBalance.Suggestion?
    /// How many compute → measure rounds were run and how far the measurements corrected the model's arrival times.
    let rounds: Int
    let modelCorrectionMs: [Double]

    var measuredImprovement: Double? {
        guard let b = measuredBefore, let a = measuredAfter, b > 0 else { return nil }
        return (b - a) / b
    }
    /// A clear, measured improvement; anything smaller is within the noise of this kind of measurement.
    var reliable: Bool { (measuredImprovement ?? 0) >= 0.05 }
}

/// Lets the UI watch and steer a running calibration from the main thread.
final class CalibrationControl: @unchecked Sendable {
    private let lock = NSLock()
    private var _finishRequested = false
    private var _improvement: Double?
    private var _searching = false
    var finishRequested: Bool { lock.lock(); defer { lock.unlock() }; return _finishRequested }
    /// Best measured improvement so far (0…1), once the original and a computed setting have been measured.
    var improvement: Double? { lock.lock(); defer { lock.unlock() }; return _improvement }
    /// True once there is a model and measurements to stop on.
    var searching: Bool { lock.lock(); defer { lock.unlock() }; return _searching }
    func requestFinish() { lock.lock(); _finishRequested = true; lock.unlock() }
    func update(improvement: Double?) { lock.lock(); _improvement = improvement; lock.unlock() }
    func setSearching() { lock.lock(); _searching = true; lock.unlock() }
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
    static let searchBudgetSeconds = 100.0
    static let settleSeconds = 0.5
    static let loopIterations = 12
    /// Speakers whose share of what a microphone hears stays below this for every microphone are treated as inaudible.
    static let minShare = 0.05
    private static let analysisRate = 24_000.0
    private static let emphasis = 0.1

    /// Rough duration of the whole measurement for the UI: identification, the computation, then at most `searchBudgetSeconds`
    /// of measuring (typically 8–12 measurements of a few seconds each).
    static func estimatedSeconds(speakers: Int, mics: Int, maxDelayMs: Double = 250) -> Double {
        let d = maxDelayMs / 1000
        let period = segmentSeconds + 2 * d + rampSeconds + 0.3
        let measureOnce = settleSeconds + (d > 0.2 ? 5.5 : 2.8) + 0.2
        return lead + d + Double(speakers + 1) * period + 3 + 12 + min(searchBudgetSeconds, 10 * measureOnce)
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

    func run(speakers: [CalibrationSpeaker], mics: [AudioDeviceInfo], control: CalibrationControl = CalibrationControl(),
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
                                                                probes: probes, speakerCount: n,
                                                                irSec: CalibrationAnalysis.responseSeconds, continuous: true)
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
        if let weakest = CalibrationAnalysis.weakestSNR(measurements.map(\.response)), weakest < CalibrationAnalysis.minReliableSNR {
            warnings.append("일부 스피커의 소리가 주변 소음에 비해 약하게 잡혀 위치를 정확히 알기 어려웠습니다 (가장 약한 스피커: 소음의 \(Int(weakest))배). 말소리·TV·청소기 같은 주변 소리를 줄이거나, 마이크를 가까이 두거나, 작은 스피커의 음량을 올려 다시 측정하면 더 정확합니다.")
        }
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

        // MARK: 2. the model and the looping programme

        // Microphones that identified every speaker carry the model; recorders are only needed for those.
        let usable = measurements.indices.filter { qi in active.allSatisfy { measurements[qi].response.speakers[$0] != nil } }
        guard !usable.isEmpty else {
            throw CalibrationFailure(message: "모든 스피커 소리를 식별한 마이크가 없습니다. 마이크를 스피커 가까이 두고 다시 시도하세요.")
        }
        let modelMics = CalibrationAnalysis.restrict(measurements.map(\.response), to: active)
        let modelMics24 = modelMics.map { $0.resampled(to: Self.analysisRate) }

        // The looping programme. Its period (a power of two at the analysis rate) must exceed the longest lag plus one
        // speaker's response, or the analysis window would cut the response off.
        let arrivals = modelMics.flatMap { $0.speakers.compactMap { $0?.arrival } }
        let maxArrival = arrivals.max() ?? 0, minArrival = arrivals.min() ?? 0
        let needed = maxArrival + (maxArrival - minArrival) + 0.3 + CalibrationAnalysis.responseSeconds
        let periodSamples = needed <= 65536.0 / Self.analysisRate ? 65536 : 131072
        let Lp = Double(periodSamples) / Self.analysisRate
        guard let loop = song.excerpts(count: 1, seconds: Lp).first, !loop.isEmpty else { throw CalibrationFailure(message: "테스트 음원이 너무 짧습니다") }
        var probe24 = Self.reduce(loop, rate: fs)
        if probe24.count > periodSamples { probe24 = Array(probe24.prefix(periodSamples)) }
        else if probe24.count < periodSamples { probe24 += [Float](repeating: 0, count: periodSamples - probe24.count) }
        let programme = Programme(probe: probe24, rate: Self.analysisRate)
        let budget = Self.searchBudgetSeconds
        let loopLen = loop.count
        var tiled = [Float](repeating: 0, count: Int((budget + 60) * fs))
        for i in 0..<tiled.count { tiled[i] = loop[i % loopLen] }

        // MARK: 3. closed loop: compute (DelayAI + digital twin) → apply → measure at once, music never stopping

        let recorders = try usable.map { try MicRecorder(device: mics[$0], seconds: budget + 90) }
        let probe = ProbeSource(samples: tiled, sampleRate: fs)
        let engine = try RouterEngine(inputs: [], shared: probe, outputs: spk.enumerated().map { ($1.device, startOriginal[$0], $1.volume) })
        defer { engine.stop(); recorders.forEach { $0.stop() } }
        for r in recorders { try r.start() }
        try await Task.sleep(nanoseconds: 300_000_000)
        let t0s = recorders.map(\.count)
        try engine.start()
        try await Task.sleep(nanoseconds: 1_200_000_000)        // let the loop settle in before the first measurement
        control.setSearching()

        let searchStart = Date()
        var applied = startOriginal
        var evaluations = 0

        /// Applies `delays`, waits for them to take effect, and returns the recovered combined response at every microphone.
        func measureAt(_ delays: [Double], label: String) async throws -> Measured? {
            for (i, sp) in spk.enumerated() where abs(applied[i] - delays[i]) > 1e-6 { engine.setDelay(uid: sp.device.uid, ms: delays[i]) }
            applied = delays
            let a = probe.elapsed + Self.settleSeconds                       // analysed stretch starts once the change has taken effect
            while probe.elapsed < a + Lp + 0.15 {
                try Task.checkCancellation()
                progress(label, min(0.98, 0.25 + 0.7 * Date().timeIntervalSince(searchStart) / budget))
                try await Task.sleep(nanoseconds: 20_000_000)
            }
            // The looped excerpt is periodic: whatever phase the window starts at, it holds one full period, rotated.
            let phase = Int((a.truncatingRemainder(dividingBy: Lp)) * fs) % loopLen
            let x = Self.reduce(Array(loop[phase...] + loop[..<phase]), rate: fs)
            var observations: [Observation] = []
            for (q, r) in recorders.enumerated() {
                let rate = r.sampleRate
                let y = Self.reduce(r.samples(from: t0s[q] + Int((a - 0.1) * rate), to: t0s[q] + Int((a + Lp) * rate)), rate: rate)
                let arr = modelMics[q].speakers.map { $0!.arrival }
                let t = zip(arr, delays).map { $0 + $1 / 1000 }
                let onsetSec = t.min() ?? 0, spreadSec = (t.max() ?? 0) - onsetSec
                let m = await Task.detached(priority: .userInitiated) {
                    CalibrationAnalysis.measure(window: y, sampleRate: Self.analysisRate, probe: x, onsetSec: onsetSec, spreadSec: spreadSec)
                }.value
                guard let m else { return nil }
                observations.append(Observation(mic: q, delaysMs: delays, ir: m.ir, pad: m.pad))
            }
            return Measured(observations: observations)
        }

        func describe(_ step: PlanStep) -> String {
            switch step {
            case .original: return "3/3 · 현재 설정 측정 중"
            case .candidate(let round, _): return "3/3 · 계산된 설정 \(round + 1)차 적용하고 바로 측정 중"
            case .local(let t):
                switch t {
                case .model(let r): return "3/3 · 계산한 보정을 적용하고 바로 확인 중 (±\(Int(r)) ms 이내)"
                case .explore(let r): return "3/3 · 주변을 시험 중 (±\(Int(r)) ms)"
                case .confirm: return "3/3 · 좋아 보이는 설정을 한 번 더 확인 중"
                default: return "3/3 · 현재 최선을 다시 측정 중"
                }
            }
        }

        progress("2/3 · 최적 지연 계산 중 (경사하강법 + 디지털 트윈)", 0.22)
        guard let plan = try await CalibrationPlanner.run(
            model: modelMics24, programme: programme, original: startOriginal, maxRounds: 3, repeats: 2,
            localIterations: Self.loopIterations,
            compute: { model in
                await Task.detached(priority: .userInitiated) {
                    CalibrationPlanner.computeBest(model: model, programme: programme, original: startOriginal)
                }.value
            },
            shouldStop: { control.finishRequested || Date().timeIntervalSince(searchStart) > budget },
            onBest: { _, best, start in
                if let start, start > 0 { control.update(improvement: max(0, (start - best) / start)) }
            },
            measure: { delays, step in try await measureAt(delays, label: describe(step)) })
        else { throw CalibrationFailure(message: "마이크로 측정값을 얻지 못했습니다. 스피커 음량을 올리고 마이크를 스피커 가까이 두세요.") }
        let best = plan.best, bestScore = plan.bestScore, originalScore = plan.startScore
        // keep the history short enough to show
        let history: [Double] = plan.history.count <= 12 ? plan.history
            : (0..<12).map { plan.history[$0 * (plan.history.count - 1) / 11] }
        let finished = plan.finished
        evaluations = plan.evaluations
        if plan.noise > 0.1 {
            warnings.append("같은 설정을 다시 측정해도 값이 \(Int(plan.noise * 100))% 정도 흔들립니다 (블루투스 지연 변동 등). 작은 개선은 확인할 수 없어, 계산 결과를 우선했습니다.")
        }
        if control.finishRequested { warnings.append("요청에 따라 측정을 일찍 마치고 지금까지의 최선을 사용했습니다.") }
        let balance = VolumeBalance.power(from: modelMics).flatMap { VolumeBalance.suggest(power: $0) }

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
                                 searchHistory: history, evaluations: evaluations, finished: finished, fit: fit,
                                 originalDelaysMs: original, balance: balance, rounds: plan.rounds, modelCorrectionMs: plan.biasMs)
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
