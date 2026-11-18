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
