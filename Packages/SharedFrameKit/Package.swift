// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "SharedFrameKit",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "SharedFrameKit", targets: ["SharedFrameKit"])
    ],
    targets: [
        .target(name: "SharedFrameKit")
    ]
)
