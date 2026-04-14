// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "WhisperKitAlign",
    platforms: [.macOS(.v13), .iOS(.v16)],
    products: [
        .library(name: "WhisperKitAlign", targets: ["WhisperKitAlign"]),
    ],
    dependencies: [
        .package(path: "../Packages/SwiftWhisper"),
    ],
    targets: [
        .target(
            name: "WhisperKitAlign",
            dependencies: [
                .product(name: "SwiftWhisper", package: "SwiftWhisper"),
            ]
        ),
        .testTarget(
            name: "WhisperKitAlignTests",
            dependencies: ["WhisperKitAlign"]
        ),
    ]
)
