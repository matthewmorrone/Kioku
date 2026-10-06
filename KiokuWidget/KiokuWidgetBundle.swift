import WidgetKit
import SwiftUI

// Entry point for the widget extension: the Word of the Day widget and the lyrics Live Activity.
@main
struct KiokuWidgetBundle: WidgetBundle {
    var body: some Widget {
        WordOfTheDayWidget()
        LyricsLiveActivity()
    }
}
