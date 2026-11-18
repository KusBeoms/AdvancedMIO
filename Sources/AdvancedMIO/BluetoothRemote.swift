@preconcurrency import CoreBluetooth
import MIOCore
import SwiftUI

@MainActor
final class BluetoothRemote: NSObject, ObservableObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    /// One connection for the whole app: closing the connection window must not drop it.
    static let shared = BluetoothRemote()

    enum Phase { case idle, scanning, connecting, enteringCode, authenticating, connected }

    struct Device: Identifiable {
        fileprivate let peripheral: CBPeripheral
        let name: String
        var id: UUID { peripheral.identifier }
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var devices: [Device] = []
    @Published private(set) var deviceName = ""
    @Published private(set) var message: String?
    @Published private(set) var lastAction: BluetoothControlAction?
    @Published private var pending: BluetoothControlRequest?
    var sending: Bool { pending != nil }

    private var central: CBCentralManager?
    private var connection: CBPeripheral?
    private var control: CBCharacteristic?
    private var code: String?
    private var timeout: Task<Void, Never>?

    func search() {
        close()
        guard BluetoothGATT.hasUsageDescription else {
            message = BluetoothGATT.needsBundle
            return
        }
        phase = .scanning
        central = CBCentralManager(delegate: self, queue: .main)
    }

    func connect(to device: Device) {
        guard let central, central.state == .poweredOn, connection == nil else { return }
        central.stopScan()
        connection = device.peripheral
        device.peripheral.delegate = self
        deviceName = device.name
        message = nil
        phase = .connecting
        central.connect(device.peripheral)
        after(25) { $0.fail("연결 시간이 초과되었습니다. 기기를 다시 검색하세요.") }
    }

    func authenticate(_ code: String) {
        guard phase == .enteringCode, let request = BluetoothControlRequest(code: code) else { return }
        phase = .authenticating
        write(request)
    }

    func send(_ action: BluetoothControlAction) {
        guard phase == .connected, let code, let request = BluetoothControlRequest(code: code, action: action) else { return }
        write(request)
    }

    func close() {
        timeout?.cancel()
        timeout = nil
        if let central {
            central.delegate = nil
            if central.state == .poweredOn {
                central.stopScan()
                if let connection { central.cancelPeripheralConnection(connection) }
            }
        }
        connection?.delegate = nil
        central = nil
        connection = nil
        control = nil
        code = nil
        pending = nil
        devices = []
        deviceName = ""
        message = nil
        lastAction = nil
        phase = .idle
    }

    private func fail(_ message: String) {
        close()
        self.message = message
    }

    private func after(_ seconds: Int, _ expiration: @escaping (BluetoothRemote) -> Void) {
        timeout?.cancel()
        timeout = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(seconds)) } catch { return }
            if let self { expiration(self) }
        }
    }

    private func write(_ request: BluetoothControlRequest) {
        guard pending == nil else { return }
        guard let connection, connection.state == .connected, let control else {
            fail("연결이 끊겼습니다. 다시 검색하세요.")
            return
        }
        pending = request
        message = nil
        lastAction = nil
        connection.writeValue(request.data, for: control, type: .withResponse)
        after(60) { $0.fail("Mac에서 응답이 없습니다. 연결을 다시 시도하세요.") }
    }

    // Both manager and peripheral delegate callbacks use the main queue supplied to the manager.
    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        MainActor.assumeIsolated {
            guard central === self.central else { return }
            switch central.state {
            case .poweredOn:
                guard phase == .scanning else { return }
                central.scanForPeripherals(withServices: [BluetoothGATT.service])
                after(12) { remote in
                    remote.central?.stopScan()
                    remote.phase = .idle
                    if remote.devices.isEmpty { remote.message = "주변에서 AdvancedMIO를 찾지 못했습니다." }
                }
            case .unknown, .resetting:
                if connection != nil {
                    fail("블루투스 연결이 재설정되었습니다. 다시 검색하세요.")
                } else {
                    after(12) { $0.fail("블루투스가 준비되지 않았습니다. 다시 시도하세요.") }
                }
            default:
                fail(BluetoothGATT.unavailableMessage(for: central.state))
            }
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                                    advertisementData: [String: Any], rssi: NSNumber) {
        MainActor.assumeIsolated {
            guard central === self.central, phase == .scanning else { return }
            let name = advertisementData[CBAdvertisementDataLocalNameKey] as? String
                ?? peripheral.name ?? "AdvancedMIO · \(peripheral.identifier.uuidString.suffix(4))"
            let device = Device(peripheral: peripheral, name: name)
            if let index = devices.firstIndex(where: { $0.id == device.id }) {
                if devices[index].name != name { devices[index] = device }
            } else {
                devices.append(device)
            }
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        MainActor.assumeIsolated {
            guard central === self.central, peripheral === connection else { return }
            peripheral.discoverServices([BluetoothGATT.service])
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        MainActor.assumeIsolated {
            guard central === self.central, peripheral === connection else { return }
            fail("기기에 연결하지 못했습니다. 다시 검색하세요.")
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        MainActor.assumeIsolated {
            guard central === self.central, peripheral === connection else { return }
            fail("연결이 끊겼습니다. 다시 검색하세요.")
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        MainActor.assumeIsolated {
            guard peripheral === connection else { return }
            guard error == nil, let service = peripheral.services?.first(where: { $0.uuid == BluetoothGATT.service }) else {
                fail("이 기기에서 AdvancedMIO 서비스를 찾지 못했습니다.")
                return
            }
            peripheral.discoverCharacteristics([BluetoothGATT.identity, BluetoothGATT.control, BluetoothGATT.presence], for: service)
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        MainActor.assumeIsolated {
            guard peripheral === connection, service.uuid == BluetoothGATT.service else { return }
            guard error == nil,
                  let identity = service.characteristics?.first(where: { $0.uuid == BluetoothGATT.identity && $0.properties.contains(.read) }),
                  let control = service.characteristics?.first(where: { $0.uuid == BluetoothGATT.control && $0.properties.contains(.write) }) else {
                fail("이 기기는 AdvancedMIO 블루투스 제어를 지원하지 않습니다.")
                return
            }
            self.control = control
            if let presence = service.characteristics?.first(where: { $0.uuid == BluetoothGATT.presence }) {
                peripheral.setNotifyValue(true, for: presence)      // lets the Mac show that this remote is connected
            }
            peripheral.readValue(for: identity)
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        MainActor.assumeIsolated {
            guard peripheral === connection, characteristic.uuid == BluetoothGATT.identity, phase == .connecting else { return }
            guard error == nil, let value = characteristic.value, value.count == 8,
                  let name = String(data: value, encoding: .ascii), name.hasPrefix("MIO-") else {
                fail("연결할 기기의 이름을 확인하지 못했습니다.")
                return
            }
            timeout?.cancel()
            deviceName = name
            phase = .enteringCode
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didModifyServices invalidatedServices: [CBService]) {
        MainActor.assumeIsolated {
            guard peripheral === connection, invalidatedServices.contains(where: { $0.uuid == BluetoothGATT.service }) else { return }
            fail("Mac의 블루투스 접속 설정이 바뀌었습니다. 다시 검색하세요.")
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        MainActor.assumeIsolated {
            guard peripheral === connection, characteristic === control, let request = pending else { return }
            timeout?.cancel()
            pending = nil
            guard let error else {
                code = request.code
                phase = .connected
                lastAction = request.action
                return
            }

            let attError = error as? CBATTError
            switch attError?.code {
            case .insufficientAuthorization:
                message = "코드가 일치하지 않습니다. Mac 화면에 표시된 코드를 확인하세요."
            case .insufficientResources:
                message = "코드 입력을 여러 번 실패했습니다. 30초 뒤 Mac에 표시된 새 코드를 입력하세요."
            case .insufficientAuthentication, .insufficientEncryption:
                message = "블루투스 인증이 필요합니다. 시스템 페어링 요청을 승인한 뒤 다시 시도하세요."
            case .unlikelyError:
                message = "지금은 Mac에서 이 명령을 실행할 수 없습니다."
            case .writeNotPermitted, .attributeNotFound:
                fail("Mac의 블루투스 접속 설정이 바뀌었습니다. 다시 검색하세요.")
                return
            default:
                message = "Mac에서 요청을 처리하지 못했습니다."
            }
            if request.action == nil || attError?.code == .insufficientAuthorization || attError?.code == .insufficientResources {
                code = nil
                phase = .enteringCode
            }
        }
    }
}

extension BluetoothControlAction {
    var title: String {
        switch self {
        case .start: return "라우팅 시작"
        case .stop: return "라우팅 정지"
        case .zero: return "최저 지연 0으로"
        }
    }
}
