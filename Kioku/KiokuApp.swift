//
//  KiokuApp.swift
//  Kioku
//
//  Created by Matthew Morrone on 2/24/26.
//

import SwiftUI
import SwiftWhisperAlign

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
        // Install the Japanese nav/tab bar chrome before any UIKit-backed chrome is first laid out
        // — but only when the user has opted into the theme (otherwise leave the system defaults).
        Theme.refreshGlobalAppearance()
        StartupTimer.mark("KiokuApp.init")
        KaraokeDebugLog.reset()
        KaraokeDebugLog.log("=== app launch ===")
        // One-time cleanup: the .srt sidecar was demoted to an export-only projection of cues.json
        // (the single source of truth), so remove the now-inert sidecars left by older builds.
        NotesAudioStore.shared.purgeLegacySRTSidecars()
        // Reclaim any over-budget vocal-stem cache that an older, UNBOUNDED build accumulated (it
        // could reach several GB). Off the main thread so the directory scan + deletes never delay
        // launch; self-healing — brings the cache back under VocalStemCache.maxBytes on every cold
        // start, then store() keeps it there.
        Task.detached(priority: .utility) { VocalStemCache.enforceBudget() }
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
