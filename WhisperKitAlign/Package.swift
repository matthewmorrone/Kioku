// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "WhisperKitAlign",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "WhisperKitAlign", targets: ["WhisperKitAlign"]),
    ],
    targets: [
        .target(name: "WhisperKitAlign"),
        .testTarget(
            name: "WhisperKitAlignTests",
            dependencies: ["WhisperKitAlign"]
        ),
    ]
)
