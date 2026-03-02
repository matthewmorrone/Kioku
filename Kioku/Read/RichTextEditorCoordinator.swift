import SwiftUI
import UIKit

final class RichTextEditorCoordinator: NSObject, UITextViewDelegate {
    @Binding var text: String
    var lastAppliedStyle: (textSize: Double, lineSpacing: Double, kerning: Double)?

    // Connects the SwiftUI text binding to the UIKit delegate coordinator.
    init(text: Binding<String>) {
        _text = text
    }

    // Propagates text view edits into SwiftUI state after each user change.
    func textViewDidChange(_ textView: UITextView) {
        text = textView.text
    }
}
