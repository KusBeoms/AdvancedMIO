import Foundation
import MIOCore

/// Files and settings of the developer page.
enum DevStore {
    static let weightKey = "dev.lateWeight"

    static var dir: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("AdvancedMIO")
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }
    static var votesURL: URL { dir.appendingPathComponent("ab-votes.json") }
    static var roomURL: URL { dir.appendingPathComponent("last-room.json") }

    /// Called at launch: the boominess index uses the weight fitted by the listening test, if there is one.
    static func applySavedWeight() {
        guard let w = UserDefaults.standard.object(forKey: weightKey) as? Double else { return }
        RoomOptimizer.lateWeight = max(0, w)
    }
    static func saveWeight(_ w: Double) {
        UserDefaults.standard.set(w, forKey: weightKey)
        RoomOptimizer.lateWeight = w
    }
    static func resetWeight() {
        UserDefaults.standard.removeObject(forKey: weightKey)
        RoomOptimizer.lateWeight = RoomOptimizer.defaultLateWeight
    }

    static func loadVotes() -> [ABVote] {
        (try? Data(contentsOf: votesURL)).flatMap { try? JSONDecoder().decode([ABVote].self, from: $0) } ?? []
    }
    static func saveVotes(_ v: [ABVote]) { try? JSONEncoder().encode(v).write(to: votesURL, options: .atomic) }

    /// The room identified by the last calibration (first microphone), for the listening test.
    static func saveRoom(_ room: MicResponse) { try? JSONEncoder().encode(room).write(to: roomURL, options: .atomic) }
    static func loadRoom() -> MicResponse? {
        guard let d = try? Data(contentsOf: roomURL), let r = try? JSONDecoder().decode(MicResponse.self, from: d),
              r.speakers.allSatisfy({ $0 != nil }), !r.speakers.isEmpty else { return nil }
        return r
    }
}

enum RoomChoice { case mine, synthetic }
enum ABSide { case a, b }

/// State of the developer page: the A/B listening test and the boominess weight fitted from its answers.
@MainActor
final class DevLab: ObservableObject {
    struct Trial {
        let a: ABStimulus, b: ABStimulus
        let bufA: [Float], bufB: [Float]
    }

    @Published var roomChoice: RoomChoice = .synthetic
    @Published private(set) var hasMyRoom = false
    @Published private(set) var votes: [ABVote] = []
    @Published private(set) var lateWeight = RoomOptimizer.lateWeight
    @Published private(set) var trial: Trial?
    @Published private(set) var playing: ABSide?
    @Published private(set) var preparing = false
    @Published var outputUID: String?
    @Published var volume = 0.4 { didSet { engine?.setGain(uid: playingUID ?? "", Float(volume)) } }
    @Published var message: String?

    private var engine: RouterEngine?
    private var source: ABSource?
    private var playingUID: String?
    private var rng = DelayAI.SplitMix(seed: UInt64(Date().timeIntervalSince1970 * 1000))
    private var myRoom: MicResponse?
    private var programme: [Float]?

    /// The room chosen on the page, nil for the synthetic one.
    var chosenRoom: MicResponse? { roomChoice == .mine ? myRoom : nil }

    var fit: PreferenceFit.Result { PreferenceFit.fit(votes: votes, defaultWeight: RoomOptimizer.defaultLateWeight) }

    func load() {
        votes = DevStore.loadVotes()
        lateWeight = RoomOptimizer.lateWeight
        myRoom = DevStore.loadRoom()
        hasMyRoom = myRoom != nil
        if myRoom != nil, trial == nil { roomChoice = .mine }
        if myRoom == nil { roomChoice = .synthetic }
    }

    func chooseRoom(_ c: RoomChoice) {
        guard c == .synthetic || hasMyRoom else { return }
        roomChoice = c
        stop(); trial = nil
    }

    func nextTrial(devices: [AudioDeviceInfo]) {
        guard !preparing else { return }
        preparing = true; message = nil
        stop()
        let room: MicResponse = (roomChoice == .mine ? myRoom : nil) ?? SyntheticRoom.make(seed: rng.next())
        let weight = lateWeight
        let seed = rng.next()
        Task {
            do {
                let programme = try loadProgramme()
                let made = await Task.detached(priority: .userInitiated) { () -> Trial? in
                    var r = DelayAI.SplitMix(seed: seed)
                    guard let (a, b) = ListeningTest.makePair(room: room, weight: weight, rng: &r),
                          let x = ListeningTest.render(room: room, delaysMs: a.delaysMs, programme: programme),
                          let y = ListeningTest.render(room: room, delaysMs: b.delaysMs, programme: programme) else { return nil }
                    return Trial(a: a, b: b, bufA: x, bufB: y)
                }.value
                preparing = false
                guard let made else { message = "이 방 모델로는 비교할 쌍을 만들지 못했습니다"; return }
                trial = made
                play(.a, devices: devices)
            } catch {
                preparing = false
                message = error.localizedDescription
            }
        }
    }

    /// The whole test song at the analysis rate (the room models are at 24 kHz).
    private func loadProgramme() throws -> [Float] {
        if let p = programme { return p }
        let song = try TestSound.load()
        let p = CalibrationRunner.reduce(song.fullMono(), rate: song.sampleRate)
        guard p.count > 24_000 else { throw IOError(message: "테스트 음원이 너무 짧습니다") }
        programme = p
        return p
    }

    func play(_ side: ABSide, devices: [AudioDeviceInfo]) {
        guard let t = trial else { return }
        if engine == nil {
            guard let uid = outputUID, let dev = devices.first(where: { $0.uid == uid }) else { message = "재생할 장치를 고르세요"; return }
            do {
                let s = ABSource(a: t.bufA, b: t.bufB, sampleRate: 24_000)
                let e = try RouterEngine(inputs: [], shared: s, outputs: [(dev, 0, volume)])
                try e.start()
                engine = e; source = s; playingUID = uid
            } catch { message = error.localizedDescription; return }
        }
        source?.select(b: side == .b)
        playing = side
    }

    func stop() {
        engine?.stop(); engine = nil; source = nil; playingUID = nil
        playing = nil
    }

    func vote(_ choice: ABChoice, room: String, devices: [AudioDeviceInfo]) {
        guard let t = trial else { return }
        votes.append(ABVote(date: Date().timeIntervalSince1970, room: room, a: t.a, b: t.b, choice: choice))
        DevStore.saveVotes(votes)
        trial = nil
        nextTrial(devices: devices)
    }

    func applyFit() {
        let w = fit.weight
        DevStore.saveWeight(w)
        lateWeight = w
    }
    func resetWeight() { DevStore.resetWeight(); lateWeight = RoomOptimizer.lateWeight }
    func clearVotes() { votes = []; DevStore.saveVotes([]) }
}
