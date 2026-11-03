import SwiftUI

// How big the transport buttons are in the karaoke and breakdown players. Large is for using the
// phone one-handed in motion (biking), where small targets are hard to hit. One source of sizes
// for every player bar so they always agree.
enum PlaybackControlSize: String, CaseIterable, Identifiable {
    case small
    case large

    var id: String { rawValue }

    // UserDefaults key shared by the Settings picker and PlaybackControlSizeReader.
    static let storageKey = "playback.controlSize"

    var title: String {
        switch self {
        case .small: "Small"
        case .large: "Large"
        }
    }

    // Diameter of the main play/pause button.
    var playDiameter: CGFloat { self == .large ? 68 : 38 }
    // Diameter of the secondary buttons (previous, next, return to line).
    var sideDiameter: CGFloat { self == .large ? 56 : 36 }
    // Glyph size inside the play button and the secondary buttons.
    var playIconSize: CGFloat { self == .large ? 30 : 15 }
    var sideIconSize: CGFloat { self == .large ? 24 : 14 }
    // Height of the bar that holds them.
    var barHeight: CGFloat { self == .large ? 92 : 56 }
    // Space between the buttons in the bar.
    var spacing: CGFloat { self == .large ? 18 : 10 }
}

// Hands its content the saved control size and redraws it when the setting changes. Exists because
// the player bars are computed properties in extensions, which can't hold an @AppStorage themselves.
struct PlaybackControlSizeReader<Content: View>: View {
    @AppStorage(PlaybackControlSize.storageKey) private var raw = PlaybackControlSize.small.rawValue
    let content: (PlaybackControlSize) -> Content

    var body: some View {
        content(PlaybackControlSize(rawValue: raw) ?? .small)
    }
}
