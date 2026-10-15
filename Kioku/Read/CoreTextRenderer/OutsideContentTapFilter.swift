import UIKit

// Gesture delegate that lets a scroll view's own tap recognizer see only touches outside its
// content view — the empty area under a short note — so a tap on the text still goes to the
// content view's recognizer alone. A separate object because UIScrollView is already the
// delegate of its built-in pan/pinch recognizers.
final class OutsideContentTapFilter: NSObject, UIGestureRecognizerDelegate {
    weak var contentView: UIView?

    // Accepts the touch only when it lands outside the content view's frame.
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        guard let contentView, let host = gestureRecognizer.view else { return false }
        return contentView.frame.contains(touch.location(in: host)) == false
    }
}
