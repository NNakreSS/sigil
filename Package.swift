// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Sigil",
    platforms: [.macOS(.v14)],
    targets: [
        // All SSH / key / config logic lives here so it can be tested without the UI.
        .target(name: "SigilCore"),
        .testTarget(name: "SigilCoreTests", dependencies: ["SigilCore"]),
    ],
    swiftLanguageModes: [.v5]
)
