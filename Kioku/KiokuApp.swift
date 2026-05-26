//
//  KiokuApp.swift
//  Kioku
//
//  Created by Matthew Morrone on 2/24/26.
//

import SwiftUI

@main
struct KiokuApp: App {
    // Fires once when SwiftUI first evaluates the app body to signal launch timing.
    init() {
        // Install crash capture BEFORE anything else so a crash during dictionary load /
        // resource init still produces a persisted record. The handlers stay live for the
        // process lifetime; MetricKit will deliver any post-mortem payloads next launch.
        CrashLogger.shared.install()
        StartupTimer.mark("KiokuApp.init")
        KaraokeDebugLog.reset()
        KaraokeDebugLog.log("=== app launch ===")
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
