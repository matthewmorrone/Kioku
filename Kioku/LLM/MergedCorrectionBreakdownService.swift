import Foundation

// Opt-in alternative to running LLMCorrectionService and SongBreakdownService as two separate
// round-trips for a song note: sends ONE request asking the model for both a corrected
// segmentation (compact format, same spec LLMCorrectionService uses) and a line-by-line
// breakdown (same markdown spec SongBreakdownParser already parses), so the breakdown pass
// gets to see the same lyrics context the segmentation pass reasons over instead of drifting
// out of sync across two independent calls.
//
// Deliberately additive: reuses LLMCorrectionService.systemPrompt / .parseCompactResponse and
// SongBreakdownPrompt / SongBreakdownParser verbatim rather than forking them, and leaves both
// existing services completely untouched. The two output halves are stitched into one prompt
// separated by `responseDelimiter`, then split back apart before parsing each half with its
// existing parser — no new wire format, no new caching model, nothing for either original path
// to migrate. Reverting this feature means removing this file and its (also additive) call
// site in SongBreakdownStore; neither existing service's behavior changes either way.
//
// The response streams (LLMStreamingClient) so the breakdown half — which the model writes
// first — feeds SongStepperView's progressive cards line by line, same as the plain path.
final class MergedCorrectionBreakdownService {

    // UserDefaults key for the merged-mode stub response, distinct from both existing stub
    // keys (kioku.llm.stubResponse, kioku.llm.song.stubResponse) since this format contains
    // both halves separated by responseDelimiter and would otherwise silently mis-parse if
    // pointed at either single-purpose stub.
    static let stubResponseKey = "kioku.llm.merged.stubResponse"

    // Marks the boundary between the breakdown markdown (before) and the compact segmentation
    // output (after) in one raw response. Chosen to not collide with the breakdown format's own
    // `---` section separator or anything a compact segmentation line could contain.
    static let responseDelimiter = "===SEGMENTATION==="

    private let urlSession: URLSession

    init(urlSession: URLSession? = nil) {
        self.urlSession = urlSession ?? MergedCorrectionBreakdownService.makeLongTimeoutSession()
    }

    // Mirrors SongBreakdownService's timeout: a combined call does at least as much work as a
    // breakdown alone, so the same generous per-request/resource timeouts apply.
    private static func makeLongTimeoutSession() -> URLSession {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 300
        config.timeoutIntervalForResource = 600
        return URLSession(configuration: config)
    }

    // Runs the merged call and returns both halves already parsed into the same types their
    // standalone services would have produced. `noteContent` is the raw note text — the
    // segmentation half is instructed to re-segment from scratch, so no pre-existing
    // segmentation input is needed (same assumption LLMCorrectionQueue makes for unseen notes).
    // `onPartialLines` receives the breakdown lines parsed so far as the stream progresses;
    // once the delimiter has arrived the breakdown half is complete and updates stop.
    func generate(
        noteContent: String,
        onPartialLines: (@Sendable ([SongLine]) -> Void)? = nil
    ) async throws -> MergedCorrectionBreakdownResult {
        let bg = BackgroundTaskHolder.begin("kioku.llm.mergedCorrectionBreakdown")
        defer { bg.endDetached() }

        let useLLM = UserDefaults.standard.bool(forKey: LLMSettings.useLLMKey)
        let compactInput = Self.compactFormat(forContent: noteContent)

        if useLLM == false {
            let stub = UserDefaults.standard.string(forKey: Self.stubResponseKey) ?? ""
            guard stub.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
                throw SongBreakdownError.noKeyConfigured
            }
            return try Self.parseCombined(stub, provider: .stub)
        }

        let provider = LLMSettings.activeProvider()
        let system = Self.systemPrompt
        let user = Self.userMessage(noteContent: noteContent, compactInput: compactInput)
        let temperature = UserDefaults.standard.object(forKey: LLMSettings.temperatureKey) as? Double
            ?? LLMSettings.defaultTemperature

        // Same restriction SongBreakdownService applies: the breakdown half of this prompt is
        // too wide for Apple Intelligence's small on-device model to reliably produce. Private
        // Cloud Compute (iOS 27+) is a full-size cloud-hosted model reached through the same
        // FoundationModels session API, so it isn't subject to that limitation — route there
        // when available, and only throw the "unsupported" error when this device has no PCC
        // access. Checked before the API-key guard for the same reason SongBreakdownService
        // checks it there — Apple Intelligence needs no key, so the key guard would otherwise
        // misreport "not configured".
        if provider == .appleIntelligence {
            #if canImport(FoundationModels)
            if #available(iOS 27.0, *), PrivateCloudComputeAvailability.isAvailable {
                let raw = try await PrivateCloudComputeMergedBreakdownClient.generate(
                    systemPrompt: system,
                    userMessage: user,
                    temperature: temperature,
                    onPartialLines: onPartialLines
                )
                return try Self.parseCombined(raw, provider: .appleIntelligence)
            }
            #endif
            throw SongBreakdownError.appleIntelligenceUnsupported
        }
        guard let apiKey = LLMSettings.activeAPIKey() else {
            throw SongBreakdownError.noKeyConfigured
        }

        let onDelta = Self.makeDeltaHandler(onPartialLines: onPartialLines)

        // Larger max_tokens than SongBreakdownService's 8192: this response has to carry a
        // full breakdown *and* a segmentation in one completion, and 8192 was observed to
        // truncate before the model ever reached the ===SEGMENTATION=== delimiter. 16384 is
        // gpt-4o's full output cap; Claude's synchronous cap is far above it.
        let raw: String
        let producedBy: SongBreakdownProvider
        switch provider {
        case .none, .appleIntelligence:
            throw SongBreakdownError.noKeyConfigured
        case .openAI:
            raw = try await LLMStreamingClient.streamOpenAI(
                apiKey: apiKey,
                model: LLMSettings.openAIModel(),
                messages: [
                    ["role": "system", "content": system],
                    ["role": "user", "content": user]
                ],
                maxTokens: 16384,
                temperature: temperature,
                urlSession: urlSession,
                onDelta: onDelta
            )
            producedBy = .openAI
        case .claude:
            // Cached system block, mirroring SongBreakdownService's request shape.
            raw = try await LLMStreamingClient.streamClaude(
                apiKey: apiKey,
                model: LLMSettings.claudeModel(),
                system: [[
                    "type": "text",
                    "text": system,
                    "cache_control": ["type": "ephemeral"]
                ]],
                userContent: user,
                maxTokens: 16384,
                temperature: temperature,
                urlSession: urlSession,
                onDelta: onDelta
            )
            producedBy = .claude
        }

        return try Self.parseCombined(raw, provider: producedBy)
    }

    // Per-fragment stream handler: re-parses the breakdown half (everything before the
    // delimiter, or the whole buffer while the delimiter hasn't arrived) whenever a line
    // completes. Once the delimiter is in the buffer the breakdown text stops changing, so
    // StreamedTextAccumulator's equality check naturally suppresses further callbacks while
    // the segmentation half streams in.
    private static func makeDeltaHandler(
        onPartialLines: (@Sendable ([SongLine]) -> Void)?
    ) -> @Sendable (String) -> Void {
        guard let onPartialLines else { return { _ in } }
        let accumulator = StreamedTextAccumulator()
        let parser = SongBreakdownParser()
        let delimiter = responseDelimiter
        return { fragment in
            guard let snapshot = accumulator.append(fragment) else { return }
            let breakdownText: String
            if let delimiterRange = snapshot.range(of: delimiter) {
                breakdownText = String(snapshot[..<delimiterRange.lowerBound])
            } else {
                breakdownText = snapshot
            }
            let lines = parser.parsePartial(markdown: breakdownText)
            if accumulator.recordEmitted(lines) {
                onPartialLines(lines)
            }
        }
    }

    // Splits a raw combined response on responseDelimiter and parses each half with the
    // existing, unmodified parsers. Thrown errors are wrapped as .parseFailed so callers can
    // treat every failure mode the same way SongBreakdownService's callers already do.
    private static func parseCombined(_ raw: String, provider: SongBreakdownProvider) throws -> MergedCorrectionBreakdownResult {
        guard let delimiterRange = raw.range(of: responseDelimiter) else {
            throw SongBreakdownError.unexpectedResponseShape(
                "Merged response is missing the \(responseDelimiter) delimiter."
            )
        }
        let breakdownMarkdown = String(raw[..<delimiterRange.lowerBound])
        let compactOutput = String(raw[delimiterRange.upperBound...])
            .trimmingCharacters(in: .whitespacesAndNewlines)

        do {
            let breakdownLines = try SongBreakdownParser().parse(markdown: breakdownMarkdown)
            let correction = try LLMCorrectionService().parseCompactResponse(compactOutput)
            return MergedCorrectionBreakdownResult(
                correction: correction,
                breakdownLines: breakdownLines,
                provider: provider
            )
        } catch let error as LocalizedError {
            // Wraps both SongBreakdownParseError (breakdown half) and LLMCorrectionError
            // (segmentation half) uniformly so every caller of generate(noteContent:) only
            // ever needs to handle SongBreakdownError, matching SongBreakdownService's contract.
            throw SongBreakdownError.parseFailed(error.errorDescription ?? "\(error)")
        }
    }

    // Combined system prompt: the breakdown's static instructions, then the segmentation
    // system prompt verbatim, then a final structural instruction tying the two halves
    // together with the delimiter. Both halves are quoted as-authored elsewhere — nothing
    // here paraphrases either prompt.
    private static var systemPrompt: String {
        """
        \(SongBreakdownPrompt.staticInstructions())

        ---

        \(LLMCorrectionService.systemPrompt)

        FINAL OUTPUT STRUCTURE:
        1. First, produce the song breakdown exactly as specified above.
        2. Then, on its own line, output exactly: \(responseDelimiter)
        3. Then produce the corrected compact-format segmentation exactly as specified above, and nothing else after it.
        """
    }

    // Builds the single user turn carrying both the raw lyrics (for the breakdown half) and
    // the degenerate compact-format input (for the segmentation half).
    private static func userMessage(noteContent: String, compactInput: String) -> String {
        """
        ## Lyrics

        \(noteContent)

        ---

        ## Segmentation input (compact format, one line per source line, to be re-segmented from scratch)

        \(compactInput)
        """
    }

    // Encodes raw note content as one degenerate segment per source line, same shape
    // LLMCorrectionQueue.compactFormat(forContent:) produces for a note with no existing
    // segmentation. Duplicated locally (rather than calling the @MainActor-isolated queue's
    // static func) so this service has no actor-hop or dependency on LLMCorrectionQueue.
    private static func compactFormat(forContent content: String) -> String {
        let lines = content.components(separatedBy: "\n")
        var out: [String] = []
        out.reserveCapacity(lines.count)
        for (index, line) in lines.enumerated() {
            let n = index + 1
            out.append(line.isEmpty ? "\(n)|" : "\(n)|\(line)|")
        }
        return out.joined(separator: "\n")
    }
}

// One merged call's parsed output: a segmentation correction ready for
// LLMCorrectionApplier.segmentRanges(from:originalText:), and breakdown lines ready for
// SongBreakdown(lines:) — the same shapes each standalone service already produces.
struct MergedCorrectionBreakdownResult {
    let correction: LLMCorrectionResponse
    let breakdownLines: [SongLine]
    let provider: SongBreakdownProvider
}
