//
//  KiokuApp.swift
//  Kioku
//
//  Created by Matthew Morrone on 2/24/26.
//

import SwiftUI
import LyricAlignment

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
        // Before anything checks for the dictionary: a UI-test launch brings its own.
        UITestDictionaryInstaller.installIfRequested()
        // Install the Japanese nav/tab bar chrome before any UIKit-backed chrome is first laid out
        // — but only when the user has opted into the theme (otherwise leave the system defaults).
        Theme.refreshGlobalAppearance()
        StartupTimer.mark("KiokuApp.init")
        KaraokeDebugLog.reset()
        KaraokeDebugLog.log("=== app launch ===")
        // Bring the vocal-stem cache back under VocalStemCache.maxBytes; store() keeps it there
        // after this. Off the main thread so the directory scan and deletes never delay launch.
        // The launch time is captured here, before anything this process downloads can start,
        // so the sweep leaves this launch's own in-flight downloads (the dictionary) alone.
        let launchedAt = Date()
        Task.detached(priority: .utility) {
            AppLog.info(.storage, "[KiokuApp] launch-time VocalStemCache.enforceBudget starting")
            VocalStemCache.enforceBudget()
            let freed = CachesCleaner.sweepStaleDownloads(launchedAt: launchedAt)
            AppLog.info(.storage, "[KiokuApp] launch-time stale-download sweep freed \(freed / 1_000_000) MB")
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                // Widget taps open a kioku://word?id=… URL. Route it through the same navigation
                // state that notification taps use so the app lands on the word detail.
                .onOpenURL { url in
                    guard let parsed = WordOfTheDayMirror.parseDeepLink(url) else { return }
                    WordOfTheDayNavigation.shared.pendingTarget = WordOfTheDayTarget(
                        entryID: parsed.entryID,
                        surface: parsed.surface
                    )
                }
        }
    }
}
