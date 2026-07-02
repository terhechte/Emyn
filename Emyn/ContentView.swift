//
//  ContentView.swift
//  Emyn
//
//  Created by Benedikt Terhechte on 01.07.26.
//

import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    private static let softwareCursorBaseSize: CGFloat = 32
    private static let softwareCursorDefaultScale: CGFloat = 2
    private static let softwareCursorHotspot = CGPoint(x: 2, y: 2)
    private static let softwareCursorImage: NSImage? = {
        if let url = Bundle.main.url(forResource: "cursor", withExtension: "png") {
            return NSImage(contentsOf: url)
        }

        return NSImage(named: "cursor")
    }()

    @StateObject private var pipeline = CameraPipeline()
    @StateObject private var extensionInstaller = SystemExtensionInstaller()
    @StateObject private var windowBackgroundPicker = WindowBackgroundPickerModel()
    @StateObject private var windowControl = WindowControlCoordinator()
    @StateObject private var functionKeys = FunctionKeyController()
    @State private var isWindowBackgroundPickerPresented = false
    @State private var isFunctionKeyConfigurationPresented = false
    @State private var previewNSView: SampleBufferPreviewView?
    @State private var cursorScale = Self.softwareCursorDefaultScale
    @State private var cursorAttentionTask: Task<Void, Never>?
    @AppStorage("excludeFunctionKeysDuringWindowControl") private var excludeFunctionKeysDuringWindowControl = true

    var body: some View {
        HStack(spacing: 0) {
            controls
            Divider()
            preview
        }
        .frame(minWidth: 980, minHeight: 640)
        .background(Color(nsColor: .windowBackgroundColor))
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
        .onChange(of: excludeFunctionKeysDuringWindowControl) { newValue in
            windowControl.setExcludeFunctionKeys(newValue)
        }
        .onReceive(windowControl.$cursorNormalised) { cursor in
            pipeline.setWindowZoomCenter(cursor)
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

    private var controls: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 10) {
                Image(systemName: "video.fill")
                    .font(.title2)
                    .foregroundStyle(.tint)
                Text("Emyn")
                    .font(.title2.weight(.semibold))
            }

            VStack(alignment: .leading, spacing: 8) {
                HStack {
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

                    Button {
                        pipeline.refreshCameras()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .help("Refresh cameras")
                }

                HStack {
                    Button {
                        pipeline.isRunning ? pipeline.stop() : pipeline.start()
                    } label: {
                        Label(
                            pipeline.isRunning ? "Stop" : "Start",
                            systemImage: pipeline.isRunning ? "stop.fill" : "play.fill"
                        )
                    }
                    .buttonStyle(.borderedProminent)

                    Text(pipeline.statusText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            VStack(alignment: .leading, spacing: 12) {
                Picker("Quality", selection: $pipeline.quality) {
                    ForEach(SegmentationQuality.allCases) { quality in
                        Text(quality.title).tag(quality)
                    }
                }
                .pickerStyle(.segmented)

                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Analysis")
                        Spacer()
                        Text(pipeline.analysisResolution.dimensionsTitle)
                            .foregroundStyle(.secondary)
                    }

                    Picker("Analysis", selection: $pipeline.analysisResolution) {
                        ForEach(SegmentationAnalysisResolution.allCases) { resolution in
                            Text(resolution.title).tag(resolution)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .help("Resolution used for Vision person segmentation")
                }

                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Smoothing")
                        Spacer()
                        Text(pipeline.temporalSmoothing, format: .percent.precision(.fractionLength(0)))
                            .foregroundStyle(.secondary)
                    }
                    Slider(value: $pipeline.temporalSmoothing, in: 0.0...0.9, step: 0.05)
                }

                Stepper(
                    "Reuse \(pipeline.maskReuseFrameCount) frame\(pipeline.maskReuseFrameCount == 1 ? "" : "s")",
                    value: $pipeline.maskReuseFrameCount,
                    in: 0...5
                )

                VStack(alignment: .leading, spacing: 8) {
                    Text("Background")

                    Picker("Background Mode", selection: backgroundModeSelection) {
                        ForEach(BackgroundMode.allCases) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)

                    if pipeline.backgroundMode == .blur {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text("Blur Radius")
                                Spacer()
                                Text("\(pipeline.backgroundBlurRadius, specifier: "%.0f") px")
                                    .foregroundStyle(.secondary)
                            }
                            Slider(value: $pipeline.backgroundBlurRadius, in: 4...40, step: 1)
                        }
                    } else if pipeline.backgroundMode == .media {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(spacing: 8) {
                                Button {
                                    chooseBackgroundMedia()
                                } label: {
                                    Label("Choose Media", systemImage: "photo.on.rectangle.angled")
                                }
                                .controlSize(.small)

                                if pipeline.hasBackgroundMediaSelection {
                                    Button {
                                        pipeline.clearBackgroundMedia()
                                    } label: {
                                        Image(systemName: "xmark.circle.fill")
                                    }
                                    .controlSize(.small)
                                    .help("Clear background media")
                                }
                            }

                            Picker("Media Fit", selection: backgroundMediaFitSelection) {
                                ForEach(BackgroundMediaFit.allCases) { fit in
                                    Text(fit.title).tag(fit)
                                }
                            }
                            .labelsHidden()
                            .pickerStyle(.segmented)
                            .controlSize(.small)

                            backgroundAlignmentPicker(selection: backgroundMediaAlignmentSelection)

                            Text(pipeline.selectedBackgroundMediaTitle ?? pipeline.backgroundMediaStatusText)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                    } else {
                        HStack(spacing: 8) {
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
                                    .frame(width: 28, height: 28)
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

                    HStack(spacing: 8) {
                        Button {
                            windowBackgroundPicker.refresh()
                            isWindowBackgroundPickerPresented = true
                        } label: {
                            Label("Choose Windows", systemImage: "rectangle.on.rectangle")
                        }
                        .controlSize(.small)

                        if pipeline.hasWindowBackgroundSelection {
                            Button {
                                clearSelectedWindowBackground()
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                            }
                            .controlSize(.small)
                            .help("Clear window background")
                        }
                    }

                    if pipeline.hasWindowBackgroundSelection {
                        Picker("Window Fit", selection: windowBackgroundFitSelection) {
                            ForEach(BackgroundMediaFit.allCases) { fit in
                                Text(fit.title).tag(fit)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.segmented)
                        .controlSize(.small)

                        backgroundAlignmentPicker(selection: windowBackgroundAlignmentSelection)
                    }

                    Text(pipeline.selectedWindowBackgroundTitle ?? pipeline.windowBackgroundStatusText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)

                    if let activeWindowBackgroundOption = pipeline.activeWindowBackgroundOption {
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
                        }
                        .controlSize(.small)
                        .disabled(previewNSView == nil)

                        Text(windowControl.statusText)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 10) {
                Button {
                    isFunctionKeyConfigurationPresented = true
                } label: {
                    Label("Function Keys", systemImage: "keyboard")
                }

                functionKeyActionButtons

                Text(functionKeys.statusText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            Divider()

            VStack(alignment: .leading, spacing: 10) {
                Text("Output")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)

                outputFlipButtons
                ntscPresetPicker
            }

            Divider()

            VStack(alignment: .leading, spacing: 10) {
                Button {
                    extensionInstaller.activate()
                } label: {
                    Label("Install Virtual Camera", systemImage: "video.badge.plus")
                }

                Button {
                    extensionInstaller.deactivate()
                } label: {
                    Label("Remove Virtual Camera", systemImage: "video.badge.minus")
                }

                Text(extensionInstaller.statusText)
                    .font(.caption)
                    .foregroundStyle(extensionInstaller.needsUserApproval ? .orange : .secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)
        }
        .padding(22)
        .frame(width: 286)
    }

    private var preview: some View {
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

    private func backgroundAlignmentPicker(selection: Binding<BackgroundContentAlignment>) -> some View {
        HStack(spacing: 8) {
            Text("Alignment")
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
            Label("NTSC Preset", systemImage: "tv")
                .font(.caption)
                .foregroundStyle(.secondary)

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

    private var cameraSelection: Binding<String> {
        Binding {
            pipeline.selectedCameraID
        } set: { newValue in
            pipeline.selectedCameraID = newValue
        }
    }

    private var backgroundModeSelection: Binding<BackgroundMode> {
        Binding {
            pipeline.backgroundMode
        } set: { newValue in
            pipeline.backgroundMode = newValue
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
                excludeFunctionKeys: excludeFunctionKeysDuringWindowControl
            )
        }
    }

    private func clearSelectedWindowBackground() {
        windowControl.deactivate()
        pipeline.clearWindowBackground()
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
                excludeFunctionKeys: excludeFunctionKeysDuringWindowControl
            )
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

#Preview {
    ContentView()
}
