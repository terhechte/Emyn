// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "WindowCaptureKit",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "WindowCaptureKit", targets: ["WindowCaptureKit"])
    ],
    dependencies: [
        .package(path: "../../platform-macos/swift/PlatformMacOSKit")
    ],
    targets: [
        .target(
            name: "WindowCaptureKit",
            dependencies: ["PlatformMacOSKit"]
        )
    ]
)
