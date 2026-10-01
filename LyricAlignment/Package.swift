// swift-tools-version: 6.0
import PackageDescription

// No package dependencies: alignment (HuBERT phonemes), vocal isolation (HTDemucs) and VAD all run on CoreML /
// Accelerate from this target's own sources.
let package = Package(
    name: "LyricAlignment",
    platforms: [.macOS(.v15), .iOS(.v18)],
    products: [
        .library(name: "LyricAlignment", targets: ["LyricAlignment"]),
    ],
    targets: [
        .target(
            name: "LyricAlignment",
            swiftSettings: [
                // HTDemucsCoreMLSeparator's cblas_sgemm calls already pass the classic Int32
                // M/N/K/lda/ldb/ldc signature; ACCELERATE_NEW_LAPACK alone opts into the
                // updated (non-deprecated) CBLAS headers without ILP64's wider integer types,
                // so no call sites need to change.
                .unsafeFlags(["-Xcc", "-DACCELERATE_NEW_LAPACK"])
            ],
            // ZipExtractor calls zlib's raw-inflate entry points directly; link it explicitly rather
            // than relying on some other framework in the host app to pull libz in.
            linkerSettings: [.linkedLibrary("z")]
        ),
        .testTarget(
            name: "LyricAlignmentTests",
            dependencies: [
                "LyricAlignment",
            ]
        ),
    ],
    // Sources target Swift 5 language mode; keep v5 so the existing concurrency annotations stay
    // valid without a strict-Swift-6 pass.
    swiftLanguageModes: [.v5]
)
