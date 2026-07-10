// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "EmynWorkspace",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(path: "Packages/VideoCompositionKit"),
        .package(path: "Packages/WindowCaptureKit")
    ],
    targets: [
        .testTarget(
            name: "EmynPerformanceTests",
            dependencies: [
                "VideoCompositionKit",
                "WindowCaptureKit"
            ],
            path: "EmynPerformanceTests"
        )
    ]
)
