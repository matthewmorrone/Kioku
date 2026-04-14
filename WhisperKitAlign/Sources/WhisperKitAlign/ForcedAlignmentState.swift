// ForcedAlignmentState.swift
// Mutable state passed through the logits_filter_callback's void* user_data pointer.
// Tracks which token the decoder should emit next and where each lyric line
// begins in the flat token sequence.

import Foundation
import whisper_cpp

// Holds the forced-alignment cursor state that the logits filter callback
// reads and advances as the decoder emits tokens.
final class ForcedAlignmentState {
    // Flat array of all lyric tokens concatenated in line order.
    let tokenSequence: [whisper_token]

    // Token index where each lyric line begins in tokenSequence.
    // lineBoundaries[i] is the index of the first token of line i.
    // An extra sentinel equal to tokenSequence.count is appended
    // so line i spans tokenSequence[lineBoundaries[i] ..< lineBoundaries[i+1]].
    let lineBoundaries: [Int]

    // Current position in tokenSequence — the next text token the decoder must emit.
    var cursor: Int = 0

    // Whisper context pointer, needed inside the callback for whisper_token_beg / whisper_n_vocab.
    let ctx: OpaquePointer

    // Builds state by tokenizing each line with whisper_tokenize.
    // Throws if any line fails to tokenize.
    init(lines: [String], ctx: OpaquePointer) throws {
        self.ctx = ctx
        var sequence: [whisper_token] = []
        var boundaries: [Int] = []

        for line in lines {
            boundaries.append(sequence.count)

            // Allocate a generous buffer — Japanese text rarely exceeds 4 tokens per character.
            var tokens = [whisper_token](repeating: 0, count: line.utf8.count * 4 + 128)
            let count = whisper_tokenize(ctx, line, &tokens, Int32(tokens.count))
            guard count > 0 else {
                throw NSError(
                    domain: "WhisperKitAlign.ForcedAlignment",
                    code: 100,
                    userInfo: [NSLocalizedDescriptionKey: "Failed to tokenize line: \(line)"]
                )
            }
            sequence.append(contentsOf: tokens.prefix(Int(count)))
        }

        // Sentinel so line-span logic works uniformly.
        boundaries.append(sequence.count)

        self.tokenSequence = sequence
        self.lineBoundaries = boundaries
    }
}
