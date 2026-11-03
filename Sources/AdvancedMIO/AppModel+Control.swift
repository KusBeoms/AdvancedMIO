import AppKit
import Carbon.HIToolbox
import MIOCore
import ServiceManagement

// Control from outside the window: menu bar, global hotkeys, `advancedmio://` URLs (Shortcuts "Open URL", scripts/amio).
extension AppModel {
    func handle(_ command: ControlCommand) {
        switch command {
        case .start: if !running { arm() }
        case .stop: if running { disarm() }
        case .toggle: toggleRunning()
        case .zeroLag: zeroMinLag()
        case .preset(let name): applyPreset(named: name)
        case .openWindow: AppWindow.show()
        }
    }

    func handle(url: URL) {
        if let c = ControlCommand.parse(url) { handle(c) }
    }

    func setHotkeys(_ on: Bool) {
        hotkeysEnabled = on
        UserDefaults.standard.set(on, forKey: "hotkeys")
        HotKeys.shared.apply(enabled: on)
    }

    fileprivate func handleHotKey(_ id: UInt32) {
        if id == HotKeys.toggleID { toggleRunning(); return }
        if id == HotKeys.zeroID { zeroMinLag(); return }
        let i = Int(id) - Int(HotKeys.presetBase)
        if presets.indices.contains(i) { applyPreset(presets[i].id) }
    }

    // MARK: Launch at login

    var launchAtLogin: Bool { SMAppService.mainApp.status == .enabled }

    func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            self.error = "로그인 시 자동 실행을 바꾸지 못했습니다 (.app으로 실행 중인지 확인하세요): \(error.localizedDescription)"
        }
        objectWillChange.send()
    }
}

/// The main window can be closed while the app keeps routing from the menu bar; this brings it back.
enum AppWindow {
    /// Set by the menu bar (which has SwiftUI's `openWindow`) as a fallback when the window object is gone.
    @MainActor static var openFallback: (() -> Void)?

    @MainActor static func show() {
        NSApp.activate(ignoringOtherApps: true)
        if let w = NSApp.windows.first(where: { $0.canBecomeMain && !($0 is NSPanel) }) {
            w.makeKeyAndOrderFront(nil)
        } else {
            openFallback?()
        }
    }
}

/// System-wide shortcuts (⌃⌥⌘ + key): S start/stop, Z lowest lag → 0, 1…9 presets. Carbon hot keys need no permission.
@MainActor
final class HotKeys {
    static let shared = HotKeys()
    fileprivate static let toggleID: UInt32 = 1, zeroID: UInt32 = 2, presetBase: UInt32 = 10
    private var refs: [EventHotKeyRef] = []
    private var handlerInstalled = false

    func apply(enabled: Bool) {
        refs.forEach { UnregisterEventHotKey($0) }
        refs = []
        guard enabled else { return }
        installHandler()
        let mods = UInt32(controlKey | optionKey | cmdKey)
        var keys: [(UInt32, Int)] = [(HotKeys.toggleID, kVK_ANSI_S), (HotKeys.zeroID, kVK_ANSI_Z)]
        let digits = [kVK_ANSI_1, kVK_ANSI_2, kVK_ANSI_3, kVK_ANSI_4, kVK_ANSI_5, kVK_ANSI_6, kVK_ANSI_7, kVK_ANSI_8, kVK_ANSI_9]
        for (i, k) in digits.enumerated() { keys.append((HotKeys.presetBase + UInt32(i), k)) }
        for (id, code) in keys {
            var ref: EventHotKeyRef?
            let hkID = EventHotKeyID(signature: 0x414D494F /* 'AMIO' */, id: id)
            if RegisterEventHotKey(UInt32(code), mods, hkID, GetApplicationEventTarget(), 0, &ref) == noErr, let ref { refs.append(ref) }
        }
    }

    private func installHandler() {
        guard !handlerInstalled else { return }
        handlerInstalled = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ -> OSStatus in
            var hk = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(0x686B6964)  /* typeEventHotKey 'hkid' */, nil,
                              MemoryLayout<EventHotKeyID>.size, nil, &hk)
            let id = hk.id
            DispatchQueue.main.async { MainActor.assumeIsolated { AppModel.shared.handleHotKey(id) } }
            return noErr
        }, 1, &spec, nil, nil)
    }
}
