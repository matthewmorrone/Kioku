import SwiftUI
import UIKit

// Renders the live typography preview in the Settings typography section.
// Shows the preview text with furigana labels and optional debug line bands,
// using the same coordinate pipeline as the read renderer (CLAUDE.md §9).
struct SettingsPreviewRenderer: UIViewRepresentable {

    // Matches the preview text used in SettingsView.
    static let previewText = "情報処理技術者試験対策資料を精読し、概念理解を深める。"

    // Hardcoded furigana readings for words in the preview text.
    private static let furigana: [(word: String, reading: String)] = [
        ("情報", "じょうほう"),
        ("処理", "しょり"),
        ("技術者", "ぎじゅつしゃ"),
        ("試験", "しけん"),
        ("対策", "たいさく"),
        ("資料", "しりょう"),
        ("精読", "せいどく"),
        ("概念", "がいねん"),
        ("理解", "りかい"),
        ("深める", "ふかめる"),
    ]

    let textSize: Double
    let lineSpacing: Double
    let kerning: Double
    let furiganaGap: Double
    let debugHeadwordLineBands: Bool
    let debugFuriganaLineBands: Bool

    // Builds the non-interactive preview text view with furigana and band overlays.
    func makeUIView(context: Context) -> UITextView {
        let textView = TextViewFactory.makeTextView()
        textView.backgroundColor = .clear
        textView.isEditable = false
        textView.isSelectable = false
        textView.isScrollEnabled = false
        textView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        textView.textContainer.lineFragmentPadding = 0
        textView.textContainer.widthTracksTextView = true

        let furiganaOverlay = FuriganaOverlayView()
        furiganaOverlay.tag = 7_340
        textView.addSubview(furiganaOverlay)

        return textView
    }

    // Refreshes typography, furigana positions, and debug band rects when settings change.
    func updateUIView(_ uiView: UITextView, context: Context) {
        apply(to: uiView)
    }

    // Applies all typography and overlay state in one pass.
    private func apply(to textView: UITextView) {
        let bodyFont = UIFont.systemFont(ofSize: textSize)
        let furiganaFont = UIFont.systemFont(ofSize: textSize * 0.5)
        let paragraphStyle = NSMutableParagraphStyle()
        // Matches the lineSpacing formula used by ReadTextStyleResolver and RichTextEditor.
        paragraphStyle.lineSpacing = lineSpacing + bodyFont.lineHeight * 0.5
        paragraphStyle.lineBreakMode = .byWordWrapping

        textView.textContainerInset = UIEdgeInsets(
            top: furiganaFont.lineHeight + CGFloat(furiganaGap) + 4,
            left: 4, bottom: 8, right: 4
        )

        textView.attributedText = NSAttributedString(
            string: Self.previewText,
            attributes: [
                .font: bodyFont,
                .kern: kerning,
                .paragraphStyle: paragraphStyle,
                .foregroundColor: UIColor.label,
            ]
        )

        // Invalidate so SwiftUI remeasures and gives the view enough height for the current
        // typography settings — prevents the second line being clipped when textSize or
        // lineSpacing is large.
        textView.invalidateIntrinsicContentSize()
        // Force layout before querying rects so caretRect and firstRect are valid (CLAUDE.md §9).
        textView.layoutIfNeeded()
        applyOverlays(to: textView, bodyFont: bodyFont, furiganaFont: furiganaFont)
    }

    // Computes furigana label frames and debug band rects, then pushes them to FuriganaOverlayView.
    private func applyOverlays(to textView: UITextView, bodyFont: UIFont, furiganaFont: UIFont) {
        guard let overlay = textView.viewWithTag(7_340) as? FuriganaOverlayView else { return }

        let overlayFrame = CGRect(
            origin: .zero,
            size: CGSize(
                width: max(textView.contentSize.width, textView.bounds.width),
                height: max(textView.contentSize.height, textView.bounds.height)
            )
        )

        // Compute furigana label positions using firstRect for each hardcoded word range.
        let fullText = Self.previewText as NSString
        var furiganaStrings: [String] = []
        var furiganaFrames: [CGRect] = []
        var furiganaColors: [UIColor] = []

        for (word, reading) in Self.furigana {
            let range = fullText.range(of: word)
            guard range.location != NSNotFound,
                  let start = textView.position(from: textView.beginningOfDocument, offset: range.location),
                  let end = textView.position(from: start, offset: range.length),
                  let textRange = textView.textRange(from: start, to: end) else { continue }

            let wordRect = textView.firstRect(for: textRange)
            guard wordRect.isNull == false, wordRect.isInfinite == false, wordRect.height > 0 else { continue }

            let readingWidth = (reading as NSString).size(withAttributes: [.font: furiganaFont]).width
            let furiganaX = wordRect.midX - readingWidth / 2
            let furiganaY = wordRect.minY - furiganaFont.lineHeight - CGFloat(furiganaGap)

            furiganaStrings.append(reading)
            furiganaFrames.append(CGRect(x: furiganaX, y: furiganaY, width: readingWidth, height: furiganaFont.lineHeight))
            furiganaColors.append(UIColor.secondaryLabel)
        }

        overlay.apply(
            overlayFrame: overlayFrame,
            selectedSegmentRect: nil,
            selectedSegmentColor: nil,
            playbackHighlightRect: nil,
            playbackHighlightColor: nil,
            illegalBoundaryRect: nil,
            illegalBoundaryColor: nil,
            furiganaStrings: furiganaStrings,
            furiganaFrames: furiganaFrames,
            furiganaColors: furiganaColors,
            furiganaFont: furiganaFont,
            debugFuriganaRectsEnabled: false,
            debugHeadwordRectsEnabled: false,
            debugHeadwordLineBandsEnabled: debugHeadwordLineBands,
            debugFuriganaLineBandsEnabled: debugFuriganaLineBands,
            debugHeadwordRects: [],
            debugHeadwordColors: [],
            debugHeadwordLineBandRects: computeHeadwordBandRects(for: textView, bodyFont: bodyFont, furiganaFont: furiganaFont, overlayWidth: overlayFrame.width),
            debugFuriganaLineBandRects: computeFuriganaBandRects(for: textView, furiganaFont: furiganaFont, overlayWidth: overlayFrame.width)
        )
    }

    // Enumerates text layout fragments and computes headword band rects via the caretRect pipeline.
    private func computeHeadwordBandRects(for textView: UITextView, bodyFont: UIFont, furiganaFont: UIFont, overlayWidth: CGFloat) -> [CGRect] {
        guard debugHeadwordLineBands,
              let tlm = textView.textLayoutManager,
              let tcm = tlm.textContentManager else { return [] }

        var rects: [CGRect] = []
        let docStart = tcm.documentRange.location
        tlm.enumerateTextLayoutFragments(from: nil, options: []) { fragment in
            let fragmentOffset = tcm.offset(from: docStart, to: fragment.rangeInElement.location)
            for lineFragment in fragment.textLineFragments {
                let lineDocStart = fragmentOffset + lineFragment.characterRange.location
                guard let anchorPos = textView.position(from: textView.beginningOfDocument, offset: lineDocStart) else { continue }
                let caretR = textView.caretRect(for: anchorPos)
                guard caretR.isNull == false, caretR.isInfinite == false, caretR.height > 0 else { continue }
                let textNS = textView.text as NSString
                let isBlankLine = lineDocStart < textNS.length
                    ? textNS.character(at: lineDocStart) == 0x000A
                    : true
                let bandY = isBlankLine ? caretR.minY + furiganaFont.lineHeight + CGFloat(lineSpacing) : caretR.minY
                rects.append(CGRect(x: 0, y: bandY, width: overlayWidth, height: bodyFont.lineHeight))
            }
            return true
        }
        return rects
    }

    // Enumerates text layout fragments and computes furigana band rects via the caretRect pipeline.
    private func computeFuriganaBandRects(for textView: UITextView, furiganaFont: UIFont, overlayWidth: CGFloat) -> [CGRect] {
        guard debugFuriganaLineBands,
              let tlm = textView.textLayoutManager,
              let tcm = tlm.textContentManager else { return [] }

        var rects: [CGRect] = []
        let docStart = tcm.documentRange.location
        tlm.enumerateTextLayoutFragments(from: nil, options: []) { fragment in
            let fragmentOffset = tcm.offset(from: docStart, to: fragment.rangeInElement.location)
            for lineFragment in fragment.textLineFragments {
                let lineDocStart = fragmentOffset + lineFragment.characterRange.location
                guard let anchorPos = textView.position(from: textView.beginningOfDocument, offset: lineDocStart) else { continue }
                let caretR = textView.caretRect(for: anchorPos)
                guard caretR.isNull == false, caretR.isInfinite == false, caretR.height > 0 else { continue }
                let textNS = textView.text as NSString
                let isBlankLine = lineDocStart < textNS.length
                    ? textNS.character(at: lineDocStart) == 0x000A
                    : true
                guard !isBlankLine else { continue }
                rects.append(CGRect(
                    x: 0,
                    y: caretR.minY - furiganaFont.lineHeight - CGFloat(furiganaGap),
                    width: overlayWidth,
                    height: furiganaFont.lineHeight
                ))
            }
            return true
        }
        return rects
    }
}
