import Foundation

extension CalibrationAnalysis {
    /// How long each speaker's response is identified (the room's reverb is not needed for timing, but a long window keeps
    /// the late energy out of the direct sound's estimate).
    public static let responseSeconds = 2.0

    /// The weakest speaker's peak-to-noise ratio over all microphones; below `minReliableSNR` the arrival times found by the
    /// identification cannot be trusted (loud talking, a TV, a vacuum cleaner while measuring).
    public static func weakestSNR(_ responses: [MicResponse]) -> Double? {
        responses.flatMap { $0.speakers.compactMap { $0?.snr } }.min()
    }
    public static let minReliableSNR = 15.0

    /// The microphones' responses restricted to `active` speakers, keeping only microphones that identified all of them.
    public static func restrict(_ responses: [MicResponse], to active: [Int]) -> [MicResponse] {
        responses.filter { r in active.allSatisfy { $0 < r.speakers.count && r.speakers[$0] != nil } }
            .map { r in MicResponse(sampleRate: r.sampleRate, speakers: active.map { r.speakers[$0] }) }
    }

    /// Per-speaker arrival time at the microphone (seconds, the applied delay removed), averaged over the microphones that
    /// identified every speaker; nil if there is none.
    public static func meanArrivals(_ responses: [MicResponse]) -> [Double]? {
        guard let n = responses.first?.speakers.count, n > 0 else { return nil }
        let full = restrict(responses, to: Array(0..<n))
        guard !full.isEmpty else { return nil }
        return (0..<n).map { i in full.map { $0.speakers[i]!.arrival }.reduce(0, +) / Double(full.count) }
    }

    /// Per-speaker delays (ms, smallest = 0) that make every speaker's sound reach the microphone at the same moment.
    /// Delays above `maxDelayMs` are capped. nil unless some microphone identified every speaker.
    public static func alignedDelays(_ responses: [MicResponse], maxDelayMs: Double = 1000) -> [Double]? {
        guard let arrival = meanArrivals(responses) else { return nil }
        let latest = arrival.max() ?? 0
        let d = arrival.map { min(maxDelayMs, max(0, (latest - $0) * 1000)) }
        let low = d.min() ?? 0
        return d.map { $0 - low }
    }

    /// Spread (ms) of the arrival times for the given applied delays, averaged over the microphones that heard every speaker.
    public static func arrivalSpreadMs(_ responses: [MicResponse], delaysMs: [Double]) -> Double? {
        guard let n = responses.first?.speakers.count, delaysMs.count == n else { return nil }
        let full = restrict(responses, to: Array(0..<n))
        guard !full.isEmpty else { return nil }
        let s = full.map { m -> Double in
            let t = (0..<n).map { m.speakers[$0]!.arrival * 1000 + delaysMs[$0] }
            return (t.max() ?? 0) - (t.min() ?? 0)
        }
        return s.reduce(0, +) / Double(s.count)
    }
}
