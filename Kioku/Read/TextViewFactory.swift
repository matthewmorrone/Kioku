import UIKit

enum TextViewFactory {
    // Creates a UITextView configured to use TextKit 2 for consistent typography behavior.
    static func makeTextView() -> UITextView {
        let textView = UITextView(usingTextLayoutManager: true)
        precondition(
            textView.textLayoutManager != nil,
            "TextKit 2 invariant violated: read editor must use UITextView with a textLayoutManager"
        )
        return textView
    }
}
