import UIKit

enum TextViewFactory {
    // Creates a UITextView configured to use TextKit 2 for consistent typography behavior.
    static func makeTextView() -> UITextView {
        let textView = UITextView(usingTextLayoutManager: true)
        precondition(
            textView.textLayoutManager != nil,
            "TextKit 2 invariant violated: read editor must use UITextView with a textLayoutManager"
        )
        textView.autocorrectionType = .no
        textView.spellCheckingType = .no
        textView.autocapitalizationType = .none
        textView.smartQuotesType = .no
        textView.smartDashesType = .no
        textView.smartInsertDeleteType = .no
        textView.dataDetectorTypes = []
        textView.textDragInteraction?.isEnabled = false
        textView.allowsEditingTextAttributes = false
        return textView
    }
}
