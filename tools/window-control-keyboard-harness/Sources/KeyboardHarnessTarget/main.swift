import AppKit
import SwiftUI

private let targetWindowTitle = "Emyn Keyboard Harness Target"

@main
struct KeyboardHarnessTargetApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var recorder: TextRecorder

    init() {
        _recorder = StateObject(wrappedValue: TextRecorder(outputURL: Self.outputURL()))
    }

    var body: some Scene {
        WindowGroup(targetWindowTitle) {
            TargetContentView(recorder: recorder)
                .frame(width: 520, height: 160)
        }
        .defaultSize(width: 520, height: 160)
    }

    private static func outputURL() -> URL {
        let arguments = CommandLine.arguments
        if let index = arguments.firstIndex(of: "--output"), arguments.indices.contains(index + 1) {
            return URL(fileURLWithPath: arguments[index + 1])
        }

        return URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("emyn-keyboard-harness-target.txt")
    }
}

private final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

private final class TextRecorder: ObservableObject {
    @Published var text = "" {
        didSet {
            write()
        }
    }

    private let outputURL: URL

    init(outputURL: URL) {
        self.outputURL = outputURL
        write()
    }

    private func write() {
        do {
            let parent = outputURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
            try text.write(to: outputURL, atomically: true, encoding: .utf8)
        } catch {
            fputs("KeyboardHarnessTarget write failed: \(error)\n", stderr)
        }
    }
}

private struct TargetContentView: View {
    @ObservedObject var recorder: TextRecorder
    @FocusState private var inputFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Keyboard Harness")
                .font(.headline)

            TextField("Type here", text: $recorder.text)
                .textFieldStyle(.roundedBorder)
                .focused($inputFocused)
                .accessibilityIdentifier("keyboard-harness-text-field")

            Text(recorder.text.isEmpty ? "Waiting for input" : recorder.text)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(20)
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                inputFocused = true
            }
        }
    }
}
