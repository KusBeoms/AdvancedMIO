// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "AdvancedMIO",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(name: "AdvancedMIO", path: "Sources/AdvancedMIO")
    ]
)
