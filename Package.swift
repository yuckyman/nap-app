// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Nap",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "NapCore", targets: ["NapCore"]),
        .executable(name: "nap-swift", targets: ["nap-swift"]),
        .executable(name: "NapApp", targets: ["NapApp"]),
    ],
    targets: [
        .target(name: "NapCore"),
        .executableTarget(name: "nap-swift", dependencies: ["NapCore"]),
        .executableTarget(name: "NapApp", dependencies: ["NapCore"]),
        .testTarget(name: "NapCoreTests", dependencies: ["NapCore"]),
    ],
    swiftLanguageModes: [.v5]
)
