import Foundation

// Lists how a note's segmentation and readings differ from what the segmenter and reading
// resolver would produce on their own, one change per line, in the compact notation the AI
// correction uses: `AB → A|B` for boundaries (default on the left), `A(B) → A(C)` for readings.
// Shown from a long-press on the Read tab's segment-list button.
nonisolated enum SegmentationChangeList {

    // Builds the change lines in text order. `defaultEdges` is the segmenter's own path for the
    // text; `defaultFurigana` is the resolver's reading for each of the CURRENT edges, so a merged
    // or split segment is only listed as a reading change when its reading was pinned away from
    // what the resolver gives that segment.
    static func lines(
        text: String,
        defaultEdges: [LatticeEdge],
        currentEdges: [LatticeEdge],
        defaultFurigana: (byLocation: [Int: String], lengthByLocation: [Int: Int]),
        currentFurigana: (byLocation: [Int: String], lengthByLocation: [Int: Int])
    ) -> [String] {
        let defaults = spans(of: defaultEdges, in: text)
        let currents = spans(of: currentEdges, in: text)
        var changes: [(location: Int, line: String)] = []

        // Boundary changes: walk both segmentations together and emit each stretch where their
        // boundaries disagree, from the first differing segment to the next shared boundary.
        var d = 0
        var c = 0
        while d < defaults.count, c < currents.count {
            if defaults[d].range == currents[c].range {
                d += 1
                c += 1
                continue
            }
            let groupStart = min(defaults[d].range.location, currents[c].range.location)
            var defaultGroup = [defaults[d]]
            var currentGroup = [currents[c]]
            d += 1
            c += 1
            var defaultEnd = NSMaxRange(defaultGroup[0].range)
            var currentEnd = NSMaxRange(currentGroup[0].range)
            while defaultEnd != currentEnd {
                if defaultEnd < currentEnd, d < defaults.count {
                    defaultGroup.append(defaults[d])
                    defaultEnd = NSMaxRange(defaults[d].range)
                    d += 1
                } else if currentEnd < defaultEnd, c < currents.count {
                    currentGroup.append(currents[c])
                    currentEnd = NSMaxRange(currents[c].range)
                    c += 1
                } else {
                    break
                }
            }
            let from = defaultGroup.map(\.surface).joined(separator: "|")
            let to = currentGroup.map(\.surface).joined(separator: "|")
            changes.append((groupStart, "\(from) → \(to)"))
        }

        // Reading changes: any current segment whose ruby differs from the resolver's default for it.
        for span in currents where ScriptClassifier.containsKanji(span.surface) {
            let from = annotated(span, furigana: defaultFurigana)
            let to = annotated(span, furigana: currentFurigana)
            if from != to {
                changes.append((span.range.location, "\(from) → \(to)"))
            }
        }

        return changes.sorted { $0.location < $1.location }.map(\.line)
    }

    // Each edge's UTF-16 range and surface, skipping edges that fall outside `text`.
    private static func spans(of edges: [LatticeEdge], in text: String) -> [(range: NSRange, surface: String)] {
        edges.compactMap { edge in
            let range = NSRange(edge.start..<edge.end, in: text)
            guard range.location != NSNotFound, range.length > 0 else { return nil }
            return (range, edge.surface)
        }
    }

    // `surface(reading)`: the segment's text with each ruby entry swapped in over the characters
    // it covers and kana kept as written (の様に → の様に(のように)); the bare surface when no
    // entry lies inside the segment.
    private static func annotated(
        _ span: (range: NSRange, surface: String),
        furigana: (byLocation: [Int: String], lengthByLocation: [Int: Int])
    ) -> String {
        var reading = ""
        var hasRuby = false
        var location = span.range.location
        var index = span.surface.startIndex
        while index < span.surface.endIndex {
            if let ruby = furigana.byLocation[location], ruby.isEmpty == false,
               let length = furigana.lengthByLocation[location], length > 0,
               location + length <= NSMaxRange(span.range) {
                reading += ruby
                hasRuby = true
                location += length
                index = span.surface.utf16.index(index, offsetBy: length)
            } else {
                let character = span.surface[index]
                reading.append(character)
                location += String(character).utf16.count
                index = span.surface.index(after: index)
            }
        }
        return hasRuby ? "\(span.surface)(\(reading))" : span.surface
    }
}
