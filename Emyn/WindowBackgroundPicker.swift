import AppKit
import ScreenCaptureKit
import SwiftUI
import WindowCaptureKit

struct WindowBackgroundPickerView: View {
    @ObservedObject var model: WindowBackgroundPickerModel
    let onSelect: ([WindowBackgroundOption]) -> Void
    let onCancel: () -> Void

    @State private var selectedWindowIDs: Set<CGWindowID>
    @State private var searchText = ""
    @State private var selectedAppName: String

    private static let allAppsFilterID = "__all_apps__"
    private let columns = [
        GridItem(.adaptive(minimum: 210, maximum: 260), spacing: 14)
    ]

    init(
        model: WindowBackgroundPickerModel,
        selectedWindowIDs: Set<CGWindowID>,
        onSelect: @escaping ([WindowBackgroundOption]) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.model = model
        self.onSelect = onSelect
        self.onCancel = onCancel
        self._selectedWindowIDs = State(initialValue: selectedWindowIDs)
        self._selectedAppName = State(initialValue: Self.allAppsFilterID)
    }

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
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Text("Select Windows")
                    .font(.headline)

                Text(selectionStatusText)
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

                Button("Use Selected") {
                    onSelect(selectedOptions)
                }
                .disabled(selectedOptions.isEmpty)
            }

            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)

                TextField("Search windows", text: $searchText)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: .infinity)

                Picker("App", selection: appFilterSelection) {
                    Text("All Apps").tag(Self.allAppsFilterID)
                    ForEach(appFilterNames, id: \.self) { appName in
                        Text(appName).tag(appName)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(width: 190)
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
        } else if filteredOptions.isEmpty {
            ContentUnavailableView("No Matching Windows", systemImage: "magnifyingglass")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVGrid(columns: columns, alignment: .leading, spacing: 14) {
                    ForEach(filteredOptions) { option in
                        Button {
                            toggleSelection(for: option)
                        } label: {
                            WindowBackgroundOptionView(
                                option: option,
                                isSelected: selectedWindowIDs.contains(option.id)
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(18)
            }
        }
    }

    private var selectedOptions: [WindowBackgroundOption] {
        model.options.filter { selectedWindowIDs.contains($0.id) }
    }

    private var filteredOptions: [WindowBackgroundOption] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let selectedApp = appFilterSelection.wrappedValue

        return model.options.filter { option in
            let matchesApp = selectedApp == Self.allAppsFilterID || option.appName == selectedApp
            let matchesSearch = query.isEmpty
                || option.appName.localizedCaseInsensitiveContains(query)
                || option.windowTitle.localizedCaseInsensitiveContains(query)

            return matchesApp && matchesSearch
        }
    }

    private var appFilterNames: [String] {
        Set(model.options.map(\.appName))
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    private var appFilterSelection: Binding<String> {
        Binding {
            appFilterNames.contains(selectedAppName) ? selectedAppName : Self.allAppsFilterID
        } set: { newValue in
            selectedAppName = newValue
        }
    }

    private var selectionStatusText: String {
        let selectedCount = selectedOptions.count
        let filteredCount = filteredOptions.count
        let baseText = filteredCount == model.options.count
            ? model.statusText
            : "\(filteredCount) of \(model.options.count) windows"

        guard selectedCount > 0 else {
            return baseText
        }

        return "\(baseText), \(selectedCount) selected"
    }

    private func toggleSelection(for option: WindowBackgroundOption) {
        if selectedWindowIDs.contains(option.id) {
            selectedWindowIDs.remove(option.id)
        } else {
            selectedWindowIDs.insert(option.id)
        }
    }
}

private struct WindowBackgroundOptionView: View {
    let option: WindowBackgroundOption
    let isSelected: Bool

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

                if isSelected {
                    VStack {
                        HStack {
                            Spacer()
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 22, weight: .semibold))
                                .foregroundStyle(.white, Color.accentColor)
                                .padding(8)
                        }
                        Spacer()
                    }
                }
            }
            .frame(height: 130)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay {
                RoundedRectangle(cornerRadius: 6)
                    .stroke(isSelected ? Color.accentColor : Color(nsColor: .separatorColor), lineWidth: isSelected ? 2 : 1)
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
                .stroke(isSelected ? Color.accentColor : Color(nsColor: .separatorColor), lineWidth: isSelected ? 2 : 1)
        }
    }
}
