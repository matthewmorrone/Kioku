import AVFoundation
import NaturalLanguage
import Speech
import SwiftUI
import UniformTypeIdentifiers

// Hosts audio-import transcription controls and speech-recognition helpers for the read screen.
extension ReadView {
    // Binds audio transcription error presentation to whether the read screen currently has a transcription failure message.
    var audioTranscriptionErrorPresented: Binding<Bool> {
        Binding(
            get: { audioTranscriptionErrorMessage.isEmpty == false },
            set: { isPresented in
                if isPresented == false {
                    audioTranscriptionErrorMessage = ""
                }
            }
        )
    }

    // Renders the title-row waveform button that imports an audio file for transcription.
    var audioTranscriptionButton: some View {
        Button {
            isShowingAudioFileImporter = true
        } label: {
            Group {
                if isPerformingAudioTranscription {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Image(systemName: "waveform")
                        .font(.system(size: 14, weight: .semibold))
                }
            }
            .foregroundStyle(isPerformingAudioTranscription ? Color.secondary : Color.accentColor)
            .frame(width: 30, height: 30)
            .background(
                Capsule()
                    .fill(Color(.tertiarySystemFill))
            )
        }
        .buttonStyle(.plain)
        .disabled(isPerformingAudioTranscription)
        .accessibilityLabel("Import Audio for Transcription")
    }

    // Handles the audio-file picker result and kicks off speech recognition.
    func handleAudioImportSelection(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let selectedURLs):
            guard let sourceURL = selectedURLs.first else {
                audioTranscriptionErrorMessage = "No audio file was selected."
                return
            }

            Task {
                await transcribeAudioFile(at: sourceURL)
            }
        case .failure(let error):
            audioTranscriptionErrorMessage = error.localizedDescription
        }
    }

    // Runs built-in Apple speech recognition for one imported audio file and creates a new note with transcript and karaoke timing data.
    func transcribeAudioFile(at sourceURL: URL) async {
        guard isPerformingAudioTranscription == false else {
            return
        }

        isPerformingAudioTranscription = true
        defer {
            isPerformingAudioTranscription = false
        }

        do {
            let copiedURL = try Self.copyImportedAudioToTemporaryLocation(sourceURL)
            defer {
                try? FileManager.default.removeItem(at: copiedURL)
            }

            try await Self.requestSpeechAuthorizationIfNeeded()
            let contextualStrings = Self.makeSpeechContextualStrings(from: text, title: resolvedTitle)
            let audioDuration = try Self.audioDuration(for: copiedURL)
            var chunkRanges = try Self.makeSpeechActiveChunkRanges(for: copiedURL, maxChunkDuration: 12.0, overlap: 0.4)
            if chunkRanges.isEmpty {
                // Falls back to fixed chunking when speech-activity detection finds no reliable active regions.
                chunkRanges = try Self.makeChunkRanges(for: copiedURL, chunkDuration: 12.0, overlap: 0.4)
            }
            guard chunkRanges.isEmpty == false else {
                audioTranscriptionErrorMessage = "The selected audio file does not contain a usable duration."
                return
            }

            let transcriptionNoteID = beginStreamingTranscriptionNote(totalChunks: chunkRanges.count)
            let firstPassResult = try await runChunkTranscriptionPass(
                sourceURL: copiedURL,
                chunkRanges: chunkRanges,
                contextualStrings: contextualStrings,
                transcriptionNoteID: transcriptionNoteID,
                statusPrefix: "Transcribing audio"
            )

            var bestTranscript = firstPassResult.transcript
            var bestSegments = firstPassResult.segments
            var bestNonFatalErrorCount = firstPassResult.nonFatalChunkErrorCount

            if Self.shouldRetryForLowYield(transcript: firstPassResult.transcript, durationSeconds: audioDuration) {
                let retryChunkRanges = try Self.makeChunkRanges(for: copiedURL, chunkDuration: 8.0, overlap: 0.8)
                let retryResult = try await runChunkTranscriptionPass(
                    sourceURL: copiedURL,
                    chunkRanges: retryChunkRanges,
                    contextualStrings: [],
                    transcriptionNoteID: transcriptionNoteID,
                    statusPrefix: "Retrying transcription"
                )

                if retryResult.transcript.count > firstPassResult.transcript.count {
                    bestTranscript = retryResult.transcript
                    bestSegments = retryResult.segments
                    bestNonFatalErrorCount = retryResult.nonFatalChunkErrorCount
                }
            }

            guard bestTranscript.isEmpty == false else {
                if bestNonFatalErrorCount > 0 {
                    audioTranscriptionErrorMessage = "No speech was recognized. \(bestNonFatalErrorCount) chunk(s) also failed with non-speech errors."
                } else {
                    audioTranscriptionErrorMessage = "No speech was recognized in the selected audio file."
                }
                return
            }

            // Generates segment timing for karaoke workflows without injecting timing payload into note text.
            _ = Self.makeKaraokeTimingJSON(from: bestSegments)
            await MainActor.run {
                finalizeStreamingTranscriptionNote(id: transcriptionNoteID, finalText: bestTranscript)
            }
        } catch {
            audioTranscriptionErrorMessage = error.localizedDescription
        }
    }

    // Processes one transcription pass over provided chunk ranges and streams progress updates into the in-flight note.
    func runChunkTranscriptionPass(
        sourceURL: URL,
        chunkRanges: [(start: TimeInterval, end: TimeInterval)],
        contextualStrings: [String],
        transcriptionNoteID: UUID,
        statusPrefix: String
    ) async throws -> (transcript: String, segments: [SFTranscriptionSegment], nonFatalChunkErrorCount: Int) {
        var accumulatedTranscript = ""
        var collectedSegments: [SFTranscriptionSegment] = []
        var nonFatalChunkErrorCount = 0

        for (chunkIndex, chunkRange) in chunkRanges.enumerated() {
            do {
                let chunkURL = try await Self.exportAudioChunk(
                    from: sourceURL,
                    start: chunkRange.start,
                    end: chunkRange.end,
                    index: chunkIndex
                )
                defer {
                    try? FileManager.default.removeItem(at: chunkURL)
                }

                let chunkTranscription = try await Self.recognizeTranscription(from: chunkURL, contextualStrings: contextualStrings)
                collectedSegments.append(contentsOf: chunkTranscription.segments)

                let chunkText = chunkTranscription.formattedString.trimmingCharacters(in: .whitespacesAndNewlines)
                if chunkText.isEmpty == false {
                    accumulatedTranscript = Self.mergeChunkTranscript(accumulatedTranscript, chunkText)
                }
            } catch {
                if Self.isNoSpeechDetectedError(error) == false {
                    nonFatalChunkErrorCount += 1
                }
            }

            await MainActor.run {
                updateStreamingTranscriptionNote(
                    id: transcriptionNoteID,
                    transcribedText: accumulatedTranscript,
                    completedChunks: chunkIndex + 1,
                    totalChunks: chunkRanges.count,
                    statusPrefix: statusPrefix
                )
            }
        }

        return (accumulatedTranscript, collectedSegments, nonFatalChunkErrorCount)
    }

    // Creates and selects a placeholder note so chunked transcription text can stream into the read area while recognition is running.
    func beginStreamingTranscriptionNote(totalChunks: Int) -> UUID {
        flushPendingNotePersistenceIfNeeded()

        let placeholderText = "[Transcribing audio 0/\(totalChunks)]"
        let transcriptionNote = Note(content: placeholderText)
        notesStore.addNote(transcriptionNote)
        shouldActivateEditModeOnLoad = true
        selectedNote = transcriptionNote
        updateStreamingTranscriptionNote(
            id: transcriptionNote.id,
            transcribedText: "",
            completedChunks: 0,
            totalChunks: totalChunks
        )
        return transcriptionNote.id
    }

    // Updates the in-progress transcription note content after each chunk so users can read output as it is generated.
    func updateStreamingTranscriptionNote(id: UUID, transcribedText: String, completedChunks: Int, totalChunks: Int, statusPrefix: String = "Transcribing audio") {
        let statusLine = "[\(statusPrefix) \(completedChunks)/\(totalChunks)]"
        let bodyText = transcribedText.trimmingCharacters(in: .whitespacesAndNewlines)
        let noteContent = bodyText.isEmpty ? statusLine : "\(statusLine)\n\n\(bodyText)"
        let titleToSave = firstLineTitle(from: noteContent)

        _ = notesStore.upsertNote(
            id: id,
            title: titleToSave,
            content: noteContent,
            segments: nil
        )

        if activeNoteID == id {
            isLoadingSelectedNote = true
            customTitle = titleToSave
            fallbackTitle = titleToSave
            text = noteContent
            segments = nil
            isLoadingSelectedNote = false
        }
    }

    // Replaces the temporary status-prefixed content with the final transcript after chunked recognition is complete.
    func finalizeStreamingTranscriptionNote(id: UUID, finalText: String) {
        let normalizedText = finalText.trimmingCharacters(in: .whitespacesAndNewlines)
        let titleToSave = firstLineTitle(from: normalizedText)

        _ = notesStore.upsertNote(
            id: id,
            title: titleToSave,
            content: normalizedText,
            segments: nil
        )

        if activeNoteID == id {
            isLoadingSelectedNote = true
            customTitle = titleToSave
            fallbackTitle = titleToSave
            text = normalizedText
            segments = nil
            isLoadingSelectedNote = false
        }
    }

    // Creates and selects a new note populated from audio transcription so the current note remains untouched.
    func createTranscriptionNote(with transcribedText: String) {
        flushPendingNotePersistenceIfNeeded()

        let recognizedNote = Note(content: transcribedText)
        notesStore.addNote(recognizedNote)
        shouldActivateEditModeOnLoad = true
        selectedNote = recognizedNote
    }

    // Copies an imported audio file into a temporary location so recognition can safely access it after file-importer scope ends.
    nonisolated static func copyImportedAudioToTemporaryLocation(_ sourceURL: URL) throws -> URL {
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
    nonisolated static func requestSpeechAuthorizationIfNeeded() async throws {
        let authorizationStatus = SFSpeechRecognizer.authorizationStatus()
        if authorizationStatus == .authorized {
            return
        }

        let granted = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
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

    // Runs one-shot URL-based recognition using Apple Speech and returns the best transcription with segment timing.
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

        return try await withCheckedThrowingContinuation { continuation in
            var didResolve = false
            var latestTranscription: SFTranscription?
            let recognitionTask = recognizer.recognitionTask(with: request) { result, error in
                if didResolve {
                    return
                }

                if let error {
                    didResolve = true
                    continuation.resume(throwing: error)
                    return
                }

                guard let result else {
                    return
                }

                latestTranscription = result.bestTranscription

                guard result.isFinal else {
                    return
                }

                didResolve = true
                continuation.resume(returning: result.bestTranscription)
            }

            // Avoids hanging forever on music chunks that never emit a final result by falling back to the latest partial.
            Task.detached(priority: .userInitiated) {
                try? await Task.sleep(nanoseconds: 25_000_000_000)
                if didResolve {
                    return
                }

                didResolve = true
                recognitionTask.cancel()

                if let latestTranscription {
                    continuation.resume(returning: latestTranscription)
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

    // Detects speech-active regions by adaptive energy thresholding and returns chunk ranges tailored for recognition.
    nonisolated static func makeSpeechActiveChunkRanges(for fileURL: URL, maxChunkDuration: TimeInterval, overlap: TimeInterval) throws -> [(start: TimeInterval, end: TimeInterval)] {
        let asset = AVURLAsset(url: fileURL)
        guard let track = asset.tracks(withMediaType: .audio).first else {
            throw NSError(
                domain: "Kioku.AudioTranscription",
                code: 10,
                userInfo: [NSLocalizedDescriptionKey: "No audio track is available for speech activity detection."]
            )
        }

        let reader = try AVAssetReader(asset: asset)
        let outputSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
            AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 1
        ]
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: outputSettings)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else {
            throw NSError(
                domain: "Kioku.AudioTranscription",
                code: 11,
                userInfo: [NSLocalizedDescriptionKey: "Could not prepare audio reader output for speech activity detection."]
            )
        }

        reader.add(output)
        guard reader.startReading() else {
            throw NSError(
                domain: "Kioku.AudioTranscription",
                code: 12,
                userInfo: [NSLocalizedDescriptionKey: "Could not start reading audio for speech activity detection."]
            )
        }

        var frameEnergies: [Double] = []
        var frameStarts: [TimeInterval] = []
        var frameDurations: [TimeInterval] = []

        while reader.status == .reading {
            guard let sampleBuffer = output.copyNextSampleBuffer() else {
                break
            }

            defer {
                CMSampleBufferInvalidate(sampleBuffer)
            }

            guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else {
                continue
            }

            var dataLength = 0
            var dataPointer: UnsafeMutablePointer<Int8>?
            let pointerStatus = CMBlockBufferGetDataPointer(
                blockBuffer,
                atOffset: 0,
                lengthAtOffsetOut: nil,
                totalLengthOut: &dataLength,
                dataPointerOut: &dataPointer
            )
            guard pointerStatus == kCMBlockBufferNoErr, let dataPointer, dataLength > 0 else {
                continue
            }

            let sampleCount = dataLength / MemoryLayout<Float>.size
            guard sampleCount > 0 else {
                continue
            }

            let floatPointer = UnsafeRawPointer(dataPointer).assumingMemoryBound(to: Float.self)
            var energySum: Double = 0
            for sampleIndex in 0..<sampleCount {
                let sample = Double(floatPointer[sampleIndex])
                energySum += sample * sample
            }

            let meanSquare = energySum / Double(sampleCount)
            let frameEnergy = sqrt(meanSquare)
            let presentationStart = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
            let presentationDuration = CMTimeGetSeconds(CMSampleBufferGetDuration(sampleBuffer))
            if presentationStart.isFinite == false || presentationDuration.isFinite == false || presentationDuration <= 0 {
                continue
            }

            frameEnergies.append(frameEnergy)
            frameStarts.append(presentationStart)
            frameDurations.append(presentationDuration)
        }

        if reader.status == .failed {
            throw reader.error ?? NSError(
                domain: "Kioku.AudioTranscription",
                code: 13,
                userInfo: [NSLocalizedDescriptionKey: "Audio reader failed during speech activity detection."]
            )
        }

        guard frameEnergies.isEmpty == false else {
            return []
        }

        let sortedEnergies = frameEnergies.sorted()
        let baselineIndex = min(sortedEnergies.count - 1, max(0, Int(Double(sortedEnergies.count - 1) * 0.2)))
        let baselineEnergy = sortedEnergies[baselineIndex]
        let adaptiveThreshold = max(0.002, baselineEnergy * 2.6)

        let averageFrameDuration = frameDurations.reduce(0, +) / Double(frameDurations.count)
        let minActiveFrames = max(1, Int(0.30 / max(averageFrameDuration, 0.001)))
        let hangoverFrames = max(1, Int(0.20 / max(averageFrameDuration, 0.001)))

        var speechRegions: [(start: TimeInterval, end: TimeInterval)] = []
        var activeStartIndex: Int?
        var belowThresholdRunLength = 0

        for frameIndex in 0..<frameEnergies.count {
            let isActiveFrame = frameEnergies[frameIndex] >= adaptiveThreshold

            if isActiveFrame {
                if activeStartIndex == nil {
                    activeStartIndex = frameIndex
                }
                belowThresholdRunLength = 0
                continue
            }

            guard let startIndex = activeStartIndex else {
                continue
            }

            belowThresholdRunLength += 1
            if belowThresholdRunLength < hangoverFrames {
                continue
            }

            let endIndex = max(startIndex, frameIndex - belowThresholdRunLength)
            if endIndex - startIndex + 1 >= minActiveFrames {
                let startTime = frameStarts[startIndex]
                let endTime = frameStarts[endIndex] + frameDurations[endIndex]
                speechRegions.append((start: startTime, end: endTime))
            }
            activeStartIndex = nil
            belowThresholdRunLength = 0
        }

        if let startIndex = activeStartIndex {
            let endIndex = frameEnergies.count - 1
            if endIndex - startIndex + 1 >= minActiveFrames {
                let startTime = frameStarts[startIndex]
                let endTime = frameStarts[endIndex] + frameDurations[endIndex]
                speechRegions.append((start: startTime, end: endTime))
            }
        }

        if speechRegions.isEmpty {
            return []
        }

        var mergedRegions: [(start: TimeInterval, end: TimeInterval)] = []
        let mergeGap: TimeInterval = 0.35
        for region in speechRegions {
            if let lastRegion = mergedRegions.last, region.start - lastRegion.end <= mergeGap {
                mergedRegions[mergedRegions.count - 1] = (start: lastRegion.start, end: max(lastRegion.end, region.end))
            } else {
                mergedRegions.append(region)
            }
        }

        let safeChunkDuration = max(4.0, maxChunkDuration)
        let safeOverlap = min(max(0, overlap), safeChunkDuration - 0.5)
        let step = safeChunkDuration - safeOverlap
        var chunkRanges: [(start: TimeInterval, end: TimeInterval)] = []

        for region in mergedRegions {
            var cursor = max(0, region.start - 0.08)
            let regionEnd = region.end + 0.08
            while cursor < regionEnd {
                let chunkEnd = min(cursor + safeChunkDuration, regionEnd)
                if chunkEnd - cursor >= 0.25 {
                    chunkRanges.append((start: cursor, end: chunkEnd))
                }

                if chunkEnd >= regionEnd {
                    break
                }

                cursor += step
            }
        }

        return chunkRanges
    }

    // Splits an audio file into overlapping fixed-duration chunk ranges to improve long-form transcription recall.
    nonisolated static func makeChunkRanges(for fileURL: URL, chunkDuration: TimeInterval, overlap: TimeInterval) throws -> [(start: TimeInterval, end: TimeInterval)] {
        let asset = AVURLAsset(url: fileURL)
        let durationSeconds = CMTimeGetSeconds(asset.duration)
        guard durationSeconds.isFinite, durationSeconds > 0 else {
            throw NSError(
                domain: "Kioku.AudioTranscription",
                code: 4,
                userInfo: [NSLocalizedDescriptionKey: "Could not determine audio duration for transcription chunking."]
            )
        }

        let safeChunkDuration = max(4.0, chunkDuration)
        let safeOverlap = min(max(0, overlap), safeChunkDuration - 0.5)
        let step = safeChunkDuration - safeOverlap

        var ranges: [(start: TimeInterval, end: TimeInterval)] = []
        var currentStart: TimeInterval = 0
        while currentStart < durationSeconds {
            let currentEnd = min(currentStart + safeChunkDuration, durationSeconds)
            ranges.append((start: currentStart, end: currentEnd))
            if currentEnd >= durationSeconds {
                break
            }

            currentStart += step
        }

        return ranges
    }

    // Returns full audio duration in seconds for quality heuristics and retry decisions.
    nonisolated static func audioDuration(for fileURL: URL) throws -> TimeInterval {
        let asset = AVURLAsset(url: fileURL)
        let durationSeconds = CMTimeGetSeconds(asset.duration)
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
    nonisolated static func exportAudioChunk(from sourceURL: URL, start: TimeInterval, end: TimeInterval, index: Int) async throws -> URL {
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

        exporter.outputURL = chunkURL
        exporter.outputFileType = .m4a
        exporter.timeRange = CMTimeRange(
            start: CMTime(seconds: start, preferredTimescale: 600),
            duration: CMTime(seconds: max(end - start, 0.01), preferredTimescale: 600)
        )

        try await Self.awaitExportCompletion(exporter)
        return chunkURL
    }

    // Awaits asynchronous AVAssetExportSession completion and surfaces a meaningful failure when export does not complete.
    nonisolated static func awaitExportCompletion(_ exporter: AVAssetExportSession) async throws {
        try await withCheckedThrowingContinuation { continuation in
            exporter.exportAsynchronously {
                switch exporter.status {
                case .completed:
                    continuation.resume(returning: ())
                case .failed:
                    continuation.resume(throwing: exporter.error ?? NSError(
                        domain: "Kioku.AudioTranscription",
                        code: 6,
                        userInfo: [NSLocalizedDescriptionKey: "Audio chunk export failed."]
                    ))
                case .cancelled:
                    continuation.resume(throwing: NSError(
                        domain: "Kioku.AudioTranscription",
                        code: 7,
                        userInfo: [NSLocalizedDescriptionKey: "Audio chunk export was cancelled."]
                    ))
                default:
                    continuation.resume(throwing: NSError(
                        domain: "Kioku.AudioTranscription",
                        code: 8,
                        userInfo: [NSLocalizedDescriptionKey: "Audio chunk export finished in an unexpected state."]
                    ))
                }
            }
        }
    }

    // Merges chunk transcripts while removing simple overlap duplication introduced by chunk window overlap.
    nonisolated static func mergeChunkTranscript(_ existingText: String, _ incomingChunkText: String) -> String {
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

    // Detects the common Speech-framework "no speech detected" failure so silent chunks can be skipped non-fatally.
    nonisolated static func isNoSpeechDetectedError(_ error: Error) -> Bool {
        let nsError = error as NSError
        if nsError.domain == "kAFAssistantErrorDomain" && nsError.code == 1110 {
            return true
        }

        return nsError.localizedDescription.localizedCaseInsensitiveContains("no speech detected")
    }

    // Triggers a retry pass when transcript density is too low for the audio duration.
    nonisolated static func shouldRetryForLowYield(transcript: String, durationSeconds: TimeInterval) -> Bool {
        let normalizedTranscript = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        if normalizedTranscript.count < 24 {
            return true
        }

        let minutes = max(durationSeconds / 60.0, 0.1)
        let charactersPerMinute = Double(normalizedTranscript.count) / minutes
        return charactersPerMinute < 50
    }

    // Extracts high-signal phrase hints from the current note with Japanese-aware segmentation for better recognition bias.
    nonisolated static func makeSpeechContextualStrings(from noteText: String, title: String) -> [String] {
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

            let containsJapanese = segment.unicodeScalars.contains { scalar in
                (0x3040...0x30FF).contains(Int(scalar.value)) || (0x4E00...0x9FFF).contains(Int(scalar.value))
            }

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

    // Builds karaoke-oriented JSON from recognizer segment timing at the finest granularity Apple Speech exposes.
    nonisolated static func makeKaraokeTimingJSON(from segments: [SFTranscriptionSegment]) -> String {
        var segmentEntries: [String] = []

        for segment in segments {
            let segmentText = segment.substring
            let startTime = segment.timestamp
            let duration = segment.duration
            let endTime = startTime + duration
            let confidence = segment.confidence

            let escapedSegmentText = Self.escapeJSONString(segmentText)
            segmentEntries.append(
                "{\"text\":\"\(escapedSegmentText)\",\"start\":\(Self.formatSeconds(startTime)),\"end\":\(Self.formatSeconds(endTime)),\"duration\":\(Self.formatSeconds(duration)),\"confidence\":\(Self.formatConfidence(confidence))}"
            )
        }

        return "{\n  \"segments\": [\n    \(segmentEntries.joined(separator: ",\n    "))\n  ]\n}"
    }

    // Formats second-based timing values with millisecond precision for karaoke synchronization.
    nonisolated static func formatSeconds(_ seconds: TimeInterval) -> String {
        String(format: "%.3f", seconds)
    }

    // Formats confidence values to keep exported timing payloads compact and stable.
    nonisolated static func formatConfidence(_ confidence: Float) -> String {
        String(format: "%.4f", confidence)
    }

    // Escapes JSON-sensitive characters so exported karaoke timing payloads stay valid.
    nonisolated static func escapeJSONString(_ value: String) -> String {
        var escaped = value.replacingOccurrences(of: "\\", with: "\\\\")
        escaped = escaped.replacingOccurrences(of: "\"", with: "\\\"")
        escaped = escaped.replacingOccurrences(of: "\n", with: "\\n")
        escaped = escaped.replacingOccurrences(of: "\r", with: "\\r")
        escaped = escaped.replacingOccurrences(of: "\t", with: "\\t")
        return escaped
    }
}
