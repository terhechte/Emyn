import AppKit
import Combine
import CoreVideo
import ScreenCaptureKit

public struct WindowBackgroundOption: Identifiable {
    public let id: CGWindowID
    public let window: SCWindow
    public let appName: String
    public let windowTitle: String
    public let frame: CGRect
    public var previewImage: NSImage?

    public init(
        id: CGWindowID,
        window: SCWindow,
        appName: String,
        windowTitle: String,
        frame: CGRect,
        previewImage: NSImage? = nil
    ) {
        self.id = id
        self.window = window
        self.appName = appName
        self.windowTitle = windowTitle
        self.frame = frame
        self.previewImage = previewImage
    }

    public var displayTitle: String {
        if windowTitle.isEmpty {
            return appName
        }

        return "\(appName) - \(windowTitle)"
    }
}

@MainActor
@available(macOS 14.0, *)
public final class WindowBackgroundPickerModel: ObservableObject {
    @Published public private(set) var options: [WindowBackgroundOption] = []
    @Published public private(set) var isLoading = false
    @Published public private(set) var statusText = "Loading windows"

    private var refreshGeneration = UUID()
    private static let previewBackgroundColor = CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0)

    public init() {}

    public func refresh() {
        let generation = UUID()
        refreshGeneration = generation
        isLoading = true
        statusText = "Loading windows"
        options = []

        Task { [weak self] in
            guard let self else { return }

            do {
                let content = try await SCShareableContent.excludingDesktopWindows(
                    false,
                    onScreenWindowsOnly: false
                )
                let windows = Self.makeOptions(from: content)

                guard refreshGeneration == generation else { return }
                options = windows
                isLoading = false
                statusText = windows.isEmpty ? "No windows available" : "\(windows.count) windows"

                await loadPreviews(for: windows, generation: generation)
            } catch {
                guard refreshGeneration == generation else { return }
                isLoading = false
                statusText = error.localizedDescription
            }
        }
    }

    private func loadPreviews(for options: [WindowBackgroundOption], generation: UUID) async {
        for option in options {
            guard refreshGeneration == generation else { return }

            do {
                let image = try await Self.capturePreview(for: option.window, frame: option.frame)
                guard refreshGeneration == generation,
                      let index = self.options.firstIndex(where: { $0.id == option.id }) else {
                    return
                }

                self.options[index].previewImage = image
            } catch {
                guard refreshGeneration == generation else { return }
                statusText = error.localizedDescription
            }
        }
    }

    private static func makeOptions(from content: SCShareableContent) -> [WindowBackgroundOption] {
        let currentBundleIdentifier = Bundle.main.bundleIdentifier
        let displayFrames = content.displays.map(\.frame)

        return content.windows.compactMap { window -> WindowBackgroundOption? in
            let intersectsDisplay = displayFrames.isEmpty || displayFrames.contains { $0.intersects(window.frame) }
            guard intersectsDisplay,
                  window.windowLayer == 0,
                  window.frame.width >= 96,
                  window.frame.height >= 72,
                  window.owningApplication?.bundleIdentifier != currentBundleIdentifier else {
                return nil
            }

            let appName = window.owningApplication?.applicationName ?? "Unknown App"
            let title = window.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

            return WindowBackgroundOption(
                id: window.windowID,
                window: window,
                appName: appName,
                windowTitle: title,
                frame: window.frame
            )
        }
        .sorted {
            if $0.appName.localizedCaseInsensitiveCompare($1.appName) == .orderedSame {
                return $0.windowTitle.localizedCaseInsensitiveCompare($1.windowTitle) == .orderedAscending
            }

            return $0.appName.localizedCaseInsensitiveCompare($1.appName) == .orderedAscending
        }
    }

    private static func capturePreview(for window: SCWindow, frame: CGRect) async throws -> NSImage {
        try await withCheckedThrowingContinuation { continuation in
            let filter = SCContentFilter(desktopIndependentWindow: window)
            let configuration = makePreviewConfiguration(frame: frame)
            SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration) { image, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let image {
                    continuation.resume(returning: NSImage(
                        cgImage: image,
                        size: NSSize(width: image.width, height: image.height)
                    ))
                } else {
                    continuation.resume(throwing: NSError(
                        domain: "WindowCaptureKit.WindowBackgroundPicker",
                        code: 1,
                        userInfo: [NSLocalizedDescriptionKey: "Window preview unavailable"]
                    ))
                }
            }
        }
    }

    private static func makePreviewConfiguration(frame: CGRect) -> SCStreamConfiguration {
        let aspectRatio = max(0.25, min(4.0, frame.height / max(frame.width, 1)))
        let width = 360
        let height = max(110, min(260, Int(CGFloat(width) * aspectRatio)))

        let configuration = SCStreamConfiguration()
        configuration.width = width
        configuration.height = height
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.showsCursor = false
        configuration.scalesToFit = true
        configuration.preservesAspectRatio = true
        configuration.ignoreShadowsSingleWindow = true
        configuration.shouldBeOpaque = false
        configuration.backgroundColor = previewBackgroundColor
        return configuration
    }
}
