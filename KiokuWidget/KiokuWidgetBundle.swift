import WidgetKit
import SwiftUI

// Entry point for the widget extension: the Word of the Day widget.
@main
struct KiokuWidgetBundle: WidgetBundle {
    var body: some Widget {
        WordOfTheDayWidget()
    }
}
