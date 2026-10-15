import SwiftUI
import UIKit

// Renders the lyrics card's word bubbles: comic-style white speech bubbles, one per word holding
// its meaning, plus one holding the breakdown's grammar note for the line on its last word. Each
// bubble's tail runs all the way to just above its word. They go in the empty space beside the
// line — each word's bubbles in the column on its side, stacked in sung order around the line's
// middle, free to run past the card's top and bottom since the neighbouring lines are centred
// too. When the line is too wide to leave room beside it, they go in rows above (meanings) and
// below (notes) it instead, and the card makes room for those rows (onNeedsBandsChange). Everything
// springs into place as words are added. Sits over the renderer in its coordinates (rects from
// KiokuScrollingTextView.reportRangeRects). Ignores touches.
struct LyricWordBubbleOverlay: View {
    let bubbles: [PlacedLyricWordBubble]
    // The whole line's rect, for the room beside it; nil before it's measured.
    let lineRect: CGRect?
    // Told whether the bubbles need the rows above and below the line (the fallback layout).
    var onNeedsBandsChange: (Bool) -> Void = { _ in }

    static let glossFont = UIFont.systemFont(ofSize: 12, weight: .medium)
    static let commentFont = UIFont.italicSystemFont(ofSize: 11)
    static let horizontalPadding: CGFloat = 12
    static let verticalPadding: CGFloat = 7
    static let cornerRadius: CGFloat = 14
    static let gap: CGFloat = 8
    static let margin: CGFloat = 12
    static let minColumnWidth: CGFloat = 70
    static let maxGlossWidth: CGFloat = 150
    static let maxCommentWidth: CGFloat = 220
    // How far a side column may run past the card's top or bottom.
    static let sideOverflow: CGFloat = 140
    static let stackedRows = 2
    // Height of one bubble row in the above/below layout, which leaves room for the tail.
    static var rowHeight: CGFloat { ceil(glossFont.lineHeight) + 2 * verticalPadding + 12 }
    // Room the card makes above and below the line for the above/below layout.
    static var band: CGFloat { CGFloat(stackedRows) * rowHeight + gap }

    // One bubble's place: its body and the point on its word its tail reaches.
    struct Slot: Equatable {
        let id: Int
        let text: String
        let isNote: Bool
        let frame: CGRect
        let tip: CGPoint
    }

    var body: some View {
        GeometryReader { proxy in
            let side = Self.sideLayout(bubbles, lineRect: lineRect, size: proxy.size)
            let slots = side ?? Self.stackedLayout(bubbles, width: proxy.size.width)
            let needsBands = side == nil && bubbles.isEmpty == false
            ZStack(alignment: .topLeading) {
                ForEach(slots, id: \.id) { slot in
                    bubble(slot, in: proxy.size)
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
            .animation(.spring(response: 0.4, dampingFraction: 0.85), value: slots)
            .onChange(of: needsBands, initial: true) { _, needs in onNeedsBandsChange(needs) }
        }
        .allowsHitTesting(false)
    }

    // One white bubble with its tail, and its text in the body (a note's in grey italics).
    private func bubble(_ slot: Slot, in size: CGSize) -> some View {
        ZStack(alignment: .topLeading) {
            PointerBubbleShape(body: slot.frame, tip: slot.tip, cornerRadius: Self.cornerRadius)
                .fill(Color.white)
                .shadow(color: .black.opacity(0.35), radius: 3, y: 1)
                .frame(width: size.width, height: size.height)
            Text(slot.text)
                .font(Font(slot.isNote ? Self.commentFont : Self.glossFont))
                .foregroundStyle(slot.isNote ? Color(white: 0.35) : Color.black)
                .lineLimit(1)
                .truncationMode(.tail)
                .padding(.horizontal, Self.horizontalPadding)
                .frame(width: slot.frame.width, height: slot.frame.height)
                .position(x: slot.frame.midX, y: slot.frame.midY)
        }
        .transition(.scale(scale: 0.4, anchor: .center).combined(with: .opacity))
    }

    // A bubble body's size for its text: padded and capped at `maxWidth`.
    private static func size(_ text: String, note: Bool, maxWidth: CGFloat) -> CGSize {
        let font = note ? commentFont : glossFont
        let textWidth = ceil((text as NSString).size(withAttributes: [.font: font]).width)
        return CGSize(width: min(textWidth + 2 * horizontalPadding, maxWidth), height: ceil(font.lineHeight) + 2 * verticalPadding)
    }

    // The beside-the-line layout, or nil when either side is too narrow or a column would run
    // further past the card than sideOverflow. Each word's meaning, then its note, goes in the
    // column on its side of the line's middle; a column is stacked in sung order and centred on
    // the line, hugging the line's edge. Every tail reaches just above its word.
    static func sideLayout(_ bubbles: [PlacedLyricWordBubble], lineRect: CGRect?, size cardSize: CGSize) -> [Slot]? {
        let width = cardSize.width
        guard let line = lineRect, width > 0 else { return nil }
        let leftWidth = line.minX - 2 * margin
        let rightWidth = width - line.maxX - 2 * margin
        guard min(leftWidth, rightWidth) >= minColumnWidth else { return nil }
        let sorted = bubbles.sorted { $0.anchor.midX < $1.anchor.midX }
        var slots: [Slot] = []
        for isLeft in [true, false] {
            let column = sorted.filter { ($0.anchor.midX < line.midX) == isLeft }
            let columnWidth = isLeft ? leftWidth : rightWidth
            var entries: [(bubble: PlacedLyricWordBubble, text: String, note: Bool, size: CGSize)] = []
            for bubble in column {
                if let gloss = bubble.gloss {
                    entries.append((bubble, gloss, false, size(gloss, note: false, maxWidth: min(columnWidth, maxGlossWidth))))
                }
                if let comment = bubble.comment {
                    entries.append((bubble, comment, true, size(comment, note: true, maxWidth: min(columnWidth, maxCommentWidth))))
                }
            }
            guard entries.isEmpty == false else { continue }
            let total = entries.reduce(0) { $0 + $1.size.height } + gap * CGFloat(entries.count - 1)
            guard total <= cardSize.height + 2 * sideOverflow else { return nil }
            var y = min(max(line.midY - total / 2, -sideOverflow), cardSize.height + sideOverflow - total)
            for entry in entries {
                let x = isLeft ? line.minX - margin - entry.size.width : line.maxX + margin
                slots.append(Slot(
                    id: entry.bubble.id * 2 + (entry.note ? 1 : 0),
                    text: entry.text,
                    isNote: entry.note,
                    frame: CGRect(x: x, y: y, width: entry.size.width, height: entry.size.height),
                    tip: CGPoint(x: entry.bubble.anchor.midX, y: line.minY - 1)
                ))
                y += entry.size.height + gap
            }
        }
        return slots
    }

    // The fallback for a line too wide to leave room beside it: meanings in rows above the line,
    // notes in rows below, each centred on its word where there's room, else in the next row out
    // (or pushed right in the last row), its tail reaching the word.
    static func stackedLayout(_ bubbles: [PlacedLyricWordBubble], width: CGFloat) -> [Slot] {
        guard width > 0 else { return [] }
        let lineTop = bubbles.map(\.anchor.minY).min() ?? 0
        let lineBottom = bubbles.map(\.anchor.maxY).max() ?? 0
        var slots: [Slot] = []
        for note in [false, true] {
            var rowEnds: [CGFloat] = []
            for bubble in bubbles.sorted(by: { $0.anchor.midX < $1.anchor.midX }) {
                guard let text = note ? bubble.comment : bubble.gloss else { continue }
                let size = size(text, note: note, maxWidth: min(width, note ? maxCommentWidth : maxGlossWidth))
                var x = min(max(0, bubble.anchor.midX - size.width / 2), width - size.width)
                var row = rowEnds.firstIndex { $0 + gap <= x }
                if row == nil {
                    if rowEnds.count < stackedRows {
                        rowEnds.append(-gap)
                        row = rowEnds.count - 1
                    } else {
                        row = rowEnds.count - 1
                        x = min(max(x, rowEnds[row!] + gap), max(0, width - size.width))
                    }
                }
                guard let row else { continue }
                rowEnds[row] = x + size.width
                let offset = 10 + CGFloat(row) * rowHeight
                let y = note ? lineBottom + offset : lineTop - offset - size.height
                slots.append(Slot(
                    id: bubble.id * 2 + (note ? 1 : 0),
                    text: text,
                    isNote: note,
                    frame: CGRect(x: x, y: y, width: size.width, height: size.height),
                    tip: CGPoint(x: bubble.anchor.midX, y: note ? bubble.anchor.maxY + 1 : bubble.anchor.minY - 1)
                ))
            }
        }
        return slots
    }
}
