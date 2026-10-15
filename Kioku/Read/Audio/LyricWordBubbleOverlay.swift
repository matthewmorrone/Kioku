import SwiftUI
import UIKit

// Renders the lyrics card's word bubbles over the active line: speech bubbles above it holding each
// word's meaning, thought bubbles below holding the breakdown's notes, each pointing at its word.
// Bubbles are laid out left to right in rows so they never overlap — one sits right over its word
// when there's room, else it moves to the next row up (or down) with a thin leader to its word — and
// they spring into place as words are added. Sits over the renderer in its coordinates (the word
// rects come from KiokuScrollingTextView.reportRangeRects) and draws into the bands the card
// reserves above and below the line (topBand / bottomBand). Ignores touches.
struct LyricWordBubbleOverlay: View {
    let bubbles: [PlacedLyricWordBubble]

    static let glossFont = UIFont.systemFont(ofSize: 11, weight: .medium)
    static let commentFont = UIFont.italicSystemFont(ofSize: 10)
    static let rowHeight: CGFloat = 24
    static let speechRows = 2
    static let thoughtRows = 2
    static let gap: CGFloat = 4
    static let maxGlossWidth: CGFloat = 140
    static let maxCommentWidth: CGFloat = 220
    // Room the card leaves above and below the line for the bubbles.
    static var topBand: CGFloat { CGFloat(speechRows) * rowHeight + gap }
    static var bottomBand: CGFloat { CGFloat(thoughtRows) * rowHeight + gap }

    // One bubble's place: its frame, where its tail meets the frame edge (0–1 of the width), and
    // the point on its word the leader runs to.
    struct Slot: Equatable {
        let id: Int
        let text: String
        let frame: CGRect
        let tailX: CGFloat
        let target: CGPoint
    }

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let lineTop = bubbles.map(\.anchor.minY).min() ?? 0
            let lineBottom = bubbles.map(\.anchor.maxY).max() ?? 0
            let speech = Self.layout(
                bubbles.compactMap { bubble in bubble.gloss.map { (bubble.id, $0, bubble.anchor) } },
                font: Self.glossFont, maxTextWidth: Self.maxGlossWidth, width: width,
                edge: lineTop, above: true, maxRows: Self.speechRows
            )
            let thought = Self.layout(
                bubbles.compactMap { bubble in bubble.comment.map { (bubble.id, $0, bubble.anchor) } },
                font: Self.commentFont, maxTextWidth: Self.maxCommentWidth, width: width,
                edge: lineBottom, above: false, maxRows: Self.thoughtRows
            )
            ZStack(alignment: .topLeading) {
                ForEach(speech, id: \.id) { slot in
                    speechBubble(slot)
                }
                ForEach(thought, id: \.id) { slot in
                    thoughtBubble(slot)
                }
            }
            .frame(width: width, height: proxy.size.height, alignment: .topLeading)
            .animation(.spring(response: 0.35, dampingFraction: 0.85), value: speech + thought)
        }
        .allowsHitTesting(false)
    }

    // A meaning above its word: the bubble with its tail, plus a leader when it sits a row up.
    private func speechBubble(_ slot: Slot) -> some View {
        ZStack(alignment: .topLeading) {
            leader(from: CGPoint(x: slot.frame.minX + slot.frame.width * slot.tailX, y: slot.frame.maxY), to: slot.target)
            Text(slot.text)
                .font(Font(Self.glossFont))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.tail)
                .padding(.horizontal, 6)
                .padding(.bottom, 5)
                .frame(width: slot.frame.width, height: slot.frame.height)
                .background(
                    SpeechBubbleShape(tailX: slot.tailX)
                        .fill(Color(.systemBackground).opacity(0.92))
                        .overlay(SpeechBubbleShape(tailX: slot.tailX).stroke(Color.secondary.opacity(0.45), lineWidth: 0.75))
                )
                .position(x: slot.frame.midX, y: slot.frame.midY)
        }
        .transition(.scale(scale: 0.4, anchor: .bottom).combined(with: .opacity))
    }

    // A note below its word: a cloud-like capsule trailed by two dots back up to the word.
    private func thoughtBubble(_ slot: Slot) -> some View {
        let dotStart = CGPoint(x: slot.target.x, y: slot.target.y + 3)
        let dotEnd = CGPoint(x: slot.frame.minX + slot.frame.width * slot.tailX, y: slot.frame.minY - 2)
        return ZStack(alignment: .topLeading) {
            Circle()
                .fill(Color(.secondarySystemBackground))
                .overlay(Circle().stroke(Color.secondary.opacity(0.35), lineWidth: 0.5))
                .frame(width: 3, height: 3)
                .position(dotStart)
            Circle()
                .fill(Color(.secondarySystemBackground))
                .overlay(Circle().stroke(Color.secondary.opacity(0.35), lineWidth: 0.5))
                .frame(width: 5, height: 5)
                .position(x: (dotStart.x + dotEnd.x) / 2, y: (dotStart.y + dotEnd.y) / 2)
            Text(slot.text)
                .font(Font(Self.commentFont))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .padding(.horizontal, 7)
                .frame(width: slot.frame.width, height: slot.frame.height)
                .background(
                    Capsule()
                        .fill(Color(.secondarySystemBackground))
                        .overlay(Capsule().stroke(Color.secondary.opacity(0.35), lineWidth: 0.5))
                )
                .position(x: slot.frame.midX, y: slot.frame.midY)
        }
        .transition(.scale(scale: 0.4, anchor: .top).combined(with: .opacity))
    }

    // A hairline from a bubble's tail to its word, for bubbles pushed a row away.
    private func leader(from start: CGPoint, to end: CGPoint) -> some View {
        Path { path in
            path.move(to: start)
            path.addLine(to: end)
        }
        .stroke(Color.secondary.opacity(0.45), lineWidth: 0.75)
    }

    // Places bubbles in rows beside the line's `edge` (its top for speech, bottom for thought),
    // left to right by word: each goes centred over its word, nudged inside the width, in the
    // nearest row with room, else the last row pushed right past its neighbour. The first row hugs
    // the line; later ones stack away from it.
    static func layout(
        _ items: [(id: Int, text: String, anchor: CGRect)],
        font: UIFont,
        maxTextWidth: CGFloat,
        width: CGFloat,
        edge: CGFloat,
        above: Bool,
        maxRows: Int
    ) -> [Slot] {
        guard width > 0 else { return [] }
        let height = rowHeight - 4
        var rowEnds: [CGFloat] = []
        var slots: [Slot] = []
        for item in items.sorted(by: { $0.anchor.midX < $1.anchor.midX }) {
            let textWidth = min(ceil((item.text as NSString).size(withAttributes: [.font: font]).width), maxTextWidth)
            let bubbleWidth = min(textWidth + 14, width)
            var x = min(max(0, item.anchor.midX - bubbleWidth / 2), width - bubbleWidth)
            var row = rowEnds.firstIndex { $0 + gap <= x }
            if row == nil {
                if rowEnds.count < maxRows {
                    rowEnds.append(-gap)
                    row = rowEnds.count - 1
                } else {
                    row = rowEnds.count - 1
                    x = min(max(x, rowEnds[row!] + gap), max(0, width - bubbleWidth))
                }
            }
            guard let row else { continue }
            rowEnds[row] = x + bubbleWidth
            let offset = gap + CGFloat(row) * rowHeight
            let y = above ? edge - offset - height : edge + offset
            let frame = CGRect(x: x, y: y, width: bubbleWidth, height: height)
            let tailX = min(max((item.anchor.midX - x) / bubbleWidth, 0.1), 0.9)
            let target = CGPoint(x: item.anchor.midX, y: above ? item.anchor.minY : item.anchor.maxY)
            slots.append(Slot(id: item.id, text: item.text, frame: frame, tailX: tailX, target: target))
        }
        return slots
    }
}
