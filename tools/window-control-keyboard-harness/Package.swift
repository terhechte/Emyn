// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "WindowControlKeyboardHarness",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "KeyboardHarnessTarget", targets: ["KeyboardHarnessTarget"]),
        .executable(name: "KeyboardHarnessDriver", targets: ["KeyboardHarnessDriver"]),
    ],
    dependencies: [
        .package(path: "../../platform-macos/swift/PlatformMacOSKit"),
    ],
    targets: [
        .executableTarget(name: "KeyboardHarnessTarget"),
        .executableTarget(
            name: "KeyboardHarnessDriver",
            dependencies: ["PlatformMacOSKit"]
        ),
    ]
)
