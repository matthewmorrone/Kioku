import UIKit

enum TextViewFactory {
    // Creates a UITextView configured to use TextKit 2 for consistent typography behavior.
    static func makeTextView() -> UITextView {
        configure(UITextView(usingTextLayoutManager: true))
    }

    // Applies the shared read/edit TextKit 2 configuration to the given instance.
    private static func configure<T: UITextView>(_ textView: T) -> T {
        precondition(textView.textLayoutManager != nil, "TextKit 2 invariant violated: read editor must use UITextView with a textLayoutManager")
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
