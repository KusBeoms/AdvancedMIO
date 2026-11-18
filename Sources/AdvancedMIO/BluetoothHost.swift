@preconcurrency import CoreBluetooth
import MIOCore
import SwiftUI

enum BluetoothGATT {
    static let service = CBUUID(string: "7569D3E1-B156-4108-9DBC-B87F1B42F012")
    static let identity = CBUUID(string: "7569D3E2-B156-4108-9DBC-B87F1B42F012")
    static let control = CBUUID(string: "7569D3E3-B156-4108-9DBC-B87F1B42F012")
    /// Subscribing to it is how a remote announces "I am connected" (Core Bluetooth reports no plain connections to a peripheral).
    static let presence = CBUUID(string: "7569D3E4-B156-4108-9DBC-B87F1B42F012")
    static let needsBundle = "블루투스를 사용하려면 빌드한 AdvancedMIO.app을 실행하세요."

    static var hasUsageDescription: Bool {
        Bundle.main.object(forInfoDictionaryKey: "NSBluetoothAlwaysUsageDescription") != nil
    }

    static func unavailableMessage(for state: CBManagerState) -> String {
        switch state {
        case .poweredOff: return "시스템 설정에서 블루투스를 켜세요."
        case .unauthorized: return "시스템 설정 › 개인정보 보호 및 보안 › Bluetooth에서 AdvancedMIO를 허용하세요."
        case .unsupported: return "이 Mac은 블루투스 저전력 연결을 지원하지 않습니다."
        default: return "블루투스가 준비되면 다시 시도하세요."
        }
    }
}

@MainActor
final class BluetoothHost: NSObject, ObservableObject, CBPeripheralManagerDelegate {
    static let shared = BluetoothHost()
    private static let preferenceKey = "bluetooth.remoteAccess"

    enum Status: Equatable {
        case off, starting, available, unavailable(String), failed(String)
    }

    @Published private(set) var enabled = UserDefaults.standard.object(forKey: preferenceKey) as? Bool ?? true
    @Published private(set) var status: Status = .off
    @Published private(set) var code = ""
    @Published private(set) var lastRemoteEvent: String?
    /// Connected remotes by Core Bluetooth central identifier; the value is whether the code was accepted.
    @Published private(set) var remotes: [UUID: Bool] = [:]
    var authenticatedCount: Int { remotes.values.filter { $0 }.count }

    // The short identifier fits in a BLE scan response. The identity characteristic also exposes it after discovery.
    let name = "MIO-" + UUID().uuidString.prefix(4)
    private var gate = BluetoothAccessGate()
    private var manager: CBPeripheralManager?
    private var service: CBMutableService?

    func start() {
        guard enabled, manager == nil else { return }
        guard BluetoothGATT.hasUsageDescription else {
            status = .unavailable(BluetoothGATT.needsBundle)
            return
        }
        status = .starting
        rotateCode()
        manager = CBPeripheralManager(delegate: self, queue: .main)
    }

    func setEnabled(_ enabled: Bool) {
        guard self.enabled != enabled else { return }
        self.enabled = enabled
        UserDefaults.standard.set(enabled, forKey: Self.preferenceKey)
        if enabled { start() } else { stop() }
    }

    func retry() {
        stop()
        start()
    }

    func rotateCode() {
        gate.rotateCode()
        code = gate.code
    }

    private func stop() {
        if let manager {
            manager.delegate = nil
            if manager.state == .poweredOn {
                manager.stopAdvertising()
                manager.removeAllServices()
            }
        }
        manager = nil
        service = nil
        code = ""
        remotes = [:]
        status = .off
    }

    // Core Bluetooth delivers these delegate callbacks on the main queue supplied to the manager.
    nonisolated func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
        MainActor.assumeIsolated {
            guard peripheral === manager else { return }
            guard peripheral.state == .poweredOn else {
                service = nil
                status = peripheral.state == .resetting || peripheral.state == .unknown
                    ? .starting : .unavailable(BluetoothGATT.unavailableMessage(for: peripheral.state))
                return
            }
            guard service == nil else { return }
            status = .starting
            let identity = CBMutableCharacteristic(type: BluetoothGATT.identity, properties: .read,
                                                   value: Data(name.utf8), permissions: .readable)
            let control = CBMutableCharacteristic(type: BluetoothGATT.control, properties: .write,
                                                  value: nil, permissions: [.writeable, .writeEncryptionRequired])
            let service = CBMutableService(type: BluetoothGATT.service, primary: true)
            let presence = CBMutableCharacteristic(type: BluetoothGATT.presence, properties: [.notify, .read],
                                                   value: nil, permissions: .readable)
            service.characteristics = [identity, control, presence]
            self.service = service
            peripheral.add(service)
        }
    }

    nonisolated func peripheralManager(_ peripheral: CBPeripheralManager, didAdd service: CBService, error: Error?) {
        MainActor.assumeIsolated {
            guard peripheral === manager, service === self.service, peripheral.state == .poweredOn else { return }
            if let error {
                status = .failed(error.localizedDescription)
            } else {
                peripheral.startAdvertising([CBAdvertisementDataServiceUUIDsKey: [BluetoothGATT.service],
                                             CBAdvertisementDataLocalNameKey: name])
            }
        }
    }

    nonisolated func peripheralManagerDidStartAdvertising(_ peripheral: CBPeripheralManager, error: Error?) {
        MainActor.assumeIsolated {
            guard peripheral === manager, status == .starting, peripheral.state == .poweredOn else { return }
            status = error.map { .failed($0.localizedDescription) } ?? .available
        }
    }

    nonisolated func peripheralManager(_ peripheral: CBPeripheralManager, central: CBCentral,
                                       didSubscribeTo characteristic: CBCharacteristic) {
        MainActor.assumeIsolated {
            guard peripheral === manager, characteristic.uuid == BluetoothGATT.presence else { return }
            if remotes[central.identifier] == nil { remotes[central.identifier] = false }
            noteRemote("원격 기기가 연결되었습니다")
        }
    }

    nonisolated func peripheralManager(_ peripheral: CBPeripheralManager, central: CBCentral,
                                       didUnsubscribeFrom characteristic: CBCharacteristic) {
        MainActor.assumeIsolated {
            guard peripheral === manager, characteristic.uuid == BluetoothGATT.presence else { return }
            if remotes.removeValue(forKey: central.identifier) != nil { noteRemote("원격 기기 연결이 끊겼습니다") }
        }
    }

    nonisolated func peripheralManager(_ peripheral: CBPeripheralManager, didReceiveWrite requests: [CBATTRequest]) {
        MainActor.assumeIsolated {
            guard let first = requests.first else { return }
            // Core Bluetooth expects one response to the entire batch. The protocol accepts one complete write.
            let result: CBATTError.Code = requests.count == 1 ? handle(first, on: peripheral) : .requestNotSupported
            peripheral.respond(to: first, withResult: result)
        }
    }

    private func noteRemote(_ text: String) {
        lastRemoteEvent = text + " · " + Date().formatted(date: .omitted, time: .standard)
    }

    private func handle(_ request: CBATTRequest, on peripheral: CBPeripheralManager) -> CBATTError.Code {
        guard peripheral === manager, status == .available, request.characteristic.uuid == BluetoothGATT.control else {
            return .writeNotPermitted
        }
        guard request.offset == 0 else { return .invalidOffset }
        guard let value = request.value, let message = BluetoothControlRequest(data: value) else {
            return .invalidAttributeValueLength
        }
        let result = gate.authorize(message, uptime: ProcessInfo.processInfo.systemUptime)
        if code != gate.code { code = gate.code }
        switch result {
        case .wrongCode: return .insufficientAuthorization
        case .rateLimited: return .insufficientResources
        case .allowed:
            remotes[request.central.identifier] = true
            guard let action = message.action else {
                noteRemote("원격 기기가 코드를 인증했습니다")
                return .success
            }
            let model = AppModel.shared
            guard !model.busy, action != .zero || model.canZeroLag else { return .unlikelyError }
            model.handle(action.command)
            noteRemote("원격 명령: \(action.title)")
            return .success
        }
    }
}
