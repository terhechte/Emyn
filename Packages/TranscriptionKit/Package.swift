// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "TranscriptionKit",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "TranscriptionKit", targets: ["TranscriptionKit"])
    ],
    dependencies: [
        .package(path: "../../transcribe-cpp-swift")
    ],
    targets: [
        .target(
            name: "TranscriptionKit",
            dependencies: [
                .product(name: "CTranscribe", package: "transcribe-cpp-swift")
            ]
        )
    ]
)
