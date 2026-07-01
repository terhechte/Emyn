import AppKit
import Combine
import ScreenCaptureKit
import SilvaLite

@MainActor
final class WindowControlCoordinator: ObservableObject {
    @Published private(set) var isActive = false
    @Published private(set) var statusText = "Window control inactive"
    @Published private(set) var cursorNormalised: CGPoint?

    private var session: CaptureSession?

    func activate(option: WindowBackgroundOption, mappedTo view: NSView?) {
        guard !isActive else { return }
        guard let view else {
            statusText = "Preview unavailable"
            return
        }
        guard let pid = option.window.owningApplication?.processID,
              let app = AppBrowser.runningApps().first(where: { $0.pid == pid }) else {
            statusText = "Target app unavailable"
            return
        }

        guard let viewBounds = Self.cgScreenRect(for: view) else {
            statusText = "Preview unavailable"
            return
        }

        let targetBounds = option.window.frame
        guard targetBounds.width > 0, targetBounds.height > 0 else {
            statusText = "Target window unavailable"
            return
        }

        let controller = RemoteAppController(app: app)
        let captureSession = CaptureSession(controller: controller)
        captureSession.onMouseMove = { [weak self] normalised in
            self?.cursorNormalised = normalised
        }
        captureSession.onDeactivate = { [weak self] in
            self?.finishDeactivation(status: "Window control stopped")
        }

        captureSession.activate(viewBoundsInCGSpace: viewBounds, targetBoundsInCGSpace: targetBounds)
        guard captureSession.isActive else {
            statusText = "Accessibility permission is required"
            cursorNormalised = nil
            return
        }

        session = captureSession
        isActive = true
        cursorNormalised = CGPoint(x: 0.5, y: 0.5)
        statusText = "Controlling \(option.appName)"
    }

    func deactivate() {
        guard let session else {
            finishDeactivation(status: "Window control inactive")
            return
        }

        session.deactivate()
    }

    private func finishDeactivation(status: String) {
        session = nil
        isActive = false
        cursorNormalised = nil
        statusText = status
    }

    private static func cgScreenRect(for view: NSView) -> CGRect? {
        guard let window = view.window else { return nil }

        let rectInWindow = view.convert(view.bounds, to: nil)
        let screenRect = window.convertToScreen(rectInWindow)
        let maxY = NSScreen.screens.first?.frame.maxY ?? 0

        return CGRect(
            x: screenRect.origin.x,
            y: maxY - screenRect.origin.y - screenRect.height,
            width: screenRect.width,
            height: screenRect.height
        )
    }
}
