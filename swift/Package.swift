// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Hark",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "hark", targets: ["hark"])
    ],
    targets: [
        // Pure / server-logic core: config, key, sanitize, wav, server, whisper.
        .target(name: "HarkCore"),
        // macOS agent: hotkey, recorder, dictate client, controller. Kept out
        // of HarkCore so tests run headless in CI (no TCC, no hardware).
        .executableTarget(name: "hark", dependencies: ["HarkCore"]),
        .testTarget(name: "HarkCoreTests", dependencies: ["HarkCore"]),
    ]
)
