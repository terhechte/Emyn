// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "VideoCompositionKit",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "VideoCompositionKit", targets: ["VideoCompositionKit"])
    ],
    dependencies: [
        .package(path: "../BackgroundRemovalKit"),
        .package(path: "../SharedFrameKit"),
        .package(path: "../WindowCaptureKit"),
        .package(path: "../../platform-macos/swift/PlatformMacOSKit")
    ],
    targets: [
        .target(
            name: "VideoCompositionKit",
            dependencies: [
                "BackgroundRemovalKit",
                "SharedFrameKit",
                "WindowCaptureKit",
                "PlatformMacOSKit"
            ]
        )
    ]
)
