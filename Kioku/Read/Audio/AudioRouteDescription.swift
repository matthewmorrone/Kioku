import AVFoundation

// Describes the audio output for the app's debug log (AppLog, audio playback), so a playback
// complaint (the first second or two silent) can be matched to the device it played on and to the
// route changes around it.
nonisolated enum AudioRouteDescription {
    nonisolated(unsafe) private static var isLoggingRouteChanges = false

    // The session's current outputs as "portType: name", comma-separated; "none" without one.
    static func current() -> String {
        let outputs = AVAudioSession.sharedInstance().currentRoute.outputs
        guard outputs.isEmpty == false else { return "none" }
        return outputs.map { "\($0.portType.rawValue): \($0.portName)" }.joined(separator: ", ")
    }

    // Logs every route change (headphones in or out, Bluetooth connecting, category changes) with
    // its reason and the route after it. Registers once, however many players call it; called on
    // the main thread.
    static func startLoggingRouteChanges() {
        guard isLoggingRouteChanges == false else { return }
        isLoggingRouteChanges = true
        NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: nil,
            queue: .main
        ) { notification in
            let reason = (notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt)
                .flatMap(AVAudioSession.RouteChangeReason.init(rawValue:))
            AppLog.info(.audioPlayback, "audio.route: changed (\(reason.map(describe) ?? "unknown reason")) → \(current())")
        }
    }

    // A readable name for a route-change reason.
    private static func describe(_ reason: AVAudioSession.RouteChangeReason) -> String {
        switch reason {
        case .newDeviceAvailable: "new device"
        case .oldDeviceUnavailable: "device gone"
        case .categoryChange: "category change"
        case .override: "override"
        case .wakeFromSleep: "wake from sleep"
        case .noSuitableRouteForCategory: "no route for category"
        case .routeConfigurationChange: "configuration change"
        case .unknown: "unknown"
        @unknown default: "reason \(reason.rawValue)"
        }
    }
}
