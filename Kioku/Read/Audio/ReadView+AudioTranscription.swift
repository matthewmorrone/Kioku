import AVFoundation
import NaturalLanguage
// @preconcurrency: Speech (SFTranscription, SFSpeechRecognitionTask, ...) predates Swift
// concurrency and its types aren't Sendable. The Task.detached + checked-continuation
// pattern at line 365+ wraps SFTranscription crossings safely; this import opts that
// boundary out of Swift 6 strict checking rather than annotating each use site.
@preconcurrency import Speech
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
            isShowingFileImporter = true
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
        .fileImporter(
            isPresented: $isShowingFileImporter,
            allowedContentTypes: [.audio, .mpeg4Audio, .mp3],
            allowsMultipleSelection: false
        ) { result in
            isShowingFileImporter = false
            handleAudioImportSelection(result)
        }
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

    // Runs the selected transcription engine for one imported audio file and creates a new note with transcript and karaoke timing data.
    func transcribeAudioFile(at sourceURL: URL) async {
        guard isPerformingAudioTranscription == false else {
            return
        }

        // Route to the on-device Whisper engine when selected; otherwise fall through
        // to the built-in Apple Speech path below. Forced alignment is unaffected.
        if TranscriptionEngine.current == .whisper {
            await transcribeAudioFileWithWhisper(at: sourceURL)
            return
        }

        isPerformingAudioTranscription = true
        defer {
            isPerformingAudioTranscription = false
        }

        do {
            let copiedURL = try AudioTranscriptionHelpers.copyImportedAudioToTemporaryLocation(sourceURL)
            defer {
                try? FileManager.default.removeItem(at: copiedURL)
            }

            try await AudioTranscriptionHelpers.requestSpeechAuthorizationIfNeeded()
            let contextualStrings = AudioTranscriptionHelpers.makeSpeechContextualStrings(from: text, title: resolvedTitle)
            let audioDuration = try await AudioTranscriptionHelpers.audioDuration(for: copiedURL)
            var chunkRanges = try await Self.makeSpeechActiveChunkRanges(for: copiedURL, maxChunkDuration: 12.0, overlap: 0.4)
            if chunkRanges.isEmpty {
                // Falls back to fixed chunking when speech-activity detection finds no reliable active regions.
                chunkRanges = try await Self.makeChunkRanges(for: copiedURL, chunkDuration: 12.0, overlap: 0.4)
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

            if AudioTranscriptionHelpers.shouldRetryForLowYield(transcript: firstPassResult.transcript, durationSeconds: audioDuration) {
                let retryChunkRanges = try await Self.makeChunkRanges(for: copiedURL, chunkDuration: 8.0, overlap: 0.8)
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

            let lineLevelCues = AudioTranscriptionHelpers.makeLineLevelSubtitleCues(
                from: bestSegments,
                fallbackTranscript: bestTranscript,
                audioDurationSeconds: audioDuration
            )
            let finalText = SubtitleParser.assembleNoteContent(from: lineLevelCues)
            let attachmentID = UUID()
            _ = try NotesAudioStore.shared.saveAudio(from: copiedURL, attachmentID: attachmentID)
            try NotesAudioStore.shared.saveCues(lineLevelCues, attachmentID: attachmentID)
            await MainActor.run {
                finalizeStreamingTranscriptionNote(
                    id: transcriptionNoteID,
                    finalText: finalText,
                    attachmentID: attachmentID
                )
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
                let chunkURL = try await AudioTranscriptionHelpers.exportAudioChunk(
                    from: sourceURL,
                    start: chunkRange.start,
                    end: chunkRange.end,
                    index: chunkIndex
                )
                defer {
                    try? FileManager.default.removeItem(at: chunkURL)
                }

                let chunkTranscription = try await AudioTranscriptionHelpers.recognizeTranscription(from: chunkURL, contextualStrings: contextualStrings)
                collectedSegments.append(contentsOf: chunkTranscription.segments)

                let chunkText = chunkTranscription.formattedString.trimmingCharacters(in: .whitespacesAndNewlines)
                if chunkText.isEmpty == false {
                    accumulatedTranscript = AudioTranscriptionHelpers.mergeChunkTranscript(accumulatedTranscript, chunkText)
                }
            } catch {
                if AudioTranscriptionHelpers.isNoSpeechDetectedError(error) == false {
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
    func finalizeStreamingTranscriptionNote(id: UUID, finalText: String, attachmentID: UUID?) {
        let normalizedText = finalText.trimmingCharacters(in: .whitespacesAndNewlines)
        let titleToSave = firstLineTitle(from: normalizedText)

        _ = notesStore.upsertNote(
            id: id,
            title: titleToSave,
            content: normalizedText,
            segments: nil
        )
        notesStore.updateAudioAttachment(id: id, attachmentID: attachmentID)

        if activeNoteID == id {
            isLoadingSelectedNote = true
            customTitle = titleToSave
            fallbackTitle = titleToSave
            text = normalizedText
            segments = nil
            loadAudioAttachmentIfNeeded(attachmentID: attachmentID)
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

}
