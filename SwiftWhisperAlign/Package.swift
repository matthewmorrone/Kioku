// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "SwiftWhisperAlign",
    platforms: [.macOS(.v13), .iOS(.v16)],
    products: [
        .library(name: "SwiftWhisperAlign", targets: ["SwiftWhisperAlign"]),
    ],
    dependencies: [
        .package(path: "../Packages/SwiftWhisper"),
    ],
    targets: [
        .target(
            name: "SwiftWhisperAlign",
            dependencies: [
                .product(name: "SwiftWhisper", package: "SwiftWhisper"),
            ]
        ),
        .testTarget(
            name: "SwiftWhisperAlignTests",
            dependencies: ["SwiftWhisperAlign"]
        ),
    ]
)
