import Foundation

// Prints boundary diffs between segmentation backends to the console for debugging.
// Compares Trie vs IPAdic, then IPAdic vs UniDic.
enum SegmentationDiffPrinter {

    // Runs all three backends on the given text and prints boundary diffs to the console.
    static func printDiffs(for text: String, trieSegmenter: any TextSegmenting) {
        guard text.isEmpty == false else { return }

        let trieSegments = trieSegmenter.longestMatchEdges(for: text).map(\.surface)

        let ipadicSegments: [String]?
        if let mecab = MeCabSegmenter(dictionary: .ipadic) {
            ipadicSegments = mecab.longestMatchEdges(for: text).map(\.surface)
        } else {
            ipadicSegments = nil
        }

        let unidicSegments: [String]?
        if let mecab = MeCabSegmenter(dictionary: .unidic) {
            unidicSegments = mecab.longestMatchEdges(for: text).map(\.surface)
        } else {
            unidicSegments = nil
        }

        if let ipadic = ipadicSegments {
            printPairDiff(leftName: "Trie", leftSegments: trieSegments, rightName: "IPAdic", rightSegments: ipadic)
        }

        if let ipadic = ipadicSegments, let unidic = unidicSegments {
            printPairDiff(leftName: "IPAdic", leftSegments: ipadic, rightName: "UniDic", rightSegments: unidic)
        }
    }

    // Prints a single pair diff, showing only segments that differ between the two backends.
    private static func printPairDiff(leftName: String, leftSegments: [String], rightName: String, rightSegments: [String]) {
        if leftSegments == rightSegments {
            print("[\(leftName) → \(rightName)] identical")
            return
        }

        print("[\(leftName) → \(rightName)]")
        print("  \(leftName):  \(leftSegments.joined(separator: " | "))")
        print("  \(rightName): \(rightSegments.joined(separator: " | "))")
    }
}
