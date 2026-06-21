// Pure helpers that ReadView+AudioTranscription used to host as nonisolated static
// methods. They never read or wrote ReadView's @State; promoting them to a
// namespace gets the host extension comfortably under the file-size guardrail
// and signals that these are independent utilities, not ReadView responsibilities.

import AVFoundation
import CoreMedia
import Foundation
// @preconcurrency: Speech (SFTranscription, SFTranscriptionSegment, SFSpeechRecognizer, ...)
// predates Swift concurrency and its types aren't Sendable. The recognizeTranscription
// boundary uses a checked continuation to bridge safely; this import opts the file
// out of strict checking on those types.
@preconcurrency import Speech
import NaturalLanguage

// Lock-guarded mutable state shared by the (background) recognition handler and the timeout task in
// recognizeTranscription. `claim()` returns true to exactly one caller, so the checked continuation
// is resumed once even though both closures race. @unchecked Sendable: the NSLock provides the safety.
// Every member is `nonisolated` — the project builds with -default-isolation=MainActor, which would
// otherwise make this class @MainActor and unusable from the background recognition callback.
private final class SpeechResolveBox: @unchecked Sendable {
    nonisolated private let lock = NSLock()
    nonisolated(unsafe) private var resolved = false
    nonisolated(unsafe) private var latest: SFTranscription?
    nonisolated(unsafe) var task: SFSpeechRecognitionTask?

    nonisolated init() {}

    // Returns true to exactly one caller; the rest get false (so the continuation resumes once).
    nonisolated func claim() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if resolved { return false }
        resolved = true
        return true
    }
    // Stores the most recent partial, used as the fallback when the timeout fires.
    nonisolated func setLatest(_ transcription: SFTranscription?) {
        lock.lock(); latest = transcription; lock.unlock()
    }
    // The latest stored partial, read under the lock.
    nonisolated var latestValue: SFTranscription? {
        lock.lock(); defer { lock.unlock() }; return latest
    }
}

enum AudioTranscriptionHelpers {

    // Copies an imported audio file into a temporary location so recognition can safely access it after file-importer scope ends.
    static func copyImportedAudioToTemporaryLocation(_ sourceURL: URL) throws -> URL {
        let didStartAccessingSecurityScope = sourceURL.startAccessingSecurityScopedResource()
        defer {
            if didStartAccessingSecurityScope {
                sourceURL.stopAccessingSecurityScopedResource()
            }
        }

        let fileExtension = sourceURL.pathExtension.isEmpty ? "m4a" : sourceURL.pathExtension
        let temporaryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(fileExtension)

        if FileManager.default.fileExists(atPath: temporaryURL.path) {
            try FileManager.default.removeItem(at: temporaryURL)
        }

        try FileManager.default.copyItem(at: sourceURL, to: temporaryURL)
        return temporaryURL
    }

    // Requests speech-recognition authorization so built-in transcription can process the imported audio file.
    // nonisolated: the Speech framework calls requestAuthorization's completion on a BACKGROUND
    // thread. Under the project's -default-isolation=MainActor, a closure here would be inferred
    // @MainActor and the runtime SIGTRAPs (dispatch_assert_queue) when it runs off-main. Marking the
    // function nonisolated makes its closures nonisolated, so the off-main callback is legal.
    nonisolated static func requestSpeechAuthorizationIfNeeded() async throws {
        let authorizationStatus = SFSpeechRecognizer.authorizationStatus()
        if authorizationStatus == .authorized {
            return
        }

        let granted = await withCheckedContinuation { continuation in
            // @Sendable forces the closure nonisolated so it can run on Speech's background callback
            // thread; without it -default-isolation=MainActor infers @MainActor and the runtime SIGTRAPs.
            SFSpeechRecognizer.requestAuthorization { @Sendable status in
                continuation.resume(returning: status == .authorized)
            }
        }

        if granted == false {
            throw NSError(
                domain: "Kioku.AudioTranscription",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Speech recognition permission is required to transcribe audio."]
            )
        }
    }

    // Runs one-shot URL-based recognition using Apple Speech and returns the best transcription with
    // segment timing. nonisolated for the same reason as requestSpeechAuthorizationIfNeeded: the
    // recognitionTask result handler fires on a background thread and must not be MainActor-inferred.
    nonisolated static func recognizeTranscription(from fileURL: URL, contextualStrings: [String]) async throws -> SFTranscription {
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "ja_JP")) else {
            throw NSError(
                domain: "Kioku.AudioTranscription",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Japanese speech recognizer is not available on this device."]
            )
        }

        guard recognizer.isAvailable else {
            throw NSError(
                domain: "Kioku.AudioTranscription",
                code: 3,
                userInfo: [NSLocalizedDescriptionKey: "Speech recognizer is currently unavailable."]
            )
        }

        let request = SFSpeechURLRecognitionRequest(url: fileURL)
        request.shouldReportPartialResults = true
        request.requiresOnDeviceRecognition = false
        request.contextualStrings = contextualStrings

        // The recognition handler runs on a background thread and races the timeout task, so its
        // mutable state lives in a lock-guarded Sendable box (a bare captured `var` can't be shared
        // across two @Sendable closures, and the lock guards against a double continuation-resume,
        // which would itself SIGTRAP). @Sendable on the handler keeps it off the MainActor.
        return try await withCheckedThrowingContinuation { continuation in
            let box = SpeechResolveBox()
            box.task = recognizer.recognitionTask(with: request) { @Sendable result, error in
                if let error {
                    if box.claim() { continuation.resume(throwing: error) }
                    return
                }
                guard let result else { return }
                box.setLatest(result.bestTranscription)
                if result.isFinal, box.claim() {
                    continuation.resume(returning: result.bestTranscription)
                }
            }

            // Avoids hanging forever on music chunks that never emit a final result by falling back to the latest partial.
            Task.detached(priority: .userInitiated) {
                try? await Task.sleep(nanoseconds: 25_000_000_000)
                guard box.claim() else { return }
                box.task?.cancel()

                if let latest = box.latestValue {
                    continuation.resume(returning: latest)
                } else {
                    continuation.resume(throwing: NSError(
                        domain: "Kioku.AudioTranscription",
                        code: 9,
                        userInfo: [NSLocalizedDescriptionKey: "Timed out waiting for a speech recognition result."]
                    ))
                }
            }
        }
    }

    // Returns full audio duration in seconds for quality heuristics and retry decisions.
    static func audioDuration(for fileURL: URL) async throws -> TimeInterval {
        let asset = AVURLAsset(url: fileURL)
        let duration = try await asset.load(.duration)
        let durationSeconds = CMTimeGetSeconds(duration)
        guard durationSeconds.isFinite, durationSeconds > 0 else {
            throw NSError(
                domain: "Kioku.AudioTranscription",
                code: 14,
                userInfo: [NSLocalizedDescriptionKey: "Could not determine audio duration."]
            )
        }

        return durationSeconds
    }

    // Exports a temporary audio file for one chunk range so Speech can process long media in smaller recognition windows.
    static func exportAudioChunk(from sourceURL: URL, start: TimeInterval, end: TimeInterval, index: Int) async throws -> URL {
        let asset = AVURLAsset(url: sourceURL)
        guard let exporter = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
            throw NSError(
                domain: "Kioku.AudioTranscription",
                code: 5,
                userInfo: [NSLocalizedDescriptionKey: "Could not create audio exporter for chunk transcription."]
            )
        }

        let chunkURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("kioku-audio-chunk-\(index)-\(UUID().uuidString)")
            .appendingPathExtension("m4a")
        if FileManager.default.fileExists(atPath: chunkURL.path) {
            try FileManager.default.removeItem(at: chunkURL)
        }

        exporter.timeRange = CMTimeRange(
            start: CMTime(seconds: start, preferredTimescale: 600),
            duration: CMTime(seconds: max(end - start, 0.01), preferredTimescale: 600)
        )

        try await exporter.export(to: chunkURL, as: .m4a)
        return chunkURL
    }

    // Merges chunk transcripts while removing simple overlap duplication introduced by chunk window overlap.
    static func mergeChunkTranscript(_ existingText: String, _ incomingChunkText: String) -> String {
        let trimmedExisting = existingText.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedIncoming = incomingChunkText.trimmingCharacters(in: .whitespacesAndNewlines)

        guard trimmedIncoming.isEmpty == false else {
            return trimmedExisting
        }

        guard trimmedExisting.isEmpty == false else {
            return trimmedIncoming
        }

        if trimmedExisting.hasSuffix(trimmedIncoming) {
            return trimmedExisting
        }

        let maxOverlapLength = min(24, trimmedExisting.count, trimmedIncoming.count)
        var matchedOverlapLength = 0

        if maxOverlapLength > 0 {
            for overlapLength in stride(from: maxOverlapLength, through: 1, by: -1) {
                let suffix = String(trimmedExisting.suffix(overlapLength))
                let prefix = String(trimmedIncoming.prefix(overlapLength))
                if suffix == prefix {
                    matchedOverlapLength = overlapLength
                    break
                }
            }
        }

        if matchedOverlapLength > 0 {
            return trimmedExisting + String(trimmedIncoming.dropFirst(matchedOverlapLength))
        }

        return trimmedExisting + "\n" + trimmedIncoming
    }

    // Builds line-level subtitle cues from timestamped speech segments so playback can highlight one line at a time.
    static func makeLineLevelSubtitleCues(
        from segments: [SFTranscriptionSegment],
        fallbackTranscript: String,
        audioDurationSeconds: TimeInterval
    ) -> [SubtitleCue] {
        let orderedSegments = segments.sorted { lhs, rhs in
            if lhs.timestamp != rhs.timestamp {
                return lhs.timestamp < rhs.timestamp
            }
            return lhs.duration < rhs.duration
        }

        var cues: [SubtitleCue] = []
        var currentText = ""
        var currentStartMs: Int?
        var currentEndMs: Int?

        // Finalises the accumulated segment text into a SubtitleCue and resets the accumulation state.
        func flushCurrentCue() {
            let trimmed = currentText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.isEmpty == false,
                  let startMs = currentStartMs,
                  let endMs = currentEndMs else {
                currentText = ""
                currentStartMs = nil
                currentEndMs = nil
                return
            }

            cues.append(
                SubtitleCue(
                    index: cues.count + 1,
                    startMs: max(0, startMs),
                    endMs: max(startMs + 1, endMs),
                    text: trimmed
                )
            )
            currentText = ""
            currentStartMs = nil
            currentEndMs = nil
        }

        for segment in orderedSegments {
            let piece = normalizedSubtitleSegmentText(segment.substring)
            guard piece.isEmpty == false else {
                continue
            }

            let startMs = Int((segment.timestamp * 1000).rounded())
            let endMs = Int(((segment.timestamp + segment.duration) * 1000).rounded())
            let gapMs = currentEndMs.map { startMs - $0 } ?? 0
            let shouldStartNewCue = gapMs > 900
                || (gapMs > 350 && currentText.count >= 24)

            if shouldStartNewCue {
                flushCurrentCue()
            }

            if currentText.isEmpty {
                currentText = piece
                currentStartMs = startMs
                currentEndMs = endMs
            } else {
                currentText = appendedSubtitleLineText(currentText, piece)
                currentEndMs = max(currentEndMs ?? endMs, endMs)
            }

            if currentText.hasSentenceEndingPunctuation {
                flushCurrentCue()
            }
        }

        flushCurrentCue()

        if cues.isEmpty {
            let trimmedFallback = fallbackTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmedFallback.isEmpty == false else {
                return []
            }

            return [
                SubtitleCue(
                    index: 1,
                    startMs: 0,
                    endMs: max(1, Int((audioDurationSeconds * 1000).rounded())),
                    text: trimmedFallback
                )
            ]
        }

        return cues
    }

    // Detects the common Speech-framework "no speech detected" failure so silent chunks can be skipped non-fatally.
    static func isNoSpeechDetectedError(_ error: Error) -> Bool {
        let nsError = error as NSError
        if nsError.domain == "kAFAssistantErrorDomain" && nsError.code == 1110 {
            return true
        }

        return nsError.localizedDescription.localizedCaseInsensitiveContains("no speech detected")
    }

    // Triggers a retry pass when transcript density is too low for the audio duration.
    static func shouldRetryForLowYield(transcript: String, durationSeconds: TimeInterval) -> Bool {
        let normalizedTranscript = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        if normalizedTranscript.count < 24 {
            return true
        }

        let minutes = max(durationSeconds / 60.0, 0.1)
        let charactersPerMinute = Double(normalizedTranscript.count) / minutes
        return charactersPerMinute < 50
    }

    // Extracts high-signal phrase hints from the current note with Japanese-aware segmentation for better recognition bias.
    static func makeSpeechContextualStrings(from noteText: String, title: String) -> [String] {
        let combinedSource = "\(title)\n\(noteText)"
        let sourceNSString = combinedSource as NSString
        let fullRange = combinedSource.startIndex..<combinedSource.endIndex

        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.string = combinedSource
        tokenizer.setLanguage(.japanese)

        var rawParts: [String] = []
        tokenizer.enumerateTokens(in: fullRange) { segmentRange, _ in
            let segment = String(combinedSource[segmentRange]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard segment.isEmpty == false else {
                return true
            }

            let containsJapanese = ScriptClassifier.containsJapanese(segment)

            // Allows single-character Japanese segments while filtering noisy short latin fragments.
            if containsJapanese || segment.count >= 2 {
                rawParts.append(segment)
            }
            return true
        }

        let fallbackParts = sourceNSString
            .components(separatedBy: CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.isEmpty == false && $0.count >= 2 }
        rawParts.append(contentsOf: fallbackParts)

        var seen = Set<String>()
        var uniqueParts: [String] = []
        for part in rawParts {
            if seen.insert(part).inserted {
                uniqueParts.append(part)
            }
        }

        // Keeps the request payload small and focused so recognition remains stable.
        return Array(uniqueParts.prefix(80))
    }

    // Normalizes one speech segment for subtitle assembly without altering Japanese text content.
    static func normalizedSubtitleSegmentText(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // Appends a segment to the current subtitle line, inserting a space only for adjacent latin/digit runs.
    static func appendedSubtitleLineText(_ existingText: String, _ incomingText: String) -> String {
        guard existingText.isEmpty == false else {
            return incomingText
        }

        guard let lastScalar = existingText.unicodeScalars.last,
              let firstScalar = incomingText.unicodeScalars.first else {
            return existingText + incomingText
        }

        let needsSpace = CharacterSet.alphanumerics.contains(lastScalar)
            && CharacterSet.alphanumerics.contains(firstScalar)
        return needsSpace ? existingText + " " + incomingText : existingText + incomingText
    }

    // Builds karaoke-oriented JSON from recognizer segment timing at the finest granularity Apple Speech exposes.
    static func makeKaraokeTimingJSON(from segments: [SFTranscriptionSegment]) -> String {
        var segmentEntries: [String] = []

        for segment in segments {
            let segmentText = segment.substring
            let startTime = segment.timestamp
            let duration = segment.duration
            let endTime = startTime + duration
            let confidence = segment.confidence

            let escapedSegmentText = escapeJSONString(segmentText)
            segmentEntries.append(
                "{\"text\":\"\(escapedSegmentText)\",\"start\":\(formatSeconds(startTime)),\"end\":\(formatSeconds(endTime)),\"duration\":\(formatSeconds(duration)),\"confidence\":\(formatConfidence(confidence))}"
            )
        }

        return "{\n  \"segments\": [\n    \(segmentEntries.joined(separator: ",\n    "))\n  ]\n}"
    }

    // Formats second-based timing values with millisecond precision for karaoke synchronization.
    static func formatSeconds(_ seconds: TimeInterval) -> String {
        String(format: "%.3f", seconds)
    }

    // Formats confidence values to keep exported timing payloads compact and stable.
    static func formatConfidence(_ confidence: Float) -> String {
        String(format: "%.4f", confidence)
    }

    // Escapes JSON-sensitive characters so exported karaoke timing payloads stay valid.
    static func escapeJSONString(_ value: String) -> String {
        var escaped = value.replacingOccurrences(of: "\\", with: "\\\\")
        escaped = escaped.replacingOccurrences(of: "\"", with: "\\\"")
        escaped = escaped.replacingOccurrences(of: "\n", with: "\\n")
        escaped = escaped.replacingOccurrences(of: "\r", with: "\\r")
        escaped = escaped.replacingOccurrences(of: "\t", with: "\\t")
        return escaped
    }
}

// Private helper used by makeLineLevelSubtitleCues to know when to flush the
// accumulated cue. Lives in this file so the namespace's collaborator stays
// co-located with its sole caller.
private extension String {
    nonisolated var hasSentenceEndingPunctuation: Bool {
        last == "。" || last == "！" || last == "？" || last == "!" || last == "?"
    }
}
