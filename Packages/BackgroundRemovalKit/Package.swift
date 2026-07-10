// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "BackgroundRemovalKit",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "BackgroundRemovalKit", targets: ["BackgroundRemovalKit"])
    ],
    targets: [
        .target(name: "BackgroundRemovalKit")
    ]
)
