import Foundation

// Prints three-way segmentation diffs to the console for debugging.
// Shows only regions where any of the three backends (Trie, IPAdic, UniDic) disagree.
enum SegmentationDiffPrinter {

    // Filters whitespace-only segments that MeCab skips but the Trie segmenter emits.
    private static func stripWhitespace(_ segments: [String]) -> [String] {
        segments.filter { $0.contains(where: { !$0.isWhitespace && !$0.isNewline }) }
    }

    // Runs all three backends on the given text and prints a unified three-way diff.
    static func printDiffs(for text: String, trieSegmenter: any TextSegmenting) {
        guard text.isEmpty == false else { return }

        let trie = stripWhitespace(trieSegmenter.longestMatchEdges(for: text).map(\.surface))

        let ipadic: [String]?
        if let mecab = MeCabSegmenter(dictionary: .ipadic) {
            ipadic = stripWhitespace(mecab.longestMatchEdges(for: text).map(\.surface))
        } else {
            print("[SegmentationDiff] IPAdic dictionary not available — skipping")
            ipadic = nil
        }

        let unidic: [String]?
        if let mecab = MeCabSegmenter(dictionary: .unidic) {
            unidic = stripWhitespace(mecab.longestMatchEdges(for: text).map(\.surface))
        } else {
            print("[SegmentationDiff] UniDic dictionary not available — skipping")
            unidic = nil
        }

        // NLTokenizer is always available — no external dictionary needed.
        let nlTokenizer = stripWhitespace(NLTokenizerSegmenter().longestMatchEdges(for: text).map(\.surface))

        // Build the list of named segmentations that are available.
        var named: [(name: String, segments: [String])] = [("Trie", trie)]
        if let ipadic { named.append(("IPAdic", ipadic)) }
        if let unidic { named.append(("UniDic", unidic)) }
        named.append(("NLTokenizer", nlTokenizer))

        guard named.count >= 2 else { return }

        printThreeWayDiff(named)
    }

    // Walks all segmentations in lockstep, emitting divergent regions where any backend disagrees.
    private static func printThreeWayDiff(_ named: [(name: String, segments: [String])]) {
        let count = named.count
        // Parallel cursors: index into each segmentation's segment array.
        var indices = Array(repeating: 0, count: count)
        // Parallel character offsets tracking how far each cursor has consumed.
        var offsets = Array(repeating: 0, count: count)

        var divergences: [[(name: String, span: [String])]] = []

        let lengths = named.map(\.segments.count)

        // Continue while at least two backends still have segments.
        var active: Bool { indices.enumerated().filter { $0.element < lengths[$0.offset] }.count >= 2 }

        while active {
            // Compute the next boundary for each backend.
            var ends: [Int] = []
            for i in 0..<count {
                if indices[i] < lengths[i] {
                    ends.append(offsets[i] + named[i].segments[indices[i]].count)
                } else {
                    ends.append(Int.max)
                }
            }

            // Check if all active backends agree on the next boundary.
            let activeEnds = ends.filter { $0 != Int.max }
            let allSame = activeEnds.allSatisfy { $0 == activeEnds[0] }

            if allSame {
                // All boundaries align — advance everyone by one segment.
                for i in 0..<count {
                    if indices[i] < lengths[i] {
                        offsets[i] = ends[i]
                        indices[i] += 1
                    }
                }
            } else {
                // Divergence — collect segments from each backend until boundaries re-align.
                var spans: [[String]] = Array(repeating: [], count: count)
                var positions = offsets

                var resolved = false
                while !resolved {
                    // Advance each backend by one segment.
                    for i in 0..<count {
                        if indices[i] < lengths[i] {
                            spans[i].append(named[i].segments[indices[i]])
                            positions[i] += named[i].segments[indices[i]].count
                            indices[i] += 1
                        }
                    }

                    // Keep advancing backends that are behind the max position.
                    let maxPos = positions.max() ?? 0
                    var advanced = true
                    while advanced {
                        advanced = false
                        for i in 0..<count {
                            while positions[i] < maxPos, indices[i] < lengths[i] {
                                spans[i].append(named[i].segments[indices[i]])
                                positions[i] += named[i].segments[indices[i]].count
                                indices[i] += 1
                                advanced = true
                            }
                        }
                    }

                    // Check if all active backends have reached the same position.
                    let activePositions = (0..<count).compactMap { indices[$0] <= lengths[$0] ? positions[$0] : nil }
                    resolved = Set(activePositions).count <= 1
                }

                offsets = positions

                // Only record this divergence if not all spans are identical.
                let spanStrings = spans.map { $0.joined(separator: " | ") }
                if Set(spanStrings).count > 1 {
                    var entry: [(name: String, span: [String])] = []
                    for i in 0..<count {
                        entry.append((name: named[i].name, span: spans[i]))
                    }
                    divergences.append(entry)
                }
            }
        }

        if divergences.isEmpty {
            let names = named.map(\.name).joined(separator: " / ")
            print("[Segmentation] \(names): identical")
            return
        }

        let maxNameLen = named.map(\.name.count).max() ?? 0
        let names = named.map(\.name).joined(separator: " / ")
        // print("[Segmentation] \(names): \(divergences.count) difference\(divergences.count == 1 ? "" : "s"):")
        /*
        for (i, entry) in divergences.enumerated() {
            let text = entry[0].span.joined()
            print("  \(i + 1). 「\(text)」")
            for item in entry {
                let padded = item.name.padding(toLength: maxNameLen, withPad: " ", startingAt: 0)
                print("     \(padded): \(item.span.joined(separator: " | "))")
            }
        }
        */
    }
}
