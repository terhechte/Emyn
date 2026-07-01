import AppKit
import ApplicationServices
import Combine
import PlatformMacOSKit
import ScreenCaptureKit

@MainActor
final class WindowControlCoordinator: ObservableObject {
    @Published private(set) var isActive = false
    @Published private(set) var statusText = "Window control inactive"
    @Published private(set) var cursorNormalised: CGPoint?
    @Published private(set) var cursorRegionNormalised = CGRect(x: 0, y: 0, width: 1, height: 1)

    private var session: WindowCaptureSession?
    private static let outputSize = CGSize(
        width: SharedFrameConfiguration.width,
        height: SharedFrameConfiguration.height
    )

    func activate(option: WindowBackgroundOption, mappedTo view: NSView?, excludeFunctionKeys: Bool) {
        guard !isActive else { return }
        guard let view else {
            statusText = "Preview unavailable"
            return
        }
        guard Self.isAccessibilityTrusted(prompt: true) else {
            statusText = "Grant Accessibility access, then try again"
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

        let controlRect = Self.videoOutputRect(in: view)
        guard let viewBounds = Self.cgScreenRect(for: controlRect, in: view),
              let cursorRegion = Self.normalisedCGRect(for: controlRect, in: view) else {
            statusText = "Preview unavailable"
            return
        }

        let targetBounds = Self.visibleTargetRect(for: windowBounds)

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
            try captureSession.activate(viewBoundsInCGSpace: viewBounds, targetBoundsInCGSpace: targetBounds)
        } catch {
            statusText = error.localizedDescription
            cursorNormalised = nil
            return
        }

        session = captureSession
        isActive = true
        cursorRegionNormalised = cursorRegion
        cursorNormalised = CGPoint(x: 0.5, y: 0.5)
        statusText = "Controlling \(option.appName)"
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
        session = nil
        isActive = false
        cursorNormalised = nil
        cursorRegionNormalised = CGRect(x: 0, y: 0, width: 1, height: 1)
        statusText = status
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

    private static func visibleTargetRect(for windowBounds: CGRect) -> CGRect {
        let outputAspect = outputSize.width / outputSize.height
        let windowAspect = windowBounds.width / max(windowBounds.height, 1)

        if windowAspect > outputAspect {
            let visibleWidth = windowBounds.height * outputAspect
            return CGRect(
                x: windowBounds.minX + (windowBounds.width - visibleWidth) * 0.5,
                y: windowBounds.minY,
                width: visibleWidth,
                height: windowBounds.height
            )
        } else {
            let visibleHeight = windowBounds.width / outputAspect
            return CGRect(
                x: windowBounds.minX,
                y: windowBounds.minY + (windowBounds.height - visibleHeight) * 0.5,
                width: windowBounds.width,
                height: visibleHeight
            )
        }
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
}
