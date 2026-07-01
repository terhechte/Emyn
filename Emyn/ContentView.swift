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
            pipeline.stop()
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
            VideoPreviewView(pipeline: pipeline)
                .background(.black)

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
}

#Preview {
    ContentView()
}
