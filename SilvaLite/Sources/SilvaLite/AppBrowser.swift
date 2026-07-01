import AppKit
import Foundation

/// Discover and locate running macOS applications.
public enum AppBrowser {

    /// All currently running user-facing applications, sorted by name.
    public static func runningApps() -> [AppDescriptor] {
        NSWorkspace.shared.runningApplications
            .filter { !$0.isTerminated && $0.activationPolicy == .regular }
            .map { AppDescriptor($0) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Find an app by name or bundle identifier.
    /// If the app is not running, this attempts to launch it and waits up to 5 seconds.
    /// - Parameter query: App name (e.g. "Safari") or bundle ID (e.g. "com.apple.Safari").
    public static func find(_ query: String) throws -> AppDescriptor {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)

        if let match = resolveRunning(trimmed) {
            return match
        }

        try launch(trimmed)

        for _ in 0..<20 {
            if let match = resolveRunning(trimmed) {
                return match
            }
            Thread.sleep(forTimeInterval: 0.25)
        }

        throw SilvaLiteError.appNotFound(query)
    }

    // MARK: – Private

    private static func resolveRunning(_ query: String) -> AppDescriptor? {
        let live = NSWorkspace.shared.runningApplications.filter { !$0.isTerminated }

        if query.contains(".") {
            return live.first {
                $0.bundleIdentifier?.caseInsensitiveCompare(query) == .orderedSame
            }.map(AppDescriptor.init)
        }

        return live.first {
            $0.localizedName?.caseInsensitiveCompare(query) == .orderedSame
            || $0.executableURL?.deletingPathExtension().lastPathComponent.caseInsensitiveCompare(query) == .orderedSame
        }.map(AppDescriptor.init)
    }

    private static func launch(_ query: String) throws {
        if query.contains(".") {
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: query) {
                try openApp(at: url)
            }
            return
        }

        let searchRoots: [URL] = [
            URL(fileURLWithPath: "/Applications"),
            URL(fileURLWithPath: "/System/Applications"),
            URL(fileURLWithPath: "/System/Library/CoreServices"),
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications"),
        ]

        let fileManager = FileManager.default
        for root in searchRoots where fileManager.fileExists(atPath: root.path) {
            guard let enumerator = fileManager.enumerator(
                at: root,
                includingPropertiesForKeys: [.isApplicationKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else { continue }

            for case let url as URL in enumerator where url.pathExtension.caseInsensitiveCompare("app") == .orderedSame {
                let appName = url.deletingPathExtension().lastPathComponent
                if appName.caseInsensitiveCompare(query) == .orderedSame {
                    try openApp(at: url)
                    return
                }
            }
        }
    }

    private static func openApp(at url: URL) throws {
        let semaphore = DispatchSemaphore(value: 0)
        let box = LaunchErrorBox()
        NSWorkspace.shared.openApplication(at: url, configuration: .init()) { _, error in
            box.error = error
            semaphore.signal()
        }

        if Thread.isMainThread {
            while semaphore.wait(timeout: .now()) == .timedOut {
                RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.01))
            }
        } else {
            semaphore.wait()
        }

        if let error = box.error { throw error }
    }
}

private final class LaunchErrorBox: @unchecked Sendable {
    var error: Error?
}
