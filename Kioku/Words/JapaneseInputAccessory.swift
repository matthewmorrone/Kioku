import SwiftUI
import UIKit

// Protocol unifying the two responder types we attach the 部/✋/⌨ accessory bar to: UITextField
// for single-line search fields and UITextView for the note body editor. Both make inputView /
// inputAccessoryView settable (UIResponder's base declarations are get-only), conform to
// UITextInput (used for replace-all in clearAll), and to UIKeyInput (insertText / deleteBackward).
// Empty conformances below let the accessory controller treat them interchangeably.
protocol JapaneseAccessoryResponder: UIView, UITextInput {
    var inputView: UIView? { get set }
    var inputAccessoryView: UIView? { get set }
}

extension UITextField: JapaneseAccessoryResponder {}
extension UITextView: JapaneseAccessoryResponder {}

// Shared accessory / inputView controller. Owns the persistent 部/✋/⌨ toggle bar, the
// radical-picker and handwriting-canvas SwiftUI hosts, and the wrapper UIViews that iOS uses to
// size each inline input. Lives in any wrapper (UIViewRepresentable for UITextField or
// UITextView) that needs the inline-input UX. Mutates the responder via UITextInput / UIKeyInput
// so the responder's own delegate callbacks (editingChanged, textViewDidChange) keep the SwiftUI
// binding in sync — the controller never touches the binding directly.
final class JapaneseInputAccessory: NSObject {
    weak var responder: JapaneseAccessoryResponder?
    let dictionaryStore: DictionaryStore?

    private var currentMode: JapaneseInputMode = .keyboard
    private var accessoryHost: UIHostingController<KeyboardModeBar>?
    private var radicalHost: UIHostingController<RadicalInputView>?
    private var handwritingHost: UIHostingController<HandwritingInputView>?
    private var inputViewContainers: [ObjectIdentifier: UIView] = [:]
    // Latest measured system-keyboard height. Captured the first time the keyboard appears
    // (which it always does before the user can tap 部/✋, since they have to focus the field
    // first). Used to size inline radical/handwriting wrappers so the swap is height-matched.
    private var measuredKeyboardHeight: CGFloat?

    init(responder: JapaneseAccessoryResponder, dictionaryStore: DictionaryStore?) {
        self.responder = responder
        self.dictionaryStore = dictionaryStore
        super.init()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(keyboardDidShow(_:)),
            name: UIResponder.keyboardDidShowNotification,
            object: nil
        )
    }

    // Removes the keyboard notification observer when the controller is torn down.
    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    // Builds and attaches the accessory bar to the responder. Call this once, after the responder
    // is created in makeUIView.
    func install() {
        installAccessoryBar()
    }

    // Captures the system keyboard's measured height so subsequent inline inputView swaps can
    // match it exactly. The reported frame includes the inputAccessoryView (the 部/✋/⌨ row),
    // which is drawn ABOVE the inputView, so subtract its height to avoid double-counting.
    @objc private func keyboardDidShow(_ note: Notification) {
        guard
            let frameValue = note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue
        else { return }
        let totalHeight = frameValue.cgRectValue.height
        let accessoryHeight = accessoryHost?.view.frame.height ?? 0
        let height = max(0, totalHeight - accessoryHeight)
        guard height > 0 else { return }
        measuredKeyboardHeight = height
        for wrapper in inputViewContainers.values {
            wrapper.frame.size.height = height
        }
    }

    // Constructs the persistent toggle bar host once and assigns it as the responder's
    // inputAccessoryView. The bar's onSelect routes to applyMode; refreshAccessoryBar then
    // updates the active-highlight by reassigning rootView.
    private func installAccessoryBar() {
        guard let responder else { return }
        let host = UIHostingController(rootView: makeBar())
        host.view.backgroundColor = .clear
        host.view.translatesAutoresizingMaskIntoConstraints = false
        host.view.frame = CGRect(x: 0, y: 0, width: UIScreen.main.bounds.width, height: 44)
        host.sizingOptions = [.intrinsicContentSize]
        accessoryHost = host
        responder.inputAccessoryView = host.view
    }

    // Constructs a fresh KeyboardModeBar rooted at the current mode. Used at install time and
    // whenever the mode changes. Right-side action callbacks route to deleteBackward (one char),
    // reset (mode-specific draft wipe), and clearAll (full text wipe).
    private func makeBar() -> KeyboardModeBar {
        KeyboardModeBar(
            mode: currentMode,
            onSelect: { [weak self] newMode in self?.applyMode(newMode) },
            onBackspace: { [weak self] in self?.deleteBackward() },
            onReset: { [weak self] in self?.reset() },
            onClear: { [weak self] in self?.clearAll() }
        )
    }

    // Swaps the responder's inputView in response to a mode toggle. Calling reloadInputViews
    // animates the transition with the standard keyboard timing.
    private func applyMode(_ newMode: JapaneseInputMode) {
        guard let responder, newMode != currentMode else { return }
        currentMode = newMode
        accessoryHost?.rootView = makeBar()
        switch newMode {
        case .keyboard:
            responder.inputView = nil
        case .radical:
            let host = radicalInputHost()
            responder.inputView = inputContainer(for: host.view)
        case .handwriting:
            let host = handwritingInputHost()
            responder.inputView = inputContainer(for: host.view)
        }
        responder.reloadInputViews()
    }

    // Lazily constructs the radical picker host wrapped in a sized container. The host outlives
    // any single swap so we don't lose grid scroll position between toggles.
    private func radicalInputHost() -> UIHostingController<RadicalInputView> {
        if let radicalHost { return radicalHost }
        let view = RadicalInputView(
            dictionaryStore: dictionaryStore,
            onEmit: { [weak self] kanji in self?.append(kanji) },
            chrome: .none
        )
        let host = UIHostingController(rootView: view)
        host.view.backgroundColor = UIColor.systemBackground
        disableInheritedSafeArea(on: host)
        wrapAsInputView(host.view)
        radicalHost = host
        return host
    }

    // Lazily constructs the handwriting host. Same persistence reasoning as the radical host —
    // keep the in-progress drawing across toggles.
    private func handwritingInputHost() -> UIHostingController<HandwritingInputView> {
        if let handwritingHost { return handwritingHost }
        let view = HandwritingInputView(
            onEmit: { [weak self] character in self?.append(character) },
            onDeleteBackward: { [weak self] in self?.deleteBackward() },
            chrome: .none
        )
        let host = UIHostingController(rootView: view)
        host.view.backgroundColor = UIColor.systemBackground
        disableInheritedSafeArea(on: host)
        wrapAsInputView(host.view)
        handwritingHost = host
        return host
    }

    // Strips inherited safe-area regions from the hosting controller so the SwiftUI body
    // doesn't leave phantom top padding inside the inputView.
    private func disableInheritedSafeArea<Root: View>(on host: UIHostingController<Root>) {
        host.additionalSafeAreaInsets = .zero
        host.view.insetsLayoutMarginsFromSafeArea = false
        host.view.layoutMargins = .zero
        host.view.directionalLayoutMargins = .zero
        if #available(iOS 16.4, *) {
            host.safeAreaRegions = []
        }
    }

    // Wraps a SwiftUI-host view in a parent UIView that iOS can size via its frame.
    private func wrapAsInputView(_ inner: UIView) {
        let height = defaultInputHeight()
        let wrapper = NoSafeAreaContainer(frame: CGRect(x: 0, y: 0, width: UIScreen.main.bounds.width, height: height))
        wrapper.autoresizingMask = .flexibleWidth
        wrapper.backgroundColor = UIColor.systemBackground
        wrapper.insetsLayoutMarginsFromSafeArea = false
        wrapper.layoutMargins = .zero
        wrapper.directionalLayoutMargins = .zero
        if let style = responder?.traitCollection.userInterfaceStyle, style != .unspecified {
            wrapper.overrideUserInterfaceStyle = style
        }

        inner.translatesAutoresizingMaskIntoConstraints = false
        wrapper.addSubview(inner)
        NSLayoutConstraint.activate([
            inner.leadingAnchor.constraint(equalTo: wrapper.leadingAnchor),
            inner.trailingAnchor.constraint(equalTo: wrapper.trailingAnchor),
            inner.topAnchor.constraint(equalTo: wrapper.topAnchor),
            inner.bottomAnchor.constraint(equalTo: wrapper.bottomAnchor),
        ])
        inputViewContainers[ObjectIdentifier(inner)] = wrapper
    }

    // Looks up the sized wrapper for a host view; falls back to the host view itself so callers
    // don't crash if wrapAsInputView was somehow skipped.
    private func inputContainer(for hostView: UIView) -> UIView {
        inputViewContainers[ObjectIdentifier(hostView)] ?? hostView
    }

    // Returns the height to use for inline radical/handwriting inputViews. Prefers the live
    // measurement captured from keyboardDidShow; falls back to a heuristic until the system
    // keyboard has been observed at least once.
    private func defaultInputHeight() -> CGFloat {
        if let measured = measuredKeyboardHeight, measured > 0 {
            return measured
        }
        let screen = UIScreen.main.bounds.height
        return max(336, screen * 0.40)
    }

    // Routes an emitted character through the responder so its native delegate (editingChanged
    // / textViewDidChange) fires and the host's SwiftUI binding stays in sync.
    private func append(_ emitted: String) {
        guard let keyInput = responder as? UIKeyInput else { return }
        keyInput.insertText(emitted)
    }

    // Backspace one character at the cursor. UIKeyInput's deleteBackward respects the current
    // selection, so deleting in the middle of a string works as expected.
    private func deleteBackward() {
        guard let keyInput = responder as? UIKeyInput else { return }
        keyInput.deleteBackward()
    }

    // Wipes the entire text by replacing the full range with empty string. Trip through
    // UITextInput so the delegate fires and the binding refreshes.
    private func clearAll() {
        guard
            let responder,
            let range = responder.textRange(
                from: responder.beginningOfDocument,
                to: responder.endOfDocument
            )
        else { return }
        responder.replace(range, withText: "")
    }

    // Mode-scoped reset: wipes the active input's in-progress draft — handwriting canvas, radical
    // selection — but leaves the destination text alone. No-op in keyboard mode.
    private func reset() {
        switch currentMode {
        case .handwriting:
            NotificationCenter.default.post(name: .kiokuHandwritingClearRequested, object: nil)
        case .radical:
            NotificationCenter.default.post(name: .kiokuRadicalClearRequested, object: nil)
        case .keyboard:
            break
        }
    }
}

// UIView subclass whose only job is to refuse safe-area inheritance from its parent (the
// keyboard window). UIKit propagates safeAreaInsets unconditionally from parent to child unless
// the property is overridden; this subclass returns .zero so the hosted SwiftUI body lays out
// flush against the top edge — no phantom band above the candidate strip.
final class NoSafeAreaContainer: UIView {
    // Returns zero insets regardless of the actual window-level safe area, breaking the
    // top-inset propagation chain into the hosting controller's view.
    override var safeAreaInsets: UIEdgeInsets { .zero }
}
