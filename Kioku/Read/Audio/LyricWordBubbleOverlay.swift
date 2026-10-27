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
    // How far the rows above and below the line may run past the card: the lyrics panel's room
    // above and below it, so bubbles are only hidden once they've used all of it.
    var verticalRoom: CGFloat = LyricWordBubbleOverlay.rowOverflow
    // Height of the clipped lyric area (coordinate space "lyricClip") the overlay sits in; when
    // known, the rows use the room it really leaves above and below the line instead of verticalRoom.
    var clipHeight: CGFloat = 0

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
    // How far the above/below rows may run past the card: about what the lyrics panel shows.
    static let rowOverflow: CGFloat = 90
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
            let clip = proxy.frame(in: .named("lyricClip"))
            let measured = clipHeight > 0
            let slots = side.map { $0.filter { shownIDs.contains($0.id) } }
                ?? Self.stackedLayout(
                    bubbles,
                    shown: shownIDs,
                    size: proxy.size,
                    roomAbove: measured ? max(0, clip.minY) : verticalRoom,
                    roomBelow: measured ? max(0, clipHeight - clip.maxY) : verticalRoom
                )
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

    // Whether the line has wrapped onto more than one text line: its words span more than a word's
    // height. Then a bubble beside the line would run its tail across the other lines' text, so the
    // rows layout is used, each word's bubble on the side its own text line faces.
    static func isWrapped(_ bubbles: [PlacedLyricWordBubble]) -> Bool {
        guard let top = bubbles.map(\.anchor.minY).min(), let bottom = bubbles.map(\.anchor.maxY).max() else { return false }
        let wordHeight = bubbles.map(\.anchor.height).max() ?? 0
        return bottom - top > wordHeight * 1.6
    }

    // The beside-the-line layout, or nil when neither side has room, a bubble would run off the
    // card's side, or a stack would run further past the card than sideOverflow. The words are shared evenly between the sides, leftmost half
    // left (all on one side when only that side has room). There, the word nearest the edge gets its meaning level with the line, the tail
    // pointing straight into the word's side; the side's other words split between a stack rising
    // from that bubble and one falling from it (earlier words up, later down), each bubble kept
    // clear of the line so its tail drops onto the word's top or bottom through empty space, never
    // across the text. Within a stack the bubble nearest the line points at the word nearest the
    // edge, so tails nest instead of crossing.
    static func sideLayout(_ bubbles: [PlacedLyricWordBubble], lineRect: CGRect?, size cardSize: CGSize) -> [Slot]? {
        let width = cardSize.width
        guard let line = lineRect, width > 0, isWrapped(bubbles) == false else { return nil }
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

        // A bubble never narrows below its longest word, so a column squeezed by a wide line can hold
        // a bubble wider than itself, running off the card — then the rows layout takes over.
        guard slots.allSatisfy({ $0.frame.minX >= 0 && $0.frame.maxX <= width }) else { return nil }
        return slots
    }

    // The fallback for a line too wide to leave room beside it: meanings in rows above and below
    // the line, each centred on its word, its tail reaching the word. `bubbles` are the ones shown
    // so far; they're placed in the order they appeared (word order), each taking the nearest row
    // with room at its place, else opening a new row on the side with fewer. When every row the
    // panel has room for is taken, the oldest bubble is popped until the new one fits, so the
    // queue goes first in, first out. Replaying the same shown words gives the same places, so a
    // bubble never moves while it's up.
    static func stackedLayout(_ bubbles: [PlacedLyricWordBubble], shown: Set<Int>? = nil, size cardSize: CGSize, roomAbove: CGFloat = rowOverflow, roomBelow: CGFloat = rowOverflow) -> [Slot] {
        let width = cardSize.width
        guard width > 0 else { return [] }
        // The line's geometry (and whether it wraps) comes from every word, so a bubble's side and
        // row don't change as the line's other words appear.
        let all = bubbles.filter { $0.gloss != nil && (shown?.contains($0.id) ?? true) }
        guard all.isEmpty == false else { return [] }
        let lineTop = bubbles.map(\.anchor.minY).min() ?? 0
        let lineBottom = bubbles.map(\.anchor.maxY).max() ?? 0
        // Rows sit one tallest bubble (plus tail room) apart, since long ones wrap.
        let rowStep = all.compactMap(\.gloss)
            .map { size($0, maxWidth: min(width, maxGlossWidth)).height + 12 }
            .max() ?? rowHeight
        // Rows that fit within `room` of the card on each side.
        let aboveCap = max(1, Int((lineTop + roomAbove - 10) / rowStep))
        let belowCap = max(1, Int((cardSize.height + roomBelow - lineBottom - 10) / rowStep))
        // The bubbles currently up in each row, nearest the line first.
        var above: [[Slot]] = []
        var below: [[Slot]] = []
        var placed = 0
        // A wrapped line is several text lines: a bubble then stays on the side its word's own line
        // faces (upper half above, lower half below), so its tail never runs across other text.
        let isWrapped = Self.isWrapped(bubbles)
        for bubble in all.sorted(by: { $0.id < $1.id }) {
            guard let text = bubble.gloss else { continue }
            let size = size(text, maxWidth: min(width, maxGlossWidth))
            let x = min(max(0, bubble.anchor.midX - size.width / 2), max(0, width - size.width))
            let prefersAbove = isWrapped ? bubble.anchor.midY < (lineTop + lineBottom) / 2 : placed % 2 == 0
            let sides = isWrapped ? [prefersAbove] : [prefersAbove, !prefersAbove]
            placed += 1
            // Where this bubble can sit in `row` clear of the bubbles already up there: over its word,
            // else slid sideways (at most a bubble's width, its tail slanting back to the word) to the
            // nearest gap. Nil when the row has no such place.
            func freeX(_ row: [Slot]) -> CGFloat? {
                let candidates = [x] + row.flatMap { [$0.frame.minX - gap - size.width, $0.frame.maxX + gap] }
                return candidates
                    .map { min(max(0, $0), max(0, width - size.width)) }
                    .filter { candidate in
                        abs(candidate - x) <= size.width
                            && row.allSatisfy { $0.frame.maxX + gap <= candidate || candidate + size.width + gap <= $0.frame.minX }
                    }
                    .min { abs($0 - x) < abs($1 - x) }
            }
            var target: (isAbove: Bool, row: Int)?
            var placedX = x
            while target == nil {
                // The nearest row with room, the preferred side before the other.
                for row in 0..<max(above.count, below.count) where target == nil {
                    for isAbove in sides {
                        let rows = isAbove ? above : below
                        // A row further out needs its tail's way to the word clear of the nearer rows' bubbles.
                        let tailClear = rows.prefix(row).allSatisfy { nearer in
                            nearer.allSatisfy { bubble.anchor.midX < $0.frame.minX - 4 || bubble.anchor.midX > $0.frame.maxX + 4 }
                        }
                        if row < rows.count, tailClear, let free = freeX(rows[row]) {
                            target = (isAbove, row)
                            placedX = free
                            break
                        }
                    }
                }
                if target != nil { break }
                let aboveOpen = above.count < aboveCap && sides.contains(true)
                let belowOpen = below.count < belowCap && sides.contains(false)
                if aboveOpen || belowOpen {
                    let isAbove = aboveOpen && belowOpen
                        ? (above.count == below.count ? prefersAbove : above.count < below.count)
                        : aboveOpen
                    if isAbove { above.append([]) } else { below.append([]) }
                    target = (isAbove, isAbove ? above.count - 1 : below.count - 1)
                } else {
                    // No room anywhere: pop the oldest bubble and look again.
                    var oldest: (isAbove: Bool, row: Int, index: Int, id: Int)?
                    for (isAbove, rows) in [(true, above), (false, below)] where sides.contains(isAbove) {
                        for (row, slots) in rows.enumerated() {
                            for (index, slot) in slots.enumerated() where oldest == nil || slot.id < oldest!.id {
                                oldest = (isAbove, row, index, slot.id)
                            }
                        }
                    }
                    guard let oldest else { break }
                    if oldest.isAbove { above[oldest.row].remove(at: oldest.index) } else { below[oldest.row].remove(at: oldest.index) }
                }
            }
            guard let (isAbove, row) = target else { continue }
            let offset = 10 + CGFloat(row) * rowStep
            let slot = Slot(
                id: bubble.id,
                text: text,
                frame: CGRect(x: placedX, y: isAbove ? lineTop - offset - size.height : lineBottom + offset, width: size.width, height: size.height),
                tip: CGPoint(x: bubble.anchor.midX, y: isAbove ? bubble.anchor.minY - 1 : bubble.anchor.maxY + 1)
            )
            if isAbove { above[row].append(slot) } else { below[row].append(slot) }
        }
        return (above + below).flatMap { $0 }.sorted { $0.id < $1.id }
    }
}
