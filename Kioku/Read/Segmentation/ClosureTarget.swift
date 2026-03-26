import Foundation

// Wraps a closure so it can be used as a UIGestureRecognizer or UIControl target.
final class ClosureTarget: NSObject {
    private let action: () -> Void
    init(_ action: @escaping () -> Void) { self.action = action }
    @objc func invoke() { action() }
}
