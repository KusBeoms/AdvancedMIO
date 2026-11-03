import Foundation
import MIOCore

/// The developer page's 울림 slider: pick one of the candidate definitions, and a slider moves between the settings of the
/// room where that definition reads smallest and clearly large, playing the test song as it would sound at each.
@MainActor
final class ResonanceLab: ObservableObject {
    nonisolated static let steps = 9

    @Published var metric: ResonanceMetric = .lateRatio { didSet { if metric != oldValue { metricChanged() } } }
    @Published var position = 0 { didSet { if position != oldValue { source?.select(position) } } }
    @Published var volume = 0.4 { didSet { engine?.setGain(uid: playingUID ?? "", Float(volume)) } }
    @Published private(set) var ladder: ResonanceLadder?
    @Published private(set) var preparing = false
    @Published private(set) var playing = false
    @Published var message: String?

    private var room: MicResponse?
    private var roomName = ""
    private var ladders: [ResonanceMetric: ResonanceLadder] = [:]
    private var programme: [Float]?
    private var engine: RouterEngine?
    private var source: LadderSource?
    private var playingUID: String?
    private var device: (AudioDeviceInfo, String)?
    private var generation = 0

    /// Called when the page opens or the room choice changes.
    func setRoom(_ r: MicResponse?, name: String) {
        if room != nil, name == roomName { return }
        stop()
        room = r ?? SyntheticRoom.make(seed: 7)
        roomName = name
        ladders = [:]; ladder = nil; message = nil
        generation += 1
    }

    var currentValue: Double? { ladder.flatMap { position < $0.steps.count ? $0.steps[position].value : nil } }
    var minValue: Double? { ladder?.steps.first?.value }
    var maxValue: Double? { ladder?.steps.last?.value }

    func play(on device: AudioDeviceInfo) {
        stop()
        self.device = (device, device.uid)
        preparing = true; message = nil
        let m = metric, gen = generation
        guard let room else { return }
        let cached = ladders
        Task {
            do {
                let programme = try loadProgramme()
                let made = await Task.detached(priority: .userInitiated) { () -> ([ResonanceMetric: ResonanceLadder], [[Float]])? in
                    let all = cached.isEmpty ? ResonanceLadderBuilder.build(room: room, steps: Self.steps) : cached
                    guard let l = all[m] else { return nil }
                    var bufs: [[Float]] = []
                    for s in l.steps {
                        guard let b = ListeningTest.render(room: room, delaysMs: s.delaysMs, programme: programme) else { return nil }
                        bufs.append(b)
                    }
                    return (all, bufs)
                }.value
                guard gen == generation, m == metric else { preparing = false; return }
                preparing = false
                guard let (all, bufs) = made, let l = all[m] else { message = "이 방 모델로는 단계를 만들지 못했습니다"; return }
                ladders = all; ladder = l      // the other candidates' settings are kept, so switching only has to render
                position = min(position, l.steps.count - 1)
                start(bufs, device: device)
            } catch {
                preparing = false
                message = error.localizedDescription
            }
        }
    }

    private func start(_ bufs: [[Float]], device: AudioDeviceInfo) {
        do {
            let s = LadderSource(buffers: bufs, sampleRate: 24_000)
            s.select(position)
            let e = try RouterEngine(inputs: [], shared: s, outputs: [(device, 0, volume)])
            try e.start()
            engine = e; source = s; playingUID = device.uid; playing = true
        } catch { message = error.localizedDescription }
    }

    func stop() {
        engine?.stop(); engine = nil; source = nil; playingUID = nil
        playing = false
    }

    private func metricChanged() {
        let wasPlaying = playing || preparing
        let dev = device?.0
        stop()
        ladder = nil
        generation += 1
        if wasPlaying, let dev { play(on: dev) }
    }

    private func loadProgramme() throws -> [Float] {
        if let p = programme { return p }
        let song = try TestSound.load()
        let p = CalibrationRunner.reduce(song.fullMono(), rate: song.sampleRate)
        guard p.count > 24_000 else { throw IOError(message: "테스트 음원이 너무 짧습니다") }
        programme = p
        return p
    }
}
