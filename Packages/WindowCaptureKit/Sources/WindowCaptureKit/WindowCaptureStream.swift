import AppKit
import CoreMedia
import CoreVideo
import Foundation
import ScreenCaptureKit

/// A reusable ScreenCaptureKit stream for a single desktop-independent window.
public final class WindowCaptureStream: NSObject, @unchecked Sendable {
    public var onFrame: ((CVPixelBuffer) -> Void)?
    public var onStarted: (() -> Void)?
    public var onStopped: ((Error?) -> Void)?

    private let queue: DispatchQueue
    private var stream: SCStream?
    private static let transparentBackgroundColor = CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0)

    public init(queue: DispatchQueue? = nil) {
        self.queue = queue ?? DispatchQueue(
            label: "WindowCaptureKit.stream",
            qos: .userInitiated
        )
        super.init()
    }

    public func start(
        window: SCWindow,
        maximumSize: CGSize,
        pixelFormat: OSType = kCVPixelFormatType_32BGRA,
        framesPerSecond: Int32 = 30
    ) {
        queue.async {
            self.stopCurrentStream()

            let filter = SCContentFilter(desktopIndependentWindow: window)
            let configuration = Self.configuration(
                for: window.frame,
                maximumSize: maximumSize,
                pixelFormat: pixelFormat,
                framesPerSecond: framesPerSecond
            )
            let stream = SCStream(filter: filter, configuration: configuration, delegate: self)

            do {
                try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: self.queue)
                self.stream = stream
                stream.startCapture { error in
                    self.queue.async {
                        guard self.stream === stream else { return }
                        if let error {
                            self.stream = nil
                            self.onStopped?(error)
                        } else {
                            self.onStarted?()
                        }
                    }
                }
            } catch {
                self.onStopped?(error)
            }
        }
    }

    public func stop() {
        queue.async {
            self.stopCurrentStream()
        }
    }

    private func stopCurrentStream() {
        guard let stream else { return }
        self.stream = nil
        stream.stopCapture { _ in }
    }

    private static func configuration(
        for frame: CGRect,
        maximumSize: CGSize,
        pixelFormat: OSType,
        framesPerSecond: Int32
    ) -> SCStreamConfiguration {
        let scale = backingScaleFactor(for: frame)
        let captureSize = WindowBackgroundCaptureSizer.captureSize(
            rawWidth: frame.width * scale,
            rawHeight: frame.height * scale,
            maxWidth: Int(maximumSize.width.rounded()),
            maxHeight: Int(maximumSize.height.rounded())
        )

        let configuration = SCStreamConfiguration()
        configuration.width = captureSize.width
        configuration.height = captureSize.height
        configuration.pixelFormat = pixelFormat
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: framesPerSecond)
        configuration.queueDepth = 3
        configuration.showsCursor = false
        configuration.scalesToFit = true
        if #available(macOS 14.0, *) {
            configuration.preservesAspectRatio = true
            configuration.ignoreShadowsSingleWindow = true
            configuration.shouldBeOpaque = false
        }
        configuration.backgroundColor = transparentBackgroundColor
        return configuration
    }

    private static func backingScaleFactor(for frame: CGRect) -> CGFloat {
        let center = CGPoint(x: frame.midX, y: frame.midY)
        return NSScreen.screens.first { $0.frame.contains(center) }?.backingScaleFactor
            ?? NSScreen.main?.backingScaleFactor
            ?? 2
    }

    private static func isCompleteOrIdleFrame(_ sampleBuffer: CMSampleBuffer) -> Bool {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
                as? [[SCStreamFrameInfo: Any]],
              let rawStatus = attachments.first?[SCStreamFrameInfo.status] as? Int,
              let status = SCFrameStatus(rawValue: rawStatus) else {
            return true
        }

        return status == .complete || status == .idle || status == .started
    }
}

extension WindowCaptureStream: SCStreamOutput, SCStreamDelegate {
    public func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of type: SCStreamOutputType
    ) {
        guard type == .screen,
              self.stream === stream,
              sampleBuffer.isValid,
              Self.isCompleteOrIdleFrame(sampleBuffer),
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            return
        }

        onFrame?(pixelBuffer)
    }

    public func stream(_ stream: SCStream, didStopWithError error: Error) {
        queue.async {
            guard self.stream === stream else { return }
            self.stream = nil
            self.onStopped?(error)
        }
    }
}
