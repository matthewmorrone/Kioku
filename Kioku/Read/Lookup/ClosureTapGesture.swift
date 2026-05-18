import UIKit

// UITapGestureRecognizer wrapper that runs a closure instead of the target/action pattern.
// UIGestureRecognizer (unlike UIControl) has no built-in UIAction support, so we route the
// selector through a stored closure so call sites can stay closure-based.
final class ClosureTapGesture: UITapGestureRecognizer {
    private let handler: () -> Void
    init(handler: @escaping () -> Void) {
        self.handler = handler
        super.init(target: nil, action: nil)
        addTarget(self, action: #selector(handleTap))
    }
    // Bridges UIGestureRecognizer's selector-based callback to the stored closure.
    @objc private func handleTap() { handler() }
}
