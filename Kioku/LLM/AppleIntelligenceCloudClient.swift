import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

// Availability check for Apple Intelligence's server-side model (Private Cloud Compute),
// mirroring AppleIntelligenceAvailability's on-device check. Kept as a plain, un-gated enum
// (like its on-device counterpart) so call sites outside a FoundationModels-aware file — Settings,
// LLMSettings — can check it without their own #if/availability boilerplate.
enum AppleIntelligenceCloudAvailability {
    // True when Foundation Models is present, the OS supports the server-side model (iOS 27+),
    // and PrivateCloudComputeLanguageModel itself reports ready — which also folds in the
    // com.apple.developer.private-cloud-compute entitlement, network reachability, and per-user
    // quota/service state. NOTE: the exact availability surface (a plain `isAvailable` Bool vs.
    // a richer `availability` enum) is unverified against a real iOS 27 SDK — this skill's
    // research found `isAvailable` cited but could not compile-check it. If this doesn't build,
    // check PrivateCloudComputeLanguageModel's actual API first.
    static var isAvailable: Bool {
        #if canImport(FoundationModels)
        if #available(iOS 27.0, *) {
            return PrivateCloudComputeLanguageModel().isAvailable
        }
        #endif
        return false
    }
}

#if canImport(FoundationModels)

// Runs a single-shot prompt through Apple Intelligence's server-side model (Private Cloud
// Compute) for the two song features that have no Apple Intelligence support at all today
// (SongBreakdownService, MergedCorrectionBreakdownService) — unlike on-device correction, which
// is deliberately per-line-chunked to fit a ~4-8K token context, PCC's 32K window can plausibly
// take the whole prompt in one shot the same way the remote HTTP providers already do.
//
// Deliberately non-streaming: FoundationModels does expose a streaming response API on-device,
// but this skill's research could not confirm its exact shape carries over unchanged to PCC, and
// getting a progressive-partial-line UI wrong is a worse failure mode than just not having one.
// Callers get the complete text once generation finishes, same as a non-streaming HTTP request.
//
// `instructions` + `prompt` are sent as one combined string rather than via a separate
// instructions parameter on the session initializer: the ONLY session-construction shape this
// skill's research could directly confirm was `LanguageModelSession(model:)` with no
// instructions argument, so folding instructions into the prompt avoids depending on a
// combined-initializer signature that could not be verified. This mirrors how
// SongBreakdownService's OpenAI path already sends "a single user-role message containing the
// whole prompt" for the same reason (its own comment: "the prompt is a self-contained
// instruction + data and doesn't benefit from a system/user split").
@available(iOS 27.0, *)
enum AppleIntelligenceCloudClient {
    // reasoningLevel is the "Cloud" (.moderate) vs "Cloud Pro" (.deep) distinction: same model,
    // more thinking time before responding. NOTE: `ContextOptions(reasoningLevel:)` and the
    // `.moderate`/`.deep` case names are sourced from this skill's post-training-cutoff research,
    // not a compiled reference — verify against the real iOS 27 SDK if this doesn't build.
    static func generate(instructions: String, prompt: String, useDeepReasoning: Bool) async throws -> String {
        let session = LanguageModelSession(model: PrivateCloudComputeLanguageModel())
        let fullPrompt = instructions + "\n\n" + prompt
        let response = try await session.respond(
            to: fullPrompt,
            contextOptions: ContextOptions(reasoningLevel: useDeepReasoning ? .deep : .moderate)
        )
        return response.content
    }
}

#endif
