import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)      // also when launched via `swift run` (no .app bundle)
        NSApp.activate(ignoringOtherApps: true)
        MainActor.assumeIsolated { HotKeys.shared.apply(enabled: AppModel.shared.hotkeysEnabled) }
    }
    // Closing the window leaves the app (and the routing) running in the menu bar; quit from there or with ⌘Q.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// Clicking the Dock icon with no window open brings the window back.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { MainActor.assumeIsolated { AppWindow.show() } }
        return true
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        MainActor.assumeIsolated { for u in urls { AppModel.shared.handle(url: u) } }
    }
}

@main
struct AdvancedMIOApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = AppModel.shared

    init() {
        if CommandLine.arguments.contains("--probe") { Probe.run(); exit(0) }
        // Diagnostics for headless CI screenshots: can this machine resolve SF Symbols?
        if CommandLine.arguments.contains("--demo") {
            let names = ["play.fill", "waveform.path", "checkmark.circle.fill", "arrow.clockwise"]
            let report = names.map { "\($0): \(NSImage(systemSymbolName: $0, accessibilityDescription: nil) != nil)" }
            try? report.joined(separator: "\n").write(toFile: "/tmp/amio_symbols.txt", atomically: true, encoding: .utf8)
        }
    }
    var body: some Scene {
        Window("AdvancedMIO", id: "main") {
            ContentView().environmentObject(model)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentMinSize)
        .defaultSize(width: 1040, height: 700)

        MenuBarExtra {
            MenuBarContent().environmentObject(model)
        } label: {
            Image(systemName: model.capturing ? "waveform.circle.fill" : "waveform.circle")
        }
        .menuBarExtraStyle(.menu)
    }
}
