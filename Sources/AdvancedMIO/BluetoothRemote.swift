@preconcurrency import CoreAudio
@preconcurrency import CoreBluetooth
import MIOCore
import SwiftUI

@MainActor
final class BluetoothRemote: NSObject, ObservableObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    /// One connection for the whole app: closing the connection window must not drop it.
    static let shared = BluetoothRemote()

    enum AudioQuality: Int, CaseIterable {
        case standard = 128_000, high = 192_000
        var title: String { self == .high ? "고음질 · 192 kbps" : "표준 · 128 kbps" }
    }
    @Published var audioQuality = AudioQuality(rawValue: UserDefaults.standard.integer(forKey: "bluetooth.audioBitRate")) ?? .standard {
        didSet { UserDefaults.standard.set(audioQuality.rawValue, forKey: "bluetooth.audioBitRate") }
    }

    enum Phase { case idle, scanning, connecting, enteringCode, authenticating, connected, reconnecting }

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
    /// The open audio channel to the connected Mac. While it exists, that Mac is offered as an output in the router.
    @Published private(set) var audioLink: BluetoothAudioSender? {
        didSet { linkBox.current = audioLink }
    }
    /// Thread-safe view of `audioLink` for the router: a running engine keeps its remote output across reconnects.
    let linkBox = RemoteLinkBox()
    /// True once the audio channel has been open in this session, so the output card (and the user's choice to use it)
    /// survives a short connection loss instead of vanishing.
    private var audioEstablished = false
    @Published private(set) var audioNote: String?
    @Published private(set) var audioStatus: String?
    private var audioStatusTimer: Timer?
    static let audioOutputUID = "amio-remote"
    private static let audioOutputID: AudioDeviceID = 0xFFFF_FF00

    /// The connected Mac as an output device card (nil until the audio channel is open).
    var outputDevice: AudioDeviceInfo? {
        guard audioEstablished, phase == .connected || phase == .reconnecting else { return nil }
        return AudioDeviceInfo(id: Self.audioOutputID, uid: Self.audioOutputUID, name: "\(deviceName) · 다른 Mac",
                               inputChannels: 0, outputChannels: 2, transport: .remote)
    }
    var sending: Bool { pending != nil }

    private var central: CBCentralManager?
    private var connection: CBPeripheral?
    private var control: CBCharacteristic?
    private var audioCharacteristic: CBCharacteristic?
    private var audioRequested = false
    private var code: String?
    private var timeout: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?
    private var audioRetryTask: Task<Void, Never>?
    private var reconnectAttempts = 0
    private var reconnectPending = false
    private var audioRetries = 0
    private var audioRestarts = 0       // audio-triggered connection restarts since the channel was last stable

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
        reconnectTask?.cancel(); reconnectTask = nil; reconnectPending = false
        audioRetryTask?.cancel(); audioRetryTask = nil
        reconnectAttempts = 0; audioRetries = 0; audioRestarts = 0
        audioEstablished = false
        if let central {
            central.delegate = nil
            if central.state == .poweredOn {
                central.stopScan()
                if let connection { central.cancelPeripheralConnection(connection) }
            }
        }
        connection?.delegate = nil
        audioLink?.close()
        audioLink = nil
        audioNote = nil
        audioStatusTimer?.invalidate(); audioStatusTimer = nil
        audioStatus = nil
        audioCharacteristic = nil
        audioRequested = false
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

    /// The link to the Mac was lost after its code had been accepted. Keep the session and win the connection back by
    /// itself: Core Bluetooth holds a pending connect until the Mac is in range again, and the stored code re-authenticates.
    /// Without an accepted code there is nothing to resume, so that case still ends the connection.
    private func lose(_ reason: String, disconnected: Bool) {
        guard phase != .idle, code != nil, let central, let connection else { fail(reason); return }
        timeout?.cancel(); timeout = nil
        audioRetryTask?.cancel(); audioRetryTask = nil
        dropAudioLink()
        audioCharacteristic = nil
        audioRequested = false
        control = nil
        pending = nil
        lastAction = nil
        phase = .reconnecting
        message = "연결이 끊겨 다시 연결하는 중입니다…"
        guard central.state == .poweredOn else { return }       // centralManagerDidUpdateState resumes once Bluetooth is back
        if disconnected || connection.state == .disconnected {
            scheduleReconnect()
        } else {
            central.cancelPeripheralConnection(connection)        // didDisconnect then schedules the reconnect
        }
    }

    private func scheduleReconnect() {
        guard !reconnectPending else { return }      // one disconnect can be reported twice: count it once
        reconnectPending = true
        reconnectTask?.cancel()
        reconnectAttempts += 1
        let delay = reconnectAttempts <= 1 ? 0 : min(5, reconnectAttempts)
        reconnectTask = Task { [weak self] in
            if delay > 0 { do { try await Task.sleep(for: .seconds(delay)) } catch { return } }
            self?.reconnectPending = false
            guard let self, !Task.isCancelled, phase == .reconnecting,
                  let central, central.state == .poweredOn, let known = connection else { return }
            // After a Bluetooth reset the old object can be stale: ask Core Bluetooth for a fresh one.
            let connection = central.retrievePeripherals(withIdentifiers: [known.identifier]).first ?? known
            self.connection = connection
            connection.delegate = self
            central.connect(connection)      // no timeout: pending until the Mac is reachable again
        }
    }

    private func dropAudioLink() {
        let link = audioLink
        audioLink = nil                       // before close(): the link's own close callback must see it as stale
        link?.close()
        audioStatusTimer?.invalidate(); audioStatusTimer = nil
        audioStatus = nil
    }

    /// The audio channel closed or could not be opened while the control connection is fine: reopen it with a short
    /// backoff. If that keeps failing, the whole connection is restarted.
    private func scheduleAudioRetry() {
        guard phase == .connected, audioLink == nil else { return }
        audioRetryTask?.cancel()
        audioRetries += 1
        if audioRetries > 4 {
            // Restarting the connection only helps a channel that used to work; a peer that never offered a working
            // one keeps its control link and just shows the note.
            if audioEstablished, audioRestarts < 3 {
                audioRestarts += 1
                audioRetries = 0
                lose("소리 전송 채널을 복구하지 못했습니다.", disconnected: false)
            } else {
                audioNote = "소리 전송 채널을 열지 못했습니다. 상대 Mac의 AdvancedMIO를 확인하세요."
            }
            return
        }
        audioNote = "소리 전송 채널을 다시 여는 중…"
        let delay = audioRetries
        audioRetryTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(delay)) } catch { return }
            guard let self, phase == .connected, audioLink == nil, let connection else { return }
            audioRequested = false
            openAudioChannel(on: connection)
        }
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
            lose("연결이 끊겼습니다. 다시 검색하세요.", disconnected: false)
            return
        }
        pending = request
        message = nil
        lastAction = nil
        connection.writeValue(request.data, for: control, type: .withResponse)
        after(60) { $0.lose("Mac에서 응답이 없습니다. 연결을 다시 시도하세요.", disconnected: false) }
    }

    // Both manager and peripheral delegate callbacks use the main queue supplied to the manager.
    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        MainActor.assumeIsolated {
            guard central === self.central else { return }
            switch central.state {
            case .poweredOn:
                if phase == .reconnecting {
                    scheduleReconnect()
                    return
                }
                guard phase == .scanning else { return }
                central.scanForPeripherals(withServices: [BluetoothGATT.service])
                after(12) { remote in
                    remote.central?.stopScan()
                    remote.phase = .idle
                    if remote.devices.isEmpty { remote.message = "주변에서 AdvancedMIO를 찾지 못했습니다." }
                }
            case .unknown, .resetting:
                if code != nil {
                    lose("블루투스 연결이 재설정되었습니다.", disconnected: true)
                } else if connection != nil {
                    fail("블루투스 연결이 재설정되었습니다. 다시 검색하세요.")
                } else {
                    after(12) { $0.fail("블루투스가 준비되지 않았습니다. 다시 시도하세요.") }
                }
            default:
                if code != nil, central.state == .poweredOff {
                    // Bluetooth was switched off (or the Mac slept): wait here and reconnect when it is back.
                    lose(BluetoothGATT.unavailableMessage(for: central.state), disconnected: true)
                    message = BluetoothGATT.unavailableMessage(for: central.state)
                } else {
                    fail(BluetoothGATT.unavailableMessage(for: central.state))
                }
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
            if phase == .reconnecting { scheduleReconnect() } else { fail("기기에 연결하지 못했습니다. 다시 검색하세요.") }
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        MainActor.assumeIsolated {
            guard central === self.central, peripheral === connection else { return }
            if phase == .reconnecting {
                scheduleReconnect()           // our own restart (or a failed attempt) finished disconnecting
            } else {
                lose("연결이 끊겼습니다. 다시 검색하세요.", disconnected: true)
            }
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        MainActor.assumeIsolated {
            guard peripheral === connection else { return }
            guard error == nil, let service = peripheral.services?.first(where: { $0.uuid == BluetoothGATT.service }) else {
                if phase == .reconnecting, reconnectAttempts < 6 { lose("서비스를 다시 찾지 못했습니다.", disconnected: false) }
                else { fail("이 기기에서 AdvancedMIO 서비스를 찾지 못했습니다.") }
                return
            }
            peripheral.discoverCharacteristics([BluetoothGATT.identity, BluetoothGATT.control, BluetoothGATT.presence, BluetoothGATT.audio], for: service)
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        MainActor.assumeIsolated {
            guard peripheral === connection, service.uuid == BluetoothGATT.service else { return }
            if phase == .reconnecting {
                resume(on: peripheral, service: service, error: error)
                return
            }
            guard error == nil,
                  let identity = service.characteristics?.first(where: { $0.uuid == BluetoothGATT.identity && $0.properties.contains(.read) }),
                  let control = service.characteristics?.first(where: { $0.uuid == BluetoothGATT.control && $0.properties.contains(.write) }) else {
                fail("이 기기는 AdvancedMIO 블루투스 제어를 지원하지 않습니다.")
                return
            }
            self.control = control
            audioCharacteristic = service.characteristics?.first { $0.uuid == BluetoothGATT.audio && $0.properties.contains(.read) }
            if let presence = service.characteristics?.first(where: { $0.uuid == BluetoothGATT.presence }) {
                peripheral.setNotifyValue(true, for: presence)      // lets the Mac show that this remote is connected
            }
            peripheral.readValue(for: identity)
        }
    }

    /// After a reconnect: the identity is already known, so only the stored code is sent again.
    private func resume(on peripheral: CBPeripheral, service: CBService, error: Error?) {
        guard error == nil,
              let control = service.characteristics?.first(where: { $0.uuid == BluetoothGATT.control && $0.properties.contains(.write) }),
              let code, let request = BluetoothControlRequest(code: code) else {
            if reconnectAttempts < 6 { lose("연결을 복구하지 못했습니다.", disconnected: false) }
            else { fail("Mac의 블루투스 접속 설정이 바뀌었습니다. 다시 검색하세요.") }
            return
        }
        self.control = control
        audioCharacteristic = service.characteristics?.first { $0.uuid == BluetoothGATT.audio && $0.properties.contains(.read) }
        if let presence = service.characteristics?.first(where: { $0.uuid == BluetoothGATT.presence }) {
            peripheral.setNotifyValue(true, for: presence)
        }
        pending = request
        peripheral.writeValue(request.data, for: control, type: .withResponse)
        after(20) { $0.lose("Mac에서 응답이 없습니다.", disconnected: false) }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        MainActor.assumeIsolated {
            if peripheral === connection, characteristic.uuid == BluetoothGATT.audio {
                guard phase == .connected else { audioRequested = false; return }
                guard error == nil, let value = characteristic.value, value.count == 2 else {
                    audioNote = "소리 전송 채널 정보를 읽지 못했습니다."
                    audioRequested = false
                    scheduleAudioRetry()
                    return
                }
                peripheral.openL2CAPChannel(CBL2CAPPSM(value[value.startIndex]) | CBL2CAPPSM(value[value.startIndex + 1]) << 8)
                return
            }
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

    /// Reads the audio channel's PSM once after the code was accepted; `didOpen` below completes the setup.
    private func openAudioChannel(on peripheral: CBPeripheral) {
        guard !audioRequested, audioLink == nil else { return }
        audioRequested = true
        guard let audioCharacteristic else {
            audioNote = "상대 Mac의 AdvancedMIO가 소리 수신을 지원하지 않습니다. 양쪽을 같은 최신 버전으로 맞추세요."
            return
        }
        audioNote = "소리 전송 채널을 여는 중…"
        peripheral.readValue(for: audioCharacteristic)
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didOpen channel: CBL2CAPChannel?, error: Error?) {
        MainActor.assumeIsolated {
            guard peripheral === connection, phase == .connected, audioLink == nil else {
                for stream in [channel?.inputStream, channel?.outputStream] { stream?.close() }     // a late channel nobody wants
                return
            }
            guard error == nil, let channel, let code else {
                audioNote = "소리 전송 채널을 열지 못했습니다."
                scheduleAudioRetry()
                return
            }
            guard let link = BluetoothAudioSender(channel: channel, code: code, bitRate: audioQuality.rawValue, onClosed: { [weak self] closed in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        guard let self, self.audioLink === closed else { return }     // a stale link's callback is ignored
                        self.dropAudioLink()
                        self.audioRequested = false
                        self.scheduleAudioRetry()
                    }
                }
            }) else {
                audioNote = "소리 인코더를 만들지 못했습니다."
                return
            }
            audioLink = link
            audioEstablished = true
            audioNote = nil
            audioStatusTimer?.invalidate()
            audioStatusTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    if self.audioLink?.isStalled(for: 5) == true {
                        // Packets go out but nothing comes back: the link is dead without any error. Reopen it.
                        self.dropAudioLink()
                        self.audioRequested = false
                        self.scheduleAudioRetry()
                        return
                    }
                    if self.audioLink?.estimatedLatencyMs != nil { self.audioRetries = 0; self.audioRestarts = 0; self.reconnectAttempts = 0 }     // the channel proved stable
                    let status = self.audioLink?.statusText
                    if self.audioStatus != status { self.audioStatus = status }
                }
            }
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didModifyServices invalidatedServices: [CBService]) {
        MainActor.assumeIsolated {
            guard peripheral === connection, invalidatedServices.contains(where: { $0.uuid == BluetoothGATT.service }) else { return }
            lose("Mac의 블루투스 접속 설정이 바뀌었습니다.", disconnected: false)
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
                message = nil
                lastAction = request.action
                openAudioChannel(on: peripheral)
                return
            }

            let attError = error as? CBATTError
            let codeRejected = attError?.code == .insufficientAuthorization || attError?.code == .insufficientResources
            if phase == .reconnecting, attError?.code == .writeNotPermitted || attError?.code == .attributeNotFound {
                fail("Mac의 블루투스 원격 접속이 꺼졌거나 바뀌었습니다. 다시 검색하세요.")
                return
            }
            if phase == .reconnecting, !codeRejected, attError?.code != .insufficientAuthentication, attError?.code != .insufficientEncryption {
                lose("연결을 복구하지 못했습니다.", disconnected: false)      // transient: try again
                return
            }
            if phase == .reconnecting { audioEstablished = false }
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
