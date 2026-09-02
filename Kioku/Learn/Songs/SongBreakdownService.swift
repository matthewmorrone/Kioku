import Foundation
import CryptoKit

// Generates a SongBreakdown by sending the verbatim song-breakdown prompt + lyrics to the
// active LLM provider, then parsing the markdown response. Shares LLMSettings (provider/key)
// with LLMCorrectionService so there's a single user-config surface for both features.
// Stub mode short-circuits the network call with a UserDefaults-stored markdown blob — same
// pattern as LLMCorrectionService — so parser iteration doesn't require an API key.
//
// Responses stream (LLMStreamingClient): every time a newline lands in the accumulated text
// the partial markdown is re-parsed and handed to `onPartialLines`, so the caller can render
// each line card as the model writes it. The final return value is parsed from the complete
// text exactly as a non-streaming request would have been.
final class SongBreakdownService {

    // UserDefaults key for the song-breakdown stub response. Distinct from the segmentation stub
    // (kioku.llm.stubResponse) because the two formats are incompatible — accidental cross-use
    // would yield parser errors with no useful diagnostic.
    static let songStubResponseKey = "kioku.llm.song.stubResponse"

    private let parser: SongBreakdownParser
    private let urlSession: URLSession

    init(parser: SongBreakdownParser = SongBreakdownParser(), urlSession: URLSession? = nil) {
        self.parser = parser
        self.urlSession = urlSession ?? SongBreakdownService.makeLongTimeoutSession()
    }

    // Long-running LLM calls regularly exceed URLSession's default 60s timeout — a full song
    // breakdown with deep word annotations can take 60-180s end-to-end. Use a 5-minute per-
    // request timeout and a 10-minute resource timeout so we wait for a real response instead
    // of the user seeing an opaque "request timed out" before the model finishes thinking.
    private static func makeLongTimeoutSession() -> URLSession {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 300
        config.timeoutIntervalForResource = 600
        return URLSession(configuration: config)
    }

    // Returns a SongBreakdown for the given note text. Stub mode parses the in-app stub field;
    // real mode dispatches to the active provider and parses the response markdown. Throws
    // .noKeyConfigured when the user has not finished LLM setup.
    // `onPartialLines` receives the lines parsed so far each time the streamed text grows by a
    // line — the last entry is usually still incomplete. Invoked on the network task.
    // Emits NSLog messages at every milestone so the user can watch progress in Console.app /
    // device logs when the call is slow (the LLM round-trip is opaque otherwise).
    func generate(
        noteID: UUID,
        lyrics: String,
        onPartialLines: (@Sendable ([SongLine]) -> Void)? = nil
    ) async throws -> SongBreakdown {
        // Keep the (often multi-minute) song-breakdown LLM call alive across app backgrounding.
        let bg = BackgroundTaskHolder.begin("kioku.llm.songBreakdown")
        defer { bg.endDetached() }
        let useLLM = UserDefaults.standard.bool(forKey: LLMSettings.useLLMKey)
        let hash = SongBreakdownService.sha256(lyrics)
        let startedAt = Date()
        NSLog("[SongBreakdown] generate start noteID=%@ lyricLength=%d useLLM=%@",
              noteID.uuidString, lyrics.count, useLLM ? "true" : "false")

        if useLLM == false {
            let stub = UserDefaults.standard.string(forKey: Self.songStubResponseKey) ?? ""
            guard stub.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
                NSLog("[SongBreakdown] stub mode but no stub response set — throwing noKeyConfigured")
                throw SongBreakdownError.noKeyConfigured
            }
            NSLog("[SongBreakdown] stub mode parsing stubLength=%d", stub.count)
            try await replayStubProgressively(stub, onPartialLines: onPartialLines)
            let lines = try parser.parse(markdown: stub)
            NSLog("[SongBreakdown] stub parsed lines=%d duration=%.2fs",
                  lines.count, Date().timeIntervalSince(startedAt))
            return SongBreakdown(
                noteID: noteID,
                sourceTextHash: hash,
                generatedAt: Date(),
                provider: .stub,
                lines: lines
            )
        }

        let provider = LLMSettings.activeProvider()
        // Song breakdown doesn't yet support on-device generation — the structured-output
        // prompt is wide enough that Apple Intelligence's small model can't reliably produce
        // it. Checked BEFORE the API-key guard below: Apple Intelligence needs no key by
        // design (LLMSettings.apiKey(for:) always returns nil for it), so without this check
        // that guard would fire first and claim "No LLM is configured" — false, since one IS
        // configured, it's just unsupported for this one feature. Throw the distinct,
        // accurate error instead.
        if provider == .appleIntelligence {
            NSLog("[SongBreakdown] Apple Intelligence selected but unsupported for breakdown — throwing appleIntelligenceUnsupported")
            throw SongBreakdownError.appleIntelligenceUnsupported
        }
        guard let apiKey = LLMSettings.activeAPIKey() else {
            NSLog("[SongBreakdown] no API key for active provider — throwing noKeyConfigured")
            throw SongBreakdownError.noKeyConfigured
        }

        let temperature = UserDefaults.standard.object(forKey: LLMSettings.temperatureKey) as? Double
            ?? LLMSettings.defaultTemperature
        let onDelta = makeDeltaHandler(onPartialLines: onPartialLines)
        NSLog("[SongBreakdown] dispatching to %@ temperature=%.2f", provider.rawValue, temperature)
        let httpStart = Date()
        let raw: String
        let producedBy: SongBreakdownProvider
        switch provider {
        case .none, .appleIntelligence:
            // Unreachable: .none has no API key (caught above), and .appleIntelligence is
            // caught before the guard. Kept exhaustive rather than `default:` so a future
            // LLMProvider case fails to compile here instead of silently mis-dispatching.
            throw SongBreakdownError.noKeyConfigured
        case .openAI:
            // A single user-role message containing the whole prompt: the prompt is a
            // self-contained instruction + data and doesn't benefit from a system/user split.
            raw = try await LLMStreamingClient.streamOpenAI(
                apiKey: apiKey,
                model: LLMSettings.openAIModel(),
                messages: [["role": "user", "content": SongBreakdownPrompt.instantiated(withLyrics: lyrics)]],
                maxTokens: 8192,
                temperature: temperature,
                urlSession: urlSession,
                onDelta: onDelta
            )
            producedBy = .openAI
        case .claude:
            // The large static instruction prompt goes as a cached system block
            // (cache_control: ephemeral) so it bills at ~0.1x on repeat calls; the per-song
            // lyrics travel uncached in the user turn. The song instructions (~2400 tokens)
            // clear Sonnet 4.6's ~2048-token minimum cacheable prefix, so the marker takes effect.
            raw = try await LLMStreamingClient.streamClaude(
                apiKey: apiKey,
                model: LLMSettings.claudeModel(),
                system: [[
                    "type": "text",
                    "text": SongBreakdownPrompt.staticInstructions(),
                    "cache_control": ["type": "ephemeral"]
                ]],
                userContent: lyrics,
                maxTokens: 8192,
                temperature: temperature,
                urlSession: urlSession,
                onDelta: onDelta
            )
            producedBy = .claude
        }
        NSLog("[SongBreakdown] %@ stream completed chars=%d duration=%.2fs — parsing",
              provider.rawValue, raw.count, Date().timeIntervalSince(httpStart))

        let lines = try parser.parse(markdown: raw)
        NSLog("[SongBreakdown] parsed lines=%d totalDuration=%.2fs",
              lines.count, Date().timeIntervalSince(startedAt))
        return SongBreakdown(
            noteID: noteID,
            sourceTextHash: hash,
            generatedAt: Date(),
            provider: producedBy,
            lines: lines
        )
    }

    // Builds the per-fragment handler for a streamed response: accumulates text and, whenever
    // a fragment completes a line, re-parses the whole buffer and reports the lines if they
    // changed. Parsing per newline (not per token) keeps the work proportional to the number
    // of output lines, and the Equatable compare suppresses no-op callbacks for blank lines.
    // State lives in a lock-guarded box because URLSession delivers fragments off the main actor.
    private func makeDeltaHandler(
        onPartialLines: (@Sendable ([SongLine]) -> Void)?
    ) -> @Sendable (String) -> Void {
        guard let onPartialLines else { return { _ in } }
        let accumulator = StreamedTextAccumulator()
        let parser = self.parser
        return { fragment in
            guard let snapshot = accumulator.append(fragment) else { return }
            let lines = parser.parsePartial(markdown: snapshot)
            if accumulator.recordEmitted(lines) {
                onPartialLines(lines)
            }
        }
    }

    // Stub mode has no network stream, so it replays the stub one line at a time with a short
    // pause between lines. This exercises the exact same progressive-card path the real
    // providers drive, which is the point of stub mode: iterate on the UI without an API key.
    // Skipped entirely when nobody is listening for partial lines.
    private func replayStubProgressively(
        _ stub: String,
        onPartialLines: (@Sendable ([SongLine]) -> Void)?
    ) async throws {
        guard let onPartialLines else { return }
        let onDelta = makeDeltaHandler(onPartialLines: onPartialLines)
        for line in stub.components(separatedBy: "\n") {
            try Task.checkCancellation()
            onDelta(line + "\n")
            try await Task.sleep(nanoseconds: 60_000_000)
        }
    }

    // Hashes the raw note text so that cache invalidation tracks only the raw input the LLM
    // saw — segmentation, override, and reading edits never change the hash, never invalidate.
    static func sha256(_ text: String) -> String {
        let digest = SHA256.hash(data: Data(text.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

// Each case maps to a specific UI state in the stepper: missing key → settings link;
// network → Retry button; parse failure → "show raw response" debug toggle.
enum SongBreakdownError: LocalizedError {
    case noKeyConfigured
    case appleIntelligenceUnsupported
    case networkError(String)
    case unexpectedResponseShape(String)
    case parseFailed(String)
    case cancelled

    var errorDescription: String? {
        switch self {
        case .noKeyConfigured:
            return "No LLM is configured. Set one up in Settings, or paste a stub response for offline use."
        case .appleIntelligenceUnsupported:
            return "Song breakdown isn't supported with Apple Intelligence yet — pick OpenAI or Claude in Settings."
        case .networkError(let msg):
            return "Network error: \(msg)"
        case .unexpectedResponseShape(let msg):
            return "Unexpected API response: \(msg)"
        case .parseFailed(let msg):
            return "Could not parse breakdown: \(msg)"
        case .cancelled:
            return "Generation cancelled."
        }
    }
}
