import WidgetKit
import SwiftUI

// Entry point for the widget extension. A bundle can vend several widgets; for now it vends only
// the Word of the Day widget.
@main
struct KiokuWidgetBundle: WidgetBundle {
    var body: some Widget {
        WordOfTheDayWidget()
    }
}
