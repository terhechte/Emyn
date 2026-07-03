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

    var body: some Scene {
        WindowGroup {
            ContentView(
                pipeline: pipeline,
                speechToText: speechToText
            )
        }

        Settings {
            EmynSettingsView(
                pipeline: pipeline,
                speechToText: speechToText,
                speechModelDownloader: speechModelDownloader,
                speechMicrophoneMonitor: speechMicrophoneMonitor
            )
        }
    }
}
