//
//  KiokuApp.swift
//  Kioku
//
//  Created by Matthew Morrone on 2/24/26.
//

import SwiftUI

@main
struct KiokuApp: App {
    // Registers the notification deep-link handler in didFinishLaunchingWithOptions — early enough
    // to catch notification taps that cold-launch the app, which ContentView.onAppear missed.
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    // Fires once when SwiftUI first evaluates the app body to signal launch timing.
    init() {
        // Install crash capture BEFORE anything else so a crash during dictionary load /
        // resource init still produces a persisted record. The handlers stay live for the
        // process lifetime; MetricKit will deliver any post-mortem payloads next launch.
        CrashLogger.shared.install()
        StartupTimer.mark("KiokuApp.init")
        KaraokeDebugLog.reset()
        KaraokeDebugLog.log("=== app launch ===")
        // One-time cleanup: the .srt sidecar was demoted to an export-only projection of cues.json
        // (the single source of truth), so remove the now-inert sidecars left by older builds.
        NotesAudioStore.shared.purgeLegacySRTSidecars()
        // (Startup dedup sweep temporarily disabled while diagnosing a launch crash — clone-on-import
        // in saveAudio still prevents NEW duplicates; the one-time reclaim sweep is re-enabled once
        // the launch path is confirmed clean.)
        // Headless alignment-tuning harness — runs only when launched with KIOKU_ALIGN_HARNESS set.
        AlignmentHarness.runIfRequested()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
