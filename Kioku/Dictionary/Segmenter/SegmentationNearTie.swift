import Foundation

// A place where the path search's choice was close: the span of one segment or two neighbouring
// segments, how the segmenter cut it, the cheapest other way to cut it, and how much more that
// alternative costs (centi-nats, from Segmenter.splitCosts). A small margin marks a low-confidence
// cut, the kind worth a second opinion. Produced by Segmenter.nearTies.
nonisolated struct SegmentationNearTie: Sendable {
    let range: Range<String.Index>
    let chosen: [String]
    let alternative: [String]
    let margin: Int
}
