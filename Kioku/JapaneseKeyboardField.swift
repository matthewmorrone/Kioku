import SwiftUI
import UIKit

// SwiftUI wrapper around JapaneseTextField (the UITextField subclass that prefers the Japanese
// IME) for single-line fields whose content is Japanese kana/text — e.g. the particle-tag entry
// in Settings. Bridges the text, an `isEditing` flag (so callers can drive focus + focus styling),
// and a submit action. Fields that are commonly typed in English (list names, personal notes)
// deliberately keep the plain SwiftUI TextField, so they don't force a Japanese keyboard.
struct JapaneseKeyboardField: UIViewRepresentable {
    @Binding var text: String
    @Binding var isEditing: Bool
    var placeholder: String = ""
    var font: UIFont = .preferredFont(forTextStyle: .subheadline)
    var onSubmit: () -> Void = {}

    // Builds the JapaneseTextField and wires editing/submit callbacks to the coordinator.
    func makeUIView(context: Context) -> JapaneseTextField {
        let field = JapaneseTextField()
        field.delegate = context.coordinator
        field.placeholder = placeholder
        field.font = font
        field.autocorrectionType = .no
        field.autocapitalizationType = .none
        field.returnKeyType = .done
        field.addTarget(context.coordinator,
                        action: #selector(Coordinator.editingChanged(_:)),
                        for: .editingChanged)
        return field
    }

    // Syncs the text and reflects SwiftUI's `isEditing` into first-responder state (tap-to-focus).
    func updateUIView(_ field: JapaneseTextField, context: Context) {
        context.coordinator.parent = self
        if field.text != text { field.text = text }
        if isEditing && field.isFirstResponder == false {
            field.becomeFirstResponder()
        } else if isEditing == false && field.isFirstResponder {
            field.resignFirstResponder()
        }
    }

    // Creates the delegate/target coordinator that bridges UIKit callbacks to the SwiftUI bindings.
    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UITextFieldDelegate {
        // Refreshed each updateUIView so the delegate callbacks write through live bindings.
        var parent: JapaneseKeyboardField
        // Seeds the coordinator with the initial representable value.
        init(_ parent: JapaneseKeyboardField) { self.parent = parent }

        // Mirrors typed text back into the SwiftUI binding.
        @objc func editingChanged(_ field: UITextField) { parent.text = field.text ?? "" }

        // Reflects focus gain into the binding so callers can style/track it.
        func textFieldDidBeginEditing(_ textField: UITextField) { parent.isEditing = true }
        // Reflects focus loss into the binding.
        func textFieldDidEndEditing(_ textField: UITextField) { parent.isEditing = false }

        // Return key commits (runs onSubmit) and dismisses the keyboard.
        func textFieldShouldReturn(_ textField: UITextField) -> Bool {
            parent.onSubmit()
            textField.resignFirstResponder()
            return true
        }
    }
}
