import SwiftUI
import UIKit

// Frame sizing for the furigana renderer when SwiftUI needs an intrinsic size
// (e.g. non-scrolling lyric cue rows that must allocate a real frame before the first render).
extension FuriganaTextRenderer {
    // Reports a fixed single-line height when scroll is disabled (e.g. lyrics cue row) so SwiftUI
    // allocates a real frame before the first render. When scrolling is enabled the view fills
    // whatever space SwiftUI offers, so we defer to the default behaviour by returning nil.
    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UITextView, context: Context) -> CGSize? {
        guard !uiView.isScrollEnabled else { return nil }
        let width = proposal.width ?? uiView.bounds.width
        let bodyFont = UIFont.systemFont(ofSize: textSize)
        let furiganaFont = UIFont.systemFont(ofSize: textSize * TypographySettings.furiganaSizeFactor)
        // Compute actual content height from attributed text bounds when multi-line.
        let insets = uiView.textContainerInset
        let textWidth = max(width - insets.left - insets.right, 0)
        if let attrText = uiView.attributedText, attrText.length > 0 {
            let boundingRect = attrText.boundingRect(
                with: CGSize(width: textWidth, height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading],
                context: nil
            )
            let topInset = furiganaFont.lineHeight + CGFloat(furiganaGap) + 4
            return CGSize(width: width, height: ceil(boundingRect.height) + topInset + 8)
        }
        // Fallback for empty text: single line height.
        let height = furiganaFont.lineHeight + CGFloat(furiganaGap) + 4 + bodyFont.lineHeight + 8
        return CGSize(width: width, height: height)
    }
}
