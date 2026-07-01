import AppKit
import CoreGraphics
import Foundation

/// Controls a target macOS application by injecting synthetic input events.
///
/// All `CGPoint` coordinates are in global screen space (origin at bottom-left,
/// matching `CGEvent` coordinates). You can convert from AppKit view-local
/// coordinates via `view.convert(_:to:nil)` followed by
/// `window.convertPoint(toScreen:)`.
///
/// Input methods block the calling thread briefly (they include small sleeps for
/// event processing). Call them off the main thread when possible.
public final class RemoteAppController {
    public let targetApp: AppDescriptor

    public init(app: AppDescriptor) {
        self.targetApp = app
    }

    // MARK: – Mouse

    /// Click at a global screen point.
    public func click(at point: CGPoint, button: MouseButton = .left, clickCount: Int = 1) throws {
        try InputSimulation.click(at: point, button: button, clickCount: clickCount, pid: targetApp.pid)
    }

    public func rightClick(at point: CGPoint) throws {
        try click(at: point, button: .right)
    }

    public func doubleClick(at point: CGPoint) throws {
        try click(at: point, button: .left, clickCount: 2)
    }

    /// Scroll at a global screen point.
    public func scroll(at point: CGPoint, direction: ScrollDirection, pages: Double = 1.0) throws {
        try InputSimulation.scroll(at: point, direction: direction, pages: pages, pid: targetApp.pid)
    }

    /// Drag from one global screen point to another.
    public func drag(from start: CGPoint, to end: CGPoint) throws {
        try InputSimulation.drag(from: start, to: end, pid: targetApp.pid)
    }

    // MARK: – Keyboard

    /// Type a string of text into the target app.
    public func typeText(_ text: String) throws {
        try InputSimulation.typeText(text, pid: targetApp.pid)
    }

    /// Press a key combination.
    ///
    /// Examples: `"cmd+c"`, `"shift+tab"`, `"return"`, `"f5"`, `"ctrl+shift+z"`.
    public func pressKey(_ specification: String) throws {
        try InputSimulation.pressKey(specification, pid: targetApp.pid)
    }

    // MARK: – Window management

    /// Attempt to bring the target app's window to the front.
    public func activate() {
        targetApp._runningApplication.activate(options: [.activateAllWindows])
    }

    // MARK: – View

    /// Returns the target app's focused window bounds in CoreGraphics screen
    /// space (origin at top-left of primary display, y increasing downward).
    /// Useful when you need to position your overlay window precisely.
    public func frontWindowBounds() throws -> CGRect {
        try CaptureSession.focusedWindowBounds(pid: targetApp.pid)
    }

    /// Returns an `NSView` that captures all mouse and keyboard events and
    /// forwards them to the target app. Make this view first responder to
    /// receive keyboard events.
    ///
    /// Position the view's window over (or mapped to) the target app's window
    /// so that screen coordinates align. The view does not render any content.
    public func makeControlView() -> RemoteControlView {
        RemoteControlView(controller: self)
    }
}
