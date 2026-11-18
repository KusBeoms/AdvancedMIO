import Foundation
import XCTest
import MIOCore

final class BluetoothControlTests: XCTestCase {
    func testRequestRoundTrip() {
        let request = BluetoothControlRequest(code: "012345", action: .zero)
        XCTAssertEqual(request?.data, Data("012345 zero".utf8))
        XCTAssertEqual(BluetoothControlRequest(data: Data("012345 zero".utf8)), request)
        XCTAssertEqual(BluetoothControlRequest(data: Data("012345".utf8))?.action, nil)
    }

    func testRejectsMalformedRequests() {
        XCTAssertNil(BluetoothControlRequest(code: "12345"))
        XCTAssertNil(BluetoothControlRequest(code: "12345a"))
        XCTAssertNil(BluetoothControlRequest(data: Data("123456 dance".utf8)))
        XCTAssertNil(BluetoothControlRequest(data: Data("123456  start".utf8)))
        XCTAssertNil(BluetoothControlRequest(data: Data("12345".utf8)))
    }

    func testGateAllowsCorrectCodeAndRejectsWrongOne() {
        var gate = BluetoothAccessGate()
        let good = BluetoothControlRequest(code: gate.code)!
        let bad = BluetoothControlRequest(code: gate.code == "000000" ? "000001" : "000000")!
        XCTAssertEqual(gate.authorize(bad, uptime: 0), .wrongCode)
        XCTAssertEqual(gate.authorize(good, uptime: 1), .allowed)
    }

    func testFiveWrongCodesRotateCodeAndLockOutFor30Seconds() {
        var gate = BluetoothAccessGate()
        let first = gate.code
        let bad = BluetoothControlRequest(code: first == "000000" ? "000001" : "000000")!
        for _ in 0..<4 { XCTAssertEqual(gate.authorize(bad, uptime: 10), .wrongCode) }
        XCTAssertEqual(gate.authorize(bad, uptime: 10), .rateLimited)
        XCTAssertNotEqual(gate.code, first)
        let good = BluetoothControlRequest(code: gate.code)!
        XCTAssertEqual(gate.authorize(good, uptime: 39), .rateLimited)
        XCTAssertEqual(gate.authorize(good, uptime: 40), .allowed)
    }
}
