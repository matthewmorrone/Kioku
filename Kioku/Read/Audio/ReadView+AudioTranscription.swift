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
        guard isPerformingAudioTranscription == false else { return }
        isPerformingAudioTranscription = true
        defer { isPerformingAudioTranscription = false }

        // One shared engine for every import path (see AudioTranscriptionService). Qwen3 isolates the
        // vocal stem first; Apple Speech chunks; Whisper needs a model. The note shows a status line
        // rather than streaming partial text — the tradeoff for a single transcription core.
        let engine = TranscriptionEngine.current
        let noteID = beginStreamingTranscriptionNote(totalChunks: 1)
        do {
            let copiedURL = try AudioTranscriptionHelpers.copyImportedAudioToTemporaryLocation(sourceURL)
            defer { try? FileManager.default.removeItem(at: copiedURL) }

            let contextual = AudioTranscriptionHelpers.makeSpeechContextualStrings(from: text, title: resolvedTitle)

            // Whisper alone needs a downloaded model — fetch it (with download progress) first.
            var modelURL: URL?
            if engine == .whisper {
                setWhisperTranscriptionNote(id: noteID, statusLine: "Preparing Whisper model…", body: "")
                modelURL = try await TranscriptionModelProvider.ensureModel { [self] fraction in
                    let pct = Int((fraction * 100).rounded())
                    Task { @MainActor in
                        setWhisperTranscriptionNote(id: noteID, statusLine: "Downloading Whisper model (\(TranscriptionModelProvider.downloadSizeText)) \(pct)%…", body: "")
                    }
                }
            }

            let isolate = TranscriptionPreprocessing.isolateVocals
            setWhisperTranscriptionNote(id: noteID, statusLine: isolate ? "Isolating vocals…" : "Transcribing audio…", body: "")
            let cues = try await AudioTranscriptionService.transcribe(
                url: copiedURL, engine: engine, isolateVocals: isolate,
                whisperModelURL: modelURL, contextualStrings: contextual
            )
            guard cues.isEmpty == false else {
                audioTranscriptionErrorMessage = "No speech was recognized in the selected audio file."
                setWhisperTranscriptionNote(id: noteID, statusLine: "No speech recognized", body: "")
                return
            }

            let finalText = SubtitleParser.assembleNoteContent(from: cues)
            let attachmentID = UUID()
            _ = try NotesAudioStore.shared.saveAudio(from: copiedURL, attachmentID: attachmentID)
            try NotesAudioStore.shared.saveCues(cues, attachmentID: attachmentID)
            await MainActor.run {
                finalizeStreamingTranscriptionNote(id: noteID, finalText: finalText, attachmentID: attachmentID)
            }
        } catch {
            audioTranscriptionErrorMessage = error.localizedDescription
            setWhisperTranscriptionNote(id: noteID, statusLine: "Transcription failed", body: error.localizedDescription)
        }
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

}
