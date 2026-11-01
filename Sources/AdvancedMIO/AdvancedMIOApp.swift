import AppKit
import SwiftUI

@main
struct AdvancedMIOApp: App {
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
