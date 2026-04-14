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

    // Advance cursor: check if the most recently emitted non-timestamp token
    // matches the token we were expecting.
    if let tokens, n_tokens > 0 {
        // Walk backwards through emitted tokens to find the last non-timestamp token.
        for i in stride(from: Int(n_tokens) - 1, through: 0, by: -1) {
            let emitted = Int(tokens[i].id)
            if emitted < begToken && emitted != eotToken {
                // This is a text token. If it matches our expected token, advance.
                if alignState.cursor < alignState.tokenSequence.count &&
                   emitted == Int(alignState.tokenSequence[alignState.cursor]) {
                    alignState.cursor += 1
                }
                break
            }
        }
    }

    let negInf = -Float.infinity

    if alignState.cursor < alignState.tokenSequence.count {
        let nextToken = Int(alignState.tokenSequence[alignState.cursor])

        // Suppress all text tokens except the next expected one.
        // Preserve EOT so the decoder can end the current segment naturally —
        // without this, all lyrics get crammed into the first audio window.
        // The forced token keeps its natural logit value so timestamp tokens
        // can still win when the model hears non-speech audio — this lets
        // the decoder advance time through instrumental sections before emitting text.
        for i in 0..<begToken {
            if i != nextToken && i != eotToken {
                logits[i] = negInf
            }
        }
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
