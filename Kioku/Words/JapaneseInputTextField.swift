import SwiftUI
import UIKit

// SwiftUI text input that can swap its keyboard for the radical picker or handwriting canvas
// inline (like Apple's emoji keyboard) without dismissing focus. The actual accessory bar +
// inputView swap logic lives in JapaneseInputAccessory, which is shared with the UITextView
// path (RichTextEditor) so both Words search and the note body editor get identical UX.
struct JapaneseInputTextField: UIViewRepresentable {
    // Visual chrome variants. .none leaves the field bare so callers (like WordsView's custom
    // capsule search bar) own the framing; .roundedRect applies the iOS-stock rounded border that
    // matches SwiftUI's .textFieldStyle(.roundedBorder).
    enum Border { case none, roundedRect }

    @Binding var text: String
    @Binding var isFocused: Bool
    let placeholder: String
    let dictionaryStore: DictionaryStore?
    let onSubmit: () -> Void
    var border: Border = .none

    // Builds the UITextField, wires its delegate to the Coordinator, and attaches the shared
    // accessory controller so the 部/✋/⌨ row appears whenever the field is focused.
    func makeUIView(context: Context) -> UITextField {
        let field = UITextField()
        field.placeholder = placeholder
        field.borderStyle = (border == .roundedRect) ? .roundedRect : .none
        field.autocorrectionType = .no
        field.autocapitalizationType = .none
        field.returnKeyType = .search
        field.clearButtonMode = .never
        field.delegate = context.coordinator
        field.addTarget(context.coordinator, action: #selector(Coordinator.editingChanged(_:)), for: .editingChanged)
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        // Anchor the field to its natural line height; SwiftUI's auto-sizing otherwise stretches
        // the UIKit view to fill all available vertical space, ballooning the capsule background
        // around it.
        field.setContentHuggingPriority(.required, for: .vertical)
        field.setContentCompressionResistancePriority(.required, for: .vertical)

        context.coordinator.textField = field
        context.coordinator.accessory = JapaneseInputAccessory(responder: field, dictionaryStore: dictionaryStore)
        context.coordinator.accessory?.install()
        return field
    }

    // Reports a single-line text-field height to SwiftUI's layout proposal. Without this the
    // Representable returns nil and SwiftUI defaults to filling all proposed height, which
    // visibly bloats the surrounding Capsule chrome (observed on first device run).
    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UITextField, context: Context) -> CGSize? {
        let intrinsic = uiView.intrinsicContentSize
        let width = proposal.width ?? intrinsic.width
        return CGSize(width: width, height: intrinsic.height)
    }

    // Reflects external state into the field: text-binding edits made outside (e.g. tapping a
    // Recent Searches row that sets searchText) need to propagate in; focus binding toggled to
    // false elsewhere needs to resign first-responder.
    func updateUIView(_ uiView: UITextField, context: Context) {
        if uiView.text != text {
            uiView.text = text
        }
        if isFocused && uiView.isFirstResponder == false {
            // Defer to next runloop: SwiftUI may still be in a layout pass when the binding
            // flips true, and becoming first responder mid-layout glitches the keyboard
            // animation on iOS 17+.
            DispatchQueue.main.async {
                _ = uiView.becomeFirstResponder()
            }
        } else if isFocused == false && uiView.isFirstResponder {
            uiView.resignFirstResponder()
        }
    }

    // Standard SwiftUI coordinator hook — bridges UIKit delegate callbacks back to our bindings.
    // The accessory bar / inputView swap logic is owned by JapaneseInputAccessory; the Coordinator
    // only owns the focus + text-binding pipeline.
    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    // MARK: - Coordinator

    // Bridges UITextField delegate events to the SwiftUI bindings. Holds the accessory controller
    // so it stays alive for the field's lifetime.
    final class Coordinator: NSObject, UITextFieldDelegate {
        let parent: JapaneseInputTextField
        weak var textField: UITextField?
        var accessory: JapaneseInputAccessory?

        init(parent: JapaneseInputTextField) {
            self.parent = parent
            super.init()
        }

        // UIKit editing-change callback — funnels typed input back into the SwiftUI binding.
        @objc func editingChanged(_ sender: UITextField) {
            parent.text = sender.text ?? ""
        }

        // Reports focus state back to the SwiftUI binding so external dismissals (taps on the
        // results list, etc.) stay in sync.
        func textFieldDidBeginEditing(_ textField: UITextField) {
            if parent.isFocused == false {
                parent.isFocused = true
            }
        }

        // Mirror of didBegin: keeps the focus binding accurate when the user dismisses the field.
        func textFieldDidEndEditing(_ textField: UITextField) {
            if parent.isFocused {
                parent.isFocused = false
            }
        }

        // Routes the keyboard's Search key back into the SwiftUI onSubmit closure so the host's
        // history-record call still fires.
        func textFieldShouldReturn(_ textField: UITextField) -> Bool {
            parent.onSubmit()
            return true
        }
    }
}
