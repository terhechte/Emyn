//
//  ContentView.swift
//  Emyn
//
//  Created by Benedikt Terhechte on 01.07.26.
//

import AppKit
import AVFoundation
import SwiftUI
import UniformTypeIdentifiers

private let selectedSettingsTabStorageKey = "settings.selectedTab.v1"

private enum ControlTab: String, CaseIterable, Identifiable {
    case camera
    case background
    case appWindow
    case functionKeys
    case speechToText
    case present

    var id: String { rawValue }

    var title: String {
        switch self {
        case .camera: return "Camera"
        case .background: return "Background"
        case .appWindow: return "App Window"
        case .functionKeys: return "Function Keys"
        case .speechToText: return "Transcribe"
        case .present: return "Present"
        }
    }

    var systemImage: String {
        switch self {
        case .camera: return "camera.fill"
        case .background: return "photo.fill"
        case .appWindow: return "rectangle.on.rectangle"
        case .functionKeys: return "keyboard"
        case .speechToText: return "text.bubble"
        case .present: return "rectangle.inset.filled.and.person.filled"
        }
    }
}

private enum SettingsTab: String {
    case background
    case virtualCamera
    case sound
    case models
}

struct ContentView: View {
    private static let windowCornerRadius: CGFloat = 30
    private static let windowPadding: CGFloat = 24
    private static let minimumWindowWidth: CGFloat = 1080
    private static let verticalSpacing: CGFloat = 16
    private static let tabBarHeight: CGFloat = 58
    private static let controlsPanelHeight: CGFloat = 220
    private static let functionKeyMappingBarHeight: CGFloat = 58
    private static let controlsPanelHorizontalPadding: CGFloat = 22
    private static let controlsPanelVerticalPadding: CGFloat = 18
    private static let previewMinimumHeight: CGFloat = 180
    private static let notesSidebarDefaultWidth: CGFloat = 360
    private static let notesSidebarMinimumWidth: CGFloat = 300
    private static let notesSidebarMaximumWidth: CGFloat = 640
    private static let softwareCursorBaseSize: CGFloat = 32
    private static let softwareCursorDefaultScale = 2.0
    private static let softwareCursorMinimumScale = softwareCursorDefaultScale / 8
    private static let softwareCursorHotspot = CGPoint(x: 2, y: 2)
    private static let speechTestSentence = "The quick brown fox jumps over the lazy dog"
    private static let softwareCursorImage: NSImage? = {
        if let url = Bundle.main.url(forResource: "cursor", withExtension: "png") {
            return NSImage(contentsOf: url)
        }

        return NSImage(named: "cursor")
    }()

    @ObservedObject private var pipeline: CameraPipeline
    @ObservedObject private var extensionInstaller: SystemExtensionInstaller
    @StateObject private var startupPermissions = StartupPermissionCoordinator()
    @StateObject private var windowBackgroundPicker = WindowBackgroundPickerModel()
    @StateObject private var windowControl = WindowControlCoordinator()
    @StateObject private var functionKeys = FunctionKeyController()
    @ObservedObject private var speechToText: SpeechToTextConfiguration
    @ObservedObject private var speechTranscriber: SpeechToTextTranscriber
    @State private var selectedTab: ControlTab = .camera
    @State private var isSpeechTestSentenceVisible = false
    @State private var isPreviewCompact = false
    @State private var isPresentationNotesSidebarVisible = false
    @State private var isWindowBackgroundPickerPresented = false
    @State private var isFunctionKeyConfigurationPresented = false
    @State private var previewNSView: SampleBufferPreviewView?
    @State private var didStartRuntime = false
    @State private var cursorAttentionScale: Double?
    @State private var cursorAttentionTask: Task<Void, Never>?
    @State private var isSoftwareCursorPreviewVisible = false
    @State private var cursorPreviewTask: Task<Void, Never>?
    @State private var notesSidebarDragStartWidth: CGFloat?
    @AppStorage("controlsBarCollapsed.v1") private var isControlsBarCollapsed = false
    @AppStorage("excludeFunctionKeysDuringWindowControl") private var excludeFunctionKeysDuringWindowControl = true
    @AppStorage("softwareCursorScale.v1") private var softwareCursorScale = Self.softwareCursorDefaultScale
    @AppStorage("presentationNotesText.v1") private var presentationNotesText = ""
    @AppStorage("presentationNotesFontSize.v1") private var presentationNotesFontSize = 18.0
    @AppStorage("presentationNotesSidebarWidth.v1") private var presentationNotesSidebarWidth = 360.0

    init(
        pipeline: CameraPipeline,
        extensionInstaller: SystemExtensionInstaller,
        speechToText: SpeechToTextConfiguration,
        speechTranscriber: SpeechToTextTranscriber
    ) {
        self.pipeline = pipeline
        self.extensionInstaller = extensionInstaller
        self.speechToText = speechToText
        self.speechTranscriber = speechTranscriber
    }

    var body: some View {
        GeometryReader { proxy in
            let notesSidebarWidth = effectiveNotesSidebarWidth(for: proxy.size.width)
            let sidebarOuterWidth = isPresentationNotesSidebarVisible
                ? notesSidebarWidth + Self.windowPadding
                : 0
            let contentSize = CGSize(
                width: max(0, proxy.size.width - sidebarOuterWidth),
                height: proxy.size.height
            )

            HStack(alignment: .top, spacing: 0) {
                mainContent(windowSize: contentSize)
                    .frame(width: contentSize.width)

                if isPresentationNotesSidebarVisible {
                    presentationNotesSidebarContainer(
                        width: notesSidebarWidth,
                        maximumWidth: maximumNotesSidebarWidth(for: proxy.size.width)
                    )
                        .frame(width: notesSidebarWidth)
                        .frame(maxHeight: .infinity)
                        .padding(.vertical, Self.windowPadding)
                        .padding(.trailing, Self.windowPadding)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
            .animation(.easeInOut(duration: 0.18), value: isPresentationNotesSidebarVisible)
        }
        .frame(minWidth: isPresentationNotesSidebarVisible ? minimumWindowWidthWithNotes : Self.minimumWindowWidth, minHeight: 460)
        .background(windowBackground)
        .onAppear {
            startupPermissions.beginStartup(with: extensionInstaller) {
                startRuntimeIfNeeded()
            }
        }
        .onDisappear {
            stopRuntime()
        }
        .onChange(of: speechToText.isSpeechToTextEnabled) { _, _ in
            updateSpeechTranscription()
            refreshSpeechCaptionOverlay()
        }
        .onChange(of: speechToText.selectedModelID) { _, _ in
            updateSpeechTranscription()
        }
        .onChange(of: speechToText.availableModels) { _, _ in
            updateSpeechTranscription()
        }
        .onChange(of: speechToText.selectedMicrophoneID) { _, _ in
            updateSpeechTranscription()
        }
        .onChange(of: speechTranscriber.transcribedText) { _, _ in
            refreshSpeechCaptionOverlay()
        }
        .onChange(of: isSpeechTestSentenceVisible) { _, _ in
            refreshSpeechCaptionOverlay()
        }
        .onChange(of: speechToText.captionRenderConfiguration) { _, _ in
            refreshSpeechCaptionOverlay()
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
        .onChange(of: pipeline.outputFrameSize) { _, _ in
            deferViewUpdateMutation {
                refreshWindowControlMapping()
            }
        }
        .onReceive(windowControl.$cursorNormalised) { cursor in
            deferViewUpdateMutation {
                pipeline.setWindowZoomCenter(cursor)
            }
        }
        .onChange(of: extensionInstaller.installationState) { _, newValue in
            startupPermissions.handleInstallerState(newValue, installer: extensionInstaller)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            startupPermissions.beginStartup(with: extensionInstaller) {
                startRuntimeIfNeeded()
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
        .sheet(
            isPresented: Binding(
                get: { startupPermissions.isWizardPresented },
                set: { _ in }
            )
        ) {
            StartupPermissionWizardView(
                coordinator: startupPermissions,
                installer: extensionInstaller
            )
            .interactiveDismissDisabled()
        }
    }

    private var storedNotesSidebarWidth: CGFloat {
        let width = CGFloat(presentationNotesSidebarWidth)
        return width.isFinite ? width : Self.notesSidebarDefaultWidth
    }

    private var minimumWindowWidthWithNotes: CGFloat {
        Self.minimumWindowWidth + clampedNotesSidebarWidth(storedNotesSidebarWidth) + Self.windowPadding
    }

    private func effectiveNotesSidebarWidth(for windowWidth: CGFloat) -> CGFloat {
        clampedNotesSidebarWidth(storedNotesSidebarWidth, maximumWidth: maximumNotesSidebarWidth(for: windowWidth))
    }

    private func maximumNotesSidebarWidth(for windowWidth: CGFloat) -> CGFloat {
        let availableWidth = windowWidth - Self.minimumWindowWidth - Self.windowPadding
        return max(
            Self.notesSidebarMinimumWidth,
            min(Self.notesSidebarMaximumWidth, availableWidth)
        )
    }

    private func clampedNotesSidebarWidth(_ width: CGFloat) -> CGFloat {
        clampedNotesSidebarWidth(width, maximumWidth: Self.notesSidebarMaximumWidth)
    }

    private func clampedNotesSidebarWidth(_ width: CGFloat, maximumWidth: CGFloat) -> CGFloat {
        min(
            max(width, Self.notesSidebarMinimumWidth),
            max(Self.notesSidebarMinimumWidth, maximumWidth)
        )
    }

    private var speechMicrophoneStatusTitle: String {
        "Listening on \(selectedSpeechMicrophoneTitle)"
    }

    private var selectedSpeechMicrophoneTitle: String {
        if let selectedDevice = selectedSpeechMicrophoneDevice {
            return selectedDevice.localizedName
        }

        return speechToText.selectedMicrophoneID.isEmpty ? "System Default Microphone" : "Selected Microphone"
    }

    private var selectedSpeechMicrophoneDevice: AVCaptureDevice? {
        if speechToText.selectedMicrophoneID.isEmpty {
            return AVCaptureDevice.default(for: .audio)
        }

        let session = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone],
            mediaType: .audio,
            position: .unspecified
        )

        return session.devices.first { $0.uniqueID == speechToText.selectedMicrophoneID }
    }

    private var shouldShowVirtualCameraToolbarWarning: Bool {
        switch extensionInstaller.installationState {
        case .notInstalled, .awaitingApproval, .failed:
            return true
        case .installing, .installed, .requiresReboot, .requestCompleted, .removing:
            return false
        }
    }

    private var virtualCameraToolbarStatusColor: Color {
        switch extensionInstaller.installationState {
        case .awaitingApproval:
            return .orange
        case .failed, .notInstalled:
            return .red
        case .installing, .installed, .requiresReboot, .requestCompleted, .removing:
            return .secondary
        }
    }

    private func settingsTabLink<Label: View>(
        tab: SettingsTab,
        @ViewBuilder label: @escaping () -> Label
    ) -> some View {
        SettingsLink {
            label()
        }
        .simultaneousGesture(
            TapGesture().onEnded {
                UserDefaults.standard.set(tab.rawValue, forKey: selectedSettingsTabStorageKey)
            }
        )
    }

    private func mainContent(windowSize: CGSize) -> some View {
        ScrollView(.vertical) {
            VStack(spacing: Self.verticalSpacing) {
                previewPanel
                    .frame(height: previewHeight(for: windowSize))

                if isControlsBarCollapsed {
                    functionKeyMappingBar
                        .frame(height: Self.functionKeyMappingBarHeight)
                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                } else {
                    tabBar
                        .frame(height: Self.tabBarHeight)

                    controlsPanel
                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                }
            }
            .padding(Self.windowPadding)
            .frame(maxWidth: .infinity)
            .frame(minHeight: windowSize.height, alignment: .top)
            .animation(.easeInOut(duration: 0.18), value: isControlsBarCollapsed)
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
                } else if isSoftwareCursorPreviewVisible {
                    GeometryReader { proxy in
                        softwareCursor(
                            at: CGPoint(
                                x: proxy.size.width * 0.5,
                                y: proxy.size.height * 0.5
                            )
                        )
                    }
                    .allowsHitTesting(false)
                    .transition(.opacity)
                }

                HStack(spacing: 10) {
                    Label("\(pipeline.measuredFramesPerSecond, specifier: "%.0f") fps", systemImage: "speedometer")
                    Text(pipeline.outputFrameSize.dimensionsTitle)
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
            ScrollView(.horizontal) {
                tabContent
                    .padding(.horizontal, Self.controlsPanelHorizontalPadding)
                    .padding(.vertical, Self.controlsPanelVerticalPadding)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: Self.controlsPanelHeight, alignment: .top)
            .id(selectedTab)
        }
        .frame(height: Self.controlsPanelHeight, alignment: .top)
    }

    private var functionKeyMappingBar: some View {
        HStack(spacing: 10) {
            ScrollView(.horizontal) {
                HStack(spacing: 8) {
                    ForEach(functionKeys.configuration.slots) { slot in
                        FunctionKeySummaryPill(slot: slot)
                            .frame(width: 128)
                    }
                }
                .padding(.horizontal, 8)
                .frame(maxHeight: .infinity)
            }
            .scrollIndicators(.hidden)

            Button {
                toggleControlsBar()
            } label: {
                Image(systemName: "chevron.up")
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .help("Show controls")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay {
            Capsule()
                .strokeBorder(.white.opacity(0.18), lineWidth: 1)
        }
    }

    private func previewHeight(for windowSize: CGSize) -> CGFloat {
        let bottomChromeHeight = isControlsBarCollapsed
            ? Self.functionKeyMappingBarHeight
            : Self.tabBarHeight + Self.controlsPanelHeight
        let bottomChromeSpacing = isControlsBarCollapsed
            ? Self.verticalSpacing
            : Self.verticalSpacing * 2
        let chromeHeight = Self.windowPadding * 2
            + bottomChromeSpacing
            + bottomChromeHeight
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
        case .speechToText:
            speechToTextTab
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

                    HStack(spacing: 8) {
                        fieldLabel("Input Quality")

                        Picker("Input Quality", selection: $pipeline.cameraInputQuality) {
                            ForEach(CameraInputQuality.allCases) { quality in
                                Text("\(quality.title) (\(quality.dimensionsTitle))")
                                    .tag(quality)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .frame(maxWidth: .infinity, alignment: .trailing)
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

            if shouldShowVirtualCameraToolbarWarning {
                panelDivider

                controlSection("Virtual Camera", systemImage: "exclamationmark.video") {
                    VStack(alignment: .leading, spacing: 10) {
                        statusLine(
                            extensionInstaller.statusText,
                            color: virtualCameraToolbarStatusColor
                        )

                        settingsTabLink(tab: .virtualCamera) {
                            Label("Open Preferences", systemImage: "gearshape")
                        }
                        .controlSize(.small)
                    }
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

            controlSection("Test Functions", systemImage: "switch.2") {
                functionKeyActionButtons
            }
        }
    }

    private var speechToTextTab: some View {
        HStack(alignment: .top, spacing: 22) {
            compactControlSection("Speech", systemImage: "waveform.and.mic") {
                VStack(alignment: .leading, spacing: 10) {
                    Toggle("Transcribe", isOn: $speechToText.isSpeechToTextEnabled)
                        .toggleStyle(.switch)

                    Button {
                        withAnimation(.easeInOut(duration: 0.16)) {
                            isSpeechTestSentenceVisible.toggle()
                        }
                    } label: {
                        Label("Test", systemImage: isSpeechTestSentenceVisible ? "text.bubble.fill" : "text.bubble")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .help(isSpeechTestSentenceVisible ? "Hide test sentence" : "Show test sentence")

                    settingsTabLink(tab: .sound) {
                        Text(speechMicrophoneStatusTitle)
                            .font(.caption)
                            .underline()
                            .lineLimit(1)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.accentColor)
                    .help("Open sound preferences")

                    HStack(spacing: 8) {
                        Text("Model: \(speechToText.selectedModel.title)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)

                        settingsTabLink(tab: .models) {
                            Text("Change")
                        }
                        .controlSize(.small)
                    }
                }
            }

            panelDivider

            controlSection("Captions", systemImage: "captions.bubble") {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 8) {
                        fieldLabel("Font")

                        Picker("Font", selection: $speechToText.captionFont) {
                            ForEach(SpeechToTextCaptionFont.allCases) { font in
                                Text(font.title).tag(font)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        valueHeader("Size", value: "\(Int(speechToText.captionFontSize.rounded())) pt")
                        Slider(value: $speechToText.captionFontSize, in: 14...56, step: 1)
                    }

                    ColorPicker("Font Color", selection: speechCaptionFontColorSelection, supportsOpacity: true)
                        .controlSize(.small)

                    ColorPicker("Background", selection: speechCaptionBackgroundColorSelection, supportsOpacity: true)
                        .controlSize(.small)

                    Toggle("Apply NTSC to captions", isOn: $speechToText.areCaptionsAffectedByNTSC)
                        .toggleStyle(.checkbox)
                        .controlSize(.small)
                        .help("When enabled, captions are rendered before the NTSC effect. When disabled, captions stay crisp.")
                }
            }
            .frame(minWidth: 240)

            panelDivider

            controlSection("Layout", systemImage: "text.alignleft") {
                VStack(alignment: .leading, spacing: 12) {
                    VStack(alignment: .leading, spacing: 6) {
                        valueHeader("Width", value: speechToText.captionWidth.title)

                        Picker("Width", selection: $speechToText.captionWidth) {
                            ForEach(SpeechToTextCaptionWidth.allCases) { width in
                                Text(width.title).tag(width)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.segmented)
                        .controlSize(.small)
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        valueHeader("Padding", value: "\(Int(speechToText.captionPadding.rounded())) px")
                        Slider(value: $speechToText.captionPadding, in: 4...48, step: 1)
                    }

                    HStack(spacing: 8) {
                        fieldLabel("Position")

                        Picker("Position", selection: $speechToText.captionAlignment) {
                            ForEach(SpeechToTextCaptionAlignment.allCases) { alignment in
                                Text(alignment.title).tag(alignment)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .controlSize(.small)
                    }
                }
            }
            .frame(minWidth: 260)
        }
    }

    private var presentTab: some View {
        HStack(alignment: .top, spacing: 22) {
            controlSection("Output", systemImage: "display") {
                VStack(alignment: .leading, spacing: 12) {
                    VStack(alignment: .leading, spacing: 6) {
                        valueHeader("Resolution", value: pipeline.outputFrameSize.dimensionsTitle)

                        Picker("Resolution", selection: $pipeline.outputFrameSize) {
                            ForEach(OutputFrameSize.allCases) { frameSize in
                                Text(frameSize.title)
                                    .tag(frameSize)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.segmented)
                        .controlSize(.small)
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

            controlSection("Notes", systemImage: "note.text") {
                Button {
                    isPresentationNotesSidebarVisible.toggle()
                } label: {
                    Label(
                        isPresentationNotesSidebarVisible ? "Hide Notes" : "Notes",
                        systemImage: isPresentationNotesSidebarVisible ? "sidebar.right" : "note.text"
                    )
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }

            panelDivider

            controlSection("Function Keys", systemImage: "keyboard") {
                presentFunctionKeyActionButtons
            }
            .frame(minWidth: 300)

            panelDivider

            controlSection("Control Window", systemImage: "cursorarrow") {
                windowControlControls
            }
        }
    }

    private var presentationNotesSidebar: some View {
        LiquidGlassSurface(cornerRadius: Self.windowCornerRadius) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    Label("Notes", systemImage: "note.text")
                        .font(.headline)

                    Spacer()

                    Button {
                        isPresentationNotesSidebarVisible = false
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .buttonStyle(.borderless)
                    .help("Close notes")
                }

                HStack(spacing: 10) {
                    Image(systemName: "textformat.size")
                        .foregroundStyle(.secondary)

                    Slider(value: $presentationNotesFontSize, in: 12...34, step: 1)

                    Stepper(value: $presentationNotesFontSize, in: 12...34, step: 1) {
                        Text("\(Int(presentationNotesFontSize.rounded())) pt")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(width: 42, alignment: .trailing)
                    }
                    .labelsHidden()
                }

                PresentationNotesTextView(
                    text: $presentationNotesText,
                    fontSize: presentationNotesFontSize
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(.white.opacity(0.12), lineWidth: 1)
                }

                HStack(spacing: 8) {
                    Button {
                        openPresentationNotesMarkdownFile()
                    } label: {
                        Label("Open", systemImage: "doc.text")
                            .frame(maxWidth: .infinity)
                    }

                    Button(role: .destructive) {
                        presentationNotesText = ""
                    } label: {
                        Label("Clear", systemImage: "trash")
                            .frame(maxWidth: .infinity)
                    }
                    .disabled(presentationNotesText.isEmpty)
                }
            }
            .padding(16)
            .frame(maxHeight: .infinity)
        }
    }

    private func presentationNotesSidebarContainer(width: CGFloat, maximumWidth: CGFloat) -> some View {
        ZStack(alignment: .leading) {
            presentationNotesSidebar
                .frame(width: width)

            notesSidebarResizeHandle(width: width, maximumWidth: maximumWidth)
                .offset(x: -7)
        }
    }

    private func notesSidebarResizeHandle(width: CGFloat, maximumWidth: CGFloat) -> some View {
        Rectangle()
            .fill(Color.white.opacity(0.001))
            .frame(width: 14)
            .overlay {
                Capsule()
                    .fill(Color.secondary.opacity(0.38))
                    .frame(width: 3, height: 44)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { value in
                        let startWidth = notesSidebarDragStartWidth ?? width
                        notesSidebarDragStartWidth = startWidth

                        let requestedWidth = startWidth - value.translation.width
                        presentationNotesSidebarWidth = Double(
                            clampedNotesSidebarWidth(requestedWidth, maximumWidth: maximumWidth)
                        )
                    }
                    .onEnded { value in
                        let startWidth = notesSidebarDragStartWidth ?? width
                        let requestedWidth = startWidth - value.translation.width
                        presentationNotesSidebarWidth = Double(
                            clampedNotesSidebarWidth(requestedWidth, maximumWidth: maximumWidth)
                        )
                        notesSidebarDragStartWidth = nil
                    }
            )
            .onHover { isHovering in
                if isHovering {
                    NSCursor.resizeLeftRight.set()
                } else {
                    NSCursor.arrow.set()
                }
            }
            .help("Resize notes sidebar")
            .accessibilityLabel("Resize notes sidebar")
    }

    @ViewBuilder
    private func softwareCursor(at position: CGPoint) -> some View {
        let cursorScale = CGFloat(effectiveSoftwareCursorScale)
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

    private var presentFunctionKeyActionButtons: some View {
        let columns = [
            GridItem(.flexible(), spacing: 6),
            GridItem(.flexible(), spacing: 6)
        ]
        let slots = activeFunctionKeySlots

        return Group {
            if slots.isEmpty {
                statusLine("No active function keys")
            } else {
                LazyVGrid(columns: columns, alignment: .leading, spacing: 6) {
                    ForEach(slots) { slot in
                        Button {
                            functionKeys.reportManualAction(slot.action, sourceTitle: slot.key.title)
                            performFunctionKeyAction(
                                slot.action,
                                identifier: slot.key.storageIdentifier,
                                imagePath: slot.imagePath
                            )
                        } label: {
                            Label("\(slot.key.title): \(slot.action.title)", systemImage: slot.action.systemImage)
                                .lineLimit(1)
                                .minimumScaleFactor(0.78)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(isFunctionKeyActionDisabled(slot.action))
                    }
                }
            }
        }
    }

    private var activeFunctionKeySlots: [FunctionKeySlot] {
        functionKeys.configuration.slots.filter(isActiveFunctionKeySlot)
    }

    private func isActiveFunctionKeySlot(_ slot: FunctionKeySlot) -> Bool {
        guard slot.action != .none else { return false }

        if slot.action == .toggleImageOverlay {
            return slot.imagePath != nil
        }

        return true
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

                VStack(alignment: .leading, spacing: 6) {
                    valueHeader("Cursor Size", value: softwareCursorScaleTitle)

                    Slider(
                        value: softwareCursorScaleSelection,
                        in: Self.softwareCursorMinimumScale...Self.softwareCursorDefaultScale
                    )
                    .controlSize(.small)

                    Button {
                        showSoftwareCursorPreview()
                    } label: {
                        Label("Preview Cursor", systemImage: "cursorarrow.rays")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(previewNSView == nil)
                }

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

    private func compactControlSection<Content: View>(
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
        .fixedSize(horizontal: true, vertical: false)
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

    private var speechCaptionFontColorSelection: Binding<Color> {
        Binding {
            speechToText.captionFontColor.swiftUIColor
        } set: { newValue in
            speechToText.captionFontColor = SpeechToTextColor(color: newValue)
        }
    }

    private var speechCaptionBackgroundColorSelection: Binding<Color> {
        Binding {
            speechToText.captionBackgroundColor.swiftUIColor
        } set: { newValue in
            speechToText.captionBackgroundColor = SpeechToTextColor(color: newValue)
        }
    }

    private var clampedSoftwareCursorScale: Double {
        max(
            Self.softwareCursorMinimumScale,
            min(Self.softwareCursorDefaultScale, softwareCursorScale)
        )
    }

    private var effectiveSoftwareCursorScale: Double {
        cursorAttentionScale ?? clampedSoftwareCursorScale
    }

    private var softwareCursorScaleTitle: String {
        let percent = clampedSoftwareCursorScale / Self.softwareCursorDefaultScale * 100
        return "\(Int(percent.rounded()))%"
    }

    private var softwareCursorScaleSelection: Binding<Double> {
        Binding {
            clampedSoftwareCursorScale
        } set: { newValue in
            cursorAttentionTask?.cancel()
            cursorAttentionTask = nil
            cursorAttentionScale = nil
            softwareCursorScale = max(
                Self.softwareCursorMinimumScale,
                min(Self.softwareCursorDefaultScale, newValue)
            )
            showSoftwareCursorPreview()
        }
    }

    private func refreshSpeechCaptionOverlay() {
        let liveText = speechToText.isSpeechToTextEnabled
            ? speechTranscriber.transcribedText
            : ""

        pipeline.setSpeechCaptionOverlay(
            text: isSpeechTestSentenceVisible
                ? Self.speechTestSentence
                : liveText.isEmpty ? nil : liveText,
            configuration: speechToText.captionRenderConfiguration
        )
    }

    private func updateSpeechTranscription() {
        guard didStartRuntime else { return }

        speechTranscriber.apply(
            model: speechToText.selectedModel,
            microphoneID: speechToText.selectedMicrophoneID,
            isEnabled: speechToText.isSpeechToTextEnabled
        )
    }

    private func startRuntimeIfNeeded() {
        guard !didStartRuntime else { return }

        didStartRuntime = true
        pipeline.refreshCameras()
        pipeline.start()
        updateSpeechTranscription()
        refreshSpeechCaptionOverlay()
        functionKeys.onTrigger = handleFunctionKeyTrigger(_:)
        functionKeys.startMonitoring()
    }

    private func stopRuntime() {
        didStartRuntime = false
        cursorAttentionTask?.cancel()
        cursorPreviewTask?.cancel()
        isSoftwareCursorPreviewVisible = false
        functionKeys.stopMonitoring()
        speechTranscriber.stopTranscribing(clearText: true)
        pipeline.setSpeechCaptionOverlay(text: nil, configuration: speechToText.captionRenderConfiguration)
        windowControl.deactivate()
        pipeline.stop()
        pipeline.clearWindowBackground()
    }

    private func isFunctionKeyActionDisabled(_ action: FunctionKeyAction) -> Bool {
        if action == .cycleWindowBackground {
            return pipeline.selectedWindowBackgroundOptions.count < 2
        }

        return action.needsWindowBackground && !pipeline.hasWindowBackgroundSelection
    }

    private func toggleControlsBar() {
        withAnimation(.easeInOut(duration: 0.18)) {
            isControlsBarCollapsed.toggle()
        }
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

    private func openPresentationNotesMarkdownFile() {
        let panel = NSOpenPanel()
        var markdownTypes: [UTType] = []
        if let mdType = UTType(filenameExtension: "md") {
            markdownTypes.append(mdType)
        }
        if let markdownType = UTType(filenameExtension: "markdown") {
            markdownTypes.append(markdownType)
        }
        panel.allowedContentTypes = markdownTypes.isEmpty ? [.plainText] : markdownTypes
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.prompt = "Open"
        panel.message = "Choose a Markdown file to load into the presentation notes."

        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }

            do {
                presentationNotesText = try String(contentsOf: url, encoding: .utf8)
            } catch {
                NSSound.beep()
            }
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
        case .toggleTranscription:
            speechToText.isSpeechToTextEnabled.toggle()
        case .toggleControlsBar:
            toggleControlsBar()
        case .pressLeftArrow:
            windowControl.pressKey(.leftArrow)
        case .pressRightArrow:
            windowControl.pressKey(.rightArrow)
        case .pressSpace:
            windowControl.pressKey(.space)
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

    private func showSoftwareCursorPreview() {
        guard !windowControl.isActive else { return }

        cursorPreviewTask?.cancel()
        withAnimation(.easeOut(duration: 0.12)) {
            isSoftwareCursorPreviewVisible = true
        }

        cursorPreviewTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            guard !Task.isCancelled else { return }

            withAnimation(.easeIn(duration: 0.18)) {
                isSoftwareCursorPreviewVisible = false
            }
        }
    }

    private func drawAttentionToCursor() {
        cursorAttentionTask?.cancel()
        cursorAttentionScale = nil
        let restingScale = clampedSoftwareCursorScale

        cursorAttentionTask = Task { @MainActor in
            let scales = [
                restingScale * 2.0,
                restingScale * 0.5,
                restingScale * 1.5,
                restingScale * 0.75,
                restingScale * 1.25,
                restingScale
            ]
            let stepDuration = 250_000_000

            for scale in scales {
                guard !Task.isCancelled else { return }

                withAnimation(.spring(response: 0.18, dampingFraction: 0.46, blendDuration: 0)) {
                    cursorAttentionScale = scale
                }

                try? await Task.sleep(nanoseconds: UInt64(stepDuration))
            }

            cursorAttentionScale = nil
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

private struct SpeechToTextMicrophoneLevelView: View {
    let level: Double
    let isMonitoring: Bool

    private var activeBarCount: Int {
        guard isMonitoring else { return 0 }
        return max(0, min(5, Int(ceil(max(0, min(1, level)) * 5))))
    }

    var body: some View {
        HStack(alignment: .bottom, spacing: 6) {
            ForEach(0..<5, id: \.self) { index in
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(index < activeBarCount ? barColor(for: index) : Color.secondary.opacity(0.18))
                    .frame(width: 12, height: CGFloat(10 + index * 6))
            }

            Text(isMonitoring ? "Live input" : "Input idle")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(height: 36, alignment: .bottomLeading)
        .animation(.easeOut(duration: 0.12), value: activeBarCount)
        .accessibilityLabel("Microphone input level")
        .accessibilityValue("\(activeBarCount) of 5 bars")
    }

    private func barColor(for index: Int) -> Color {
        switch index {
        case 0...2:
            return .green
        case 3:
            return .yellow
        default:
            return .red
        }
    }
}

private struct SpeechToTextCaptionOverlay: View {
    @ObservedObject var configuration: SpeechToTextConfiguration
    let text: String

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: configuration.captionAlignment.swiftUIAlignment) {
                Text(text)
                    .font(configuration.captionFont.swiftUIFont(size: CGFloat(configuration.captionFontSize)))
                    .foregroundStyle(configuration.captionFontColor.swiftUIColor)
                    .multilineTextAlignment(configuration.captionAlignment.textAlignment)
                    .lineLimit(2)
                    .minimumScaleFactor(0.72)
                    .padding(CGFloat(configuration.captionPadding))
                    .frame(
                        width: max(120, proxy.size.width * CGFloat(configuration.captionWidth.rawValue)),
                        alignment: configuration.captionAlignment.frameAlignment
                    )
                    .background(
                        configuration.captionBackgroundColor.swiftUIColor,
                        in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                    )
                    .padding(10)
            }
        }
    }
}

struct EmynSettingsView: View {
    @ObservedObject var pipeline: CameraPipeline
    @ObservedObject var extensionInstaller: SystemExtensionInstaller
    @ObservedObject var speechToText: SpeechToTextConfiguration
    @ObservedObject var speechModelCatalog: SpeechToTextModelCatalog
    @ObservedObject var speechModelDownloader: SpeechToTextModelDownloader
    @ObservedObject var speechMicrophoneMonitor: SpeechToTextMicrophoneMonitor
    @ObservedObject var speechTranscriber: SpeechToTextTranscriber
    @AppStorage(selectedSettingsTabStorageKey) private var selectedTab: SettingsTab = .background

    var body: some View {
        TabView(selection: $selectedTab) {
            BackgroundRemovalSettingsView(pipeline: pipeline)
                .tabItem {
                    Label("Background", systemImage: "person.crop.rectangle")
                }
                .tag(SettingsTab.background)

            VirtualCameraSettingsView(installer: extensionInstaller)
                .tabItem {
                    Label("Virtual Camera", systemImage: "video.badge.plus")
                }
                .tag(SettingsTab.virtualCamera)

            SpeechSoundSettingsView(
                configuration: speechToText,
                microphoneMonitor: speechMicrophoneMonitor
            )
            .tabItem {
                Label("Sound", systemImage: "mic")
            }
            .tag(SettingsTab.sound)

            SpeechModelSettingsView(
                configuration: speechToText,
                catalog: speechModelCatalog,
                downloader: speechModelDownloader,
                transcriber: speechTranscriber
            )
            .tabItem {
                Label("Models", systemImage: "shippingbox")
            }
            .tag(SettingsTab.models)
        }
        .frame(width: 520, height: 460)
    }
}

private struct VirtualCameraSettingsView: View {
    @ObservedObject var installer: SystemExtensionInstaller

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Label("Virtual Camera", systemImage: "video.badge.plus")
                .font(.title3.weight(.semibold))

            Form {
                LabeledContent("Status") {
                    SettingsStatusLine(text: installer.statusText)
                }

                LabeledContent("Install") {
                    HStack(spacing: 8) {
                        Button {
                            installer.activate()
                        } label: {
                            Label("Install", systemImage: "video.badge.plus")
                        }
                        .disabled(isInstallDisabled)

                        Button {
                            installer.reinstall()
                        } label: {
                            Label("Update", systemImage: "arrow.triangle.2.circlepath")
                        }
                        .disabled(isUpdateDisabled)
                        .help("Reinstall the virtual camera so it picks up the version bundled with this app")

                        Button {
                            installer.deactivate()
                        } label: {
                            Label("Remove", systemImage: "video.badge.minus")
                        }
                        .disabled(isRemoveDisabled)
                    }
                }

                if installer.needsUserApproval {
                    LabeledContent("Approval") {
                        SettingsStatusLine(text: "Approve the virtual camera in System Settings, then return to Emyn.")
                    }
                }
            }
            .formStyle(.grouped)
        }
        .padding(24)
        .frame(width: 460)
    }

    private var isInstallDisabled: Bool {
        switch installer.installationState {
        case .installing, .installed, .requiresReboot:
            return true
        case .notInstalled, .awaitingApproval, .requestCompleted, .removing, .failed:
            return false
        }
    }

    private var isRemoveDisabled: Bool {
        switch installer.installationState {
        case .notInstalled, .installing, .removing:
            return true
        case .awaitingApproval, .installed, .requiresReboot, .requestCompleted, .failed:
            return false
        }
    }

    private var isUpdateDisabled: Bool {
        switch installer.installationState {
        case .notInstalled, .installing, .removing:
            return true
        case .awaitingApproval, .installed, .requiresReboot, .requestCompleted, .failed:
            return false
        }
    }
}

private struct SpeechSoundSettingsView: View {
    @ObservedObject var configuration: SpeechToTextConfiguration
    @ObservedObject var microphoneMonitor: SpeechToTextMicrophoneMonitor

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Label("Sound Source", systemImage: "mic")
                .font(.title3.weight(.semibold))

            Form {
                Picker("Microphone", selection: $configuration.selectedMicrophoneID) {
                    Text("System Default").tag("")

                    ForEach(microphoneMonitor.microphones) { microphone in
                        Text(microphone.title).tag(microphone.id)
                    }

                    if shouldShowMissingSelectedMicrophone {
                        Text("Unavailable Microphone").tag(configuration.selectedMicrophoneID)
                    }
                }

                HStack {
                    Text("Input")
                    Spacer()
                    SpeechToTextMicrophoneLevelView(
                        level: microphoneMonitor.inputLevel,
                        isMonitoring: microphoneMonitor.isMonitoring
                    )
                }

                HStack {
                    Text("Monitor")
                    Spacer()
                    Button {
                        startMonitoring()
                    } label: {
                        Label("Test", systemImage: "waveform")
                    }

                    Button {
                        microphoneMonitor.refreshDevices()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .help("Refresh microphones")
                }

                LabeledContent("Status") {
                    SettingsStatusLine(text: microphoneMonitor.statusText)
                }
            }
            .formStyle(.grouped)
        }
        .padding(24)
        .frame(width: 460)
        .onAppear {
            microphoneMonitor.refreshDevices()
            startMonitoring()
        }
        .onDisappear {
            microphoneMonitor.stopMonitoring()
        }
        .onChange(of: configuration.selectedMicrophoneID) { _, _ in
            startMonitoring()
        }
    }

    private var shouldShowMissingSelectedMicrophone: Bool {
        !configuration.selectedMicrophoneID.isEmpty
            && !microphoneMonitor.microphones.contains { $0.id == configuration.selectedMicrophoneID }
    }

    private func startMonitoring() {
        microphoneMonitor.startMonitoring(deviceID: configuration.selectedMicrophoneID)
    }
}

private struct SpeechModelSettingsView: View {
    @ObservedObject var configuration: SpeechToTextConfiguration
    @ObservedObject var catalog: SpeechToTextModelCatalog
    @ObservedObject var downloader: SpeechToTextModelDownloader
    @ObservedObject var transcriber: SpeechToTextTranscriber

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Label("Speech Model", systemImage: "shippingbox")
                .font(.title3.weight(.semibold))

            Form {
                Picker("Model", selection: $configuration.selectedModelID) {
                    ForEach(configuration.availableModels) { model in
                        Text("\(model.title) (\(model.sizeTitle))")
                            .tag(model.id)
                    }
                }

                LabeledContent("Catalog") {
                    HStack(spacing: 8) {
                        SettingsStatusLine(text: catalog.statusText)

                        Button {
                            catalog.refresh(configuration: configuration)
                        } label: {
                            Label("Refresh", systemImage: "arrow.clockwise")
                        }
                        .disabled(catalog.isRefreshing)
                    }
                }

                LabeledContent("Size") {
                    Text(configuration.selectedModel.sizeTitle)
                        .foregroundStyle(.secondary)
                }

                LabeledContent("Details") {
                    SettingsStatusLine(text: configuration.selectedModel.detail)
                }

                if let path = configuration.localModelPathForBackend() {
                    LabeledContent("Local File") {
                        Text(path)
                            .font(.caption2.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }

                LabeledContent("Download") {
                    modelDownloadControls(configuration.selectedModel)
                }

                if downloader.activeModelID == configuration.selectedModel.id {
                    ProgressView(value: downloader.progress)
                        .progressViewStyle(.linear)
                }

                LabeledContent("Status") {
                    SettingsStatusLine(text: downloader.statusText)
                }

                LabeledContent("Backend") {
                    SettingsStatusLine(text: configuration.backendStatusText)
                }

                LabeledContent("Runtime") {
                    SettingsStatusLine(text: transcriber.modelStatusText)
                }
            }
            .formStyle(.grouped)
        }
        .padding(24)
        .frame(width: 460)
        .onAppear {
            catalog.refreshIfNeeded(configuration: configuration)
            transcriber.loadModelIfAvailable(configuration.selectedModel)
        }
        .onChange(of: configuration.selectedModelID) { _, _ in
            transcriber.loadModelIfAvailable(configuration.selectedModel)
        }
        .onChange(of: configuration.availableModels) { _, _ in
            transcriber.loadModelIfAvailable(configuration.selectedModel)
        }
        .onChange(of: downloader.statusText) { _, _ in
            guard downloader.isModelDownloaded(configuration.selectedModel) else { return }
            transcriber.loadModelIfAvailable(configuration.selectedModel)
        }
    }

    private func modelDownloadControls(_ model: SpeechToTextModelDescriptor) -> some View {
        let isDownloaded = downloader.isModelDownloaded(model)
        let isActiveDownload = downloader.activeModelID == model.id

        return HStack(spacing: 8) {
            Button {
                if isActiveDownload {
                    downloader.cancel()
                } else {
                    downloader.download(model)
                }
            } label: {
                Label(
                    isActiveDownload ? "Cancel" : isDownloaded ? "Downloaded" : "Download",
                    systemImage: isActiveDownload ? "xmark.circle" : isDownloaded ? "checkmark.circle.fill" : "arrow.down.circle"
                )
            }
            .disabled(isDownloaded && !isActiveDownload)

            Button {
                downloader.revealDownloadedModel(model)
            } label: {
                Image(systemName: "folder")
            }
            .disabled(!isDownloaded)
            .help("Reveal downloaded model")

            Button(role: .destructive) {
                downloader.deleteDownloadedModel(model)
            } label: {
                Image(systemName: "trash")
            }
            .disabled(!isDownloaded || isActiveDownload)
            .help("Delete downloaded model")
        }
    }
}

private struct SettingsStatusLine: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.trailing)
            .lineLimit(2)
            .fixedSize(horizontal: false, vertical: true)
    }
}

struct BackgroundRemovalSettingsView: View {
    @ObservedObject var pipeline: CameraPipeline

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Label("Background Removal", systemImage: "person.crop.rectangle")
                .font(.title3.weight(.semibold))

            Form {
                Picker("Quality", selection: $pipeline.quality) {
                    ForEach(SegmentationQuality.allCases) { quality in
                        Text(quality.title).tag(quality)
                    }
                }

                Picker("Analysis", selection: $pipeline.analysisResolution) {
                    ForEach(SegmentationAnalysisResolution.allCases) { resolution in
                        Text("\(resolution.title) (\(resolution.dimensionsTitle(for: pipeline.outputFrameSize)))")
                            .tag(resolution)
                    }
                }

                HStack {
                    Text("Smoothing")
                    Slider(value: $pipeline.temporalSmoothing, in: 0.0...0.9, step: 0.05)
                    Text(pipeline.temporalSmoothing, format: .percent.precision(.fractionLength(0)))
                        .foregroundStyle(.secondary)
                        .frame(width: 44, alignment: .trailing)
                }

                HStack {
                    Text("Mask Blur")
                    Slider(value: $pipeline.maskBlurRadius, in: 0.0...4.0, step: 0.1)
                    Text("\(pipeline.maskBlurRadius, specifier: "%.1f") px")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .frame(width: 56, alignment: .trailing)
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
    ContentView(
        pipeline: CameraPipeline(),
        extensionInstaller: SystemExtensionInstaller(),
        speechToText: SpeechToTextConfiguration(),
        speechTranscriber: SpeechToTextTranscriber()
    )
}
