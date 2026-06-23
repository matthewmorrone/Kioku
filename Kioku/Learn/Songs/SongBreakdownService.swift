import Foundation
import CryptoKit

// Generates a SongBreakdown by sending the verbatim song-breakdown prompt + lyrics to the
// active LLM provider, then parsing the markdown response. Shares LLMSettings (provider/key)
// with LLMCorrectionService so there's a single user-config surface for both features.
// Stub mode short-circuits the network call with a UserDefaults-stored markdown blob — same
// pattern as LLMCorrectionService — so parser iteration doesn't require an API key.
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
    // Emits NSLog messages at every milestone so the user can watch progress in Console.app /
    // device logs when the call is slow (the LLM round-trip is opaque otherwise).
    func generate(noteID: UUID, lyrics: String) async throws -> SongBreakdown {
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
        guard let apiKey = LLMSettings.activeAPIKey() else {
            NSLog("[SongBreakdown] no API key for active provider — throwing noKeyConfigured")
            throw SongBreakdownError.noKeyConfigured
        }

        let prompt = SongBreakdownPrompt.instantiated(withLyrics: lyrics)
        NSLog("[SongBreakdown] dispatching to %@ promptLength=%d",
              provider.rawValue, prompt.count)
        let raw: String
        let producedBy: SongBreakdownProvider
        switch provider {
        case .none:
            throw SongBreakdownError.noKeyConfigured
        case .openAI:
            raw = try await callOpenAI(apiKey: apiKey, prompt: prompt)
            producedBy = .openAI
        case .claude:
            raw = try await callClaude(apiKey: apiKey, lyrics: lyrics)
            producedBy = .claude
        }
        NSLog("[SongBreakdown] %@ response received bytes=%d duration=%.2fs — parsing",
              provider.rawValue, raw.count, Date().timeIntervalSince(startedAt))

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

    // Hashes the raw note text so that cache invalidation tracks only the raw input the LLM
    // saw — segmentation, override, and reading edits never change the hash, never invalidate.
    static func sha256(_ text: String) -> String {
        let digest = SHA256.hash(data: Data(text.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    // Calls OpenAI chat completions. Uses a single user-role message containing the whole
    // prompt because the prompt is self-contained instruction + data and doesn't benefit from
    // a system/user split. max_tokens is generous to accommodate full song breakdowns.
    private func callOpenAI(apiKey: String, prompt: String) async throws -> String {
        let url = URL(string: "https://api.openai.com/v1/chat/completions")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let temperature = UserDefaults.standard.object(forKey: LLMSettings.temperatureKey) as? Double
            ?? LLMSettings.defaultTemperature
        let model = LLMSettings.openAIModel()
        let body: [String: Any] = [
            "model": model,
            "messages": [
                ["role": "user", "content": prompt]
            ],
            "max_tokens": 8192,
            "temperature": temperature
        ]

        let bodyData = try JSONSerialization.data(withJSONObject: body)
        request.httpBody = bodyData
        NSLog("[SongBreakdown] POST openai bodyBytes=%d temperature=%.2f model=%@",
              bodyData.count, temperature, model)

        let httpStart = Date()
        let (data, response) = try await urlSession.data(for: request)
        NSLog("[SongBreakdown] openai HTTP completed bytes=%d duration=%.2fs",
              data.count, Date().timeIntervalSince(httpStart))
        try validate(response: response, data: data, providerName: "OpenAI")

        guard
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let choices = json["choices"] as? [[String: Any]],
            let firstChoice = choices.first,
            let message = firstChoice["message"] as? [String: Any],
            let content = message["content"] as? String
        else {
            throw SongBreakdownError.unexpectedResponseShape(
                "OpenAI response missing choices[0].message.content"
            )
        }
        return content
    }

    // Calls the Anthropic Messages API using the configured Claude model (Sonnet 4.6 by default),
    // chosen for the depth the prompt asks for (etymology, register, cultural context).
    // The large static instruction prompt is sent as a cached system block (cache_control:
    // ephemeral) so it bills at ~0.1x on repeat calls; the per-song lyrics travel uncached in
    // the user turn. Prompt caching is GA — no beta header; the anthropic-version header above
    // suffices. The song instructions (~2400 tokens) clear Sonnet 4.6's ~2048-token minimum
    // cacheable prefix, so the cache marker takes effect here.
    private func callClaude(apiKey: String, lyrics: String) async throws -> String {
        let url = URL(string: "https://api.anthropic.com/v1/messages")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let temperature = UserDefaults.standard.object(forKey: LLMSettings.temperatureKey) as? Double
            ?? LLMSettings.defaultTemperature
        let model = LLMSettings.claudeModel()
        let body: [String: Any] = [
            "model": model,
            "max_tokens": 8192,
            "temperature": temperature,
            "system": [
                [
                    "type": "text",
                    "text": SongBreakdownPrompt.staticInstructions(),
                    "cache_control": ["type": "ephemeral"]
                ]
            ],
            "messages": [
                ["role": "user", "content": lyrics]
            ]
        ]

        let bodyData = try JSONSerialization.data(withJSONObject: body)
        request.httpBody = bodyData
        NSLog("[SongBreakdown] POST claude bodyBytes=%d temperature=%.2f model=%@",
              bodyData.count, temperature, model)

        let httpStart = Date()
        let (data, response) = try await urlSession.data(for: request)
        NSLog("[SongBreakdown] claude HTTP completed bytes=%d duration=%.2fs",
              data.count, Date().timeIntervalSince(httpStart))
        try validate(response: response, data: data, providerName: "Claude")

        guard
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let content = json["content"] as? [[String: Any]],
            let firstBlock = content.first,
            let text = firstBlock["text"] as? String
        else {
            throw SongBreakdownError.unexpectedResponseShape(
                "Claude response missing content[0].text"
            )
        }
        return text
    }

    // Validates the HTTP status and surfaces the error body so the UI can show a meaningful
    // failure (quota exceeded, model unavailable, etc.) instead of an opaque "network error".
    private func validate(response: URLResponse, data: Data, providerName: String) throws {
        guard let http = response as? HTTPURLResponse else {
            NSLog("[SongBreakdown] %@ non-HTTP response", providerName)
            throw SongBreakdownError.networkError("\(providerName): non-HTTP response")
        }
        guard (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? "(unreadable)"
            let bodyPreview = String(body.prefix(400))
            NSLog("%@", "[SongBreakdown] \(providerName) HTTP \(http.statusCode) body=\(bodyPreview)")
            throw SongBreakdownError.networkError(
                "\(providerName) HTTP \(http.statusCode): \(body)"
            )
        }
    }
}

// Each case maps to a specific UI state in the stepper: missing key → settings link;
// network → Retry button; parse failure → "show raw response" debug toggle.
enum SongBreakdownError: LocalizedError {
    case noKeyConfigured
    case networkError(String)
    case unexpectedResponseShape(String)
    case parseFailed(String)
    case cancelled

    var errorDescription: String? {
        switch self {
        case .noKeyConfigured:
            return "No LLM is configured. Set one up in Settings, or paste a stub response for offline use."
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
