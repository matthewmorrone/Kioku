import Foundation

// On-device Whisper transcription path (audio → note), selected when
// TranscriptionEngine.current == .whisper. Mirrors the Apple-Speech path's note
// lifecycle (begin → stream status → finalize with cues) but routes through
// SwiftWhisperTranscriptionProvider with the Small model. Forced alignment is
// untouched and stays on Base — see TranscriptionModelProvider.
extension ReadView {

    // Transcribes one imported audio file with Whisper and creates a note with cues.
    func transcribeAudioFileWithWhisper(at sourceURL: URL) async {
        guard isPerformingAudioTranscription == false else { return }
        isPerformingAudioTranscription = true
        defer { isPerformingAudioTranscription = false }

        let noteID = beginStreamingTranscriptionNote(totalChunks: 1)

        do {
            let copiedURL = try AudioTranscriptionHelpers.copyImportedAudioToTemporaryLocation(sourceURL)
            defer { try? FileManager.default.removeItem(at: copiedURL) }

            // 1. Ensure the Small transcription model (first use downloads ~466 MB).
            setWhisperTranscriptionNote(id: noteID, statusLine: "Preparing Whisper model…", body: "")
            let modelURL = try await TranscriptionModelProvider.ensureModel { [self] fraction in
                let pct = Int((fraction * 100).rounded())
                Task { @MainActor in
                    setWhisperTranscriptionNote(
                        id: noteID,
                        statusLine: "Downloading Whisper model (\(TranscriptionModelProvider.downloadSizeText)) \(pct)%…",
                        body: ""
                    )
                }
            }

            setWhisperTranscriptionNote(id: noteID, statusLine: "Transcribing audio…", body: "")

            // 2. Whole-file Whisper transcription (Japanese pinned inside the provider).
            let provider = SwiftWhisperTranscriptionProvider(modelURL: modelURL)
            let segments = try await provider.transcribe(url: copiedURL)

            // 3. Whisper segments are already phrase-level — map them straight to cues.
            let cues = Self.makeSubtitleCues(from: segments)
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

    // Maps Whisper segments (second-based) to millisecond SubtitleCues, one per
    // non-empty segment, with sequential 1-based indices.
    private static func makeSubtitleCues(from segments: [AlignmentSegment]) -> [SubtitleCue] {
        var cues: [SubtitleCue] = []
        for seg in segments {
            let trimmed = seg.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.isEmpty == false else { continue }
            cues.append(SubtitleCue(
                index: cues.count + 1,
                startMs: max(0, Int((seg.start * 1000).rounded())),
                endMs: max(0, Int((seg.end * 1000).rounded())),
                text: trimmed
            ))
        }
        return cues
    }

    // Writes a free-form status line (and optional body) into the streaming note,
    // mirroring updateStreamingTranscriptionNote's note/text update so the in-flight
    // note shows live progress.
    func setWhisperTranscriptionNote(id: UUID, statusLine: String, body: String) {
        let bodyText = body.trimmingCharacters(in: .whitespacesAndNewlines)
        let noteContent = bodyText.isEmpty ? "[\(statusLine)]" : "[\(statusLine)]\n\n\(bodyText)"
        let titleToSave = firstLineTitle(from: noteContent)
        _ = notesStore.upsertNote(id: id, title: titleToSave, content: noteContent, segments: nil)
        if activeNoteID == id {
            isLoadingSelectedNote = true
            customTitle = titleToSave
            fallbackTitle = titleToSave
            text = noteContent
            segments = nil
            isLoadingSelectedNote = false
        }
    }
}
