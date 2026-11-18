import Foundation
import XCTest
import MIOCore

final class BluetoothAudioFramingTests: XCTestCase {
    func testFramesSurviveArbitraryChunking() {
        let stream = AudioFraming.hello(code: "123456", cookie: Data([1, 2, 3]))!
            + AudioFraming.encode(.audio, Data(repeating: 7, count: 300))
            + AudioFraming.encode(.audio, Data([9]))
        var parser = AudioFrameParser()
        var frames: [AudioFrame] = []
        for start in stride(from: 0, to: stream.count, by: 5) {
            frames += parser.feed(stream[start..<min(start + 5, stream.count)])!
        }
        XCTAssertEqual(frames.map(\.type), [.hello, .audio, .audio])
        XCTAssertEqual(frames[1].body.count, 300)
        let hello = AudioFraming.parseHello(frames[0].body)
        XCTAssertEqual(hello?.code, "123456")
        XCTAssertEqual(hello?.cookie, Data([1, 2, 3]))
    }

    func testRejectsInvalidStreams() {
        var zero = AudioFrameParser(); XCTAssertNil(zero.feed(Data([0, 0, 1])))
        var huge = AudioFrameParser(); XCTAssertNil(huge.feed(Data([0xFF, 0xFF, 1])))
        var unknown = AudioFrameParser(); XCTAssertNil(unknown.feed(Data([2, 0, 99, 0])))
    }

    func testHelloRequiresSixDigitCode() {
        XCTAssertNil(AudioFraming.hello(code: "12345", cookie: Data()))
        XCTAssertNil(AudioFraming.parseHello(Data("AMIOabcdef\u{0}".utf8)))
    }
}

final class AudioPacketTests: XCTestCase {
    func testPacketRoundTrip() {
        let packet = AudioPacket(sequence: 0x0102_0304, sendMs: 0xFFFF_FFFE, payload: Data([1, 2, 3, 4, 5]))
        var parser = AudioFrameParser()
        let frames = parser.feed(packet.frame)!
        XCTAssertEqual(frames.count, 1)
        XCTAssertEqual(frames[0].type, .audio)
        XCTAssertEqual(AudioPacket(body: frames[0].body), packet)
        XCTAssertNil(AudioPacket(body: Data(repeating: 0, count: 8)))      // header only: no audio
    }

    func testAckRoundTrip() {
        let ack = AudioAck(sequence: 7, echoSendMs: 123_456, bufferMs: 130, outputLagMs: 292)
        var parser = AudioFrameParser()
        let frames = parser.feed(ack.frame)!
        XCTAssertEqual(frames[0].type, .ack)
        XCTAssertEqual(AudioAck(body: frames[0].body), ack)
        XCTAssertNil(AudioAck(body: Data(count: 11)))
    }
}

final class JitterBufferTests: XCTestCase {
    private func block(_ v: Float) -> JitterBuffer.Block {
        JitterBuffer.Block(left: [Float](repeating: v, count: 1024), right: [Float](repeating: v, count: 1024))
    }

    private func value(_ o: JitterBuffer.Output) -> Float? {
        if case .block(let b) = o { return b.left[0] }
        return nil
    }

    func testPlaysNothingUntilTheCushionIsFilledThenInOrder() {
        var j = JitterBuffer(target: 3, minTarget: 2, maxTarget: 6)
        j.push(block(1)); j.push(block(2))
        guard case .priming = j.pop() else { return XCTFail("should still be priming") }
        j.push(block(3))
        XCTAssertEqual(value(j.pop()), 1)
        XCTAssertEqual(value(j.pop()), 2)
        XCTAssertEqual(value(j.pop()), 3)
    }

    func testUnderrunGrowsTheCushionAndRebuffers() {
        var j = JitterBuffer(target: 2, minTarget: 2, maxTarget: 4)
        j.push(block(1)); j.push(block(2))
        _ = j.pop(); _ = j.pop()
        guard case .underrun = j.pop() else { return XCTFail("expected underrun") }
        XCTAssertEqual(j.underruns, 1)
        XCTAssertEqual(j.target, 3)
        j.push(block(3)); j.push(block(4))
        guard case .priming = j.pop() else { return XCTFail("rebuffers up to the new target") }
    }

    func testBurstDropsOldestNotNewest() {
        var j = JitterBuffer(target: 2, minTarget: 2, maxTarget: 4)
        for v in 1...8 { j.push(block(Float(v))) }
        XCTAssertGreaterThan(j.dropped, 0)
        XCTAssertLessThanOrEqual(j.depth, j.target + 3)
        var last: Float = 0
        while let v = value(j.pop()) { last = v }
        XCTAssertEqual(last, 8)
    }

    func testPlayoutRateStaysWithinOnePercentAndPointsTowardTheTarget() {
        var j = JitterBuffer(target: 4, minTarget: 4, maxTarget: 8)
        for v in 1...4 { j.push(block(Float(v))) }
        _ = j.pop()                                   // primed; 3 left, one below the target
        XCTAssertLessThan(j.playoutRate, 1)
        XCTAssertGreaterThanOrEqual(j.playoutRate, 0.99)
        j.push(block(9)); j.push(block(10)); j.push(block(11))
        XCTAssertGreaterThan(j.playoutRate, 1)
        XCTAssertLessThanOrEqual(j.playoutRate, 1.01)
    }

    func testCushionShrinksAfterACalmPeriod() {
        var j = JitterBuffer(target: 4, minTarget: 2, maxTarget: 8, calmSeconds: 0.1)   // ≈ 5 blocks
        for _ in 0..<40 {
            j.push(block(1)); j.push(block(1))
            _ = j.pop()
        }
        XCTAssertLessThan(j.target, 4)
    }
}
