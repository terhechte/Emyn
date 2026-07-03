import AppKit
import ApplicationServices
import Combine
import Darwin
import PlatformMacOSKit
import ScreenCaptureKit

@MainActor
final class WindowControlCoordinator: ObservableObject {
    @Published private(set) var isActive = false
    @Published private(set) var statusText = "Window control inactive"
    @Published private(set) var cursorNormalised: CGPoint?
    @Published private(set) var cursorRegionNormalised = CGRect(x: 0, y: 0, width: 1, height: 1)

    private var session: WindowCaptureSession?
    private var secureInputPollTask: Task<Void, Never>?
    private static var outputSize: CGSize {
        CGSize(
            width: SharedFrameConfiguration.outputFrameSize.width,
            height: SharedFrameConfiguration.outputFrameSize.height
        )
    }
    private static let secureKeyboardEntryMessage =
        "keyboard forwarding unavailable: another app has Secure Keyboard Entry enabled " +
        "(e.g. a password field, 1Password, or a terminal's Secure Keyboard Entry)"

    func activate(
        option: WindowBackgroundOption,
        mappedTo view: NSView?,
        fit: BackgroundMediaFit,
        alignment: BackgroundContentAlignment,
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

        guard let mapping = Self.controlMapping(
            for: windowBounds,
            fit: fit,
            alignment: alignment,
            in: view
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

    func deactivate() {
        guard let session else {
            finishDeactivation(status: "Window control inactive")
            return
        }

        session.deactivate()
        finishDeactivation(status: "Window control inactive")
    }

    func setExcludeFunctionKeys(_ exclude: Bool) {
        session?.excludeFunctionKeys = exclude
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

    private static func videoOutputRect(in view: NSView) -> CGRect {
        aspectFitRect(contentSize: outputSize, in: view.bounds)
    }

    private struct ControlMapping {
        var viewRect: CGRect
        var targetRect: CGRect
    }

    private static func controlMapping(
        for windowBounds: CGRect,
        fit: BackgroundMediaFit,
        alignment: BackgroundContentAlignment,
        in view: NSView
    ) -> ControlMapping? {
        guard windowBounds.width > 0,
              windowBounds.height > 0,
              outputSize.width > 0,
              outputSize.height > 0 else {
            return nil
        }

        let outputExtent = CGRect(origin: .zero, size: outputSize)
        let fittedRect = fittedContentRect(
            contentSize: windowBounds.size,
            fit: fit,
            alignment: alignment,
            outputExtent: outputExtent
        )

        let outputControlRect: CGRect
        let targetRect: CGRect
        switch fit {
        case .fill:
            outputControlRect = outputExtent
            targetRect = visibleTargetRect(
                for: windowBounds,
                fittedRect: fittedRect,
                outputExtent: outputExtent
            )
        case .contain:
            outputControlRect = fittedRect.intersection(outputExtent)
            targetRect = windowBounds
        case .scale:
            outputControlRect = outputExtent
            targetRect = windowBounds
        }

        guard !outputControlRect.isNull,
              outputControlRect.width > 0,
              outputControlRect.height > 0,
              targetRect.width > 0,
              targetRect.height > 0 else {
            return nil
        }

        return ControlMapping(
            viewRect: viewRect(forOutputRect: outputControlRect, in: view),
            targetRect: targetRect
        )
    }

    private static func fittedContentRect(
        contentSize: CGSize,
        fit: BackgroundMediaFit,
        alignment: BackgroundContentAlignment,
        outputExtent: CGRect
    ) -> CGRect {
        let scaleX: CGFloat
        let scaleY: CGFloat
        switch fit {
        case .fill:
            let scale = max(outputExtent.width / contentSize.width, outputExtent.height / contentSize.height)
            scaleX = scale
            scaleY = scale
        case .contain:
            let scale = min(outputExtent.width / contentSize.width, outputExtent.height / contentSize.height)
            scaleX = scale
            scaleY = scale
        case .scale:
            scaleX = outputExtent.width / contentSize.width
            scaleY = outputExtent.height / contentSize.height
        }

        let scaledSize = CGSize(
            width: contentSize.width * scaleX,
            height: contentSize.height * scaleY
        )
        return CGRect(
            origin: alignment.origin(for: scaledSize, in: outputExtent),
            size: scaledSize
        )
    }

    private static func visibleTargetRect(
        for windowBounds: CGRect,
        fittedRect: CGRect,
        outputExtent: CGRect
    ) -> CGRect {
        let visibleOutputRect = fittedRect.intersection(outputExtent)
        guard !visibleOutputRect.isNull,
              fittedRect.width > 0,
              fittedRect.height > 0 else {
            return windowBounds
        }

        let scaleX = fittedRect.width / windowBounds.width
        let scaleY = fittedRect.height / windowBounds.height
        guard scaleX > 0, scaleY > 0 else {
            return windowBounds
        }

        let visibleMinX = max(0, (visibleOutputRect.minX - fittedRect.minX) / scaleX)
        let visibleMaxX = min(windowBounds.width, (visibleOutputRect.maxX - fittedRect.minX) / scaleX)
        let visibleMinYFromBottom = max(0, (visibleOutputRect.minY - fittedRect.minY) / scaleY)
        let visibleMaxYFromBottom = min(windowBounds.height, (visibleOutputRect.maxY - fittedRect.minY) / scaleY)

        let visibleWidth = max(0, visibleMaxX - visibleMinX)
        let visibleHeight = max(0, visibleMaxYFromBottom - visibleMinYFromBottom)
        guard visibleWidth > 0, visibleHeight > 0 else {
            return windowBounds
        }

        return CGRect(
            x: windowBounds.minX + visibleMinX,
            y: windowBounds.minY + windowBounds.height - visibleMaxYFromBottom,
            width: visibleWidth,
            height: visibleHeight
        )
    }

    private static func viewRect(forOutputRect outputRect: CGRect, in view: NSView) -> CGRect {
        let videoRect = videoOutputRect(in: view)
        let scaleX = videoRect.width / outputSize.width
        let scaleY = videoRect.height / outputSize.height

        return CGRect(
            x: videoRect.minX + outputRect.minX * scaleX,
            y: videoRect.minY + outputRect.minY * scaleY,
            width: outputRect.width * scaleX,
            height: outputRect.height * scaleY
        )
    }

    private static func aspectFitRect(contentSize: CGSize, in container: CGRect) -> CGRect {
        guard contentSize.width > 0,
              contentSize.height > 0,
              container.width > 0,
              container.height > 0 else {
            return container
        }

        let scale = min(container.width / contentSize.width, container.height / contentSize.height)
        let size = CGSize(width: contentSize.width * scale, height: contentSize.height * scale)
        return CGRect(
            x: container.midX - size.width * 0.5,
            y: container.midY - size.height * 0.5,
            width: size.width,
            height: size.height
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
