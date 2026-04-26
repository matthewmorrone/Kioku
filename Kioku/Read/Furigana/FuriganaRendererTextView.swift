import UIKit

// UITextView subclass used by FuriganaTextRenderer so the renderer can notice when SwiftUI's
// initial layout pass resolves a real width. Without this hook, the first updateUIView call
// runs with bounds.width = 0, firstRect returns empty rects for every segment, and no furigana
// frames are produced. SwiftUI does not re-invoke updateUIView on its own when the view is
// subsequently sized, so the overlay stays empty until an unrelated state change (e.g. a slider
// adjustment in Settings) happens to trigger another pass.
final class FuriganaRendererTextView: UITextView {
    // Invoked on the main runloop whenever bounds.width transitions from zero to non-zero. Callers
    // use it to re-run the render pipeline with real geometry after SwiftUI finishes laying out.
    // Fires on every 0→non-zero transition (not just the first) so that views which transiently
    // collapse to width=0 — for example when SwiftUI Form rows go offscreen and back — recover
    // their overlay on the next layout pass instead of staying empty until an unrelated state
    // change forces another updateUIView call.
    var onFirstLayoutResolved: (() -> Void)?
    private var lastLayoutWidth: CGFloat = 0

    // Detects every zero-to-non-zero width transition so the owner can re-run geometry-dependent work.
    override func layoutSubviews() {
        super.layoutSubviews()
        let currentWidth = bounds.width
        if lastLayoutWidth == 0, currentWidth > 0 {
            // Dispatch async so the callback runs after the current layout pass completes;
            // re-rendering synchronously from inside layoutSubviews can trigger re-entrancy
            // in TextKit 2's layout manager.
            DispatchQueue.main.async { [weak self] in
                self?.onFirstLayoutResolved?()
            }
        }
        lastLayoutWidth = currentWidth
    }
}
