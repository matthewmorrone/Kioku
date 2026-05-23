import SwiftUI
import UIKit

// UIViewRepresentable lifecycle hooks for the furigana renderer:
// coordinator creation and initial UITextView construction with gesture recognizers and overlay.
extension FuriganaTextRenderer {
    // Creates coordinator state used to skip redundant expensive furigana layout passes.
    func makeCoordinator() -> FuriganaTextRendererCoordinator {
        FuriganaTextRendererCoordinator(
            textSize: $textSize,
            onScrollOffsetYChanged: onScrollOffsetYChanged,
            onSegmentTapped: onSegmentTapped
        )
    }

    // Builds the read-mode text view with a furigana overlay that scrolls with text content.
    func makeUIView(context: Context) -> UITextView {
        context.coordinator.markMakeUIViewIfNeeded()
        let textView = TextViewFactory.makeFuriganaRendererTextView()
        textView.delegate = context.coordinator
        // Replay the latest render pipeline once SwiftUI's first layout pass resolves bounds.width,
        // because firstRect returns empty rects at width=0 so the initial updateUIView produces no
        // furigana frames. Without this hook the overlay stays empty until an unrelated state change
        // (e.g. adjusting a slider) happens to trigger another SwiftUI update pass.
        textView.onFirstLayoutResolved = { [weak textView] in
            guard let textView = textView else { return }
            context.coordinator.pendingRender?(textView)
        }
        textView.textLayoutManager?.delegate = context.coordinator
        textView.tag = 7_331
        textView.backgroundColor = .clear
        textView.isEditable = false
        textView.isSelectable = false
        textView.alwaysBounceVertical = true
        textView.showsVerticalScrollIndicator = false
        textView.adjustsFontForContentSizeCategory = true
        textView.textContainerInset = UIEdgeInsets(top: 8, left: 4, bottom: 8, right: 4)
        textView.textContainer.lineFragmentPadding = 0
        textView.textAlignment = textAlignment
        textView.isScrollEnabled = isScrollEnabled
        configureWrapping(for: textView)
        textView.clipsToBounds = true
        let pinchRecognizer = UIPinchGestureRecognizer(target: context.coordinator, action: #selector(FuriganaTextRendererCoordinator.handlePinch(_:)))
        pinchRecognizer.cancelsTouchesInView = false
        textView.addGestureRecognizer(pinchRecognizer)
        let tapRecognizer = UITapGestureRecognizer(target: context.coordinator, action: #selector(FuriganaTextRendererCoordinator.handleTap(_:)))
        tapRecognizer.cancelsTouchesInView = false
        textView.addGestureRecognizer(tapRecognizer)

        let overlayView = FuriganaOverlayView()
        overlayView.tag = 7_332
        overlayView.backgroundColor = .clear
        overlayView.isUserInteractionEnabled = false
        textView.addSubview(overlayView)

        return textView
    }
}
