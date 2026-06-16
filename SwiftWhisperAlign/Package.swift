// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SwiftWhisperAlign",
    // iOS 18 required by Qwen3ASR (soniqo speech-swift) for the CTC forced aligner.
    platforms: [.macOS(.v15), .iOS(.v18)],
    products: [
        .library(name: "SwiftWhisperAlign", targets: ["SwiftWhisperAlign"]),
    ],
    dependencies: [
        .package(path: "../Packages/SwiftWhisper"),
        // CTC forced aligner (Qwen3ForcedAligner) — replaces the Whisper-DTW path.
        // Model downloads at runtime via fromPretrained(); nothing is bundled.
        .package(url: "https://github.com/soniqo/speech-swift", branch: "main"),
    ],
    targets: [
        .target(
            name: "SwiftWhisperAlign",
            dependencies: [
                .product(name: "SwiftWhisper", package: "SwiftWhisper"),
                .product(name: "Qwen3ASR", package: "speech-swift"),
            ]
        ),
        .testTarget(
            name: "SwiftWhisperAlignTests",
            dependencies: [
                "SwiftWhisperAlign",
                .product(name: "SwiftWhisper", package: "SwiftWhisper"),
            ]
        ),
    ],
    // Tools 6.0 is needed for the .iOS(.v18) platform (Qwen3ASR requirement), but the
    // sources target Swift 5 language mode (as they did under tools 5.9). Keep v5 so the
    // existing concurrency annotations stay valid and we don't force a strict-Swift-6 pass.
    swiftLanguageModes: [.v5]
)
