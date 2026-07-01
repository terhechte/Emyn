// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SilvaLite",
    platforms: [.macOS(.v13)],
    products: [
        .library(
            name: "SilvaLite",
            targets: ["SilvaLite"]
        ),
    ],
    targets: [
        .target(
            name: "SilvaLite",
            swiftSettings: [
                .swiftLanguageMode(.v5),
            ]
        ),
        .testTarget(
            name: "SilvaLiteTests",
            dependencies: ["SilvaLite"],
            swiftSettings: [
                .swiftLanguageMode(.v5),
            ]
        ),
    ]
)
