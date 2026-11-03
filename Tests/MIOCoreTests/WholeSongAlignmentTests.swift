import XCTest
@testable import MIOCore

/// The calibration plays the whole song once while every speaker in turn is emphasised, then solves the arrival times from
/// the complete recording. This runs that against a simulated room.
final class WholeSongAlignmentTests: XCTestCase {
    func testArrivalsFromAWholeSongRecording() {
        let fs = 24_000.0, n = 3, K = n + 1
        let room = SyntheticRoom.make(speakers: n, seed: 21, sampleRate: fs, seconds: 1.0)
        let applied = [0.0, 35.0, 12.0]                                   // ms, what the router applies when measuring
        let song = CalibrationSimulationTests.musicLoop(period: Int(80 * fs), fs: fs, seed: 4)
        let Lseg = 4.0, ramp = 1.0, lead = 0.8, emphasis = 0.1
        let dMax = applied.max()! / 1000
        let period = Lseg + 2 * dMax + ramp + 0.3
        let P = ((Int((80 - 1 - lead - 2 * dMax - Lseg - 0.8) / period) + 1) / K) * K
        XCTAssertGreaterThanOrEqual(P, 2 * K)
        var trials: [JointTrial] = []
        for p in 0..<P {
            let k = p % K
            trials.append(JointTrial(startSec: lead + Double(p) * period + dMax,
                                     gains: (0..<n).map { k == 0 || $0 == k - 1 ? 1 : emphasis }, delaysMs: applied))
        }
        func plateau(_ p: Int) -> Double { lead + Double(p) * period }
        func gains(at t: Double) -> [Double] {
            var k = 0
            for j in 1..<P where t >= plateau(j) - ramp { k = j }
            if k == 0 { return trials[0].gains }
            let u = min(1, max(0, (t - (plateau(k) - ramp)) / ramp)), s = u * u * (3 - 2 * u)
            return (0..<n).map { trials[k - 1].gains[$0] + (trials[k].gains[$0] - trials[k - 1].gains[$0]) * s }
        }

        var rec = [Double](repeating: 0, count: song.count)
        var rng = DelayAI.SplitMix(seed: 8)
        for i in 0..<n {
            let sp = room.speakers[i]!
            let x = (0..<song.count).map { Float(Double(song[$0]) * gains(at: Double($0) / fs)[i]) }
            let y = ListeningTest.convolve(x, with: sp.h, wrap: false)
            let lag = Int(((sp.arrival + applied[i] / 1000) * fs).rounded()) - sp.pre
            for t in 0..<song.count where t - lag >= 0 && t - lag < y.count { rec[t] += y[t - lag] }
        }
        let recording = rec.map { Float($0 + 0.003 * rng.normal()) }
        let probes = trials.map { Array(song[Int($0.startSec * fs)..<Int(($0.startSec + Lseg) * fs)]) }
        let r = CalibrationAnalysis.identify(recording: recording, sampleRate: fs, trials: trials, probes: probes, speakerCount: n,
                                             irSec: CalibrationAnalysis.responseSeconds, continuous: true)
        let got = r.speakers.map { $0?.arrival }
        XCTAssertTrue(got.allSatisfy { $0 != nil }, "\(got)")
        // only differences between speakers mean anything
        let base = room.speakers[0]!.arrival, gbase = got[0] ?? 0
        for i in 1..<n {
            let want = (room.speakers[i]!.arrival - base) * 1000, have = ((got[i] ?? 0) - gbase) * 1000
            XCTAssertEqual(have, want, accuracy: 0.5, "speaker \(i)")
        }
        // the delays that align them
        let d = CalibrationAnalysis.alignedDelays([r])!
        let t = (0..<n).map { room.speakers[$0]!.arrival * 1000 + d[$0] }
        XCTAssertEqual(t.max()! - t.min()!, 0, accuracy: 0.5)
        XCTAssertEqual(d.min()!, 0, accuracy: 1e-9)
    }
}
