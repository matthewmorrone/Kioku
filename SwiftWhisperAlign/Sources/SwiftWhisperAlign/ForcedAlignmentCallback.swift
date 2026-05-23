// ForcedAlignmentCallback.swift
// Non-capturing Swift function that bridges to whisper.cpp's logits_filter_callback.
// At each decoder step it forces the next expected lyric token while preserving
// timestamp logits at their natural values for timing extraction.

import whisper_cpp

// Logits filter that forces the decoder to follow the provided lyric token sequence.
// Must be a free function (no captures) so Swift can bridge it to a C function pointer.
//
// Strategy:
//   - Preserve timestamp token logits (id >= whisper_token_beg) at their natural
//     values from the model, so Whisper inserts timing boundaries when it naturally
//     predicts them.
//   - Force the next expected text token by suppressing all other text tokens.
//     EOT is suppressed while any lyric token remains — the chunked driver in
//     ForcedAlignmentProvider owns window boundaries and the decoder must not
//     exit a window early (which on a fresh 30 s chunk with no prior context
//     it will otherwise do immediately, emitting zero lyric tokens).
//   - Advance the cursor when the decoder emits the expected token (detected
//     by inspecting the most recently emitted non-timestamp token in `tokens`).
//   - Once all lyric tokens have been emitted, allow only the EOT token.
//
// The SOT sequence (SOT, language, task tokens) is processed by whisper.cpp
// as a batch prompt BEFORE the autoregressive loop starts, so this callback
// never sees those tokens — it only runs during autoregressive sampling.
func forcedAlignmentLogitsFilter(
    _ ctx: OpaquePointer?,
    _ state: OpaquePointer?,
    _ tokens: UnsafePointer<whisper_token_data>?,
    _ n_tokens: Int32,
    _ logits: UnsafeMutablePointer<Float>?,
    _ user_data: UnsafeMutableRawPointer?
) {
    guard let ctx, let logits, let user_data else { return }

    let alignState = Unmanaged<ForcedAlignmentState>.fromOpaque(user_data).takeUnretainedValue()
    let vocabSize = Int(whisper_n_vocab(ctx))
    let begToken = Int(whisper_token_beg(ctx))
    let eotToken = Int(whisper_token_eot(ctx))

    // Snapshot cursor + count locally before any subscript. whisper.cpp dispatches
    // this callback through std::thread lambdas (see whisper_full_with_state::$_2
    // in the crash trace) and concurrent decode threads share a single alignState
    // via the void* user_data. Without the snapshot, the previous code read
    // `alignState.cursor` twice — once for `cursor < count` and once for
    // `tokenSequence[cursor]` — and a second thread bumping cursor between those
    // reads could push the subscript past the end, trapping with Array OOB. The
    // snapshot makes the check-then-subscript pair safe by binding both to the
    // same Int. The mutating write (`alignState.cursor = ...`) below is still
    // racy in the rare case two threads both observe the matching emitted token,
    // but the worst case is a double-advance of one position — never out of range.
    let tokenCount = alignState.tokenSequence.count
    var cursorSnapshot = alignState.cursor

    if let tokens, n_tokens > 0 {
        // Walk backwards through emitted tokens to find the last non-timestamp token.
        for i in stride(from: Int(n_tokens) - 1, through: 0, by: -1) {
            let emitted = Int(tokens[i].id)
            if emitted < begToken && emitted != eotToken {
                // This is a text token. If it matches our expected token, advance.
                if cursorSnapshot < tokenCount &&
                   emitted == Int(alignState.tokenSequence[cursorSnapshot]) {
                    alignState.cursor = cursorSnapshot + 1
                    cursorSnapshot += 1
                }
                break
            }
        }
    }

    let negInf = -Float.infinity

    if cursorSnapshot < tokenCount {
        let nextToken = Int(alignState.tokenSequence[cursorSnapshot])

        // Suppress all text tokens except the next expected one, and also
        // suppress EOT. The chunked driver bounds how many lyric tokens land
        // in each window by sizing tokenSequence to that window's budget;
        // within a window the decoder must consume every token before it is
        // allowed to stop. The forced token keeps its natural logit value so
        // timestamp tokens can still win when the model hears non-speech
        // audio, letting time advance through instrumental gaps before the
        // next lyric token is emitted.
        for i in 0..<begToken where i != nextToken {
            logits[i] = negInf
        }
        logits[eotToken] = negInf
        // Timestamp logits (begToken..<vocabSize) are left untouched — the model
        // decides when to insert timing boundaries based on audio content.
    } else {
        // All lyric tokens emitted — suppress everything except EOT.
        for i in 0..<vocabSize {
            logits[i] = negInf
        }
        logits[eotToken] = 0
    }
}
