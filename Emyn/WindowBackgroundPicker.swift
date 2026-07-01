import AppKit
import Combine
import CoreVideo
import ScreenCaptureKit
import SwiftUI

struct WindowBackgroundOption: Identifiable {
    let id: CGWindowID
    let window: SCWindow
    let appName: String
    let windowTitle: String
    let frame: CGRect
    var previewImage: NSImage?

    var displayTitle: String {
        if windowTitle.isEmpty {
            return appName
        }

        return "\(appName) - \(windowTitle)"
    }
}

@MainActor
final class WindowBackgroundPickerModel: ObservableObject {
    @Published private(set) var options: [WindowBackgroundOption] = []
    @Published private(set) var isLoading = false
    @Published private(set) var statusText = "Loading windows"

    private var refreshGeneration = UUID()
    private static let previewBackgroundColor = CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1)

    func refresh() {
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
                frame: window.frame,
                previewImage: nil
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
                        domain: "com.stylemac.Emyn.WindowBackgroundPicker",
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
        configuration.shouldBeOpaque = true
        configuration.backgroundColor = previewBackgroundColor
        return configuration
    }
}

struct WindowBackgroundPickerView: View {
    @ObservedObject var model: WindowBackgroundPickerModel
    let onSelect: (WindowBackgroundOption) -> Void
    let onCancel: () -> Void

    private let columns = [
        GridItem(.adaptive(minimum: 210, maximum: 260), spacing: 14)
    ]

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            content
        }
        .frame(width: 760, height: 560)
        .onAppear {
            if model.options.isEmpty {
                model.refresh()
            }
        }
    }

    private var toolbar: some View {
        HStack(spacing: 10) {
            Text("Select Window")
                .font(.headline)

            Text(model.statusText)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)

            Spacer()

            Button {
                model.refresh()
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .disabled(model.isLoading)
            .help("Refresh windows")

            Button("Cancel") {
                onCancel()
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
    }

    @ViewBuilder
    private var content: some View {
        if model.options.isEmpty && model.isLoading {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if model.options.isEmpty {
            ContentUnavailableView("No Windows", systemImage: "rectangle.on.rectangle.slash")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVGrid(columns: columns, alignment: .leading, spacing: 14) {
                    ForEach(model.options) { option in
                        Button {
                            onSelect(option)
                        } label: {
                            WindowBackgroundOptionView(option: option)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(18)
            }
        }
    }
}

private struct WindowBackgroundOptionView: View {
    let option: WindowBackgroundOption

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack {
                Rectangle()
                    .fill(Color(nsColor: .controlBackgroundColor))

                if let image = option.previewImage {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFit()
                } else {
                    ProgressView()
                        .controlSize(.small)
                }
            }
            .frame(height: 130)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay {
                RoundedRectangle(cornerRadius: 6)
                    .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(option.appName)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                Text(option.windowTitle.isEmpty ? "Untitled Window" : option.windowTitle)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(8)
        .background(Color(nsColor: .textBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
        }
    }
}
