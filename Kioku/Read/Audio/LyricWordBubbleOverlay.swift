import SwiftUI
import UIKit

// Renders the lyrics card's word bubbles: comic-style white speech bubbles, one per word holding
// its meaning, each bubble's tail running all the way to its word. They go in the empty space
// beside the line — each side taking half the words, one level with the line and the rest split
// above and below it so tails never cross the text (sideLayout), free to run past the card's top
// and bottom since the neighbouring lines are centred too. When the line is too wide to leave room
// beside it, they go in rows above and below it instead, over the neighbouring lines; the card
// never grows for them. Places are planned for the whole line, so each bubble pops in where it stays. Sits over the renderer in its coordinates (rects from
// KiokuScrollingTextView.reportRangeRects). Ignores touches.
struct LyricWordBubbleOverlay: View {
    let bubbles: [PlacedLyricWordBubble]
    // The whole line's rect, for the room beside it; nil before it's measured.
    let lineRect: CGRect?

    static let glossFont = UIFont.systemFont(ofSize: 12, weight: .medium)
    static let horizontalPadding: CGFloat = 12
    static let verticalPadding: CGFloat = 7
    static let cornerRadius: CGFloat = 14
    static let gap: CGFloat = 8
    static let margin: CGFloat = 8
    // Narrowest side room the side layout uses; bubbles there wrap between words.
    static let minColumnWidth: CGFloat = 52
    static let maxGlossWidth: CGFloat = 150
    // How far a side stack may run past the card's top or bottom.
    static let sideOverflow: CGFloat = 220
    // Least space between the line and a stacked side bubble, and between stacked bubbles.
    static let lineClearance: CGFloat = 4
    static let stackGap: CGFloat = 10
    // Height of a one-line bubble row in the above/below layout, which leaves room for the tail.
    static var rowHeight: CGFloat { ceil(glossFont.lineHeight) + 2 * verticalPadding + 12 }

    // One bubble's place: its body and the point on its word its tail reaches.
    struct Slot: Equatable {
        let id: Int
        let text: String
        let frame: CGRect
        let tip: CGPoint
    }

    var body: some View {
        GeometryReader { proxy in
            // Laid out for every word of the line, drawn only for those shown, so a bubble's place
            // is fixed before it appears.
            let side = Self.sideLayout(bubbles, lineRect: lineRect, size: proxy.size)
            let shownIDs = Set(bubbles.filter(\.isShown).map(\.id))
            let slots = (side ?? Self.stackedLayout(bubbles, width: proxy.size.width))
                .filter { shownIDs.contains($0.id) }
            ZStack(alignment: .topLeading) {
                ForEach(slots, id: \.id) { slot in
                    bubble(slot, in: proxy.size)
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
            .animation(.spring(response: 0.4, dampingFraction: 0.85), value: slots)
        }
        .allowsHitTesting(false)
    }

    // One white bubble with its tail, and its text in the body.
    private func bubble(_ slot: Slot, in size: CGSize) -> some View {
        ZStack(alignment: .topLeading) {
            PointerBubbleShape(body: slot.frame, tip: slot.tip, cornerRadius: Self.cornerRadius)
                .fill(Color.white)
                .shadow(color: .black.opacity(0.35), radius: 3, y: 1)
                .frame(width: size.width, height: size.height)
            Text(Self.displayText(slot.text))
                .font(Font(Self.glossFont))
                .foregroundStyle(Color.black)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, Self.horizontalPadding)
                .frame(width: slot.frame.width, height: slot.frame.height)
                .position(x: slot.frame.midX, y: slot.frame.midY)
        }
        .transition(.scale(scale: 0.4, anchor: .center).combined(with: .opacity))
    }

    // A bubble's text with its inline markdown applied (a breakdown definition's *emphasis*), so the
    // asterisks aren't drawn; the plain text when it doesn't parse.
    static func displayText(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
    }

    // A bubble body's size for its text: padded and capped at `maxWidth`, wrapping between words onto
    // as many lines as it takes, and never narrower than its longest word so no word is broken.
    private static func size(_ markdown: String, maxWidth: CGFloat) -> CGSize {
        let text = String(displayText(markdown).characters)
        let attributes: [NSAttributedString.Key: Any] = [.font: glossFont]
        let textWidth = ceil((text as NSString).size(withAttributes: attributes).width)
        let longestWord = text.split(separator: " ")
            .map { ceil((String($0) as NSString).size(withAttributes: attributes).width) }
            .max() ?? 0
        // +1 so rounding in Text's own layout never breaks the longest word.
        let inner = min(textWidth, max(maxWidth - 2 * horizontalPadding, longestWord)) + 1
        let height = ceil((text as NSString).boundingRect(
            with: CGSize(width: inner, height: .greatestFiniteMagnitude),
            options: .usesLineFragmentOrigin,
            attributes: attributes,
            context: nil
        ).height)
        return CGSize(width: inner + 2 * horizontalPadding, height: height + 2 * verticalPadding)
    }

    // The beside-the-line layout, or nil when neither side has room or a stack would run further
    // past the card than sideOverflow. The words are shared evenly between the sides, leftmost half
    // left (all on one side when only that side has room). There, the word nearest the edge gets its meaning level with the line, the tail
    // pointing straight into the word's side; the side's other words split between a stack rising
    // from that bubble and one falling from it (earlier words up, later down), each bubble kept
    // clear of the line so its tail drops onto the word's top or bottom through empty space, never
    // across the text. Within a stack the bubble nearest the line points at the word nearest the
    // edge, so tails nest instead of crossing.
    static func sideLayout(_ bubbles: [PlacedLyricWordBubble], lineRect: CGRect?, size cardSize: CGSize) -> [Slot]? {
        let width = cardSize.width
        guard let line = lineRect, width > 0 else { return nil }
        let leftWidth = min(line.minX - 2 * margin, maxGlossWidth)
        let rightWidth = min(width - line.maxX - 2 * margin, maxGlossWidth)
        let leftFits = leftWidth >= minColumnWidth
        let rightFits = rightWidth >= minColumnWidth
        guard leftFits || rightFits else { return nil }
        let sorted = bubbles.sorted { $0.anchor.midX < $1.anchor.midX }
        // The sides share the words evenly, the leftmost half going left (all of them to the one
        // side with room when only one has).
        let leftCount = leftFits && rightFits ? (sorted.count + 1) / 2 : (leftFits ? sorted.count : 0)
        var slots: [Slot] = []
        for isLeft in [true, false] {
            // The side's words, nearest the edge first.
            let side = isLeft ? Array(sorted.prefix(leftCount)) : Array(sorted.dropFirst(leftCount))
            let fromEdge = isLeft ? side : side.reversed()
            let columnWidth = isLeft ? leftWidth : rightWidth
            // A bubble's x: hugging the line's edge on this side.
            func x(for size: CGSize) -> CGFloat { isLeft ? line.minX - margin - size.width : line.maxX + margin }
            // The meanings of `words` in order.
            func entries(_ words: [PlacedLyricWordBubble]) -> [(bubble: PlacedLyricWordBubble, text: String, size: CGSize)] {
                words.compactMap { bubble in
                    bubble.gloss.map { (bubble, $0, size($0, maxWidth: min(columnWidth, maxGlossWidth))) }
                }
            }

            // The level bubble: the edge word's meaning, centred on the line.
            var top = line.minY
            var bottom = line.maxY
            var rest = fromEdge
            if let edgeWord = fromEdge.first, let gloss = edgeWord.gloss {
                let size = size(gloss, maxWidth: min(columnWidth, maxGlossWidth))
                let frame = CGRect(x: x(for: size), y: line.midY - size.height / 2, width: size.width, height: size.height)
                slots.append(Slot(
                    id: edgeWord.id,
                    text: gloss,
                    frame: frame,
                    tip: CGPoint(x: isLeft ? edgeWord.anchor.minX - 1 : edgeWord.anchor.maxX + 1, y: line.midY)
                ))
                top = min(frame.minY, line.minY)
                bottom = max(frame.maxY, line.maxY)
                rest = Array(fromEdge.dropFirst())
            }

            // Earlier words (in sung order) up, later ones down, half each; an odd one out goes
            // down on the left and up on the right, so above and below stay even overall.
            let sung = rest.sorted { $0.anchor.midX < $1.anchor.midX }
            let splitAt = isLeft ? sung.count / 2 : (sung.count + 1) / 2
            let upWords = Set(sung.prefix(splitAt).map(\.id))
            for isAbove in [true, false] {
                let words = rest.filter { upWords.contains($0.id) == isAbove }
                var edge = isAbove ? min(top - stackGap, line.minY - lineClearance) : max(bottom + stackGap, line.maxY + lineClearance)
                for entry in entries(words) {
                    let y = isAbove ? edge - entry.size.height : edge
                    guard y >= -sideOverflow, y + entry.size.height <= cardSize.height + sideOverflow else { return nil }
                    slots.append(Slot(
                        id: entry.bubble.id,
                        text: entry.text,
                        frame: CGRect(x: x(for: entry.size), y: y, width: entry.size.width, height: entry.size.height),
                        tip: CGPoint(x: entry.bubble.anchor.midX, y: isAbove ? line.minY - 1 : line.maxY + 1)
                    ))
                    edge = isAbove ? y - stackGap : y + entry.size.height + stackGap
                }
            }
        }

        return slots
    }

    // The fallback for a line too wide to leave room beside it: meanings in rows above and below
    // the line, each centred on its word, its tail reaching the word. Words alternate which side
    // they try first, so the two sides stay even; a bubble takes the nearest row on either side
    // with room at its place, else opens a new row on the side with fewer, so bubbles never overlap.
    static func stackedLayout(_ bubbles: [PlacedLyricWordBubble], width: CGFloat) -> [Slot] {
        guard width > 0 else { return [] }
        let lineTop = bubbles.map(\.anchor.minY).min() ?? 0
        let lineBottom = bubbles.map(\.anchor.maxY).max() ?? 0
        // Rows sit one tallest bubble (plus tail room) apart, since long ones wrap.
        let rowStep = bubbles.compactMap(\.gloss)
            .map { size($0, maxWidth: min(width, maxGlossWidth)).height + 12 }
            .max() ?? rowHeight
        // Each row's right end, nearest the line first.
        var aboveEnds: [CGFloat] = []
        var belowEnds: [CGFloat] = []
        var slots: [Slot] = []
        var placed = 0
        for bubble in bubbles.sorted(by: { $0.anchor.midX < $1.anchor.midX }) {
            guard let text = bubble.gloss else { continue }
            let size = size(text, maxWidth: min(width, maxGlossWidth))
            let x = min(max(0, bubble.anchor.midX - size.width / 2), max(0, width - size.width))
            let prefersAbove = placed % 2 == 0
            placed += 1
            // Rows in the order tried: nearest first, the preferred side before the other.
            var choice: (above: Bool, row: Int)?
            for row in 0..<max(aboveEnds.count, belowEnds.count) where choice == nil {
                for above in [prefersAbove, !prefersAbove] {
                    let ends = above ? aboveEnds : belowEnds
                    if row < ends.count, ends[row] + gap <= x {
                        choice = (above, row)
                        break
                    }
                }
            }
            if choice == nil {
                let above = aboveEnds.count == belowEnds.count ? prefersAbove : aboveEnds.count < belowEnds.count
                if above { aboveEnds.append(-gap) } else { belowEnds.append(-gap) }
                choice = (above, above ? aboveEnds.count - 1 : belowEnds.count - 1)
            }
            guard let (above, row) = choice else { continue }
            if above { aboveEnds[row] = x + size.width } else { belowEnds[row] = x + size.width }
            let offset = 10 + CGFloat(row) * rowStep
            slots.append(Slot(
                id: bubble.id,
                text: text,
                frame: CGRect(x: x, y: above ? lineTop - offset - size.height : lineBottom + offset, width: size.width, height: size.height),
                tip: CGPoint(x: bubble.anchor.midX, y: above ? bubble.anchor.minY - 1 : bubble.anchor.maxY + 1)
            ))
        }
        return slots
    }
}
