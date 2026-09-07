import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

// AppleIntelligenceCloudAvailability lives in its own file (AppleIntelligenceCloudAvailability.swift)
// per this repo's Type Organization rule — see that file's header for why.
//
// KIOKU_APPLE_INTELLIGENCE_CLOUD gates this whole type off by default (never set in this repo) —
// see AppleIntelligenceCloudAvailability.swift's header comment for why: CI's pinned Xcode 26.5
// genuinely doesn't declare PrivateCloudComputeLanguageModel/ContextOptions, confirmed by an
// actual CI compile failure, not a guess.

#if canImport(FoundationModels) && KIOKU_APPLE_INTELLIGENCE_CLOUD

// Runs a prompt through Apple Intelligence's server-side model (Private Cloud Compute) for the
// song feature that has Apple Intelligence support (SongBreakdownService) — unlike on-device
// correction, which is deliberately per-line-chunked to fit a ~4-8K token context, PCC's 32K
// window can plausibly take the whole prompt in one shot the same way the remote HTTP providers
// already do.
//
// Streaming shape confirmed against gouwsxander/Apple-Intelligence-API (an open-source
// OpenAI-compatible server wrapping FoundationModels, real compiling Swift, not this skill's own
// research): `session.streamResponse(to:options:)` returns an AsyncSequence whose each element's
// `.content` is the FULL cumulative text generated so far, not just the new fragment — that repo
// computes the delta the same way `onDelta` below does, by dropping the previous snapshot's
// length off the front. That reference targets on-device SystemLanguageModel specifically, not
// PrivateCloudComputeLanguageModel, but both share the same LanguageModelSession/streamResponse
// surface per Apple's "one unified API across on-device and PCC" design, so this should carry
// over unchanged.
//
// `instructions` + `prompt` are sent as one combined string rather than via a separate
// instructions parameter on the session initializer: the reference above only ever constructs
// `LanguageModelSession(model:)` (no instructions argument) and folds a system-role message into
// the transcript/prompt instead, so combining instructions+prompt into one string avoids
// depending on a combined-initializer signature neither that reference nor this skill's research
// could confirm. This mirrors how SongBreakdownService's OpenAI path already sends "a single
// user-role message containing the whole prompt" for the same reason (its own comment: "the
// prompt is a self-contained instruction + data and doesn't benefit from a system/user split").
@available(iOS 27.0, *)
enum AppleIntelligenceCloudClient {
    // reasoningLevel is the "Cloud" (.moderate) vs "Cloud Pro" (.deep) distinction: same model,
    // more thinking time before responding. NOTE: unlike the streaming mechanism above,
    // `ContextOptions(reasoningLevel:)` and the `.moderate`/`.deep` case names are NOT confirmed
    // against real code — the gouwsxander reference never sets a reasoning level at all — they're
    // sourced from this skill's post-training-cutoff research. Verify against the real iOS 27 SDK
    // if this doesn't build; the streaming plumbing around it should still be sound either way.
    //
    // onDelta, when supplied, receives each new fragment as it streams in (already de-cumulated —
    // callers don't re-derive the delta themselves). Omit it for a plain one-shot call.
    static func generate(
        instructions: String,
        prompt: String,
        useDeepReasoning: Bool,
        onDelta: (@Sendable (String) -> Void)? = nil
    ) async throws -> String {
        let session = LanguageModelSession(model: PrivateCloudComputeLanguageModel())
        let fullPrompt = instructions + "\n\n" + prompt
        let contextOptions = ContextOptions(reasoningLevel: useDeepReasoning ? .deep : .moderate)

        guard let onDelta else {
            let response = try await session.respond(to: fullPrompt, contextOptions: contextOptions)
            return response.content
        }

        var previousLength = 0
        var finalText = ""
        let stream = session.streamResponse(to: fullPrompt, contextOptions: contextOptions)
        for try await snapshot in stream {
            finalText = snapshot.content
            let fragment = String(finalText.dropFirst(previousLength))
            previousLength = finalText.count
            if fragment.isEmpty == false {
                onDelta(fragment)
            }
        }
        return finalText
    }
}

#endif
