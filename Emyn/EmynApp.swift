//
//  EmynApp.swift
//  Emyn
//
//  Created by Benedikt Terhechte on 01.07.26.
//

import SwiftUI

@main
struct EmynApp: App {
    @StateObject private var pipeline = CameraPipeline()
    @StateObject private var speechToText = SpeechToTextConfiguration()
    @StateObject private var speechModelDownloader = SpeechToTextModelDownloader()
    @StateObject private var speechMicrophoneMonitor = SpeechToTextMicrophoneMonitor()
    @StateObject private var speechTranscriber = SpeechToTextTranscriber()

    var body: some Scene {
        WindowGroup {
            ContentView(
                pipeline: pipeline,
                speechToText: speechToText,
                speechTranscriber: speechTranscriber
            )
        }

        Settings {
            EmynSettingsView(
                pipeline: pipeline,
                speechToText: speechToText,
                speechModelDownloader: speechModelDownloader,
                speechMicrophoneMonitor: speechMicrophoneMonitor,
                speechTranscriber: speechTranscriber
            )
        }
    }
}
