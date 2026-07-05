// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "TranscribeCppBinary",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(name: "CTranscribe", targets: ["CTranscribe"])
    ],
    targets: [
        .binaryTarget(
            name: "CTranscribe",
            path: "TranscribeCpp.xcframework"
        )
    ]
)
