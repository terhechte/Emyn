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
            url: "https://github.com/handy-computer/transcribe.cpp/releases/download/v0.1.0/TranscribeCpp.xcframework.zip",
            checksum: "1d092eb1f3a4e1a55d3a544d552bf86092311ddaf1536e9a7de9cb8f5cf71666"
        )
    ]
)
