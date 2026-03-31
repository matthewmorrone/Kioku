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
        StartupTimer.mark("KiokuApp.init")
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
