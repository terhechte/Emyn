//
//  ContentView.swift
//  Emyn
//
//  Created by Benedikt Terhechte on 01.07.26.
//

import SwiftUI

struct ContentView: View {
    @StateObject private var pipeline = CameraPipeline()
    @StateObject private var extensionInstaller = SystemExtensionInstaller()
    @StateObject private var windowBackgroundPicker = WindowBackgroundPickerModel()
    @StateObject private var windowControl = WindowControlCoordinator()
    @State private var isWindowBackgroundPickerPresented = false
    @State private var selectedWindowBackgroundOption: WindowBackgroundOption?
    @State private var previewNSView: SampleBufferPreviewView?
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
        }
        .onDisappear {
            windowControl.deactivate()
            pipeline.stop()
            pipeline.clearWindowBackground()
        }
        .onChange(of: excludeFunctionKeysDuringWindowControl) { newValue in
            windowControl.setExcludeFunctionKeys(newValue)
        }
        .sheet(isPresented: $isWindowBackgroundPickerPresented) {
            WindowBackgroundPickerView(
                model: windowBackgroundPicker,
                onSelect: { option in
                    windowControl.deactivate()
                    selectedWindowBackgroundOption = option
                    pipeline.selectWindowBackground(option)
                    isWindowBackgroundPickerPresented = false
                },
                onCancel: {
                    isWindowBackgroundPickerPresented = false
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

                        HStack(spacing: 8) {
                            Button {
                                windowBackgroundPicker.refresh()
                                isWindowBackgroundPickerPresented = true
                            } label: {
                                Label("Choose Window", systemImage: "rectangle.on.rectangle")
                            }
                            .controlSize(.small)

                            if pipeline.selectedWindowBackgroundTitle != nil {
                                Button {
                                    clearSelectedWindowBackground()
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                }
                                .controlSize(.small)
                                .help("Clear window background")
                            }
                        }

                        Text(pipeline.selectedWindowBackgroundTitle ?? pipeline.windowBackgroundStatusText)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)

                        if pipeline.selectedWindowBackgroundTitle != nil, let selectedWindowBackgroundOption {
                            Toggle(
                                "Exclude Function Keys",
                                isOn: $excludeFunctionKeysDuringWindowControl
                            )
                            .toggleStyle(.checkbox)
                            .controlSize(.small)
                            .help("Keep F1-F12 available outside the controlled window")

                            Button {
                                toggleWindowControl(for: selectedWindowBackgroundOption)
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
                    Circle()
                        .fill(.black.opacity(0.32))
                        .overlay {
                            Circle()
                                .stroke(.white, lineWidth: 2)
                        }
                        .frame(width: 18, height: 18)
                        .shadow(color: .black.opacity(0.45), radius: 2, y: 1)
                        .position(
                            x: proxy.size.width * (region.minX + cursor.x * region.width),
                            y: proxy.size.height * (region.minY + cursor.y * region.height)
                        )
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
            if newValue == .blur {
                clearSelectedWindowBackground()
            }
            pipeline.backgroundMode = newValue
        }
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
        selectedWindowBackgroundOption = nil
        pipeline.clearWindowBackground()
    }
}

#Preview {
    ContentView()
}
