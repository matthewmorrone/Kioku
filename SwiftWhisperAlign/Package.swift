// swift-tools-version: 6.0
import PackageDescription

// No package dependencies: alignment (MMS), vocal isolation (HTDemucs) and VAD all run on CoreML /
// Accelerate from this target's own sources.
let package = Package(
    name: "SwiftWhisperAlign",
    platforms: [.macOS(.v15), .iOS(.v18)],
    products: [
        .library(name: "SwiftWhisperAlign", targets: ["SwiftWhisperAlign"]),
    ],
    targets: [
        .target(
            name: "SwiftWhisperAlign",
            swiftSettings: [
                // HTDemucsCoreMLSeparator's cblas_sgemm calls already pass the classic Int32
                // M/N/K/lda/ldb/ldc signature; ACCELERATE_NEW_LAPACK alone opts into the
                // updated (non-deprecated) CBLAS headers without ILP64's wider integer types,
                // so no call sites need to change.
                .unsafeFlags(["-Xcc", "-DACCELERATE_NEW_LAPACK"])
            ]
        ),
        .testTarget(
            name: "SwiftWhisperAlignTests",
            dependencies: [
                "SwiftWhisperAlign",
            ]
        ),
    ],
    // Sources target Swift 5 language mode; keep v5 so the existing concurrency annotations stay
    // valid without a strict-Swift-6 pass.
    swiftLanguageModes: [.v5]
)
