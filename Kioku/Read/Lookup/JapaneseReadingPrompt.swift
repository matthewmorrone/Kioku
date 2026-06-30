import UIKit

// UITextField subclass that prefers the Japanese IME while editing, so the kana keyboard opens
// by default for reading entry. UIAlertController.addTextField(configurationHandler:) hands back
// a UIKit-managed UITextField whose class can't be swapped and whose textInputMode is read-only,
// so custom-reading entry is hosted in JapaneseReadingPromptController (below) instead of an alert.
final class JapaneseTextField: UITextField {
    // Return the first active Japanese input mode so the kana keyboard is presented; fall back to
    // the system default when no Japanese keyboard is installed on the device.
    override var textInputMode: UITextInputMode? {
        UITextInputMode.activeInputModes.first { $0.primaryLanguage?.hasPrefix("ja") == true }
            ?? super.textInputMode
    }
}

// Alert-style modal for entering a custom reading. Mirrors the prior UIAlertController flow
// (title, prefilled field, Set / Cancel / optional Reset) but hosts a JapaneseTextField so the
// Japanese keyboard is the default input mode. Presented over the current context with a dimmed
// backdrop and a centered card matching system alert metrics.
final class JapaneseReadingPromptController: UIViewController {

    private let promptTitle: String
    private let initialText: String
    private let placeholder: String
    private let showsReset: Bool
    private let onSet: (String) -> Void
    private let onReset: (() -> Void)?

    private let textField = JapaneseTextField()

    // showsReset/onReset drive the optional destructive Reset action, shown only when an override
    // is currently active (matching the alert's `activeReadingOverrideProvider` guard).
    init(title: String,
         initialText: String,
         placeholder: String,
         showsReset: Bool,
         onSet: @escaping (String) -> Void,
         onReset: (() -> Void)?) {
        self.promptTitle = title
        self.initialText = initialText
        self.placeholder = placeholder
        self.showsReset = showsReset
        self.onSet = onSet
        self.onReset = onReset
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .overFullScreen
        modalTransitionStyle = .crossDissolve
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // Builds the dimmed backdrop and the centered alert card, then focuses the field so the
    // Japanese keyboard appears immediately.
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor.black.withAlphaComponent(0.4)

        let card = buildCard()
        view.addSubview(card)
        NSLayoutConstraint.activate([
            card.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            card.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            card.widthAnchor.constraint(equalToConstant: 270)
        ])
    }

    // Auto-focus the field on appearance so the keyboard (Japanese by default) opens without a tap.
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        textField.becomeFirstResponder()
    }

    // Assembles the rounded card: title, the JapaneseTextField (prefilled), and the action row.
    private func buildCard() -> UIView {
        let card = UIView()
        card.translatesAutoresizingMaskIntoConstraints = false
        card.backgroundColor = .secondarySystemBackground
        card.layer.cornerRadius = 14
        card.layer.cornerCurve = .continuous

        let titleLabel = UILabel()
        titleLabel.text = promptTitle
        titleLabel.font = .systemFont(ofSize: 17, weight: .semibold)
        titleLabel.textAlignment = .center
        titleLabel.numberOfLines = 0

        textField.text = initialText
        textField.placeholder = placeholder
        textField.borderStyle = .roundedRect
        textField.clearButtonMode = .whileEditing
        textField.keyboardType = .default
        textField.autocorrectionType = .no
        textField.spellCheckingType = .no
        textField.returnKeyType = .done
        textField.addTarget(self, action: #selector(setTapped), for: .editingDidEndOnExit)

        let contentStack = UIStackView(arrangedSubviews: [titleLabel, textField, buildButtonStack()])
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        contentStack.axis = .vertical
        contentStack.spacing = 14
        contentStack.setCustomSpacing(18, after: textField)
        card.addSubview(contentStack)
        NSLayoutConstraint.activate([
            contentStack.topAnchor.constraint(equalTo: card.topAnchor, constant: 18),
            contentStack.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 18),
            contentStack.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -18),
            contentStack.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -16)
        ])
        return card
    }

    // Lays out Cancel / Set side by side, with an optional full-width destructive Reset below.
    private func buildButtonStack() -> UIView {
        let cancel = makeButton(title: "Cancel", style: .plain, action: #selector(cancelTapped))
        let set = makeButton(title: "Set", style: .prominent, action: #selector(setTapped))
        let primaryRow = UIStackView(arrangedSubviews: [cancel, set])
        primaryRow.axis = .horizontal
        primaryRow.distribution = .fillEqually
        primaryRow.spacing = 10

        let stack = UIStackView(arrangedSubviews: [primaryRow])
        stack.axis = .vertical
        stack.spacing = 10
        if showsReset {
            stack.addArrangedSubview(makeButton(title: "Reset", style: .destructive, action: #selector(resetTapped)))
        }
        return stack
    }

    private enum ButtonStyle { case plain, prominent, destructive }

    // Builds a rounded action button styled per role (plain/prominent/destructive) at alert scale.
    private func makeButton(title: String, style: ButtonStyle, action: Selector) -> UIButton {
        var config = UIButton.Configuration.gray()
        config.title = title
        config.cornerStyle = .large
        config.buttonSize = .medium
        switch style {
        case .plain:
            config.baseForegroundColor = .label
        case .prominent:
            config = .filled()
            config.title = title
            config.cornerStyle = .large
            config.buttonSize = .medium
        case .destructive:
            config.baseForegroundColor = .systemRed
        }
        let button = UIButton(configuration: config)
        button.addTarget(self, action: action, for: .touchUpInside)
        return button
    }

    // Commits the trimmed entry (no-op on empty, matching the alert) and dismisses.
    @objc private func setTapped() {
        let entered = textField.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard entered.isEmpty == false else { return }
        dismiss(animated: true) { [onSet] in onSet(entered) }
    }

    // Dismisses without committing any change.
    @objc private func cancelTapped() { dismiss(animated: true) }

    // Clears the override (runs the destructive Reset action) and dismisses.
    @objc private func resetTapped() {
        dismiss(animated: true) { [onReset] in onReset?() }
    }
}
