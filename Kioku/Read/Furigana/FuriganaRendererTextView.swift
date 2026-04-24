import UIKit

// UITextView subclass used by FuriganaTextRenderer so the renderer can notice when SwiftUI's
// initial layout pass resolves a real width. Without this hook, the first updateUIView call
// runs with bounds.width = 0, firstRect returns empty rects for every segment, and no furigana
// frames are produced. SwiftUI does not re-invoke updateUIView on its own when the view is
// subsequently sized, so the overlay stays empty until an unrelated state change (e.g. a slider
// adjustment in Settings) happens to trigger another pass.
final class FuriganaRendererTextView: UITextView {
    // Invoked once, on the main runloop, the first time bounds.width becomes non-zero. Callers
    // use it to re-run the render pipeline with real geometry after SwiftUI finishes laying out.
    var onFirstLayoutResolved: (() -> Void)?
    private var hasResolvedLayout = false

    // Detects the zero-to-non-zero width transition so the owner can re-run geometry-dependent work.
    override func layoutSubviews() {
        super.layoutSubviews()
        if !hasResolvedLayout, bounds.width > 0 {
            hasResolvedLayout = true
            // Dispatch async so the callback runs after the current layout pass completes;
            // re-rendering synchronously from inside layoutSubviews can trigger re-entrancy
            // in TextKit 2's layout manager.
            DispatchQueue.main.async { [weak self] in
                self?.onFirstLayoutResolved?()
            }
        }
    }
}
