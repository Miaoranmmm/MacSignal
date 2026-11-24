// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "MacSignal",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "MacSignal", targets: ["MacSignal"])],
    targets: [
        .target(name: "MacSignalCore"),
        .executableTarget(name: "MacSignal", dependencies: ["MacSignalCore"]),
        .testTarget(name: "MacSignalCoreTests", dependencies: ["MacSignalCore"]),
        .testTarget(name: "MacSignalTests", dependencies: ["MacSignal"])
    ]
)
