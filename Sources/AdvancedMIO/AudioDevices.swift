import CoreAudio
import Foundation

enum DeviceTransport {
    case builtIn, usb, bluetooth, hdmi, airplay, thunderbolt, virtual, aggregate, other

    var label: String {
        switch self {
        case .builtIn: return "내장"
        case .usb: return "USB"
        case .bluetooth: return "블루투스"
        case .hdmi: return "HDMI/DP"
        case .airplay: return "AirPlay"
        case .thunderbolt: return "Thunderbolt"
        case .virtual: return "가상"
        case .aggregate: return "통합"
        case .other: return "기타"
        }
    }
}

struct AudioDeviceInfo: Identifiable, Hashable {
    let id: AudioDeviceID
    let uid: String
    let name: String
    let inputChannels: Int
    let outputChannels: Int
    let transport: DeviceTransport

    var isInput: Bool { inputChannels > 0 }
    var isOutput: Bool { outputChannels > 0 }

    /// SF Symbol for the device (name hints win over transport).
    func symbol(forOutput: Bool) -> String {
        let n = name.lowercased()
        if n.contains("airpods") { return "airpodspro" }
        if n.contains("headphone") || n.contains("buds") || n.contains("헤드폰") { return "headphones" }
        switch transport {
        case .builtIn: return forOutput ? "laptopcomputer" : "mic.fill"
        case .usb: return forOutput ? "cable.connector" : "mic.fill"
        case .bluetooth: return "headphones"
        case .hdmi: return "tv"
        case .airplay: return "airplayaudio"
        case .thunderbolt: return "bolt.horizontal.fill"
        case .virtual: return "waveform.path"
        case .aggregate: return "rectangle.3.group"
        case .other: return forOutput ? "speaker.wave.2.fill" : "mic.fill"
        }
    }
}

struct IOError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
    static func hal(_ what: String, _ status: OSStatus) -> IOError {
        IOError(message: "\(what) 실패 (\(fourCC(status)))")
    }
    private static func fourCC(_ s: OSStatus) -> String {
        let u = UInt32(bitPattern: s)
        let bytes = [UInt8((u >> 24) & 255), UInt8((u >> 16) & 255), UInt8((u >> 8) & 255), UInt8(u & 255)]
        if bytes.allSatisfy({ $0 >= 32 && $0 < 127 }) { return String(decoding: bytes, as: UTF8.self) }
        return "\(s)"
    }
}

enum HAL {
    /// Number of other processes currently playing to the AdvancedMIO virtual device (driver-defined property 'amip').
    /// nil when the installed driver predates the property.
    static func playbackClients(_ id: AudioDeviceID) -> UInt32? {
        var addr = AudioObjectPropertyAddress(mSelector: 0x616D6970, mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &value) == noErr else { return nil }
        return value
    }

    private static func address(_ sel: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: sel, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    /// Reads a fixed-size POD property.
    static func get<T>(_ obj: AudioObjectID, _ sel: AudioObjectPropertySelector,
                       scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal, initial: T) -> T? {
        var addr = address(sel, scope)
        var value = initial
        var size = UInt32(MemoryLayout<T>.size)
        guard AudioObjectGetPropertyData(obj, &addr, 0, nil, &size, &value) == noErr else { return nil }
        return value
    }

    static func string(_ obj: AudioObjectID, _ sel: AudioObjectPropertySelector) -> String? {
        var addr = address(sel, kAudioObjectPropertyScopeGlobal)
        var cf: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(obj, &addr, 0, nil, &size, &cf) == noErr, let s = cf else { return nil }
        return s.takeRetainedValue() as String
    }

    static func array<T>(_ obj: AudioObjectID, _ sel: AudioObjectPropertySelector,
                         scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal, of: T.Type) -> [T] {
        var addr = address(sel, scope)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(obj, &addr, 0, nil, &size) == noErr, size > 0 else { return [] }
        let count = Int(size) / MemoryLayout<T>.stride
        let ptr = UnsafeMutablePointer<T>.allocate(capacity: count)
        defer { ptr.deallocate() }
        guard AudioObjectGetPropertyData(obj, &addr, 0, nil, &size, ptr) == noErr else { return [] }
        return Array(UnsafeBufferPointer(start: ptr, count: min(count, Int(size) / MemoryLayout<T>.stride)))
    }

    static func channelCount(_ id: AudioObjectID, scope: AudioObjectPropertyScope) -> Int {
        var addr = address(kAudioDevicePropertyStreamConfiguration, scope)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, raw) == noErr else { return 0 }
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    static func transport(_ id: AudioObjectID) -> DeviceTransport {
        guard let t: UInt32 = get(id, kAudioDevicePropertyTransportType, initial: 0) else { return .other }
        switch t {
        case kAudioDeviceTransportTypeBuiltIn: return .builtIn
        case kAudioDeviceTransportTypeUSB: return .usb
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE: return .bluetooth
        case kAudioDeviceTransportTypeHDMI, kAudioDeviceTransportTypeDisplayPort: return .hdmi
        case kAudioDeviceTransportTypeAirPlay: return .airplay
        case kAudioDeviceTransportTypeThunderbolt: return .thunderbolt
        case kAudioDeviceTransportTypeVirtual: return .virtual
        case kAudioDeviceTransportTypeAggregate: return .aggregate
        default: return .other
        }
    }

    static func allDevices() -> [AudioDeviceInfo] {
        let ids = array(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDevices, of: AudioDeviceID.self)
        return ids.compactMap { id in
            guard let uid = string(id, kAudioDevicePropertyDeviceUID),
                  let name = string(id, kAudioObjectPropertyName) else { return nil }
            let i = channelCount(id, scope: kAudioObjectPropertyScopeInput)
            let o = channelCount(id, scope: kAudioObjectPropertyScopeOutput)
            guard i > 0 || o > 0 else { return nil }
            return AudioDeviceInfo(id: id, uid: uid, name: name, inputChannels: i, outputChannels: o, transport: transport(id))
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    static func nominalSampleRate(_ id: AudioObjectID) -> Double? {
        get(id, kAudioDevicePropertyNominalSampleRate, initial: Float64(0))
    }

    /// Verifies every active stream in `scope` is 32-bit float PCM (what the HAL normally exposes) and returns the sample rate.
    static func validateFloatIO(_ id: AudioObjectID, scope: AudioObjectPropertyScope) throws -> Double {
        guard let rate = nominalSampleRate(id), rate > 0 else { throw IOError(message: "샘플레이트를 읽을 수 없습니다") }
        let streams = array(id, kAudioDevicePropertyStreams, scope: scope, of: AudioStreamID.self)
        guard !streams.isEmpty else { throw IOError(message: "스트림이 없습니다") }
        for s in streams {
            guard let f: AudioStreamBasicDescription = get(s, kAudioStreamPropertyVirtualFormat, initial: AudioStreamBasicDescription()) else { continue }
            let isFloat = (f.mFormatFlags & kAudioFormatFlagIsFloat) != 0
            if f.mFormatID != kAudioFormatLinearPCM || !isFloat || f.mBitsPerChannel != 32 {
                throw IOError(message: "지원하지 않는 오디오 포맷입니다 (32-bit float PCM 필요)")
            }
        }
        return rate
    }

    /// Reported output latency in ms: device + stream latency + safety offset + one buffer.
    static func outputLatencyMs(_ id: AudioObjectID) -> Double? {
        guard let rate = nominalSampleRate(id), rate > 0 else { return nil }
        let scope = kAudioObjectPropertyScopeOutput
        let dev: UInt32 = get(id, kAudioDevicePropertyLatency, scope: scope, initial: 0) ?? 0
        let safety: UInt32 = get(id, kAudioDevicePropertySafetyOffset, scope: scope, initial: 0) ?? 0
        let buf: UInt32 = get(id, kAudioDevicePropertyBufferFrameSize, initial: 0) ?? 0
        let streams = array(id, kAudioDevicePropertyStreams, scope: scope, of: AudioStreamID.self)
        let st: UInt32 = streams.first.flatMap { get($0, kAudioStreamPropertyLatency, initial: 0) } ?? 0
        return Double(dev + safety + buf + st) / rate * 1000
    }
}

/// One IOProc attached to one device.
final class DeviceIO {
    let deviceID: AudioDeviceID
    private var procID: AudioDeviceIOProcID?
    private var running = false

    init(deviceID: AudioDeviceID, block: @escaping AudioDeviceIOBlock) throws {
        self.deviceID = deviceID
        let status = AudioDeviceCreateIOProcIDWithBlock(&procID, deviceID, nil, block)
        guard status == noErr, procID != nil else { throw IOError.hal("IOProc 생성", status) }
    }

    func start() throws {
        let status = AudioDeviceStart(deviceID, procID)
        guard status == noErr else { throw IOError.hal("장치 시작", status) }
        running = true
    }

    func stop() {
        if running { AudioDeviceStop(deviceID, procID); running = false }
        if let p = procID { AudioDeviceDestroyIOProcID(deviceID, p); procID = nil }
    }

    deinit { stop() }
}
