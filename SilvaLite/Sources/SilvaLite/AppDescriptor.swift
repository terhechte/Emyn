import AppKit
import Foundation

/// Describes a running macOS application that can be controlled.
public struct AppDescriptor {
    public let name: String
    public let bundleIdentifier: String?
    public let pid: pid_t

    // Held so we can activate/raise the window when needed.
    let _runningApplication: NSRunningApplication

    init(_ app: NSRunningApplication) {
        _runningApplication = app
        pid = app.processIdentifier
        bundleIdentifier = app.bundleIdentifier
        name = app.localizedName
            ?? app.bundleURL?.deletingPathExtension().lastPathComponent
            ?? app.executableURL?.lastPathComponent
            ?? "pid-\(app.processIdentifier)"
    }
}
