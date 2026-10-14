// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Sigil",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Sigil", targets: ["Sigil"])
    ],
    dependencies: [
        // Auto-updates from GitHub Releases (EdDSA-signed appcast).
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.9.0"),
        // Embedded terminal (MIT). Pinned to 1.19.x; 1.99 is a fresh pre-2.0 preview.
        .package(url: "https://github.com/migueldeicaza/SwiftTerm", .upToNextMinor(from: "1.19.0")),
    ],
    targets: [
        // All SSH / key / config logic lives here so it can be tested without the UI.
        .target(name: "SigilCore"),
        .executableTarget(
            name: "Sigil",
            dependencies: [
                "SigilCore",
                .product(name: "Sparkle", package: "Sparkle"),
                .product(name: "SwiftTerm", package: "SwiftTerm"),
            ],
            linkerSettings: [
                // Sparkle.framework is embedded in Sigil.app/Contents/Frameworks by scripts/make-app.sh.
                .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"]),
            ]
        ),
        .testTarget(name: "SigilCoreTests", dependencies: ["SigilCore"]),
    ],
    swiftLanguageModes: [.v5]
)
