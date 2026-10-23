import Foundation

extension LineFuriganaCache {
    // Cuts the line into one piece per segment, each carrying the furigana that falls inside it
    // re-based to the piece's own text, so a breakdown card can lay its segments out one per line.
    // Text between segments (unsegmented spaces or punctuation) becomes a piece of its own so the
    // pieces always cover the whole line.
    func segmentPieces() -> [SongLineSegmentPiece] {
        let text = sourceText as NSString
        let segmentNSRanges = segmentationRanges
            .map { NSRange($0, in: sourceText) }
            .sorted { $0.location < $1.location }
        var spans: [NSRange] = []
        var cursor = 0
        for range in segmentNSRanges where range.location >= cursor && range.length > 0 {
            if range.location > cursor {
                spans.append(NSRange(location: cursor, length: range.location - cursor))
            }
            spans.append(range)
            cursor = range.location + range.length
        }
        if cursor < text.length {
            spans.append(NSRange(location: cursor, length: text.length - cursor))
        }
        return spans.map { span in
            let pieceText = text.substring(with: span)
            var byLocation: [Int: String] = [:]
            var lengthByLocation: [Int: Int] = [:]
            for (location, reading) in furiganaBySegmentLocation
            where location >= span.location && location < span.location + span.length {
                byLocation[location - span.location] = reading
                lengthByLocation[location - span.location] = furiganaLengthBySegmentLocation[location]
            }
            return SongLineSegmentPiece(
                location: span.location,
                cache: LineFuriganaCache(
                    sourceText: pieceText,
                    segmentationRanges: [pieceText.startIndex..<pieceText.endIndex],
                    furiganaBySegmentLocation: byLocation,
                    furiganaLengthBySegmentLocation: lengthByLocation
                )
            )
        }
    }
}
