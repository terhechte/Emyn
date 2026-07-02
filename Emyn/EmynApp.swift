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

    var body: some Scene {
        WindowGroup {
            ContentView(pipeline: pipeline)
        }

        Settings {
            BackgroundRemovalSettingsView(pipeline: pipeline)
        }
    }
}
