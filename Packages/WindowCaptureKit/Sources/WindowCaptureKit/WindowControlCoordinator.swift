import AppKit
import ApplicationServices
import Combine
import Darwin
import PlatformMacOSKit

public enum WindowControlKeyPress {
    case leftArrow
    case rightArrow
    case space

    fileprivate var keyCode: CGKeyCode {
        switch self {
        case .leftArrow: return 123
        case .rightArrow: return 124
        case .space: return 49
        }
    }
}

@MainActor
public final class WindowControlCoordinator: ObservableObject {
    @Published public private(set) var isActive = false
    @Published public private(set) var statusText = "Window control inactive"
    @Published public private(set) var cursorNormalised: CGPoint?
    @Published public private(set) var cursorRegionNormalised = CGRect(x: 0, y: 0, width: 1, height: 1)

    private var session: WindowCaptureSession?
    private var secureInputPollTask: Task<Void, Never>?
    private static let secureKeyboardEntryMessage =
        "keyboard forwarding unavailable: another app has Secure Keyboard Entry enabled " +
        "(e.g. a password field, 1Password, or a terminal's Secure Keyboard Entry)"

    public init() {}

    public func activate(
        option: WindowBackgroundOption,
        mappedTo view: NSView?,
        fit: BackgroundMediaFit,
        alignment: BackgroundContentAlignment,
        outputSize: CGSize,
        excludeFunctionKeys: Bool
    ) {
        guard !isActive else { return }
        guard let view else {
            statusText = "Preview unavailable"
            return
        }
        let secureInputEnabled = Self.prepareForKeyboardCapture(in: view.window)
        Self.logPermissionState(context: "activate requested", secureInputEnabled: secureInputEnabled)
        guard Self.isAccessibilityTrusted(prompt: true) else {
            statusText = "Grant Accessibility access, then try again"
            return
        }
        guard Self.isInputMonitoringTrusted(prompt: true) else {
            Self.openInputMonitoringSettings()
            statusText = "Grant Input Monitoring access, then try again"
            return
        }
        guard let pid = option.window.owningApplication?.processID else {
            statusText = "Target app unavailable"
            return
        }

        let windowBounds = option.window.frame
        guard windowBounds.width > 0, windowBounds.height > 0 else {
            statusText = "Target window unavailable"
            return
        }

        guard let mapping = WindowPointerMapper.mapping(
            for: windowBounds,
            fit: fit,
            alignment: alignment,
            outputSize: outputSize,
            viewBounds: view.bounds
        ),
              let viewBounds = Self.cgScreenRect(for: mapping.viewRect, in: view),
              let cursorRegion = Self.normalisedCGRect(for: mapping.viewRect, in: view) else {
            statusText = "Preview unavailable"
            return
        }

        view.window?.orderFrontRegardless()

        let captureSession = WindowCaptureSession(
            targetPid: pid,
            targetWindowID: option.id,
            excludeFunctionKeys: excludeFunctionKeys
        )
        captureSession.onMouseMove = { [weak self] normalised in
            self?.cursorNormalised = normalised
        }
        captureSession.onDeactivate = { [weak self] in
            self?.finishDeactivation(status: "Window control stopped")
        }

        do {
            try captureSession.activate(
                viewBoundsInCGSpace: viewBounds,
                targetBoundsInCGSpace: mapping.targetRect
            )
        } catch {
            statusText = error.localizedDescription
            cursorNormalised = nil
            return
        }

        session = captureSession
        isActive = true
        cursorRegionNormalised = cursorRegion
        cursorNormalised = CGPoint(x: 0.5, y: 0.5)
        updateActiveStatus(appName: option.appName, secureInputEnabled: Self.isSecureEventInputEnabled())
        startSecureInputPolling(appName: option.appName)
    }

    public func deactivate() {
        guard let session else {
            finishDeactivation(status: "Window control inactive")
            return
        }

        session.deactivate()
        finishDeactivation(status: "Window control inactive")
    }

    public func setExcludeFunctionKeys(_ exclude: Bool) {
        session?.excludeFunctionKeys = exclude
    }

    public func pressKey(_ key: WindowControlKeyPress) {
        guard isActive, let session else { return }

        do {
            try session.forwardKey(keyCode: key.keyCode, keyDown: true)
            try session.forwardKey(keyCode: key.keyCode, keyDown: false)
        } catch {
            statusText = "Key press failed: \(error.localizedDescription)"
        }
    }

    private func finishDeactivation(status: String) {
        secureInputPollTask?.cancel()
        secureInputPollTask = nil
        session = nil
        isActive = false
        cursorNormalised = nil
        cursorRegionNormalised = CGRect(x: 0, y: 0, width: 1, height: 1)
        statusText = status
    }

    private func updateActiveStatus(appName: String, secureInputEnabled: Bool) {
        if secureInputEnabled {
            statusText = "Controlling \(appName); \(Self.secureKeyboardEntryMessage)"
        } else {
            statusText = "Controlling \(appName)"
        }
    }

    private func startSecureInputPolling(appName: String) {
        secureInputPollTask?.cancel()
        secureInputPollTask = Task { @MainActor [weak self] in
            var lastSecureInputEnabled: Bool?
            while !Task.isCancelled {
                let secureInputEnabled = Self.isSecureEventInputEnabled()
                if lastSecureInputEnabled != secureInputEnabled {
                    lastSecureInputEnabled = secureInputEnabled
                    self?.updateActiveStatus(
                        appName: appName,
                        secureInputEnabled: secureInputEnabled
                    )
                }
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
        }
    }

    private static func cgScreenRect(for rect: CGRect, in view: NSView) -> CGRect? {
        guard let window = view.window else { return nil }

        let rectInWindow = view.convert(rect, to: nil)
        let screenRect = window.convertToScreen(rectInWindow)
        let maxY = NSScreen.screens.map(\.frame.maxY).max() ?? 0

        return CGRect(
            x: screenRect.origin.x,
            y: maxY - screenRect.origin.y - screenRect.height,
            width: screenRect.width,
            height: screenRect.height
        )
    }

    private static func normalisedCGRect(for rect: CGRect, in view: NSView) -> CGRect? {
        guard let viewRect = cgScreenRect(for: view.bounds, in: view),
              let rect = cgScreenRect(for: rect, in: view),
              viewRect.width > 0,
              viewRect.height > 0 else {
            return nil
        }

        return CGRect(
            x: (rect.minX - viewRect.minX) / viewRect.width,
            y: (rect.minY - viewRect.minY) / viewRect.height,
            width: rect.width / viewRect.width,
            height: rect.height / viewRect.height
        )
    }

    private static func isAccessibilityTrusted(prompt: Bool) -> Bool {
        let options = [
            kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: prompt
        ] as CFDictionary

        return AXIsProcessTrustedWithOptions(options)
    }

    private static func isInputMonitoringTrusted(prompt: Bool) -> Bool {
        if CGPreflightListenEventAccess() {
            return true
        }

        return prompt && CGRequestListenEventAccess()
    }

    private typealias HIToolboxBooleanFunction = @convention(c) () -> UInt8

    private static let isSecureEventInputEnabledFunction: HIToolboxBooleanFunction? = {
        let path = "/System/Library/Frameworks/Carbon.framework/Frameworks/HIToolbox.framework/HIToolbox"
        guard let handle = dlopen(path, RTLD_LAZY | RTLD_GLOBAL),
              let symbol = dlsym(handle, "IsSecureEventInputEnabled") else {
            return nil
        }

        return unsafeBitCast(symbol, to: HIToolboxBooleanFunction.self)
    }()

    private static func prepareForKeyboardCapture(in window: NSWindow?) -> Bool {
        releaseAppKeyboardFocus(in: window)
        return isSecureEventInputEnabled()
    }

    private static func releaseAppKeyboardFocus(in window: NSWindow?) {
        let windows = [window, NSApp.keyWindow]
            .compactMap { $0 }
            .reduce(into: [NSWindow]()) { uniqueWindows, candidate in
                if !uniqueWindows.contains(where: { $0 === candidate }) {
                    uniqueWindows.append(candidate)
                }
            }

        for window in windows {
            window.endEditing(for: nil)
            window.makeFirstResponder(nil)
        }
    }

    private static func logPermissionState(context: String, secureInputEnabled: Bool) {
        print(
            "[window-control] \(context) ax=\(AXIsProcessTrusted()) " +
            "inputMonitoring=\(CGPreflightListenEventAccess()) " +
            "secureInput=\(secureInputEnabled) " +
            "bundle=\(Bundle.main.bundleIdentifier ?? "<none>") " +
            "executable=\(Bundle.main.executablePath ?? "<none>")"
        )
    }

    private static func isSecureEventInputEnabled() -> Bool {
        guard let isSecureEventInputEnabledFunction else {
            return false
        }

        return isSecureEventInputEnabledFunction() != 0
    }

    private static func openInputMonitoringSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent") else {
            return
        }

        NSWorkspace.shared.open(url)
    }
}
