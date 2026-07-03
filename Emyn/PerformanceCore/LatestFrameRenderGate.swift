import Foundation

final class LatestFrameRenderGate<Frame> {
    private let lock = NSLock()
    private var renderInFlight = false
    private var pendingFrame: Frame?

    func begin(with frame: Frame) -> Frame? {
        lock.lock()
        defer { lock.unlock() }

        guard !renderInFlight else {
            pendingFrame = frame
            return nil
        }

        renderInFlight = true
        return frame
    }

    func finish() -> Frame? {
        lock.lock()
        defer { lock.unlock() }

        guard let frame = pendingFrame else {
            renderInFlight = false
            return nil
        }

        pendingFrame = nil
        return frame
    }
}
