import SwiftUI

@main
struct AdvancedMIOApp: App {
    var body: some Scene {
        WindowGroup("AdvancedMIO") {
            ContentView()
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentMinSize)
        .defaultSize(width: 1040, height: 700)
    }
}
