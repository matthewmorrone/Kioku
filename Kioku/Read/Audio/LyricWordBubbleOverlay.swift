import SwiftUI
import UIKit

// Renders the lyrics card's word bubbles: comic-style white speech bubbles, one per word holding
// its meaning, each bubble's tail running all the way to its word. They go in rows above and
// below the line, alternating sides, over the neighbouring lines; the card never grows for them.
// Places are planned for the whole line, so each bubble pops in where it stays. Sits over the
// renderer in its coordinates (rects from KiokuScrollingTextView.reportRangeRects). Ignores touches.
struct LyricWordBubbleOverlay: View {
    let bubbles: [PlacedLyricWordBubble]
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
    // Widest a bubble gets; longer meanings wrap between words.
    static let maxGlossWidth: CGFloat = 150
    // How far the above/below rows may run past the card: about what the lyrics panel shows.
    static let rowOverflow: CGFloat = 90

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
            let shownIDs = Set(bubbles.filter(\.isShown).map(\.id))
            let clip = proxy.frame(in: .named("lyricClip"))
            let measured = clipHeight > 0
            let roomAbove = measured ? max(0, clip.minY) : verticalRoom
            let roomBelow = measured ? max(0, clipHeight - clip.maxY) : verticalRoom
            let slots = Self.stackedLayout(
                bubbles,
                shown: shownIDs,
                size: proxy.size,
                roomAbove: roomAbove,
                roomBelow: roomBelow
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
    // height. Then a bubble's tail may run across the other lines' text, so a word's own text
    // line decides its side whenever the sides are tied.
    static func isWrapped(_ bubbles: [PlacedLyricWordBubble]) -> Bool {
        guard let top = bubbles.map(\.anchor.minY).min(), let bottom = bubbles.map(\.anchor.maxY).max() else { return false }
        let wordHeight = bubbles.map(\.anchor.height).max() ?? 0
        return bottom - top > wordHeight * 1.6
    }

    // Whether any bubble's tail (from where it leaves its body to its tip) crosses another tail or
    // runs through another bubble, so the layouts can keep the arrows apart.
    static func hasCrossing(_ slots: [Slot]) -> Bool {
        let tails: [(id: Int, from: CGPoint, to: CGPoint)] = slots.compactMap { slot in
            PointerBubbleShape.tailRoot(body: slot.frame, tip: slot.tip, cornerRadius: cornerRadius).map { (slot.id, $0.edge, slot.tip) }
        }
        // Whether segment a–b properly crosses segment c–d (each end on opposite sides of the other).
        func cross(_ a: CGPoint, _ b: CGPoint, _ c: CGPoint, _ d: CGPoint) -> Bool {
            // Which side of p–q the point r lies on (the sign of the cross product).
            func turn(_ p: CGPoint, _ q: CGPoint, _ r: CGPoint) -> CGFloat { (q.x - p.x) * (r.y - p.y) - (q.y - p.y) * (r.x - p.x) }
            return turn(a, b, c) * turn(a, b, d) < 0 && turn(c, d, a) * turn(c, d, b) < 0
        }
        for (index, tail) in tails.enumerated() {
            for other in tails[(index + 1)...] where cross(tail.from, tail.to, other.from, other.to) { return true }
            for slot in slots where slot.id != tail.id {
                let body = slot.frame.insetBy(dx: 1, dy: 1)
                let corners = [CGPoint(x: body.minX, y: body.minY), CGPoint(x: body.maxX, y: body.minY), CGPoint(x: body.maxX, y: body.maxY), CGPoint(x: body.minX, y: body.maxY)]
                if body.contains(tail.to) || body.contains(tail.from) { return true }
                for edge in 0..<4 where cross(tail.from, tail.to, corners[edge], corners[(edge + 1) % 4]) { return true }
            }
        }
        return false
    }

    // The layout: meanings in rows above and below
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
        // The room each side leaves past the line. A row is as tall as its own tallest bubble (plus
        // tail room), so one long meaning doesn't make every row that expensive.
        let spaceAbove = lineTop + roomAbove
        let spaceBelow = cardSize.height + roomBelow - lineBottom
        // Whether `rows` (nearest the line first) stack within `space`, so no bubble is clipped.
        func rowsFit(_ rows: [[Slot]], space: CGFloat) -> Bool {
            let heights = rows.filter { $0.isEmpty == false }.map { $0.map(\.frame.height).max() ?? 0 }
            guard heights.isEmpty == false else { return true }
            return 10 + heights.reduce(0, +) + 12 * CGFloat(heights.count - 1) <= space
        }
        // The rows' bubbles with their y set: rows stack outward from the line, each as tall as its
        // tallest bubble plus tail room.
        func placedSlots(_ rows: [[Slot]], isAbove: Bool) -> [Slot] {
            var result: [Slot] = []
            var offset: CGFloat = 10
            for row in rows where row.isEmpty == false {
                for slot in row {
                    let y = isAbove ? lineTop - offset - slot.frame.height : lineBottom + offset
                    result.append(Slot(id: slot.id, text: slot.text, frame: CGRect(x: slot.frame.minX, y: y, width: slot.frame.width, height: slot.frame.height), tip: slot.tip))
                }
                offset += (row.map(\.frame.height).max() ?? 0) + 12
            }
            return result
        }
        // Whether `rows` fit the room and no tail crosses another tail or a bubble.
        func accepts(_ rows: [[Slot]], isAbove: Bool) -> Bool {
            rowsFit(rows, space: isAbove ? spaceAbove : spaceBelow) && hasCrossing(placedSlots(rows, isAbove: isAbove)) == false
        }
        // `rows` with `slot` added to `row` (a new last row when `row` is past the end).
        func adding(_ slot: Slot, toRow row: Int, of rows: [[Slot]]) -> [[Slot]] {
            var result = rows
            if row < result.count { result[row].append(slot) } else { result.append([slot]) }
            return result
        }
        // The bubbles currently up in each row, nearest the line first.
        var above: [[Slot]] = []
        var below: [[Slot]] = []
        var placed = 0
        // A wrapped line is several text lines, so some arrows run across other lines' text; the
        // bubbles still alternate above and below, a tie going to the side the word's own line faces.
        let isWrapped = Self.isWrapped(bubbles)
        for bubble in all.sorted(by: { $0.id < $1.id }) {
            guard let text = bubble.gloss else { continue }
            let size = size(text, maxWidth: min(width, maxGlossWidth))
            let x = min(max(0, bubble.anchor.midX - size.width / 2), max(0, width - size.width))
            // The side with fewer bubbles up, so they alternate above and below; on a tie, the side
            // the word's text line faces on a wrapped line (upper half above), else the next in turn.
            let aboveUp = above.reduce(0) { $0 + $1.count }
            let belowUp = below.reduce(0) { $0 + $1.count }
            let prefersAbove = aboveUp != belowUp
                ? aboveUp < belowUp
                : (isWrapped ? bubble.anchor.midY < (lineTop + lineBottom) / 2 : placed % 2 == 0)
            let preferredSides = [prefersAbove, !prefersAbove]
            placed += 1
            // Where this bubble can sit in `row` clear of the bubbles already up there: over its word,
            // else slid sideways (its tail slanting back to the word) to the
            // nearest gap. Nil when the row has no such place.
            func freeX(_ row: [Slot]) -> CGFloat? {
                let candidates = [x] + row.flatMap { [$0.frame.minX - gap - size.width, $0.frame.maxX + gap] }
                return candidates
                    .map { min(max(0, $0), max(0, width - size.width)) }
                    .filter { candidate in
                        row.allSatisfy { $0.frame.maxX + gap <= candidate || candidate + size.width + gap <= $0.frame.minX }
                    }
                    .min { abs($0 - x) < abs($1 - x) }
            }
            // The bubble's body; its y is set once every row's height is known.
            func slot(at x: CGFloat, above isAbove: Bool) -> Slot {
                Slot(
                    id: bubble.id,
                    text: text,
                    frame: CGRect(x: x, y: 0, width: size.width, height: size.height),
                    tip: CGPoint(x: bubble.anchor.midX, y: isAbove ? bubble.anchor.minY - 1 : bubble.anchor.maxY + 1)
                )
            }
            // Sides where this bubble fits at all, the preferred one first. A wrapped line's bubble
            // fills the side its text line faces before the other (its arrow then crosses the line's
            // other text, which beats popping a bubble while room is left). One that fits nowhere is
            // skipped, not drawn clipped.
            func fits(_ isAbove: Bool) -> Bool { accepts([[slot(at: x, above: isAbove)]], isAbove: isAbove) }
            let sides = preferredSides.filter(fits)
            guard sides.isEmpty == false else { continue }
            var target: (isAbove: Bool, row: Int)?
            var placedX = x
            while target == nil {
                // The preferred side first: a free place in one of its rows, else a new row of its
                // own, before the other side is tried, so the bubbles alternate sides.
                for isAbove in sides where target == nil {
                    let rows = isAbove ? above : below
                    for row in 0..<rows.count where target == nil {
                        if let free = freeX(rows[row]),
                           accepts(adding(slot(at: free, above: isAbove), toRow: row, of: rows), isAbove: isAbove) {
                            target = (isAbove, row)
                            placedX = free
                        }
                    }
                    if target == nil, accepts(adding(slot(at: x, above: isAbove), toRow: rows.count, of: rows), isAbove: isAbove) {
                        if isAbove { above.append([]) } else { below.append([]) }
                        target = (isAbove, rows.count)
                    }
                }
                if target != nil {
                    break
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
                    // A row the pop emptied takes no room.
                    above.removeAll { $0.isEmpty }
                    below.removeAll { $0.isEmpty }
                }
            }
            guard let (isAbove, row) = target else { continue }
            let placedSlot = slot(at: placedX, above: isAbove)
            if isAbove {
                if row < above.count { above[row].append(placedSlot) } else { above.append([placedSlot]) }
            } else {
                if row < below.count { below[row].append(placedSlot) } else { below.append([placedSlot]) }
            }
        }
        let result = placedSlots(above, isAbove: true) + placedSlots(below, isAbove: false)
        return result.sorted { $0.id < $1.id }
    }
}
