import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import PlatformMacOSKit

private let targetWindowTitle = "Emyn Keyboard Harness Target"

@main
enum KeyboardHarnessDriver {
    static func main() {
        Task {
            let code: Int32
            do {
                try await Driver().run()
                code = 0
            } catch {
                fputs("KeyboardHarnessDriver failed: \(error)\n", stderr)
                code = 1
            }

            exit(code)
        }

        CFRunLoopRun()
    }
}

private struct Driver {
    private let textToType: String
    private let outputURL: URL
    private let targetExecutableURL: URL
    private let keepTargetFrontmost: Bool
    private let inputSource: InputSource

    init(arguments: [String] = CommandLine.arguments) throws {
        textToType = Self.argument("--text", in: arguments) ?? "emynok123"
        keepTargetFrontmost = arguments.contains("--keep-target-frontmost")
        inputSource = InputSource(rawValue: Self.argument("--input-source", in: arguments) ?? "direct-forward")
            ?? .directForward
        let outputPath = Self.argument("--output", in: arguments)
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("emyn-keyboard-harness-output.txt")
                .path
        outputURL = URL(fileURLWithPath: outputPath)

        let targetPath = Self.argument("--target", in: arguments)
            ?? Self.defaultTargetExecutablePath()
        targetExecutableURL = URL(fileURLWithPath: targetPath)
    }

    func run() async throws {
        print("listenEventAccess=\(CGPreflightListenEventAccess()) accessibility=\(AXIsProcessTrusted())")

        try? FileManager.default.removeItem(at: outputURL)
        let process = try launchTarget()
        defer {
            process.terminate()
            process.waitUntilExit()
        }

        let window = try await waitForTargetWindow(pid: process.processIdentifier)
        print("targetPid=\(process.processIdentifier) windowId=\(window.windowID) bounds=\(window.bounds)")

        if !keepTargetFrontmost {
            activateFinder()
            try await sleep(milliseconds: 400)
        }

        let session = WindowCaptureSession(
            targetPid: process.processIdentifier,
            targetWindowID: CGWindowID(window.windowID),
            excludeFunctionKeys: true
        )
        session.onMouseMove = { point in
            print("tapMouseMove=\(point)")
        }
        defer {
            session.deactivate()
        }

        let viewBounds = controlViewBounds()
        try session.activate(
            viewBoundsInCGSpace: viewBounds,
            targetBoundsInCGSpace: window.bounds
        )
        try await sleep(milliseconds: 200)

        clickTextField(controlBounds: viewBounds)
        try await sleep(milliseconds: 250)
        try await type(textToType, using: session)

        let observed = try await waitForOutputText(textToType)
        print("observed=\(observed)")
    }

    private func launchTarget() throws -> Process {
        let process = Process()
        process.executableURL = targetExecutableURL
        process.arguments = ["--output", outputURL.path]
        process.standardOutput = FileHandle.standardOutput
        process.standardError = FileHandle.standardError
        try process.run()
        return process
    }

    private func waitForTargetWindow(pid: pid_t) async throws -> TargetWindow {
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            if let window = findTargetWindow(pid: pid) {
                return window
            }

            try await sleep(milliseconds: 100)
        }

        throw HarnessError.targetWindowNotFound(pid)
    }

    private func findTargetWindow(pid: pid_t) -> TargetWindow? {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let windows = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }

        for window in windows {
            guard let ownerPID = window[kCGWindowOwnerPID as String] as? pid_t,
                  ownerPID == pid,
                  let layer = window[kCGWindowLayer as String] as? Int,
                  layer == 0,
                  let windowID = window[kCGWindowNumber as String] as? Int,
                  let boundsDict = window[kCGWindowBounds as String] as? [String: Any],
                  let bounds = CGRect(dictionaryRepresentation: boundsDict as CFDictionary) else {
                continue
            }

            let title = window[kCGWindowName as String] as? String ?? ""
            if title.contains(targetWindowTitle) || title.isEmpty {
                return TargetWindow(windowID: UInt32(windowID), bounds: bounds)
            }
        }

        return nil
    }

    private func activateFinder() {
        NSRunningApplication
            .runningApplications(withBundleIdentifier: "com.apple.finder")
            .first?
            .activate(options: [.activateIgnoringOtherApps])
    }

    private func controlViewBounds() -> CGRect {
        if let screen = NSScreen.main {
            let frame = screen.frame
            return CGRect(x: frame.minX + 40, y: frame.minY + 80, width: 420, height: 260)
        }

        return CGRect(x: 40, y: 80, width: 420, height: 260)
    }

    private func clickTextField(controlBounds: CGRect) {
        let point = CGPoint(x: controlBounds.midX, y: controlBounds.minY + controlBounds.height * 0.34)
        postMouse(type: .mouseMoved, at: point)
        postMouse(type: .leftMouseDown, at: point)
        postMouse(type: .leftMouseUp, at: point)
    }

    private func postMouse(type: CGEventType, at point: CGPoint) {
        guard let source = CGEventSource(stateID: .hidSystemState),
              let event = CGEvent(
                mouseEventSource: source,
                mouseType: type,
                mouseCursorPosition: point,
                mouseButton: .left
              ) else {
            return
        }

        event.post(tap: .cghidEventTap)
    }

    private func type(_ text: String, using session: WindowCaptureSession) async throws {
        switch inputSource {
        case .systemEvents:
            try await typeWithSystemEvents(text)
        case .cgEvent:
            typeWithCGEvents(text)
        case .directForward:
            try await typeWithDirectForward(text, using: session)
        }
    }

    private func typeWithCGEvents(_ text: String) {
        for character in text {
            guard let keyCode = keyCode(for: character) else {
                continue
            }

            postKey(keyCode: keyCode, keyDown: true)
            Thread.sleep(forTimeInterval: 0.035)
            postKey(keyCode: keyCode, keyDown: false)
            Thread.sleep(forTimeInterval: 0.04)
        }
    }

    private func typeWithSystemEvents(_ text: String) async throws {
        let lines = text.compactMap { character -> String? in
            guard let keyCode = keyCode(for: character) else {
                return nil
            }

            return """
            key code \(keyCode)
            delay 0.04
            """
        }

        let script = """
        tell application "System Events"
        \(lines.joined(separator: "\n"))
        end tell
        """

        try await runProcess(
            executableURL: URL(fileURLWithPath: "/usr/bin/osascript"),
            arguments: ["-e", script]
        )
    }

    private func typeWithDirectForward(_ text: String, using session: WindowCaptureSession) async throws {
        for character in text {
            guard let keyCode = keyCode(for: character) else {
                continue
            }

            try session.forwardKeyForTesting(keyCode: keyCode, keyDown: true)
            try await sleep(milliseconds: 35)
            try session.forwardKeyForTesting(keyCode: keyCode, keyDown: false)
            try await sleep(milliseconds: 40)
        }
    }

    private func postKey(keyCode: CGKeyCode, keyDown: Bool) {
        guard let source = CGEventSource(stateID: .hidSystemState),
              let event = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: keyDown) else {
            return
        }

        event.flags = []
        event.post(tap: .cghidEventTap)
    }

    private func waitForOutputText(_ expected: String) async throws -> String {
        let deadline = Date().addingTimeInterval(6)
        while Date() < deadline {
            let current = (try? String(contentsOf: outputURL, encoding: .utf8)) ?? ""
            if current == expected {
                return current
            }

            try await sleep(milliseconds: 100)
        }

        let current = (try? String(contentsOf: outputURL, encoding: .utf8)) ?? ""
        throw HarnessError.unexpectedOutput(expected: expected, actual: current)
    }

    private static func argument(_ name: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: name),
              arguments.indices.contains(index + 1) else {
            return nil
        }

        return arguments[index + 1]
    }

    private static func defaultTargetExecutablePath() -> String {
        let driverURL = URL(fileURLWithPath: CommandLine.arguments[0])
        return driverURL
            .deletingLastPathComponent()
            .appendingPathComponent("KeyboardHarnessTarget")
            .path
    }

    private func sleep(milliseconds: UInt64) async throws {
        try await Task.sleep(nanoseconds: milliseconds * 1_000_000)
    }

    private func runProcess(executableURL: URL, arguments: [String]) async throws {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let process = Process()
                    process.executableURL = executableURL
                    process.arguments = arguments
                    process.standardOutput = FileHandle.standardOutput
                    process.standardError = FileHandle.standardError
                    try process.run()
                    process.waitUntilExit()

                    if process.terminationStatus == 0 {
                        continuation.resume()
                    } else {
                        continuation.resume(throwing: HarnessError.processFailed(
                            executableURL.path,
                            process.terminationStatus
                        ))
                    }
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}

private enum InputSource: String {
    case systemEvents = "system-events"
    case cgEvent = "cgevent"
    case directForward = "direct-forward"
}

private struct TargetWindow {
    let windowID: UInt32
    let bounds: CGRect
}

private enum HarnessError: Error, CustomStringConvertible {
    case targetWindowNotFound(pid_t)
    case unexpectedOutput(expected: String, actual: String)
    case processFailed(String, Int32)

    var description: String {
        switch self {
        case .targetWindowNotFound(let pid):
            return "target window not found for pid \(pid)"
        case .unexpectedOutput(let expected, let actual):
            return "expected output \(String(reflecting: expected)), got \(String(reflecting: actual))"
        case .processFailed(let path, let status):
            return "\(path) exited with status \(status)"
        }
    }
}

private func keyCode(for character: Character) -> CGKeyCode? {
    switch character {
    case "a": 0
    case "s": 1
    case "d": 2
    case "f": 3
    case "h": 4
    case "g": 5
    case "z": 6
    case "x": 7
    case "c": 8
    case "v": 9
    case "b": 11
    case "q": 12
    case "w": 13
    case "e": 14
    case "r": 15
    case "y": 16
    case "t": 17
    case "1": 18
    case "2": 19
    case "3": 20
    case "4": 21
    case "6": 22
    case "5": 23
    case "9": 25
    case "7": 26
    case "8": 28
    case "0": 29
    case "o": 31
    case "u": 32
    case "i": 34
    case "p": 35
    case "l": 37
    case "j": 38
    case "k": 40
    case "n": 45
    case "m": 46
    default:
        nil
    }
}
