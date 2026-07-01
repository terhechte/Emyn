import AppKit
import Combine
import Foundation
import SwiftUI
import UniformTypeIdentifiers

enum FunctionKey: String, CaseIterable, Codable, Identifiable {
    case f1
    case f2
    case f3
    case f4
    case f5
    case f6
    case f7
    case f8
    case f9
    case f10
    case f11
    case f12

    var id: String { rawValue }

    var title: String {
        rawValue.uppercased()
    }

    var storageIdentifier: String {
        String(format: "F%02d", number)
    }

    var number: Int {
        switch self {
        case .f1: return 1
        case .f2: return 2
        case .f3: return 3
        case .f4: return 4
        case .f5: return 5
        case .f6: return 6
        case .f7: return 7
        case .f8: return 8
        case .f9: return 9
        case .f10: return 10
        case .f11: return 11
        case .f12: return 12
        }
    }

    init?(keyCode: UInt16) {
        switch keyCode {
        case 122: self = .f1
        case 120: self = .f2
        case 99: self = .f3
        case 118: self = .f4
        case 96: self = .f5
        case 97: self = .f6
        case 98: self = .f7
        case 100: self = .f8
        case 101: self = .f9
        case 109: self = .f10
        case 103: self = .f11
        case 111: self = .f12
        default: return nil
        }
    }
}

enum FunctionKeyAction: String, CaseIterable, Codable, Identifiable {
    case none
    case toggleWindowBackground
    case togglePersonPosition
    case toggleWindowAndPerson
    case toggleImageOverlay
    case toggleWindowZoom
    case drawAttentionToCursor

    var id: String { rawValue }

    var title: String {
        switch self {
        case .none: return "None"
        case .toggleWindowBackground: return "Window"
        case .togglePersonPosition: return "Person"
        case .toggleWindowAndPerson: return "Window + Person"
        case .toggleImageOverlay: return "Image"
        case .toggleWindowZoom: return "Zoom"
        case .drawAttentionToCursor: return "Cursor"
        }
    }

    var systemImage: String {
        switch self {
        case .none: return "minus.circle"
        case .toggleWindowBackground: return "rectangle.on.rectangle"
        case .togglePersonPosition: return "person.crop.rectangle"
        case .toggleWindowAndPerson: return "rectangle.on.rectangle"
        case .toggleImageOverlay: return "photo"
        case .toggleWindowZoom: return "plus.magnifyingglass"
        case .drawAttentionToCursor: return "cursorarrow.rays"
        }
    }

    static var sidebarActions: [FunctionKeyAction] {
        [
            .toggleWindowBackground,
            .togglePersonPosition,
            .toggleWindowZoom,
            .toggleWindowAndPerson,
            .drawAttentionToCursor
        ]
    }

    var needsWindowBackground: Bool {
        switch self {
        case .toggleWindowBackground, .toggleWindowZoom, .toggleWindowAndPerson:
            return true
        case .none, .togglePersonPosition, .toggleImageOverlay, .drawAttentionToCursor:
            return false
        }
    }
}

struct FunctionKeySlot: Codable, Equatable, Identifiable {
    var key: FunctionKey
    var action: FunctionKeyAction
    var imagePath: String?

    var id: String { key.id }
}

struct FunctionKeyConfiguration: Codable, Equatable {
    var slots: [FunctionKeySlot]

    private static let storageKey = "functionKeyConfiguration.v1"

    static var empty: FunctionKeyConfiguration {
        FunctionKeyConfiguration(
            slots: FunctionKey.allCases.map {
                FunctionKeySlot(key: $0, action: .none, imagePath: nil)
            }
        )
    }

    static func load() -> FunctionKeyConfiguration {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let decoded = try? JSONDecoder().decode(FunctionKeyConfiguration.self, from: data) else {
            return .empty
        }

        return decoded.normalized()
    }

    func save() {
        guard let data = try? JSONEncoder().encode(normalized()) else { return }
        UserDefaults.standard.set(data, forKey: Self.storageKey)
    }

    func slot(for key: FunctionKey) -> FunctionKeySlot {
        normalized().slots.first(where: { $0.key == key })
            ?? FunctionKeySlot(key: key, action: .none, imagePath: nil)
    }

    mutating func updateSlot(for key: FunctionKey, _ update: (inout FunctionKeySlot) -> Void) {
        self = normalized()
        guard let index = slots.firstIndex(where: { $0.key == key }) else {
            var slot = FunctionKeySlot(key: key, action: .none, imagePath: nil)
            update(&slot)
            slots.append(slot)
            self = normalized()
            return
        }

        update(&slots[index])
    }

    func normalized() -> FunctionKeyConfiguration {
        let existingByKey = Dictionary(uniqueKeysWithValues: slots.map { ($0.key, $0) })
        return FunctionKeyConfiguration(
            slots: FunctionKey.allCases.map { key in
                existingByKey[key] ?? FunctionKeySlot(key: key, action: .none, imagePath: nil)
            }
        )
    }
}

struct FunctionKeyTrigger {
    let key: FunctionKey
    let slot: FunctionKeySlot
}

@MainActor
final class FunctionKeyController: ObservableObject {
    @Published var configuration: FunctionKeyConfiguration {
        didSet {
            configuration.save()
        }
    }
    @Published private(set) var statusText = "Function keys ready"

    var onTrigger: ((FunctionKeyTrigger) -> Void)?

    private var localMonitor: Any?
    private var globalMonitor: Any?

    init(configuration: FunctionKeyConfiguration = .load()) {
        self.configuration = configuration.normalized()
    }

    func startMonitoring() {
        guard localMonitor == nil, globalMonitor == nil else { return }

        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            return self.handle(event: event) ? nil : event
        }

        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            _ = self?.handle(event: event)
        }
    }

    func stopMonitoring() {
        if let localMonitor {
            NSEvent.removeMonitor(localMonitor)
            self.localMonitor = nil
        }

        if let globalMonitor {
            NSEvent.removeMonitor(globalMonitor)
            self.globalMonitor = nil
        }
    }

    func slot(for key: FunctionKey) -> FunctionKeySlot {
        configuration.slot(for: key)
    }

    func setAction(_ action: FunctionKeyAction, for key: FunctionKey) {
        configuration.updateSlot(for: key) { slot in
            slot.action = action
            if action != .toggleImageOverlay {
                slot.imagePath = nil
            }
        }
    }

    func setImagePath(_ imagePath: String?, for key: FunctionKey) {
        configuration.updateSlot(for: key) { slot in
            slot.imagePath = imagePath
            if imagePath != nil {
                slot.action = .toggleImageOverlay
            }
        }
    }

    func reportManualAction(_ action: FunctionKeyAction, sourceTitle: String = "Button") {
        guard action != .none else { return }
        statusText = "\(sourceTitle): \(action.title)"
    }

    private func handle(event: NSEvent) -> Bool {
        guard !event.isARepeat,
              let key = FunctionKey(keyCode: event.keyCode),
              event.hasNoCommandModifiers else {
            return false
        }

        let slot = configuration.slot(for: key)
        guard slot.action != .none else { return false }

        if slot.action == .toggleImageOverlay, slot.imagePath == nil {
            statusText = "\(key.title): no image"
            return true
        }

        statusText = "\(key.title): \(slot.action.title)"
        onTrigger?(FunctionKeyTrigger(key: key, slot: slot))
        return true
    }
}

private extension NSEvent {
    var hasNoCommandModifiers: Bool {
        let blocked: ModifierFlags = [.command, .option, .control, .shift]
        return modifierFlags.intersection(blocked).isEmpty
    }
}

struct FunctionKeyConfigurationView: View {
    @ObservedObject var controller: FunctionKeyController
    let onClose: () -> Void

    private let columns = [
        GridItem(.adaptive(minimum: 196, maximum: 230), spacing: 12)
    ]

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            ScrollView {
                LazyVGrid(columns: columns, alignment: .leading, spacing: 12) {
                    ForEach(FunctionKey.allCases) { key in
                        FunctionKeySlotView(
                            key: key,
                            slot: controller.slot(for: key),
                            action: actionBinding(for: key),
                            onImageDropped: { url in
                                controller.setImagePath(url.path, for: key)
                            },
                            onClearImage: {
                                controller.setImagePath(nil, for: key)
                            }
                        )
                    }
                }
                .padding(18)
            }
        }
        .frame(width: 760, height: 560)
    }

    private var toolbar: some View {
        HStack(spacing: 10) {
            Text("Function Keys")
                .font(.headline)

            Text(controller.statusText)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)

            Spacer()

            Button("Done") {
                onClose()
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
    }

    private func actionBinding(for key: FunctionKey) -> Binding<FunctionKeyAction> {
        Binding {
            controller.slot(for: key).action
        } set: { action in
            controller.setAction(action, for: key)
        }
    }
}

private struct FunctionKeySlotView: View {
    let key: FunctionKey
    let slot: FunctionKeySlot
    @Binding var action: FunctionKeyAction
    let onImageDropped: (URL) -> Void
    let onClearImage: () -> Void

    @State private var isDropTargeted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text(key.title)
                    .font(.headline.monospacedDigit())
                    .frame(width: 42, alignment: .leading)

                Spacer()

                Image(systemName: action.systemImage)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(action == .none ? Color.secondary : Color.accentColor)
            }

            Picker("Action", selection: $action) {
                ForEach(FunctionKeyAction.allCases) { action in
                    Label(action.title, systemImage: action.systemImage)
                        .tag(action)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)

            imageDropArea
                .opacity(action == .toggleImageOverlay ? 1 : 0.46)
        }
        .padding(12)
        .frame(height: 178)
        .background(Color(nsColor: .textBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(isDropTargeted ? Color.accentColor : Color(nsColor: .separatorColor), lineWidth: 1)
        }
        .onDrop(
            of: [UTType.fileURL.identifier],
            isTargeted: $isDropTargeted,
            perform: handleDrop(providers:)
        )
    }

    @ViewBuilder
    private var imageDropArea: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6)
                .fill(Color(nsColor: .controlBackgroundColor))

            if let image = imagePreview {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .padding(5)

                VStack {
                    HStack {
                        Spacer()
                        Button {
                            onClearImage()
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                        }
                        .buttonStyle(.plain)
                        .help("Clear image")
                    }
                    Spacer()
                }
                .padding(5)
            } else {
                Label("Drop Image", systemImage: "photo.badge.plus")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(height: 76)
        .overlay {
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
                .foregroundStyle(isDropTargeted ? Color.accentColor : Color(nsColor: .separatorColor))
        }
    }

    private var imagePreview: NSImage? {
        guard let imagePath = slot.imagePath else { return nil }
        return NSImage(contentsOfFile: imagePath)
    }

    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first(where: { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }) else {
            return false
        }

        provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
            let url: URL?
            if let item = item as? URL {
                url = item
            } else if let data = item as? Data {
                url = URL(dataRepresentation: data, relativeTo: nil)
            } else {
                url = nil
            }

            guard let url, Self.isSupportedImageURL(url) else { return }
            DispatchQueue.main.async {
                onImageDropped(url)
            }
        }

        return true
    }

    private static func isSupportedImageURL(_ url: URL) -> Bool {
        guard let type = try? url.resourceValues(forKeys: [.contentTypeKey]).contentType else {
            return NSImage(contentsOf: url) != nil
        }

        return type.conforms(to: .image)
    }
}
