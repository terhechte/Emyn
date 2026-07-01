import AppKit
import ApplicationServices
import Carbon.HIToolbox
import CoreGraphics
import Foundation

/// Installs a system-level event tap that intercepts all mouse and keyboard
/// input and forwards it to a target app, hiding the system cursor.
///
/// ## Usage
/// ```swift
/// let session = CaptureSession(controller: ctrl)
/// session.onMouseMove = { normalised in
///     softwareCursorView.frame.origin = normalised  // drive your own cursor
/// }
/// session.onDeactivate = { /* re-enable UI */ }
/// try session.activate(mappedTo: screenshotView)
/// ```
///
/// ## Coordinate mapping
/// The view's current screen frame is mapped linearly onto the target app's
/// focused window. A point at the top-left of the view sends a click to the
/// top-left of the target window, and so on.
///
/// ## Escape
/// Press the Option (⌥) key `escapeKeyTapCount` times within
/// `escapeTapInterval` seconds to deactivate (default: 3 taps / 1 s).
/// All Option events are still forwarded to the target app.
public final class CaptureSession {

    public let controller: RemoteAppController

    /// Number of consecutive Option taps that trigger deactivation.
    public var escapeKeyTapCount: Int = 3
    /// Time window (seconds) in which the taps must occur.
    public var escapeTapInterval: TimeInterval = 1.0

    public private(set) var isActive = false

    /// Called on the main thread when the session deactivates (via escape or `deactivate()`).
    public var onDeactivate: (() -> Void)?

    /// Called on the main thread whenever a mouse event is intercepted.
    /// Provides the cursor position in **normalised view space** (0…1 in each
    /// axis, clamped) so you can position a software cursor over your screenshot.
    public var onMouseMove: ((_ normalised: CGPoint) -> Void)?

    // MARK: – Private state

    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var tapRetain: Unmanaged<CaptureSession>?

    private var viewBounds: CGRect = .zero    // CG screen space (y-down)
    private var targetBounds: CGRect = .zero  // CG screen space (y-down)

    private var altPressTimes: [TimeInterval] = []

    // MARK: – Init

    public init(controller: RemoteAppController) {
        self.controller = controller
    }

    deinit { removeTap() }

    // MARK: – Public API

    /// Activate, auto-detecting the view's screen frame and the target app's
    /// focused window as the coordinate endpoints.
    public func activate(mappedTo view: NSView) throws {
        guard !isActive else { return }
        guard let vb = Self.cgScreenRect(for: view) else {
            throw SilvaLiteError.inputSimulationFailed("View has no window — make sure the view is visible before calling activate")
        }
        let tb = try Self.focusedWindowBounds(pid: controller.targetApp.pid)
        activate(viewBoundsInCGSpace: vb, targetBoundsInCGSpace: tb)
    }

    /// Activate with explicit bounds (both in CoreGraphics screen space: origin
    /// at top-left of primary display, y increasing downward).
    public func activate(viewBoundsInCGSpace: CGRect, targetBoundsInCGSpace: CGRect) {
        guard !isActive else { return }
        viewBounds = viewBoundsInCGSpace
        targetBounds = targetBoundsInCGSpace
        installTap()
    }

    /// Release the event tap and restore the system cursor.
    public func deactivate() {
        guard isActive else { return }
        removeTap()
        CGDisplayShowCursor(CGMainDisplayID())
        isActive = false
        altPressTimes.removeAll()
        onDeactivate?()
    }

    // MARK: – Tap installation

    private func installTap() {
        var mask: CGEventMask = 0
        for t: CGEventType in [.mouseMoved, .leftMouseDown, .leftMouseUp, .leftMouseDragged,
                                .rightMouseDown, .rightMouseUp, .rightMouseDragged,
                                .otherMouseDown, .otherMouseUp, .otherMouseDragged,
                                .scrollWheel, .keyDown, .keyUp, .flagsChanged] {
            mask |= Self.bit(t)
        }

        let retain = Unmanaged.passRetained(self)

        guard let newTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, event, userInfo -> Unmanaged<CGEvent>? in
                guard let userInfo else { return Unmanaged.passRetained(event) }
                let s = Unmanaged<CaptureSession>.fromOpaque(userInfo).takeUnretainedValue()
                return s.handle(type: type, event: event)
            },
            userInfo: retain.toOpaque()
        ) else {
            retain.release()
            return
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, newTap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: newTap, enable: true)

        tap = newTap
        runLoopSource = source
        tapRetain = retain
        isActive = true
        CGDisplayHideCursor(CGMainDisplayID())
    }

    private func removeTap() {
        guard let t = tap else { return }
        CGEvent.tapEnable(tap: t, enable: false)
        if let src = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), src, .commonModes)
        }
        tap = nil
        runLoopSource = nil
        tapRetain?.release()
        tapRetain = nil
    }

    // MARK: – Event handling (called on main run-loop thread)

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        // Re-enable the tap if macOS disabled it due to timeout
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let t = tap { CGEvent.tapEnable(tap: t, enable: true) }
            return Unmanaged.passRetained(event)
        }

        // ----- Keyboard -----
        if type == .flagsChanged || type == .keyDown || type == .keyUp {
            handleKeyEvent(type: type, event: event)
            // Forward to target (after escape check — all 3 alt taps are forwarded)
            event.copy()?.postToPid(controller.targetApp.pid)
            return nil  // suppress from normal delivery
        }

        // ----- Mouse -----
        let rawPoint = event.location
        let confined = confine(rawPoint)

        // Keep the hidden cursor within the view area
        if confined != rawPoint {
            CGWarpMouseCursorPosition(confined)
        }

        // Normalised position in view space (0…1)
        let norm = CGPoint(
            x: (confined.x - viewBounds.minX) / viewBounds.width,
            y: (confined.y - viewBounds.minY) / viewBounds.height
        )

        // Report position for software-cursor rendering
        if type == .mouseMoved || type == .leftMouseDragged
            || type == .rightMouseDragged || type == .otherMouseDragged {
            onMouseMove?(norm)
        }

        // Remap to target app coordinates and post
        let mapped = CGPoint(
            x: targetBounds.minX + norm.x * targetBounds.width,
            y: targetBounds.minY + norm.y * targetBounds.height
        )
        if let copy = event.copy() {
            copy.location = mapped
            copy.postToPid(controller.targetApp.pid)
        }
        return nil  // suppress from normal delivery
    }

    private func handleKeyEvent(type: CGEventType, event: CGEvent) {
        guard type == .flagsChanged else { return }
        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        let isOption = keyCode == Int64(kVK_Option) || keyCode == Int64(kVK_RightOption)
        guard isOption else {
            // Any non-option modifier resets the escape sequence
            altPressTimes.removeAll()
            return
        }

        let isDown = event.flags.contains(.maskAlternate)
        guard isDown else { return }  // only count key-down transitions

        let now = ProcessInfo.processInfo.systemUptime
        altPressTimes.append(now)
        altPressTimes = altPressTimes.filter { now - $0 < escapeTapInterval }

        if altPressTimes.count >= escapeKeyTapCount {
            altPressTimes.removeAll()
            // Defer so we finish the current callback before tearing down the tap
            DispatchQueue.main.async { [weak self] in self?.deactivate() }
        }
    }

    // MARK: – Coordinate helpers

    private func confine(_ point: CGPoint) -> CGPoint {
        CGPoint(
            x: min(max(point.x, viewBounds.minX), viewBounds.maxX),
            y: min(max(point.y, viewBounds.minY), viewBounds.maxY)
        )
    }

    private static func bit(_ type: CGEventType) -> CGEventMask {
        1 << type.rawValue
    }

    // MARK: – Screen rect conversion

    /// Convert an NSView's frame to CoreGraphics screen space (origin top-left, y↓).
    static func cgScreenRect(for view: NSView) -> CGRect? {
        guard let window = view.window else { return nil }
        let rectInWindow = view.convert(view.bounds, to: nil)
        let screenRect = window.convertToScreen(rectInWindow)
        // AppKit screen space has origin at bottom-left; CG space has origin at top-left.
        let maxY = NSScreen.screens.first?.frame.maxY ?? 0
        return CGRect(
            x: screenRect.origin.x,
            y: maxY - screenRect.origin.y - screenRect.height,
            width: screenRect.width,
            height: screenRect.height
        )
    }

    // MARK: – AX window bounds

    /// Bounds of the target app's focused (or first) window in CG screen space.
    static func focusedWindowBounds(pid: pid_t) throws -> CGRect {
        let app = AXUIElementCreateApplication(pid)

        var ref: CFTypeRef?
        if AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &ref) == .success,
           let window = ref {
            return try axBounds(window as! AXUIElement)
        }

        var windowsRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &windowsRef) == .success,
           let windows = windowsRef as? [AXUIElement], let first = windows.first {
            return try axBounds(first)
        }

        throw SilvaLiteError.inputSimulationFailed("Could not find a window for the target app")
    }

    private static func axBounds(_ window: AXUIElement) throws -> CGRect {
        var posRef: CFTypeRef?
        var sizeRef: CFTypeRef?
        AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &posRef)
        AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &sizeRef)

        guard let pv = posRef, let sv = sizeRef else {
            throw SilvaLiteError.inputSimulationFailed("Could not read target window position/size")
        }

        var pos = CGPoint.zero
        var size = CGSize.zero
        AXValueGetValue(pv as! AXValue, .cgPoint, &pos)
        AXValueGetValue(sv as! AXValue, .cgSize, &size)

        guard size.width > 0, size.height > 0 else {
            throw SilvaLiteError.inputSimulationFailed("Target window has zero size")
        }

        return CGRect(origin: pos, size: size)
    }
}
