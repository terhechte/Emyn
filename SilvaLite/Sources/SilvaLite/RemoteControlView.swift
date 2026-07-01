import AppKit
import CoreGraphics

/// An `NSView` that captures all mouse and keyboard events and forwards them
/// to a remote target app via `CGEvent.postToPid`.
///
/// ## Setup
/// ```swift
/// let view = controller.makeControlView()
/// window.contentView = view
/// window.makeFirstResponder(view)   // required for keyboard events
/// ```
///
/// ## Coordinate mapping
/// Events are forwarded with their original screen coordinates. Position your
/// window so that its screen area corresponds to the visible area of the target
/// app's window — the user then "sees through" your view into the target app.
///
/// If you capture the target app's screen using `ScreenCaptureKit` or a
/// `CGWindowListCreateImage` snapshot and display it as the view's layer
/// contents, the coordinates align automatically.
public final class RemoteControlView: NSView {

    public var controller: RemoteAppController
    private var trackingArea: NSTrackingArea?

    public init(controller: RemoteAppController) {
        self.controller = controller
        super.init(frame: .zero)
        wantsLayer = true
    }

    required init?(coder: NSCoder) {
        fatalError("Use init(controller:)")
    }

    public override var acceptsFirstResponder: Bool { true }

    // MARK: – Tracking area (mouse-moved events require this)

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        rebuildTrackingArea()
    }

    public override func updateTrackingAreas() {
        super.updateTrackingAreas()
        rebuildTrackingArea()
    }

    private func rebuildTrackingArea() {
        if let old = trackingArea { removeTrackingArea(old) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.activeAlways, .mouseMoved, .mouseEnteredAndExited, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    // MARK: – Event forwarding
    //
    // NSEvent.cgEvent returns the underlying CGEvent. We copy it (to get an
    // independent, mutable object) then redirect it to the target PID.
    // The event's position and data are already correct — the only change is
    // the destination process.

    private func forward(_ event: NSEvent) {
        event.cgEvent?.copy()?.postToPid(controller.targetApp.pid)
    }

    // Mouse
    public override func mouseDown(with event: NSEvent)       { forward(event) }
    public override func mouseUp(with event: NSEvent)         { forward(event) }
    public override func mouseDragged(with event: NSEvent)    { forward(event) }
    public override func mouseMoved(with event: NSEvent)      { forward(event) }
    public override func rightMouseDown(with event: NSEvent)  { forward(event) }
    public override func rightMouseUp(with event: NSEvent)    { forward(event) }
    public override func rightMouseDragged(with event: NSEvent) { forward(event) }
    public override func otherMouseDown(with event: NSEvent)  { forward(event) }
    public override func otherMouseUp(with event: NSEvent)    { forward(event) }
    public override func otherMouseDragged(with event: NSEvent) { forward(event) }
    public override func scrollWheel(with event: NSEvent)     { forward(event) }

    // Keyboard (requires first responder)
    public override func keyDown(with event: NSEvent)         { forward(event) }
    public override func keyUp(with event: NSEvent)           { forward(event) }
    public override func flagsChanged(with event: NSEvent)    { forward(event) }
}
