// swift-tools-version:5.9
import PackageDescription

var targets: [Target] = [
    // Platform-independent DSP core (ring buffer, delay/resample, haptic planning). Tested on any OS.
    .target(name: "MIOCore", path: "Sources/MIOCore"),
    .testTarget(name: "MIOCoreTests", dependencies: ["MIOCore"], path: "Tests/MIOCoreTests"),
]
var products: [Product] = [.library(name: "MIOCore", targets: ["MIOCore"])]

#if os(macOS)
targets.append(.executableTarget(name: "AdvancedMIO", dependencies: ["MIOCore"], path: "Sources/AdvancedMIO"))
products.append(.executable(name: "AdvancedMIO", targets: ["AdvancedMIO"]))
#endif

let package = Package(
    name: "AdvancedMIO",
    platforms: [.macOS(.v13)],
    products: products,
    targets: targets
)
