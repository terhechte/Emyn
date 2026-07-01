// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PlatformMacOSKit",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "PlatformMacOSKit", targets: ["PlatformMacOSKit"]),
    ],
    targets: [
        .binaryTarget(
            name: "platform_macosFFI",
            path: "platform_macosFFI.xcframework"
        ),
        .target(
            name: "PlatformMacOSKit",
            dependencies: ["platform_macosFFI"],
            swiftSettings: [
                .swiftLanguageMode(.v5),
            ]
        ),
    ]
)
