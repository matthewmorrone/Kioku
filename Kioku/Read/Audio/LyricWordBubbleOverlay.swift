import SwiftUI
import UIKit

// Renders the lyrics card's word bubbles: comic-style white speech bubbles, one per word holding
// its meaning, plus one holding the breakdown's grammar note for the line on its last word. Each
// bubble's tail runs all the way to its word. The meanings go in the empty space beside the line —
// each side taking half the words, one level with the line and the rest split above and below it so
// tails never cross the text — and the note goes below the line (sideLayout), free to run past the card's top and bottom since the
// neighbouring lines are centred too. When the line is too wide to leave room beside it, they go
// in rows above (meanings) and below (notes) it instead, over the neighbouring lines; the card
// never grows for them. Places are planned for the whole line, so each bubble pops in where it stays. Sits over the renderer in its coordinates (rects from
// KiokuScrollingTextView.reportRangeRects). Ignores touches.
struct LyricWordBubbleOverlay: View {
    let bubbles: [PlacedLyricWordBubble]
    // The whole line's rect, for the room beside it; nil before it's measured.
    let lineRect: CGRect?

    static let glossFont = UIFont.systemFont(ofSize: 12, weight: .medium)
    static let commentFont = UIFont.italicSystemFont(ofSize: 11)
    static let horizontalPadding: CGFloat = 12
    static let verticalPadding: CGFloat = 7
    static let cornerRadius: CGFloat = 14
    static let gap: CGFloat = 8
    static let margin: CGFloat = 8
    // Narrowest side room the side layout uses; bubbles there wrap between words.
    static let minColumnWidth: CGFloat = 52
    static let maxGlossWidth: CGFloat = 150
    static let maxCommentWidth: CGFloat = 220
    // How far a side stack may run past the card's top or bottom.
    static let sideOverflow: CGFloat = 220
    // Least space between the line and a stacked side bubble, and between stacked bubbles.
    static let lineClearance: CGFloat = 4
    static let stackGap: CGFloat = 10
    static let stackedRows = 2
    // Height of a one-line bubble row in the above/below layout, which leaves room for the tail.
    static var rowHeight: CGFloat { ceil(glossFont.lineHeight) + 2 * verticalPadding + 12 }

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
            // Laid out for every word of the line, drawn only for those shown, so a bubble's place
            // is fixed before it appears.
            let side = Self.sideLayout(bubbles, lineRect: lineRect, size: proxy.size)
            let shownIDs = Set(bubbles.filter(\.isShown).map(\.id))
            let slots = (side ?? Self.stackedLayout(bubbles, width: proxy.size.width))
                .filter { shownIDs.contains($0.id / 2) }
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

    // One white bubble with its tail, and its text in the body (a note's in grey italics).
    private func bubble(_ slot: Slot, in size: CGSize) -> some View {
        ZStack(alignment: .topLeading) {
            PointerBubbleShape(body: slot.frame, tip: slot.tip, cornerRadius: Self.cornerRadius)
                .fill(Color.white)
                .shadow(color: .black.opacity(0.35), radius: 3, y: 1)
                .frame(width: size.width, height: size.height)
            Text(Self.displayText(slot.text))
                .font(Font(slot.isNote ? Self.commentFont : Self.glossFont))
                .foregroundStyle(slot.isNote ? Color(white: 0.35) : Color.black)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, Self.horizontalPadding)
                .frame(width: slot.frame.width, height: slot.frame.height)
                .position(x: slot.frame.midX, y: slot.frame.midY)
        }
        .transition(.scale(scale: 0.4, anchor: .center).combined(with: .opacity))
    }

    // A bubble's text with its inline markdown applied (a breakdown note's *emphasis*), so the
    // asterisks aren't drawn; the plain text when it doesn't parse.
    static func displayText(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
    }

    // A bubble body's size for its text: padded and capped at `maxWidth`, wrapping between words onto
    // as many lines as it takes, and never narrower than its longest word so no word is broken.
    private static func size(_ markdown: String, note: Bool, maxWidth: CGFloat) -> CGSize {
        let text = String(displayText(markdown).characters)
        let font = note ? commentFont : glossFont
        let attributes: [NSAttributedString.Key: Any] = [.font: font]
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
    // edge, so tails nest instead of crossing. Notes are too long for a side column (they'd wrap
    // into a tower running off the card), so they go below the line instead, as wide as
    // maxCommentWidth allows, under whatever the columns put there.
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
            func entries(_ words: [PlacedLyricWordBubble]) -> [(bubble: PlacedLyricWordBubble, text: String, note: Bool, size: CGSize)] {
                words.compactMap { bubble in
                    bubble.gloss.map { (bubble, $0, false, size($0, note: false, maxWidth: min(columnWidth, maxGlossWidth))) }
                }
            }

            // The level bubble: the edge word's meaning, centred on the line.
            var top = line.minY
            var bottom = line.maxY
            var rest = fromEdge
            if let edgeWord = fromEdge.first, let gloss = edgeWord.gloss {
                let size = size(gloss, note: false, maxWidth: min(columnWidth, maxGlossWidth))
                let frame = CGRect(x: x(for: size), y: line.midY - size.height / 2, width: size.width, height: size.height)
                slots.append(Slot(
                    id: edgeWord.id * 2,
                    text: gloss,
                    isNote: false,
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
                        id: entry.bubble.id * 2 + (entry.note ? 1 : 0),
                        text: entry.text,
                        isNote: entry.note,
                        frame: CGRect(x: x(for: entry.size), y: y, width: entry.size.width, height: entry.size.height),
                        tip: CGPoint(x: entry.bubble.anchor.midX, y: isAbove ? line.minY - 1 : line.maxY + 1)
                    ))
                    edge = isAbove ? y - stackGap : y + entry.size.height + stackGap
                }
            }
        }

        // The notes, below the line: centred on their word where the card allows, each under the
        // lowest bubble already placed across its span so nothing overlaps.
        for word in sorted {
            guard let comment = word.comment else { continue }
            let size = size(comment, note: true, maxWidth: min(width - 2 * margin, maxCommentWidth))
            let x = min(max(margin, word.anchor.midX - size.width / 2), max(margin, width - margin - size.width))
            let y = slots
                .filter { $0.frame.maxY > line.maxY && $0.frame.maxX + gap > x && $0.frame.minX - gap < x + size.width }
                .map { $0.frame.maxY + stackGap }
                .reduce(line.maxY + 10, max)
            guard y + size.height <= cardSize.height + sideOverflow else { return nil }
            slots.append(Slot(
                id: word.id * 2 + 1,
                text: comment,
                isNote: true,
                frame: CGRect(x: x, y: y, width: size.width, height: size.height),
                tip: CGPoint(x: word.anchor.midX, y: line.maxY + 1)
            ))
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
            // Rows sit one tallest bubble (plus tail room) apart, since long ones wrap.
            let rowStep = bubbles.compactMap { note ? $0.comment : $0.gloss }
                .map { size($0, note: note, maxWidth: min(width, note ? maxCommentWidth : maxGlossWidth)).height + 12 }
                .max() ?? rowHeight
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
                let offset = 10 + CGFloat(row) * rowStep
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
