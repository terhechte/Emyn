// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "EmynPerformance",
    platforms: [.macOS(.v13)],
    products: [
        .library(
            name: "EmynPerformanceCore",
            targets: ["EmynPerformanceCore"]
        )
    ],
    targets: [
        .target(
            name: "EmynPerformanceCore",
            path: "Emyn/PerformanceCore",
            sources: [
                "LatestFrameRenderGate.swift",
                "NtscEffectFrameSizer.swift",
                "WindowBackgroundCaptureSizer.swift"
            ]
        ),
        .testTarget(
            name: "EmynPerformanceTests",
            dependencies: ["EmynPerformanceCore"],
            path: "EmynPerformanceTests"
        )
    ]
)
