import SwiftUI
import UIKit

// UITextView wrapper that preserves selection and scroll position when the text
// binding is updated programmatically (e.g. by timestamp shift or normalization).
// Tapping on a timestamp selects the entire "HH:MM:SS,mmm --> HH:MM:SS,mmm" range.
struct StableTextEditor: UIViewRepresentable {
    @Binding var text: String
    @Binding var selectedRange: NSRange
    var font: UIFont = .monospacedSystemFont(ofSize: 13, weight: .regular)

    // Matches individual SRT timestamps: "HH:MM:SS,mmm"
    private static let timestampPattern = try! NSRegularExpression(
        pattern: #"\d{2}:\d{2}:\d{2}[,.]\d{3}"#
    )

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: StableTextEditor
        // Suppresses binding feedback when we're applying a programmatic update.
        var isUpdatingFromBinding = false

        init(_ parent: StableTextEditor) {
            self.parent = parent
        }

        // Propagates user edits back to the binding and re-applies timestamp highlighting.
        func textViewDidChange(_ textView: UITextView) {
            guard isUpdatingFromBinding == false else { return }
            parent.text = textView.text

            // Re-highlight after edits, preserving cursor.
            let sel = textView.selectedRange
            isUpdatingFromBinding = true
            StableTextEditor.applyHighlightedText(to: textView, text: textView.text)
            isUpdatingFromBinding = false
            textView.selectedRange = sel
        }

        // Publishes selection changes so the parent can scope operations to selected cues.
        func textViewDidChangeSelection(_ textView: UITextView) {
            guard isUpdatingFromBinding == false else { return }
            let sel = textView.selectedRange
            if parent.selectedRange != sel {
                parent.selectedRange = sel
            }
        }

        // Intercepts taps and selects the full timestamp range if the tap lands inside one.
        @objc func handleTap(_ gesture: UITapGestureRecognizer) {
            guard let textView = gesture.view as? UITextView else { return }
            let point = gesture.location(in: textView)
            let layoutManager = textView.layoutManager
            let textContainer = textView.textContainer

            // Convert tap point to text container coordinates.
            let textContainerOffset = textView.textContainerInset
            let locationInContainer = CGPoint(
                x: point.x - textContainerOffset.left,
                y: point.y - textContainerOffset.top
            )

            let charIndex = layoutManager.characterIndex(
                for: locationInContainer,
                in: textContainer,
                fractionOfDistanceBetweenInsertionPoints: nil
            )

            let nsText = textView.text as NSString
            guard charIndex < nsText.length else { return }

            // Check if the tapped character falls within an individual timestamp.
            let fullRange = NSRange(location: 0, length: nsText.length)
            let matches = StableTextEditor.timestampPattern.matches(in: textView.text, range: fullRange)
            for match in matches {
                if NSLocationInRange(charIndex, match.range) {
                    textView.selectedRange = match.range
                    return
                }
            }

            // No timestamp hit — place cursor normally.
            textView.selectedRange = NSRange(location: charIndex, length: 0)
            textView.becomeFirstResponder()
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeUIView(context: Context) -> UITextView {
        let tv = UITextView()
        tv.delegate = context.coordinator
        tv.autocorrectionType = .no
        tv.autocapitalizationType = .none
        tv.smartQuotesType = .no
        tv.smartDashesType = .no
        tv.allowsEditingTextAttributes = false
        StableTextEditor.applyHighlightedText(to: tv, text: text, font: font)

        // Add tap gesture for timestamp selection.
        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleTap(_:)))
        tap.delegate = context.coordinator
        tv.addGestureRecognizer(tap)

        return tv
    }

    // Applies binding changes while preserving cursor and scroll position.
    func updateUIView(_ textView: UITextView, context: Context) {
        guard textView.text != text else { return }

        let savedSelection = textView.selectedRange
        let savedOffset = textView.contentOffset

        context.coordinator.isUpdatingFromBinding = true
        StableTextEditor.applyHighlightedText(to: textView, text: text, font: font)
        context.coordinator.isUpdatingFromBinding = false

        // Clamp selection to new text length to avoid out-of-bounds crash.
        let maxLocation = (textView.text as NSString).length
        let clampedLocation = min(savedSelection.location, maxLocation)
        let clampedLength = min(savedSelection.length, maxLocation - clampedLocation)
        textView.selectedRange = NSRange(location: clampedLocation, length: clampedLength)

        // Restore scroll after layout pass so the content size is correct.
        DispatchQueue.main.async {
            let maxOffsetY = max(0, textView.contentSize.height - textView.bounds.height)
            textView.contentOffset = CGPoint(
                x: savedOffset.x,
                y: min(savedOffset.y, maxOffsetY)
            )
        }
    }

    // Builds an attributed string with timestamps highlighted and applies it to the text view.
    static func applyHighlightedText(to textView: UITextView, text: String, font: UIFont = .monospacedSystemFont(ofSize: 13, weight: .regular)) {
        let attr = NSMutableAttributedString(string: text, attributes: [
            .font: font,
            .foregroundColor: UIColor.label
        ])

        let fullRange = NSRange(location: 0, length: (text as NSString).length)
        let matches = Self.timestampPattern.matches(in: text, range: fullRange)
        for match in matches {
            attr.addAttribute(.foregroundColor, value: UIColor.systemCyan, range: match.range)
        }

        textView.attributedText = attr
    }
}

// Allows the custom tap gesture to fire alongside UITextView's built-in gestures.
extension StableTextEditor.Coordinator: UIGestureRecognizerDelegate {
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        true
    }
}
