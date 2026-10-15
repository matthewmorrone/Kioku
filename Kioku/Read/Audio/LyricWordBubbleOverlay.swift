import SwiftUI
import UIKit

// Renders the lyrics card's word bubbles: a white speech bubble per word holding its meaning, and
// one holding the breakdown's grammar note for the line on its last word. They go in the empty space beside the line —
// each word's bubbles in the column on its side, stacked in sung order around the line's middle,
// with a tail toward the line and a white leader arcing over to a bar on the word (solid for
// meanings, dotted for notes). When the line is too wide to leave room beside it, they go in rows above (meanings) and
// below (notes) it instead. Everything springs into place as words are added. Sits over the
// renderer in its coordinates (rects from KiokuScrollingTextView.reportRangeRects) and may draw
// into the bands the card reserves above and below the line (topBand / bottomBand). Ignores touches.
struct LyricWordBubbleOverlay: View {
    let bubbles: [PlacedLyricWordBubble]
    // The whole line's rect, for the room beside it; nil before it's measured.
    let lineRect: CGRect?

    static let glossFont = UIFont.systemFont(ofSize: 12, weight: .medium)
    static let commentFont = UIFont.italicSystemFont(ofSize: 11)
    static let horizontalPadding: CGFloat = 11
    static let verticalPadding: CGFloat = 7
    static let tailLength: CGFloat = 6
    static let cornerRadius: CGFloat = 14
    static let gap: CGFloat = 6
    static let margin: CGFloat = 10
    static let minColumnWidth: CGFloat = 70
    static let maxGlossWidth: CGFloat = 150
    static let maxCommentWidth: CGFloat = 220
    static let stackedRows = 2
    // Height of one bubble row in the above/below layout.
    static var rowHeight: CGFloat { ceil(glossFont.lineHeight) + 2 * verticalPadding + tailLength + 4 }
    // Room the card leaves above and below the line for the bubbles.
    static var topBand: CGFloat { CGFloat(stackedRows) * rowHeight + gap }
    static var bottomBand: CGFloat { CGFloat(stackedRows) * rowHeight + gap }

    // One bubble's place: its frame, which edge its tail is on and where along it, and the leader
    // from the tail's tip to its word (curving through `control` when set).
    struct Slot: Equatable {
        let id: Int
        let text: String
        let isNote: Bool
        let frame: CGRect
        let tailEdge: Edge
        let tailFraction: CGFloat
        let tip: CGPoint
        let target: CGPoint
        let control: CGPoint?
        // Width of the word the bar at the leader's end spans.
        let wordWidth: CGFloat
    }

    var body: some View {
        GeometryReader { proxy in
            let slots = Self.sideLayout(bubbles, lineRect: lineRect, size: proxy.size)
                ?? Self.stackedLayout(bubbles, width: proxy.size.width)
            ZStack(alignment: .topLeading) {
                ForEach(slots, id: \.id) { slot in
                    bubble(slot)
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
            .animation(.spring(response: 0.4, dampingFraction: 0.85), value: slots)
        }
        .allowsHitTesting(false)
    }

    // One bubble with its pointer: a white leader from its tail to the word, ending in a short bar
    // spanning the word (above it, or below for a note in the above/below layout) so it's plain
    // which word it means; the bubble itself white, a meaning tailed, a note plain.
    private func bubble(_ slot: Slot) -> some View {
        ZStack(alignment: .topLeading) {
            Path { path in
                path.move(to: slot.tip)
                if let control = slot.control {
                    path.addQuadCurve(to: slot.target, control: control)
                } else {
                    path.addLine(to: slot.target)
                }
            }
            .stroke(Self.pointerColor, style: StrokeStyle(lineWidth: 1.5, lineCap: .round, dash: slot.isNote ? [2, 3.5] : []))
            .shadow(color: .black.opacity(0.35), radius: 1)
            Capsule()
                .fill(Self.pointerColor)
                .frame(width: max(slot.wordWidth, 8), height: 3)
                .position(x: slot.target.x, y: slot.target.y)
                .shadow(color: .black.opacity(0.35), radius: 1)
            Text(slot.text)
                .font(Font(slot.isNote ? Self.commentFont : Self.glossFont))
                .foregroundStyle(slot.isNote ? Color(white: 0.3) : Color.black)
                .lineLimit(1)
                .truncationMode(.tail)
                .padding(.horizontal, Self.horizontalPadding)
                .padding(edgeInsets(for: slot))
                .frame(width: slot.frame.width, height: slot.frame.height)
                .background(
                    SpeechBubbleShape(edge: slot.tailEdge, tailFraction: slot.tailFraction,
                                      tailLength: slot.isNote ? 0 : Self.tailLength, cornerRadius: Self.cornerRadius)
                        .fill(Color.white)
                        .shadow(color: .black.opacity(0.3), radius: 3, y: 1)
                )
                .position(x: slot.frame.midX, y: slot.frame.midY)
        }
        .transition(.scale(scale: 0.4, anchor: .center).combined(with: .opacity))
    }

    // The pointer's colour: white like the bubbles, shadowed so it reads on a light card too.
    static let pointerColor = Color.white

    // Keeps the text clear of a speech bubble's tail.
    private func edgeInsets(for slot: Slot) -> EdgeInsets {
        let tail = slot.isNote ? 0 : Self.tailLength
        switch slot.tailEdge {
        case .top: return EdgeInsets(top: tail, leading: 0, bottom: 0, trailing: 0)
        case .bottom: return EdgeInsets(top: 0, leading: 0, bottom: tail, trailing: 0)
        case .leading: return EdgeInsets(top: 0, leading: tail, bottom: 0, trailing: 0)
        case .trailing: return EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: tail)
        }
    }

    // A bubble's size for its text: padded, capped at `maxWidth`, plus the tail's length on the
    // axis it sticks out on.
    private static func size(_ text: String, note: Bool, maxWidth: CGFloat, tailHorizontal: Bool) -> CGSize {
        let font = note ? commentFont : glossFont
        let textWidth = ceil((text as NSString).size(withAttributes: [.font: font]).width)
        let tail = note ? 0 : tailLength
        let width = min(textWidth + 2 * horizontalPadding + (tailHorizontal ? tail : 0), maxWidth)
        let height = ceil(font.lineHeight) + 2 * verticalPadding + (tailHorizontal ? 0 : tail)
        return CGSize(width: width, height: height)
    }

    // The beside-the-line layout, or nil when either side is too narrow or a column would be taller
    // than the card plus its bands. Each word's meaning, then its note, goes in the column on its
    // side of the line's middle; a column is stacked in sung order and centred on the line, hugging
    // the line's edge.
    static func sideLayout(_ bubbles: [PlacedLyricWordBubble], lineRect: CGRect?, size cardSize: CGSize) -> [Slot]? {
        let width = cardSize.width
        guard let line = lineRect, width > 0 else { return nil }
        let availableHeight = cardSize.height + topBand + bottomBand
        let leftWidth = line.minX - 2 * margin
        let rightWidth = width - line.maxX - 2 * margin
        guard min(leftWidth, rightWidth) >= minColumnWidth else { return nil }
        let sorted = bubbles.sorted { $0.anchor.midX < $1.anchor.midX }
        var slots: [Slot] = []
        for isLeft in [true, false] {
            let column = sorted.filter { ($0.anchor.midX < line.midX) == isLeft }
            let columnWidth = isLeft ? leftWidth : rightWidth
            // Every bubble in the column with its size, in order.
            var entries: [(bubble: PlacedLyricWordBubble, text: String, note: Bool, size: CGSize, gapAfter: CGFloat)] = []
            for (index, bubble) in column.enumerated() {
                let isLast = index == column.count - 1
                if let gloss = bubble.gloss {
                    let size = size(gloss, note: false, maxWidth: min(columnWidth, maxGlossWidth), tailHorizontal: true)
                    entries.append((bubble, gloss, false, size, bubble.comment == nil ? (isLast ? 0 : gap) : 3))
                }
                if let comment = bubble.comment {
                    let size = size(comment, note: true, maxWidth: min(columnWidth, maxCommentWidth), tailHorizontal: true)
                    entries.append((bubble, comment, true, size, isLast ? 0 : gap))
                }
            }
            let total = entries.reduce(0) { $0 + $1.size.height + $1.gapAfter }
            guard total <= availableHeight else { return nil }
            // Centred on the line, kept within the card and its bands.
            var y = min(max(line.midY - total / 2, -topBand), cardSize.height + bottomBand - total)
            for entry in entries {
                let x = isLeft ? line.minX - margin - entry.size.width : line.maxX + margin
                let frame = CGRect(x: x, y: y, width: entry.size.width, height: entry.size.height)
                let tip = CGPoint(x: isLeft ? frame.maxX : frame.minX, y: frame.midY)
                let target = CGPoint(x: entry.bubble.anchor.midX, y: line.minY - 2)
                let control = CGPoint(x: entry.bubble.anchor.midX, y: min(tip.y, target.y) - 14)
                slots.append(Slot(
                    id: entry.bubble.id * 2 + (entry.note ? 1 : 0),
                    text: entry.text,
                    isNote: entry.note,
                    frame: frame,
                    tailEdge: isLeft ? .trailing : .leading,
                    tailFraction: 0.5,
                    tip: tip,
                    target: target,
                    control: control,
                    wordWidth: entry.bubble.anchor.width
                ))
                y += entry.size.height + entry.gapAfter
            }
        }
        return slots
    }

    // The fallback for a line too wide to leave room beside it: meanings in rows above the line,
    // notes in rows below, each centred on its word where there's room, else in the next row out
    // (or pushed right in the last row), with a leader back to the word.
    static func stackedLayout(_ bubbles: [PlacedLyricWordBubble], width: CGFloat) -> [Slot] {
        guard width > 0 else { return [] }
        let lineTop = bubbles.map(\.anchor.minY).min() ?? 0
        let lineBottom = bubbles.map(\.anchor.maxY).max() ?? 0
        var slots: [Slot] = []
        for note in [false, true] {
            var rowEnds: [CGFloat] = []
            for bubble in bubbles.sorted(by: { $0.anchor.midX < $1.anchor.midX }) {
                guard let text = note ? bubble.comment : bubble.gloss else { continue }
                let size = size(text, note: note, maxWidth: min(width, note ? maxCommentWidth : maxGlossWidth), tailHorizontal: false)
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
                let offset = gap + CGFloat(row) * rowHeight
                let y = note ? lineBottom + offset : lineTop - offset - size.height
                let frame = CGRect(x: x, y: y, width: size.width, height: size.height)
                let fraction = min(max((bubble.anchor.midX - x) / size.width, 0.1), 0.9)
                slots.append(Slot(
                    id: bubble.id * 2 + (note ? 1 : 0),
                    text: text,
                    isNote: note,
                    frame: frame,
                    tailEdge: note ? .top : .bottom,
                    tailFraction: fraction,
                    tip: CGPoint(x: frame.minX + frame.width * fraction, y: note ? frame.minY : frame.maxY),
                    target: CGPoint(x: bubble.anchor.midX, y: note ? bubble.anchor.maxY + 2 : bubble.anchor.minY - 2),
                    control: nil,
                    wordWidth: bubble.anchor.width
                ))
            }
        }
        return slots
    }
}
