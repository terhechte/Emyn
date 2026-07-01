import CoreGraphics
import Foundation
#if canImport(platform_macosFFI)
import platform_macosFFI
#endif

/// Ergonomic wrapper around the uniffi-generated `CaptureSession`.
///
/// The Rust side is polling-based, not callback-based (uniffi's `Arc<dyn Fn>`
/// can't cross the FFI), so this polls `drainEvents()` on a timer and
/// re-exposes the results as closures.
public final class WindowCaptureSession {
    private let session: CaptureSession
    private var timer: Timer?

    public var onMouseMove: ((CGPoint) -> Void)?
    public var onDeactivate: (() -> Void)?

    public init(targetPid: pid_t) {
        session = CaptureSession(targetPid: Int32(targetPid))
    }

    public var isActive: Bool { session.isActive() }

    /// Both bounds must be in CG screen space (top-left origin, y increasing
    /// downward), matching `CGEventGetLocation`/the AX API.
    public func activate(viewBoundsInCGSpace view: CGRect, targetBoundsInCGSpace target: CGRect) throws {
        try session.activateWithRects(
            viewRect: Rect(x: view.origin.x, y: view.origin.y, width: view.width, height: view.height),
            targetRect: Rect(x: target.origin.x, y: target.origin.y, width: target.width, height: target.height)
        )
        startPolling()
    }

    public func deactivate() {
        session.deactivate()
        stopPolling()
    }

    private func startPolling() {
        stopPolling()
        // kCFRunLoopCommonModes on the Rust side, so this must match to keep
        // ticking during tracking loops (e.g. window drags).
        let t = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            self?.drain()
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func stopPolling() {
        timer?.invalidate()
        timer = nil
    }

    private func drain() {
        for event in session.drainEvents() {
            switch event {
            case .mouseMove(let normX, let normY):
                onMouseMove?(CGPoint(x: normX, y: normY))
            case .deactivated:
                onDeactivate?()
                stopPolling()
            }
        }
    }
}
