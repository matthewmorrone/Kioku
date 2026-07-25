import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

// Best-effort recovery for a remote LLM response that failed parsing outright —
// LLMCorrectionService.parseCompactResponse found no recognizable "N|seg|...|" lines at all,
// typically because the model prefaced its reply with conversational text despite the system
// prompt's "output ONLY the corrected format" instruction. Runs the malformed text back through
// Apple's on-device model with a small, focused reformatting instruction — entirely local, no
// network call, no additional API cost — before ever bothering the user with an error alert.
// Never throws: returns nil on any failure (unavailable, session error, still-unparseable
// output) so the caller (LLMCorrectionService.parseWithSalvage) falls through to the next
// escalation tier, a corrective retry to the original remote provider.
enum LLMResponseSalvage {
    // Asks the on-device model to reformat a malformed response into the strict compact
    // format, given the specific validation failure. Returns nil (never throws) so the
    // caller can fall through to the next recovery tier on any failure.
    @available(iOS 26.0, *)
    static func reformat(rawResponse: String, parseError: String) async -> String? {
        #if canImport(FoundationModels)
        guard AppleIntelligenceAvailability.isAvailable else { return nil }
        let session = LanguageModelSession(instructions: """
            You reformat malformed tool output into a strict line format. The text below was \
            supposed to follow this format: each line is exactly `N|seg1|seg2|...|` — starting \
            AND ending with the `|` character, where N is the 1-based line number and each seg \
            is either plain text or a `(kanji)[reading]` annotation.
            Validation failed with: \(parseError)
            Find the underlying line-numbered segmentation data inside the text below — it may \
            be preceded or followed by unrelated commentary — and re-emit ONLY that data, one \
            line per line number, strictly in the required format. Do not add, remove, or \
            reword any segment content; only fix the formatting/structure. Output nothing else \
            — no explanation, no markdown, no commentary.
            """)
        let options = GenerationOptions(temperature: 0.1)
        do {
            let response = try await session.respond(to: rawResponse, options: options)
            return response.content
        } catch {
            AppLog.error(.llmCorrection, "on-device salvage reformat session failed — \(error.localizedDescription)")
            return nil
        }
        #else
        return nil
        #endif
    }
}
