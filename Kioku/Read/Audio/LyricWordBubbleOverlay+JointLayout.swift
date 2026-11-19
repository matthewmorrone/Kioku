import SwiftUI

// The word bubbles' joint planner: lays out every bubble of a line at once. Within a row it finds
// the positions closest to each word that keep the bubbles apart (an isotonic fit), so the row
// spreads evenly about its words instead of the first bubble sitting over the first word and the
// rest being pushed along. Words are dealt across 1…n rows (alternating sides unless everything
// goes above) and the arrangement with the least total drift and fewest rows that fits wins.
extension LyricWordBubbleOverlay {
    // The planned slots for every glossed bubble, or nil when no arrangement fits the room (the
    // caller then falls back to the first-in, first-out queue).
    static func jointLayout(_ bubbles: [PlacedLyricWordBubble], size cardSize: CGSize, roomAbove: CGFloat, roomBelow: CGFloat, belowInset: CGFloat, aboveOnly: Bool) -> [Slot]? {
        let width = cardSize.width
        let glossed = bubbles.filter { $0.gloss != nil }.sorted { $0.anchor.midX < $1.anchor.midX }
        guard width > 0, glossed.isEmpty == false else { return nil }
        let lineTop = bubbles.map(\.anchor.minY).min() ?? 0
        let lineBottom = bubbles.map(\.anchor.maxY).max() ?? 0
        let spaceAbove = lineTop + roomAbove
        let spaceBelow = aboveOnly ? -CGFloat.greatestFiniteMagnitude : cardSize.height + roomBelow - lineBottom - belowInset
        let isWrapped = Self.isWrapped(bubbles)
        let midline = (lineTop + lineBottom) / 2

        // Which side each bubble takes: all above, or alternating (a wrapped line's upper words above).
        var sideIsAbove: [Int: Bool] = [:]
        for (index, bubble) in glossed.enumerated() {
            sideIsAbove[bubble.id] = aboveOnly ? true : (isWrapped ? bubble.anchor.midY < midline : index % 2 == 0)
        }
        let sizes = Dictionary(uniqueKeysWithValues: glossed.map { ($0.id, size($0.gloss ?? "", maxWidth: min(width, maxGlossWidth))) })

        var best: (slots: [Slot], cost: CGFloat)?
        for rowsPerSide in 1 ... 4 {
            var slots: [Slot] = []
            var drift: CGFloat = 0
            var feasible = true
            for isAbove in [true, false] {
                let group = glossed.filter { sideIsAbove[$0.id] == isAbove }
                guard group.isEmpty == false else { continue }
                // Dealt round-robin, so neighbouring words land in different rows and each row's
                // bubbles are far enough apart to sit over their own words.
                var rows: [[PlacedLyricWordBubble]] = Array(repeating: [], count: rowsPerSide)
                for (index, bubble) in group.enumerated() { rows[index % rowsPerSide].append(bubble) }
                rows.removeAll { $0.isEmpty }
                var placedRows: [[Slot]] = []
                for row in rows {
                    guard let centres = spreadCentres(for: row, sizes: sizes, width: width) else { feasible = false; break }
                    var rowSlots: [Slot] = []
                    for (bubble, centre) in zip(row, centres) {
                        let bubbleSize = sizes[bubble.id] ?? .zero
                        drift += abs(centre - bubble.anchor.midX)
                        rowSlots.append(Slot(
                            id: bubble.id,
                            text: bubble.gloss ?? "",
                            frame: CGRect(x: centre - bubbleSize.width / 2, y: 0, width: bubbleSize.width, height: bubbleSize.height),
                            tip: CGPoint(x: bubble.anchor.midX, y: isAbove ? bubble.anchor.minY - 1 : bubble.anchor.maxY + 1)
                        ))
                    }
                    placedRows.append(rowSlots)
                }
                guard feasible else { break }
                // Rows stack outward from the line, each as tall as its tallest bubble plus tail room.
                let heights = placedRows.map { $0.map(\.frame.height).max() ?? 0 }
                let needed = 10 + heights.reduce(0, +) + 12 * CGFloat(max(0, heights.count - 1))
                guard needed <= (isAbove ? spaceAbove : spaceBelow) else { feasible = false; break }
                var offset: CGFloat = 10
                for (row, rowHeight) in zip(placedRows, heights) {
                    for slot in row {
                        let y = isAbove ? lineTop - offset - slot.frame.height : lineBottom + belowInset + offset
                        slots.append(Slot(id: slot.id, text: slot.text, frame: CGRect(x: slot.frame.minX, y: y, width: slot.frame.width, height: slot.frame.height), tip: slot.tip))
                    }
                    offset += rowHeight + 12
                }
            }
            guard feasible else { continue }
            // Tails may pass behind nearer bubbles when everything is above (they are drawn
            // farthest first); otherwise none may cross.
            if aboveOnly == false, hasCrossing(slots) { continue }
            // Each extra row costs about a bubble's height of clutter.
            let usedRows = Set(slots.map { $0.frame.minY.rounded() }).count
            let cost = drift + CGFloat(usedRows) * 24
            if best == nil || cost < best!.cost { best = (slots, cost) }
        }
        return best?.slots.sorted { $0.id < $1.id }
    }

    // Bubble centres for one row (words left to right): the positions nearest each word's centre
    // that keep neighbours a gap apart and the row inside the card. Nil when the row is too wide.
    // Subtracting each bubble's minimum offset from the first turns the spacing rule into "centres
    // never decrease", which pool-adjacent-violators solves exactly; clamping that result to the
    // card edges keeps it optimal.
    private static func spreadCentres(for row: [PlacedLyricWordBubble], sizes: [Int: CGSize], width: CGFloat) -> [CGFloat]? {
        let widths = row.map { sizes[$0.id]?.width ?? 0 }
        var offsets: [CGFloat] = [0]
        for index in 1 ..< max(1, widths.count) {
            offsets.append(offsets[index - 1] + (widths[index - 1] + widths[index]) / 2 + gap)
        }
        let targets = zip(row, offsets).map { $0.anchor.midX - $1 }
        // Pool adjacent violators: merge neighbouring blocks that decrease into their mean.
        var blocks: [(sum: CGFloat, count: Int)] = []
        for target in targets {
            blocks.append((target, 1))
            while blocks.count > 1, blocks[blocks.count - 2].sum / CGFloat(blocks[blocks.count - 2].count) > blocks[blocks.count - 1].sum / CGFloat(blocks[blocks.count - 1].count) {
                let last = blocks.removeLast()
                blocks[blocks.count - 1].sum += last.sum
                blocks[blocks.count - 1].count += last.count
            }
        }
        var fitted: [CGFloat] = []
        for block in blocks { fitted.append(contentsOf: Array(repeating: block.sum / CGFloat(block.count), count: block.count)) }
        let low = (widths.first ?? 0) / 2
        let high = width - (widths.last ?? 0) / 2 - (offsets.last ?? 0)
        guard low <= high else { return nil }
        return zip(fitted, offsets).map { min(max($0, low), high) + $1 }
    }
}
