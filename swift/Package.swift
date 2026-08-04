// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Tacet",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "tacet", targets: ["tacet"])
    ],
    targets: [
        // Pure / server-logic core: config, key, sanitize, wav, server, whisper.
        .target(name: "TacetCore"),
        // macOS agent: hotkey, recorder, dictate client, controller. Kept out
        // of TacetCore so tests run headless in CI (no TCC, no hardware).
        .executableTarget(name: "tacet", dependencies: ["TacetCore"]),
        .testTarget(name: "TacetCoreTests", dependencies: ["TacetCore"]),
    ]
)
