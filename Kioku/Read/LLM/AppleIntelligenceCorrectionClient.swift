import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

// Wraps the Apple Intelligence on-device model (iOS 26+) as a correction backend
// for LLMCorrectionService. Hidden behind an availability check so older OS
// versions never see this provider; Settings hides the option on devices
// where SystemLanguageModel.default.isAvailable returns false.
enum AppleIntelligenceAvailability {
    // Returns true when Foundation Models is present AND the device's system
    // language model reports itself as ready. Reads the framework lazily so
    // the symbol is only touched inside the #available guard.
    static var isAvailable: Bool {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) {
            return SystemLanguageModel.default.isAvailable
        }
        #endif
        return false
    }
}

#if canImport(FoundationModels)

// Foundation Models Tool that lets the on-device model query our local
// JMdict before merging or splitting segments. Grounds the model in real
// dictionary truth so it stops hallucinating compound words like 涙出
// (not a word) with invented readings. Returns a short "YES" / "NO" string
// the model is instructed to consult before acting on any merge proposal.
@available(iOS 26.0, *)
struct JapaneseWordLookupTool: Tool {
    let name = "lookupJapaneseWord"
    let description = "Check whether a Japanese string is a known word in JMdict. Call this BEFORE merging two consecutive segments into a candidate compound: only merge if this tool returns YES. Also useful BEFORE splitting a segment, to confirm the split pieces are real words."

    @Generable
    struct Arguments {
        @Guide(description: "The Japanese string to check — kanji, kana, or mixed. Plain text only, no annotation markup.")
        let word: String
    }

    let dictionary: DictionaryStore

    // Resolves the tool's lookup by querying DictionaryStore in kanjiAndKana
    // mode (matches both indices, so all-kana and kanji surfaces resolve
    // through one call) and returns a short YES/NO string the model can
    // reason about in its next response chunk. Logs each invocation so we
    // can tell whether the on-device model is actually using the tool —
    // small models often skip tool calls even when instructed.
    func call(arguments: Arguments) async throws -> String {
        let trimmed = arguments.word.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else {
            LLMDebugLog.log("[JMdictTool] lookup(empty) → NO")
            return "NO (empty input)"
        }
        // kanjiAndKana mode matches both indices, so all-kana and kanji
        // surfaces both resolve through the same call.
        if let entries = try? dictionary.lookup(surface: trimmed, mode: .kanjiAndKana),
           entries.isEmpty == false {
            LLMDebugLog.log("[JMdictTool] lookup(\"\(trimmed)\") → YES (\(entries.count) entries)")
            return "YES — \"\(trimmed)\" is in the dictionary"
        }
        LLMDebugLog.log("[JMdictTool] lookup(\"\(trimmed)\") → NO")
        return "NO — \"\(trimmed)\" is not in the dictionary; do not merge into it."
    }
}

// Runs LLMCorrectionService's correction request through Apple Intelligence
// using the EXACT same prompt and compact-format I/O the remote providers
// use. The only Apple-Intelligence-specific concern is per-line chunking
// (the on-device context window is small) and a fresh LanguageModelSession
// per call (sessions retain transcript history that would push subsequent
// calls over the limit). Output is parsed with parseCompactResponse — the
// same parser the remote-provider responses already use — so success and
// failure modes are identical across providers. When a DictionaryStore is
// supplied, the session is wired with JapaneseWordLookupTool so the model
// can verify candidate merges against JMdict before committing to them.
@available(iOS 26.0, *)
enum AppleIntelligenceCorrectionClient {
    // Dispatches the compact-format correction request line by line through
    // the on-device model and assembles the responses into the same
    // LLMCorrectionResponse shape the remote provider paths return. When
    // onPartial is supplied, it fires after EACH line completes with a
    // cumulative response — lines that haven't been processed yet still
    // appear in the response using their current baseline segmentation,
    // so the caller can re-apply incrementally and the user sees the
    // text update line by line instead of waiting for the whole batch.
    // Each line uses a fresh LanguageModelSession so transcript history
    // can't push the small on-device context window over its limit, and
    // per-line failures preserve the baseline segments for that line so a
    // single bad chunk doesn't fail the whole correction.
    static func requestCorrections(
        compactSegments: String,
        dictionary: DictionaryStore? = nil,
        onPartial: (@Sendable @MainActor (LLMCorrectionResponse) -> Void)? = nil
    ) async throws -> LLMCorrectionResponse {
        // Override the user-configurable temperature with a fixed low value:
        // the on-device model hallucinates segmentations at higher temps, and
        // the correction task wants conservative output ("when in doubt, leave
        // it alone") more than creative output.
        let options = GenerationOptions(temperature: 0.1)
        let parser = LLMCorrectionService()
        let lookupTool = dictionary.map { JapaneseWordLookupTool(dictionary: $0) }

        let lines = compactSegments
            .components(separatedBy: "\n")
            .filter { $0.isEmpty == false }

        // Baseline per-line segments: what each line looks like BEFORE the
        // model touches it. Used as the placeholder for not-yet-processed
        // lines in streaming partials so the user's view keeps showing the
        // existing segmentation while the AI catches up. Also serves as the
        // fallback for lines whose AI response fails validation.
        let baseline: [[LLMSegmentEntry]] = lines.map { line in
            if Self.isBareLine(line) {
                return []  // blank-line marker; buildResponse emits just "\n"
            }
            return Self.extractLineSegments(from: line, parser: parser)
        }
        var current = baseline

        // Pre-count the lines we'll actually dispatch (bare blank-line entries
        // don't hit the model) so the overlay's "X of Y" denominator reflects
        // real work, not noise.
        let dispatchableLineCount = lines.filter { Self.isBareLine($0) == false }.count
        await MainActor.run {
            AICorrectionProgress.shared.begin(total: dispatchableLineCount)
        }
        defer {
            Task { @MainActor in
                AICorrectionProgress.shared.finish()
            }
        }

        var lastError: Error?
        var processedLineCount = 0
        var failedLineCount = 0

        for (index, line) in lines.enumerated() {
            // Bare blank-line entry (`N|`) — no segments to correct.
            if Self.isBareLine(line) {
                continue
            }

            processedLineCount += 1

            // Mark this line as in flight so ReadView can highlight it. The
            // index matches the note-text line index because compactSegments
            // encodes one entry per note line. AICorrectionProgress.advance()
            // clears it after the model returns.
            await MainActor.run {
                AICorrectionProgress.shared.startLine(at: index)
            }

            // Fresh session per call so transcript history can't push the
            // small on-device context window past its limit between chunks.
            // The dictionary tool, when available, gives the model a way to
            // verify candidate merges against JMdict before producing them.
            let session: LanguageModelSession
            if let lookupTool {
                session = LanguageModelSession(
                    tools: [lookupTool],
                    instructions: LLMCorrectionService.systemPrompt
                )
            } else {
                session = LanguageModelSession(instructions: LLMCorrectionService.systemPrompt)
            }
            do {
                let response = try await session.respond(to: line, options: options)
                let partial = try parser.parseCompactResponse(response.content)
                // Per-line semantic validation: the parsed surfaces must
                // concat back to the input line's raw text. The on-device
                // model intermittently emits full-width parens or drops
                // characters; parseCompactResponse accepts the malformed
                // output structurally, but applying it would later fail
                // the whole-note concat check. Catching it here lets a
                // single bad line fall back to baseline while the good
                // ones still land.
                let inputRaw = Self.extractRawSourceText(from: line, parser: parser)
                let parsedRaw = partial.segments
                    .filter { $0.surface != "\n" && $0.surface.isEmpty == false }
                    .map(\.surface)
                    .joined()
                guard parsedRaw == inputRaw else {
                    throw LLMCorrectionError.unexpectedResponseShape(
                        "surface mismatch: expected \"\(inputRaw.prefix(40))\" got \"\(parsedRaw.prefix(40))\""
                    )
                }
                // Reject the line when the model put kanji in a `[reading]` slot.
                // The on-device model occasionally produces things like
                // `(食)[食]べる` — the surface concat still equals the input, but
                // the reading "食べる" would render kanji as furigana over the
                // kanji. Validating per-segment catches it before that lands.
                if let badSeg = partial.segments.first(where: { seg in
                    seg.reading.isEmpty == false && ScriptClassifier.containsKanji(seg.reading)
                }) {
                    throw LLMCorrectionError.unexpectedResponseShape(
                        "reading contains kanji: \"\(badSeg.surface)\" → \"\(badSeg.reading)\""
                    )
                }
                // Strip parseCompactResponse's trailing "\n" entry — buildResponse
                // adds line separators between entries on assembly.
                let lineSegments = partial.segments.filter { $0.surface != "\n" }
                current[index] = lineSegments
            } catch {
                // Per-line failure: safety guardrails, decoding glitch, or
                // a malformed response the validator rejected. current[index]
                // already holds the baseline segments, so concat still matches
                // the source — the line just doesn't get the AI's pass.
                lastError = error
                failedLineCount += 1
                LLMDebugLog.log("[AppleIntelligence] skipped line — \(error.localizedDescription)")
            }
            await MainActor.run {
                AICorrectionProgress.shared.advance()
            }

            if let onPartial {
                let snapshot = Self.buildResponse(from: current)
                await onPartial(snapshot)
            }
        }

        // If every model call failed, escalate so the caller surfaces a
        // proper error instead of silently returning the baseline (which
        // would look like a successful no-op correction).
        if processedLineCount > 0, failedLineCount == processedLineCount, let err = lastError {
            throw err
        }

        return Self.buildResponse(from: current)
    }

    // Assembles a full LLMCorrectionResponse from per-line segment lists,
    // inserting the implicit "\n" separator the parseCompactResponse path
    // also emits between lines. Empty per-line lists encode "blank line"
    // (just a "\n" entry, matching the bare `N|` compact-format marker).
    private static func buildResponse(from perLine: [[LLMSegmentEntry]]) -> LLMCorrectionResponse {
        var entries: [LLMSegmentEntry] = []
        for lineEntries in perLine {
            if lineEntries.isEmpty {
                entries.append(LLMSegmentEntry(surface: "\n", reading: ""))
            } else {
                entries.append(contentsOf: lineEntries)
                entries.append(LLMSegmentEntry(surface: "\n", reading: ""))
            }
        }
        return LLMCorrectionResponse(segments: entries)
    }

    // Decomposes one compact-format input line into its existing segments
    // (with readings) via the shared parser. Used to seed the per-line
    // baseline that fills in for not-yet-processed lines in streaming
    // partials, and as the fallback when a model call fails validation.
    // Falls back to a single raw-line segment if the parser rejects the
    // input — better than emitting nothing.
    private static func extractLineSegments(from compactLine: String, parser: LLMCorrectionService) -> [LLMSegmentEntry] {
        if let parsed = try? parser.parseCompactResponse(compactLine) {
            let segs = parsed.segments.filter {
                $0.surface != "\n" && $0.surface.isEmpty == false
            }
            if segs.isEmpty == false {
                return segs
            }
        }
        let raw = Self.stripOuterPipes(from: compactLine) ?? compactLine
        if raw.isEmpty == false {
            return [LLMSegmentEntry(surface: raw, reading: "")]
        }
        return []
    }

    // Returns just the raw source text for one compact-format line by
    // joining the parsed segment surfaces. Used by the per-line semantic
    // validation step to compare AI output against the original text.
    private static func extractRawSourceText(from compactLine: String, parser: LLMCorrectionService) -> String {
        if let parsed = try? parser.parseCompactResponse(compactLine) {
            let joined = parsed.segments
                .filter { $0.surface != "\n" && $0.surface.isEmpty == false }
                .map(\.surface)
                .joined()
            if joined.isEmpty == false {
                return joined
            }
        }
        return Self.stripOuterPipes(from: compactLine) ?? compactLine
    }

    // Last-ditch fallback: drops the `N|` prefix and a single trailing `|`
    // from a compact-format line. Used when the proper parser rejects the
    // input — better than echoing the raw `N|...|` string verbatim.
    private static func stripOuterPipes(from compactLine: String) -> String? {
        guard let pipeIdx = compactLine.firstIndex(of: "|") else { return nil }
        let afterFirstPipe = compactLine.index(after: pipeIdx)
        guard afterFirstPipe < compactLine.endIndex else { return "" }
        let rest = compactLine[afterFirstPipe...]
        if rest.hasSuffix("|") {
            return String(rest.dropLast())
        }
        return String(rest)
    }

    // Returns true when the line is the compact format's "extra blank line"
    // marker (`N|`) — digits followed by a single `|` and nothing else.
    private static func isBareLine(_ line: String) -> Bool {
        guard line.hasSuffix("|") else { return false }
        let withoutPipe = line.dropLast()
        guard withoutPipe.isEmpty == false else { return false }
        return withoutPipe.allSatisfy(\.isNumber)
    }
}

#endif
