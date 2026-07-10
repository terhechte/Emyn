//
//  EmynApp.swift
//  Emyn
//
//  Created by Benedikt Terhechte on 01.07.26.
//

import SwiftUI
import TranscriptionKit
import VideoCompositionKit

@main
struct EmynApp: App {
    @StateObject private var pipeline = CameraPipeline()
    @StateObject private var speechToText = SpeechToTextConfiguration()
    @StateObject private var speechModelCatalog = SpeechToTextModelCatalog()
    @StateObject private var speechModelDownloader = SpeechToTextModelDownloader()
    @StateObject private var speechMicrophoneMonitor = SpeechToTextMicrophoneMonitor()
    @StateObject private var speechTranscriber = SpeechToTextTranscriber()
    @StateObject private var extensionInstaller = SystemExtensionInstaller()

    var body: some Scene {
        WindowGroup {
            ContentView(
                pipeline: pipeline,
                extensionInstaller: extensionInstaller,
                speechToText: speechToText,
                speechTranscriber: speechTranscriber
            )
        }

        Settings {
            EmynSettingsView(
                pipeline: pipeline,
                extensionInstaller: extensionInstaller,
                speechToText: speechToText,
                speechModelCatalog: speechModelCatalog,
                speechModelDownloader: speechModelDownloader,
                speechMicrophoneMonitor: speechMicrophoneMonitor,
                speechTranscriber: speechTranscriber
            )
        }
    }
}
