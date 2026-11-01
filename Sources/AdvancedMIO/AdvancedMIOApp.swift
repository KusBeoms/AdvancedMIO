import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)      // also when launched via `swift run` (no .app bundle)
        NSApp.activate(ignoringOtherApps: true)
    }
    // Closing the window stops routing: there is no other UI to stop it with.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

@main
struct AdvancedMIOApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    init() {
        // Diagnostics for headless CI screenshots: can this machine resolve SF Symbols?
        if CommandLine.arguments.contains("--demo") {
            let names = ["play.fill", "waveform.path", "checkmark.circle.fill", "arrow.clockwise"]
            let report = names.map { "\($0): \(NSImage(systemSymbolName: $0, accessibilityDescription: nil) != nil)" }
            try? report.joined(separator: "\n").write(toFile: "/tmp/amio_symbols.txt", atomically: true, encoding: .utf8)
        }
    }
    var body: some Scene {
        WindowGroup("AdvancedMIO") {
            ContentView()
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentMinSize)
        .defaultSize(width: 1040, height: 700)
    }
}
