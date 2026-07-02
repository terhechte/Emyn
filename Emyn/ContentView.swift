//
//  ContentView.swift
//  Emyn
//
//  Created by Benedikt Terhechte on 01.07.26.
//

import AppKit
import SwiftUI
import UniformTypeIdentifiers

private enum ControlTab: String, CaseIterable, Identifiable {
    case camera
    case background
    case appWindow
    case functionKeys
    case present

    var id: String { rawValue }

    var title: String {
        switch self {
        case .camera: return "Camera"
        case .background: return "Background"
        case .appWindow: return "App Window"
        case .functionKeys: return "Function Keys"
        case .present: return "Present"
        }
    }

    var systemImage: String {
        switch self {
        case .camera: return "camera.fill"
        case .background: return "photo.fill"
        case .appWindow: return "rectangle.on.rectangle"
        case .functionKeys: return "keyboard"
        case .present: return "rectangle.inset.filled.and.person.filled"
        }
    }
}

struct ContentView: View {
    private static let windowCornerRadius: CGFloat = 30
    private static let windowPadding: CGFloat = 24
    private static let verticalSpacing: CGFloat = 16
    private static let tabBarHeight: CGFloat = 58
    private static let controlsPanelHeight: CGFloat = 220
    private static let previewMinimumHeight: CGFloat = 180
    private static let softwareCursorBaseSize: CGFloat = 32
    private static let softwareCursorDefaultScale: CGFloat = 2
    private static let softwareCursorHotspot = CGPoint(x: 2, y: 2)
    private static let softwareCursorImage: NSImage? = {
        if let url = Bundle.main.url(forResource: "cursor", withExtension: "png") {
            return NSImage(contentsOf: url)
        }

        return NSImage(named: "cursor")
    }()

    @ObservedObject private var pipeline: CameraPipeline
    @StateObject private var extensionInstaller = SystemExtensionInstaller()
    @StateObject private var windowBackgroundPicker = WindowBackgroundPickerModel()
    @StateObject private var windowControl = WindowControlCoordinator()
    @StateObject private var functionKeys = FunctionKeyController()
    @State private var selectedTab: ControlTab = .camera
    @State private var isPreviewCompact = false
    @State private var isWindowBackgroundPickerPresented = false
    @State private var isFunctionKeyConfigurationPresented = false
    @State private var previewNSView: SampleBufferPreviewView?
    @State private var cursorScale = Self.softwareCursorDefaultScale
    @State private var cursorAttentionTask: Task<Void, Never>?
    @AppStorage("excludeFunctionKeysDuringWindowControl") private var excludeFunctionKeysDuringWindowControl = true

    init(pipeline: CameraPipeline = CameraPipeline()) {
        self.pipeline = pipeline
    }

    var body: some View {
        GeometryReader { proxy in
            ScrollView(.vertical) {
                VStack(spacing: Self.verticalSpacing) {
                    previewPanel
                        .frame(height: previewHeight(for: proxy.size))

                    tabBar
                        .frame(height: Self.tabBarHeight)

                    controlsPanel
                }
                .padding(Self.windowPadding)
                .frame(maxWidth: .infinity)
                .frame(minHeight: proxy.size.height, alignment: .top)
            }
        }
        .frame(minWidth: 1080, minHeight: 460)
        .background(windowBackground)
        .onAppear {
            pipeline.refreshCameras()
            pipeline.start()
            functionKeys.onTrigger = handleFunctionKeyTrigger(_:)
            functionKeys.startMonitoring()
        }
        .onDisappear {
            cursorAttentionTask?.cancel()
            functionKeys.stopMonitoring()
            windowControl.deactivate()
            pipeline.stop()
            pipeline.clearWindowBackground()
        }
        .onChange(of: excludeFunctionKeysDuringWindowControl) { _, newValue in
            windowControl.setExcludeFunctionKeys(newValue)
        }
        .onChange(of: pipeline.windowBackgroundFit) { _, _ in
            deferViewUpdateMutation {
                refreshWindowControlMapping()
            }
        }
        .onChange(of: pipeline.windowBackgroundAlignment) { _, _ in
            deferViewUpdateMutation {
                refreshWindowControlMapping()
            }
        }
        .onReceive(windowControl.$cursorNormalised) { cursor in
            deferViewUpdateMutation {
                pipeline.setWindowZoomCenter(cursor)
            }
        }
        .sheet(isPresented: $isWindowBackgroundPickerPresented) {
            WindowBackgroundPickerView(
                model: windowBackgroundPicker,
                selectedWindowIDs: Set(pipeline.selectedWindowBackgroundOptions.map(\.id)),
                onSelect: { options in
                    windowControl.deactivate()
                    pipeline.selectWindowBackgrounds(options)
                    isWindowBackgroundPickerPresented = false
                },
                onCancel: {
                    isWindowBackgroundPickerPresented = false
                }
            )
        }
        .sheet(isPresented: $isFunctionKeyConfigurationPresented) {
            FunctionKeyConfigurationView(
                controller: functionKeys,
                onClose: {
                    isFunctionKeyConfigurationPresented = false
                }
            )
        }
    }

    private var windowBackground: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor)
            LinearGradient(
                colors: [
                    Color(nsColor: .controlBackgroundColor).opacity(0.56),
                    Color.accentColor.opacity(0.16),
                    Color(nsColor: .textBackgroundColor).opacity(0.74)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
        .ignoresSafeArea()
    }

    private var previewPanel: some View {
        LiquidGlassSurface(cornerRadius: Self.windowCornerRadius) {
            ZStack(alignment: .bottomLeading) {
                VideoPreviewView(
                    pipeline: pipeline,
                    onViewReady: { view in
                        DispatchQueue.main.async {
                            if previewNSView !== view {
                                previewNSView = view
                            }
                        }
                    }
                )
                .background(.black)

                if windowControl.isActive, let cursor = windowControl.cursorNormalised {
                    GeometryReader { proxy in
                        let region = windowControl.cursorRegionNormalised
                        let outputCursor = CGPoint(
                            x: pipeline.outputFlipHorizontal ? 1 - cursor.x : cursor.x,
                            y: pipeline.outputFlipVertical ? 1 - cursor.y : cursor.y
                        )
                        let position = CGPoint(
                            x: proxy.size.width * (region.minX + outputCursor.x * region.width),
                            y: proxy.size.height * (region.minY + outputCursor.y * region.height)
                        )
                        softwareCursor(at: position)
                    }
                    .allowsHitTesting(false)
                }

                HStack(spacing: 10) {
                    Label("\(pipeline.measuredFramesPerSecond, specifier: "%.0f") fps", systemImage: "speedometer")
                    Text("\(SharedFrameConfiguration.width)x\(SharedFrameConfiguration.height)")
                }
                .font(.caption.monospacedDigit())
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(.black.opacity(0.62), in: Capsule())
                .foregroundStyle(.white)
                .padding(14)

                VStack {
                    HStack {
                        Spacer()
                        Button {
                            isPreviewCompact.toggle()
                        } label: {
                            Image(systemName: isPreviewCompact ? "arrow.up.left.and.arrow.down.right" : "arrow.down.right.and.arrow.up.left")
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .help(isPreviewCompact ? "Expand preview" : "Shrink preview")
                    }
                    Spacer()
                }
                .padding(14)
            }
            .clipShape(RoundedRectangle(cornerRadius: Self.windowCornerRadius - 3, style: .continuous))
        }
        .aspectRatio(16.0 / 9.0, contentMode: .fit)
    }

    private var tabBar: some View {
        HStack(spacing: 6) {
            ForEach(ControlTab.allCases) { tab in
                Button {
                    selectedTab = tab
                } label: {
                    Label(tab.title, systemImage: tab.systemImage)
                        .font(.headline)
                        .lineLimit(1)
                        .minimumScaleFactor(0.82)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 12)
                        .frame(maxWidth: .infinity)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(selectedTab == tab ? Color.primary : Color.secondary)
                .background {
                    if selectedTab == tab {
                        Capsule()
                            .fill(.regularMaterial)
                            .overlay {
                                Capsule()
                                    .strokeBorder(.white.opacity(0.22), lineWidth: 1)
                            }
                    }
                }
                .help(tab.title)
            }
        }
        .padding(6)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay {
            Capsule()
                .strokeBorder(.white.opacity(0.18), lineWidth: 1)
        }
    }

    private var controlsPanel: some View {
        LiquidGlassSurface(cornerRadius: Self.windowCornerRadius) {
            ScrollView {
                tabContent
                    .padding(22)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(height: Self.controlsPanelHeight)
    }

    private func previewHeight(for windowSize: CGSize) -> CGFloat {
        let chromeHeight = Self.windowPadding * 2
            + Self.verticalSpacing * 2
            + Self.tabBarHeight
            + Self.controlsPanelHeight
        let availableHeight = windowSize.height - chromeHeight
        let availableWidth = max(0, windowSize.width - Self.windowPadding * 2)
        let maximumAspectHeight = availableWidth * 9.0 / 16.0
        let fullHeight = max(
            Self.previewMinimumHeight,
            min(availableHeight, maximumAspectHeight)
        )

        if isPreviewCompact {
            return max(Self.previewMinimumHeight, fullHeight * 0.5)
        }

        return fullHeight
    }

    @ViewBuilder
    private var tabContent: some View {
        switch selectedTab {
        case .camera:
            cameraTab
        case .background:
            backgroundTab
        case .appWindow:
            appWindowTab
        case .functionKeys:
            functionKeysTab
        case .present:
            presentTab
        }
    }

    private var cameraTab: some View {
        HStack(alignment: .top, spacing: 22) {
            controlSection("Camera", systemImage: "camera.fill") {
                VStack(alignment: .leading, spacing: 12) {
                    fieldLabel("Pick")
                    HStack(spacing: 8) {
                        Picker("Camera", selection: cameraSelection) {
                            if pipeline.cameras.isEmpty {
                                Text("No Camera").tag("")
                            } else {
                                ForEach(pipeline.cameras) { camera in
                                    Text(camera.name).tag(camera.id)
                                }
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .frame(maxWidth: .infinity)

                        Button {
                            pipeline.refreshCameras()
                        } label: {
                            Image(systemName: "arrow.clockwise")
                        }
                        .help("Refresh cameras")
                    }

                    Button {
                        pipeline.isRunning ? pipeline.stop() : pipeline.start()
                    } label: {
                        Label(
                            pipeline.isRunning ? "Stop" : "Start",
                            systemImage: pipeline.isRunning ? "stop.fill" : "play.fill"
                        )
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)

                    statusLine(pipeline.statusText)
                }
            }

            panelDivider

            controlSection("Virtual Camera", systemImage: "video.badge.plus") {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 8) {
                        Button {
                            extensionInstaller.activate()
                        } label: {
                            Label("Install", systemImage: "video.badge.plus")
                        }

                        Button {
                            extensionInstaller.deactivate()
                        } label: {
                            Label("Remove", systemImage: "video.badge.minus")
                        }
                    }

                    statusLine(
                        extensionInstaller.statusText,
                        color: extensionInstaller.needsUserApproval ? .orange : .secondary
                    )
                }
            }
        }
    }

    private var backgroundTab: some View {
        HStack(alignment: .top, spacing: 22) {
            controlSection("Background", systemImage: "square.stack.3d.down.right.fill") {
                VStack(alignment: .leading, spacing: 12) {
                    Toggle("Remove Background", isOn: $pipeline.backgroundRemovalEnabled)
                        .toggleStyle(.checkbox)

                    VStack(alignment: .leading, spacing: 8) {
                        Toggle("Color", isOn: $pipeline.backgroundColorEnabled)
                            .toggleStyle(.checkbox)
                        Toggle("Background", isOn: $pipeline.backgroundBlurEnabled)
                            .toggleStyle(.checkbox)
                        Toggle("Media", isOn: $pipeline.backgroundMediaEnabled)
                            .toggleStyle(.checkbox)
                    }
                }
            }

            if pipeline.backgroundColorEnabled {
                panelDivider

                controlSection("Color", systemImage: "paintpalette.fill") {
                    VStack(alignment: .leading, spacing: 12) {
                        backgroundPresetButtons
                        statusLine(pipeline.backgroundPreset.title)
                    }
                }
            }

            if pipeline.backgroundBlurEnabled {
                panelDivider

                controlSection("Background", systemImage: "camera.aperture") {
                    VStack(alignment: .leading, spacing: 10) {
                        valueHeader("Blur", value: "\(String(format: "%.0f", pipeline.backgroundBlurRadius)) px")
                        Slider(value: $pipeline.backgroundBlurRadius, in: 4...40, step: 1)
                    }
                }
            }

            if pipeline.backgroundMediaEnabled {
                panelDivider

                controlSection("Media", systemImage: "photo.on.rectangle.angled") {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 8) {
                            Button {
                                chooseBackgroundMedia()
                            } label: {
                                Label("Choose", systemImage: "plus")
                            }

                            if pipeline.hasBackgroundMediaSelection {
                                Button {
                                    pipeline.clearBackgroundMedia()
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                }
                                .help("Clear background media")
                            }
                        }

                        valueHeader("Blur Media", value: "\(String(format: "%.0f", pipeline.backgroundMediaBlurRadius)) px")
                        Slider(value: $pipeline.backgroundMediaBlurRadius, in: 0...40, step: 1)

                        Picker("Media Fit", selection: backgroundMediaFitSelection) {
                            ForEach(BackgroundMediaFit.allCases) { fit in
                                Text(fit.title).tag(fit)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.segmented)

                        backgroundAlignmentPicker(selection: backgroundMediaAlignmentSelection)

                        statusLine(pipeline.selectedBackgroundMediaTitle ?? pipeline.backgroundMediaStatusText)
                    }
                }
            }
        }
    }

    private var appWindowTab: some View {
        HStack(alignment: .top, spacing: 22) {
            controlSection("Select Windows", systemImage: "rectangle.badge.plus") {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 8) {
                        Button {
                            windowBackgroundPicker.refresh()
                            isWindowBackgroundPickerPresented = true
                        } label: {
                            Label("Add", systemImage: "plus")
                        }

                        Button {
                            clearSelectedWindowBackground()
                        } label: {
                            Label("Clear", systemImage: "xmark.circle")
                        }
                        .disabled(!pipeline.hasWindowBackgroundSelection)
                    }

                    statusLine(pipeline.selectedWindowBackgroundTitle ?? pipeline.windowBackgroundStatusText)
                }
            }

            panelDivider

            controlSection("Windows", systemImage: "list.bullet.rectangle") {
                selectedWindowTable
            }
            .frame(minWidth: 390)

            panelDivider

            controlSection("Layout", systemImage: "arrow.up.left.and.arrow.down.right") {
                VStack(alignment: .leading, spacing: 12) {
                    Picker("Window Fit", selection: windowBackgroundFitSelection) {
                        ForEach(BackgroundMediaFit.allCases) { fit in
                            Text(fit.title).tag(fit)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)

                    backgroundAlignmentPicker(selection: windowBackgroundAlignmentSelection)
                }
            }
        }
    }

    private var functionKeysTab: some View {
        HStack(alignment: .top, spacing: 22) {
            controlSection("Function Keys", systemImage: "keyboard") {
                VStack(alignment: .leading, spacing: 12) {
                    Button {
                        isFunctionKeyConfigurationPresented = true
                    } label: {
                        Label("Configure", systemImage: "slider.horizontal.3")
                    }
                    .buttonStyle(.borderedProminent)

                    statusLine(functionKeys.statusText)
                }
            }

            panelDivider

            controlSection("Current Configuration", systemImage: "list.bullet") {
                functionKeyConfigurationSummary
            }
            .frame(minWidth: 360)

            panelDivider

            controlSection("Buttons", systemImage: "switch.2") {
                functionKeyActionButtons
            }
        }
    }

    private var presentTab: some View {
        HStack(alignment: .top, spacing: 22) {
            controlSection("Output", systemImage: "display") {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("Resolution")
                        Spacer()
                        Text("\(SharedFrameConfiguration.width)x\(SharedFrameConfiguration.height)")
                            .font(.callout.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }

                    outputFlipButtons
                }
            }

            panelDivider

            controlSection("NTSC", systemImage: "tv") {
                VStack(alignment: .leading, spacing: 12) {
                    Toggle("Enabled", isOn: $pipeline.ntscEffectEnabled)
                        .toggleStyle(.switch)

                    ntscPresetPicker
                }
            }

            panelDivider

            controlSection("Function Buttons", systemImage: "switch.2") {
                functionKeyActionButtons
            }
            .frame(minWidth: 300)

            panelDivider

            controlSection("Control Window", systemImage: "cursorarrow") {
                windowControlControls
            }
        }
    }

    @ViewBuilder
    private func softwareCursor(at position: CGPoint) -> some View {
        let cursorSize = Self.softwareCursorBaseSize * cursorScale

        if let cursorImage = Self.softwareCursorImage {
            let imageScale = cursorSize / max(cursorImage.size.width, 1)
            Image(nsImage: cursorImage)
                .resizable()
                .interpolation(.high)
                .frame(width: cursorSize, height: cursorSize)
                .shadow(color: .black.opacity(0.35), radius: 2, y: 1)
                .position(
                    x: position.x + cursorSize * 0.5 - Self.softwareCursorHotspot.x * imageScale,
                    y: position.y + cursorSize * 0.5 - Self.softwareCursorHotspot.y * imageScale
                )
        } else {
            Circle()
                .fill(.black.opacity(0.32))
                .overlay {
                    Circle()
                        .stroke(.white, lineWidth: 2)
                }
                .frame(width: 18 * cursorScale, height: 18 * cursorScale)
                .shadow(color: .black.opacity(0.45), radius: 2, y: 1)
                .position(position)
        }
    }

    private var outputFlipButtons: some View {
        let columns = [
            GridItem(.flexible(), spacing: 6),
            GridItem(.flexible(), spacing: 6)
        ]

        return LazyVGrid(columns: columns, alignment: .leading, spacing: 6) {
            outputFlipButton(
                title: "Horizontal",
                systemImage: "arrow.left.and.right",
                isActive: pipeline.outputFlipHorizontal
            ) {
                pipeline.outputFlipHorizontal.toggle()
            }

            outputFlipButton(
                title: "Vertical",
                systemImage: "arrow.up.and.down",
                isActive: pipeline.outputFlipVertical
            ) {
                pipeline.outputFlipVertical.toggle()
            }
        }
    }

    private func outputFlipButton(
        title: String,
        systemImage: String,
        isActive: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .lineLimit(1)
                .minimumScaleFactor(0.78)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .foregroundStyle(isActive ? Color.accentColor : Color.primary)
        .background(isActive ? Color.accentColor.opacity(0.14) : Color.clear, in: RoundedRectangle(cornerRadius: 6))
        .overlay {
            RoundedRectangle(cornerRadius: 6)
                .stroke(isActive ? Color.accentColor.opacity(0.7) : Color.clear, lineWidth: 1)
        }
        .help(isActive ? "\(title) flip enabled" : "Flip output \(title.lowercased())")
    }

    private var backgroundPresetButtons: some View {
        HStack(spacing: 9) {
            ForEach(BackgroundPreset.allCases) { preset in
                Button {
                    pipeline.backgroundPreset = preset
                } label: {
                    ZStack {
                        Circle()
                            .fill(Color(nsColor: preset.nsColor))
                        if preset == .transparent {
                            Image(systemName: "circle.dotted")
                                .font(.system(size: 20, weight: .semibold))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .frame(width: 30, height: 30)
                    .overlay {
                        Circle()
                            .stroke(
                                pipeline.backgroundPreset == preset ? Color.accentColor : Color.clear,
                                lineWidth: 3
                            )
                    }
                }
                .buttonStyle(.plain)
                .help(preset.title)
            }
        }
    }

    private func backgroundAlignmentPicker(selection: Binding<BackgroundContentAlignment>) -> some View {
        HStack(spacing: 8) {
            Text("Align")
                .font(.caption)
                .foregroundStyle(.secondary)

            Picker("Alignment", selection: selection) {
                ForEach(BackgroundContentAlignment.allCases) { alignment in
                    Text(alignment.title).tag(alignment)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .controlSize(.small)
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }

    private var ntscPresetPicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            valueHeader("Preset", value: pipeline.ntscPreset.title)

            Picker("NTSC Preset", selection: ntscPresetSelection) {
                ForEach(NtscPreset.allCases) { preset in
                    Text(preset.title)
                        .tag(preset)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .controlSize(.small)
        }
    }

    private var selectedWindowTable: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Window")
                Spacer()
                Text("Size")
                    .frame(width: 78, alignment: .trailing)
                Text("")
                    .frame(width: 96)
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)

            Divider()

            if pipeline.selectedWindowBackgroundOptions.isEmpty {
                Label("No windows selected", systemImage: "rectangle.on.rectangle.slash")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 94)
            } else {
                ForEach(pipeline.selectedWindowBackgroundOptions) { option in
                    selectedWindowRow(option)
                    if option.id != pipeline.selectedWindowBackgroundOptions.last?.id {
                        Divider()
                    }
                }
            }
        }
        .background(.black.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(.white.opacity(0.12), lineWidth: 1)
        }
    }

    private func selectedWindowRow(_ option: WindowBackgroundOption) -> some View {
        let index = windowIndex(for: option)
        let isActive = pipeline.activeWindowBackgroundOption?.id == option.id

        return HStack(spacing: 10) {
            Image(systemName: "line.3.horizontal")
                .foregroundStyle(.tertiary)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(option.appName)
                        .font(.callout.weight(.semibold))
                        .lineLimit(1)

                    if isActive {
                        Image(systemName: "record.circle")
                            .font(.caption)
                            .foregroundStyle(Color.accentColor)
                    }
                }

                Text(option.windowTitle.isEmpty ? "Untitled Window" : option.windowTitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 10)

            Text("\(Int(option.frame.width.rounded()))x\(Int(option.frame.height.rounded()))")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 78, alignment: .trailing)

            HStack(spacing: 4) {
                Button {
                    moveWindowBackground(option, offset: -1)
                } label: {
                    Image(systemName: "chevron.up")
                }
                .disabled(index == nil || index == 0)
                .help("Move up")

                Button {
                    moveWindowBackground(option, offset: 1)
                } label: {
                    Image(systemName: "chevron.down")
                }
                .disabled(index == nil || index == pipeline.selectedWindowBackgroundOptions.count - 1)
                .help("Move down")

                Button {
                    removeSelectedWindowBackground(option)
                } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .help("Remove window")
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
            .frame(width: 96, alignment: .trailing)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    private var functionKeyConfigurationSummary: some View {
        let columns = [
            GridItem(.adaptive(minimum: 112, maximum: 150), spacing: 8)
        ]

        return LazyVGrid(columns: columns, alignment: .leading, spacing: 8) {
            ForEach(functionKeys.configuration.slots) { slot in
                FunctionKeySummaryPill(slot: slot)
            }
        }
    }

    private var functionKeyActionButtons: some View {
        let columns = [
            GridItem(.flexible(), spacing: 6),
            GridItem(.flexible(), spacing: 6)
        ]
        let imageSlots = functionKeys.configuration.slots.filter {
            $0.action == .toggleImageOverlay && $0.imagePath != nil
        }

        return LazyVGrid(columns: columns, alignment: .leading, spacing: 6) {
            ForEach(FunctionKeyAction.sidebarActions) { action in
                Button {
                    functionKeys.reportManualAction(action)
                    performFunctionKeyAction(
                        action,
                        identifier: "sidebar.\(action.rawValue)",
                        imagePath: nil
                    )
                } label: {
                    Label(action.title, systemImage: action.systemImage)
                        .lineLimit(1)
                        .minimumScaleFactor(0.78)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(isFunctionKeyActionDisabled(action))
            }

            ForEach(imageSlots) { slot in
                Button {
                    functionKeys.reportManualAction(slot.action, sourceTitle: slot.key.title)
                    performFunctionKeyAction(
                        slot.action,
                        identifier: slot.key.storageIdentifier,
                        imagePath: slot.imagePath
                    )
                } label: {
                    Label(slot.key.title, systemImage: slot.action.systemImage)
                        .lineLimit(1)
                        .minimumScaleFactor(0.78)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
    }

    @ViewBuilder
    private var windowControlControls: some View {
        if let activeWindowBackgroundOption = pipeline.activeWindowBackgroundOption {
            VStack(alignment: .leading, spacing: 10) {
                Toggle(
                    "Exclude Function Keys",
                    isOn: $excludeFunctionKeysDuringWindowControl
                )
                .toggleStyle(.checkbox)
                .controlSize(.small)
                .help("Keep F1-F12 available outside the controlled window")

                Button {
                    toggleWindowControl(for: activeWindowBackgroundOption)
                } label: {
                    Label(
                        windowControl.isActive ? "Stop Control" : "Control Window",
                        systemImage: windowControl.isActive ? "xmark.circle" : "cursorarrow"
                    )
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(previewNSView == nil)

                statusLine(windowControl.statusText)
            }
        } else {
            Label("No app window selected", systemImage: "rectangle.on.rectangle.slash")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private func controlSection<Content: View>(
        _ title: String,
        systemImage: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(title, systemImage: systemImage)
                .font(.headline)
                .lineLimit(1)

            content()
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private var panelDivider: some View {
        Divider()
            .frame(minHeight: 160)
            .opacity(0.7)
    }

    private func fieldLabel(_ text: String) -> some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .textCase(.uppercase)
    }

    private func valueHeader(_ title: String, value: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(value)
                .foregroundStyle(.secondary)
        }
        .font(.caption)
    }

    private func statusLine(_ text: String, color: Color = .secondary) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(color)
            .lineLimit(2)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var cameraSelection: Binding<String> {
        Binding {
            pipeline.selectedCameraID
        } set: { newValue in
            pipeline.selectedCameraID = newValue
        }
    }

    private var backgroundMediaFitSelection: Binding<BackgroundMediaFit> {
        Binding {
            pipeline.backgroundMediaFit
        } set: { newValue in
            pipeline.backgroundMediaFit = newValue
        }
    }

    private var backgroundMediaAlignmentSelection: Binding<BackgroundContentAlignment> {
        Binding {
            pipeline.backgroundMediaAlignment
        } set: { newValue in
            pipeline.backgroundMediaAlignment = newValue
        }
    }

    private var windowBackgroundFitSelection: Binding<BackgroundMediaFit> {
        Binding {
            pipeline.windowBackgroundFit
        } set: { newValue in
            pipeline.windowBackgroundFit = newValue
        }
    }

    private var windowBackgroundAlignmentSelection: Binding<BackgroundContentAlignment> {
        Binding {
            pipeline.windowBackgroundAlignment
        } set: { newValue in
            pipeline.windowBackgroundAlignment = newValue
        }
    }

    private var ntscPresetSelection: Binding<NtscPreset> {
        Binding {
            pipeline.ntscPreset
        } set: { newValue in
            pipeline.ntscPreset = newValue
        }
    }

    private func isFunctionKeyActionDisabled(_ action: FunctionKeyAction) -> Bool {
        if action == .cycleWindowBackground {
            return pipeline.selectedWindowBackgroundOptions.count < 2
        }

        return action.needsWindowBackground && !pipeline.hasWindowBackgroundSelection
    }

    private func toggleWindowControl(for option: WindowBackgroundOption) {
        if windowControl.isActive {
            windowControl.deactivate()
        } else {
            windowControl.activate(
                option: option,
                mappedTo: previewNSView,
                fit: pipeline.windowBackgroundFit,
                alignment: pipeline.windowBackgroundAlignment,
                excludeFunctionKeys: excludeFunctionKeysDuringWindowControl
            )
        }
    }

    private func refreshWindowControlMapping() {
        guard windowControl.isActive,
              let activeWindowBackgroundOption = pipeline.activeWindowBackgroundOption else {
            return
        }

        windowControl.deactivate()
        windowControl.activate(
            option: activeWindowBackgroundOption,
            mappedTo: previewNSView,
            fit: pipeline.windowBackgroundFit,
            alignment: pipeline.windowBackgroundAlignment,
            excludeFunctionKeys: excludeFunctionKeysDuringWindowControl
        )
    }

    private func clearSelectedWindowBackground() {
        windowControl.deactivate()
        pipeline.clearWindowBackground()
    }

    private func removeSelectedWindowBackground(_ option: WindowBackgroundOption) {
        if pipeline.activeWindowBackgroundOption?.id == option.id {
            windowControl.deactivate()
        }

        pipeline.removeWindowBackground(id: option.id)
    }

    private func moveWindowBackground(_ option: WindowBackgroundOption, offset: Int) {
        guard let index = windowIndex(for: option) else { return }

        let destination: Int
        if offset < 0 {
            destination = max(0, index + offset)
        } else {
            destination = min(pipeline.selectedWindowBackgroundOptions.count, index + offset + 1)
        }

        pipeline.moveWindowBackgrounds(from: IndexSet(integer: index), to: destination)
        refreshWindowControlMapping()
    }

    private func windowIndex(for option: WindowBackgroundOption) -> Int? {
        pipeline.selectedWindowBackgroundOptions.firstIndex { $0.id == option.id }
    }

    private func chooseBackgroundMedia() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image, .movie, .video]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.prompt = "Choose"
        panel.message = "Choose an image or video to use as the generated video background."

        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            pipeline.selectBackgroundMedia(url: url)
        }
    }

    private func handleFunctionKeyTrigger(_ trigger: FunctionKeyTrigger) {
        performFunctionKeyAction(
            trigger.slot.action,
            identifier: trigger.key.storageIdentifier,
            imagePath: trigger.slot.imagePath
        )
    }

    private func performFunctionKeyAction(
        _ action: FunctionKeyAction,
        identifier: String,
        imagePath: String?
    ) {
        switch action {
        case .none:
            break
        case .toggleWindowBackground:
            pipeline.toggleWindowBackgroundVisibility()
        case .togglePersonPosition:
            pipeline.togglePersonCompactPosition()
        case .toggleWindowAndPerson:
            pipeline.toggleWindowAndCompactPerson()
        case .toggleImageOverlay:
            guard let imagePath else { return }
            pipeline.toggleImageOverlay(identifier: identifier, imagePath: imagePath)
        case .toggleWindowZoom:
            pipeline.toggleWindowZoom()
        case .drawAttentionToCursor:
            drawAttentionToCursor()
        case .triggerConfetti:
            pipeline.triggerConfetti()
        case .cycleWindowBackground:
            cycleWindowBackground()
        case .toggleNtscEffect:
            pipeline.toggleNtscEffect()
        }
    }

    private func cycleWindowBackground() {
        guard pipeline.selectedWindowBackgroundOptions.count > 1 else { return }

        let shouldResumeControl = windowControl.isActive
        windowControl.deactivate()
        let activeOption = pipeline.cycleWindowBackground()

        if shouldResumeControl, let activeOption {
            windowControl.activate(
                option: activeOption,
                mappedTo: previewNSView,
                fit: pipeline.windowBackgroundFit,
                alignment: pipeline.windowBackgroundAlignment,
                excludeFunctionKeys: excludeFunctionKeysDuringWindowControl
            )
        }
    }

    private func deferViewUpdateMutation(_ action: @escaping @MainActor () -> Void) {
        Task { @MainActor in
            await Task.yield()
            action()
        }
    }

    private func drawAttentionToCursor() {
        cursorAttentionTask?.cancel()
        cursorScale = Self.softwareCursorDefaultScale

        cursorAttentionTask = Task { @MainActor in
            let scales: [CGFloat] = [4, 1, 3, 1.5, 2.5, Self.softwareCursorDefaultScale]
            let stepDuration = 250_000_000

            for scale in scales {
                guard !Task.isCancelled else { return }

                withAnimation(.spring(response: 0.18, dampingFraction: 0.46, blendDuration: 0)) {
                    cursorScale = scale
                }

                try? await Task.sleep(nanoseconds: UInt64(stepDuration))
            }
        }
    }
}

private struct LiquidGlassSurface<Content: View>: View {
    let cornerRadius: CGFloat
    @ViewBuilder let content: Content

    init(cornerRadius: CGFloat, @ViewBuilder content: () -> Content) {
        self.cornerRadius = cornerRadius
        self.content = content()
    }

    var body: some View {
        content
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(.white.opacity(0.20), lineWidth: 1)
            }
            .shadow(color: .black.opacity(0.18), radius: 24, y: 12)
    }
}

private struct FunctionKeySummaryPill: View {
    let slot: FunctionKeySlot

    var body: some View {
        HStack(spacing: 8) {
            Text(slot.key.title)
                .font(.caption.weight(.bold).monospacedDigit())
                .frame(width: 28, alignment: .leading)

            Image(systemName: slot.action.systemImage)
                .font(.caption)
                .foregroundStyle(slot.action == .none ? Color.secondary : Color.accentColor)

            Text(slot.action.title)
                .font(.caption)
                .lineLimit(1)
                .minimumScaleFactor(0.76)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.black.opacity(0.08), in: Capsule())
        .overlay {
            Capsule()
                .stroke(.white.opacity(0.10), lineWidth: 1)
        }
    }
}

struct BackgroundRemovalSettingsView: View {
    @ObservedObject var pipeline: CameraPipeline

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Label("Background Removal", systemImage: "person.crop.rectangle")
                .font(.title3.weight(.semibold))

            Form {
                Toggle("Remove Background", isOn: $pipeline.backgroundRemovalEnabled)

                Picker("Quality", selection: $pipeline.quality) {
                    ForEach(SegmentationQuality.allCases) { quality in
                        Text(quality.title).tag(quality)
                    }
                }

                Picker("Analysis", selection: $pipeline.analysisResolution) {
                    ForEach(SegmentationAnalysisResolution.allCases) { resolution in
                        Text("\(resolution.title) (\(resolution.dimensionsTitle))").tag(resolution)
                    }
                }

                HStack {
                    Text("Smoothing")
                    Slider(value: $pipeline.temporalSmoothing, in: 0.0...0.9, step: 0.05)
                    Text(pipeline.temporalSmoothing, format: .percent.precision(.fractionLength(0)))
                        .foregroundStyle(.secondary)
                        .frame(width: 44, alignment: .trailing)
                }

                Stepper(
                    "Reuse \(pipeline.maskReuseFrameCount) frame\(pipeline.maskReuseFrameCount == 1 ? "" : "s")",
                    value: $pipeline.maskReuseFrameCount,
                    in: 0...5
                )
            }
            .formStyle(.grouped)
        }
        .padding(24)
        .frame(width: 460)
    }
}

#Preview {
    ContentView()
}
