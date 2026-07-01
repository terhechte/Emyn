/// SilvaLite — lightweight macOS app remote-control library.
///
/// Quick start:
/// ```swift
/// let app = try AppBrowser.find("Safari")
/// let ctrl = RemoteAppController(app: app)
/// try ctrl.click(at: CGPoint(x: 400, y: 300))
/// try ctrl.pressKey("cmd+t")
///
/// // Or use RemoteControlView to forward your own events:
/// let view = ctrl.makeControlView()
/// window.contentView = view
/// window.makeFirstResponder(view)
/// ```
