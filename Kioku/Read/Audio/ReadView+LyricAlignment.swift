import SwiftUI
import UniformTypeIdentifiers

// Hosts the note-level lyric-alignment flow: transcribes audio on-device using SwiftWhisper,
// aligns transcription segments to note text lines, and saves the resulting SRT.
extension ReadView {
    var hasEditableSubtitles: Bool {
        if activeAudioAttachmentID != nil {
            return true
        }

        guard let activeNoteID else {
            return false
        }

        return notesStore.note(withID: activeNoteID)?.audioAttachmentID != nil
    }

    var lyricAlignmentErrorPresented: Binding<Bool> {
        Binding(
            get: { lyricAlignmentErrorMessage.isEmpty == false },
            set: { isPresented in
                if isPresented == false {
                    lyricAlignmentErrorMessage = ""
                }
            }
        )
    }

    var canOpenSubtitleFlow: Bool {
        isGeneratingLyricAlignment == false
    }

    var generateSRTButton: some View {
        Group {
            if isGeneratingLyricAlignment {
                ProgressView()
                    .controlSize(.small)
            } else {
                Image(systemName: "captions.bubble")
                    .font(.system(size: 14, weight: .semibold))
            }
        }
        .foregroundStyle(canOpenSubtitleFlow ? Color.accentColor : Color.secondary)
        .frame(width: 30, height: 30)
        .background(
            Capsule()
                .fill(Color(.tertiarySystemFill))
        )
        .contentShape(Capsule())
        .onTapGesture {
            guard canOpenSubtitleFlow else {
                return
            }
            if hasEditableSubtitles {
                presentSubtitleEditorIfPossible()
            } else {
                isShowingSubtitleSubmissionSheet = true
            }
        }
        .onLongPressGesture(minimumDuration: 0.45) {
            guard canOpenSubtitleFlow else {
                return
            }
            resetCurrentSubtitleAttachment()
        }
        .opacity(canOpenSubtitleFlow ? 1 : 0.6)
        .accessibilityLabel("Subtitles")
        .accessibilityHint("Press and hold to clear attached audio and subtitles")
    }

    // Receives the file picker result for an alignment audio file and copies it to a temporary staging location.
    @MainActor
    func handleLyricAlignmentAudioSelection(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let selectedURLs):
            guard let sourceURL = selectedURLs.first else {
                lyricAlignmentErrorMessage = "No audio file was selected."
                return
            }
            preparePendingSubtitleAudioSelection(from: sourceURL)
        case .failure(let error):
            lyricAlignmentErrorMessage = error.localizedDescription
        }
    }

    // Uses on-device Whisper transcription to align note lyrics to the audio and persists the resulting SRT.
    @MainActor
    func generateAlignedSRT(fromPreparedAudioURL sourceURL: URL, originalAudioFilename: String) async {
        guard isGeneratingLyricAlignment == false else {
            return
        }

        let trimmedLyrics = lyricsForAlignment
        guard trimmedLyrics.isEmpty == false else {
            lyricAlignmentErrorMessage = "Add lyrics to the note before generating subtitles."
            return
        }

        flushPendingNotePersistenceIfNeeded()

        guard let noteID = activeNoteID else {
            lyricAlignmentErrorMessage = "Save or enter note text before generating subtitles."
            return
        }

        isGeneratingLyricAlignment = true
        lyricAlignmentProgressMessage = "Preparing..."
        lyricAlignmentSourceFilename = originalAudioFilename
        defer {
            isGeneratingLyricAlignment = false
            lyricAlignmentProgressMessage = ""
            lyricAlignmentSourceFilename = ""
        }

        do {
            // Use an existing model, or download the default one automatically.
            let modelURL: URL
            if let existing = OnDeviceLyricAligner.bestAvailableModelURL() {
                modelURL = existing
            } else {
                lyricAlignmentProgressMessage = "Downloading Whisper model (142 MB)..."
                modelURL = try await OnDeviceLyricAligner.downloadDefaultModel { [self] message in
                    lyricAlignmentProgressMessage = message
                }
            }

            print("[LyricAlignment] using on-device model: \(modelURL.lastPathComponent)")
            lyricAlignmentProgressMessage = "Transcribing audio..."

            // Accumulate decoded text so the overlay shows what Whisper has heard so far.
            var transcribedSoFar = ""
            let srtText = try await OnDeviceLyricAligner.align(
                audioURL: sourceURL,
                lyrics: trimmedLyrics,
                modelURL: modelURL,
                onProgress: { [self] fraction in
                    // fraction is 0–1; show percentage once inference has started.
                    let pct = Int((fraction * 100).rounded())
                    lyricAlignmentProgressMessage = pct > 0
                        ? "Transcribing audio... \(pct)%"
                        : "Transcribing audio..."
                },
                onSegment: { [self] segmentText in
                    // Append each decoded segment so the user can see results streaming in.
                    transcribedSoFar += segmentText
                    // Keep the overlay text short — show only the tail of what's been decoded.
                    let tail = String(transcribedSoFar.suffix(120))
                    lyricAlignmentProgressMessage = tail
                }
            )

            lyricAlignmentProgressMessage = "Saving subtitles..."
            try saveAlignedSubtitles(
                srtText: srtText,
                audioURL: sourceURL,
                originalAudioFilename: originalAudioFilename,
                noteID: noteID
            )
        } catch {
            lyricAlignmentErrorMessage = error.localizedDescription
        }
    }

    // Writes the on-device alignment SRT and paired audio file to disk and links them to the note.
    @MainActor
    func saveAlignedSubtitles(
        srtText: String,
        audioURL: URL,
        originalAudioFilename: String,
        noteID: UUID
    ) throws {
        let cues = SubtitleParser.parse(srtText)
        guard cues.isEmpty == false else {
            throw NSError(
                domain: "Kioku.LyricAlignment",
                code: 4,
                userInfo: [NSLocalizedDescriptionKey: "Alignment produced output but it was not valid SRT."]
            )
        }

        let previousAttachmentID = notesStore.note(withID: noteID)?.audioAttachmentID
        let newAttachmentID = UUID()

        do {
            _ = try NotesAudioStore.shared.saveAudio(from: audioURL, attachmentID: newAttachmentID)
            try NotesAudioStore.shared.saveCues(cues, attachmentID: newAttachmentID)
            _ = try NotesAudioStore.shared.saveSRT(
                srtText,
                attachmentID: newAttachmentID,
                preferredFilename: NotesAudioStore.preferredSubtitleFilename(forAudioFilename: originalAudioFilename)
            )
        } catch {
            NotesAudioStore.shared.deleteAttachment(newAttachmentID)
            throw error
        }

        notesStore.updateAudioAttachment(id: noteID, attachmentID: newAttachmentID)

        if let previousAttachmentID, previousAttachmentID != newAttachmentID {
            NotesAudioStore.shared.deleteAttachment(previousAttachmentID)
        }

        if activeNoteID == noteID {
            loadAudioAttachmentIfNeeded(attachmentID: newAttachmentID)
        }
    }

    var lyricAlignmentProgressOverlay: some View {
        ZStack {
            Color.black.opacity(0.15)
                .ignoresSafeArea()

            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    ProgressView()
                        .controlSize(.regular)
                    if lyricAlignmentSourceFilename.isEmpty == false {
                        Text(lyricAlignmentSourceFilename)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                // Show streaming transcript text when available, otherwise a status label.
                Text(lyricAlignmentProgressMessage.isEmpty ? "Generating subtitles..." : lyricAlignmentProgressMessage)
                    .font(.callout)
                    .foregroundStyle(.primary)
                    .lineLimit(4)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: 280, alignment: .leading)
                    .animation(.easeInOut(duration: 0.15), value: lyricAlignmentProgressMessage)
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 18)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        }
    }

    // Drops a duplicated title line from the alignment payload when the note starts with the title.
    // This keeps alignment tolerant of notes shaped like "Title\n\nlyrics...".
    private var lyricsForAlignment: String {
        let normalizedText = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalizedText.isEmpty == false else {
            return ""
        }

        let trimmedTitle = resolvedTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedTitle.isEmpty == false else {
            return normalizedText
        }

        let lines = normalizedText.components(separatedBy: "\n")
        guard let firstNonEmptyLineIndex = lines.firstIndex(where: {
            $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        }) else {
            return normalizedText
        }

        let firstLine = lines[firstNonEmptyLineIndex].trimmingCharacters(in: .whitespacesAndNewlines)
        guard firstLine == trimmedTitle else {
            return normalizedText
        }

        let remainingLines = Array(lines.dropFirst(firstNonEmptyLineIndex + 1))
        let remainingText = remainingLines
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return remainingText.isEmpty ? normalizedText : remainingText
    }

    // Copies the selected audio file to a temporary location so security-scoped access can be released.
    @MainActor
    private func preparePendingSubtitleAudioSelection(from sourceURL: URL) {
        do {
            clearPendingSubtitleAudioSelection()
            pendingSubtitleAudioURL = try Self.copyImportedAudioToTemporaryLocation(sourceURL)
            pendingSubtitleAudioFilename = sourceURL.lastPathComponent
        } catch {
            lyricAlignmentErrorMessage = error.localizedDescription
        }
    }

    // Clears staged audio selection state, optionally cleaning up the temporary copy.
    @MainActor
    func clearPendingSubtitleAudioSelection(removeTemporaryFile: Bool = true) {
        let temporaryURL = pendingSubtitleAudioURL
        pendingSubtitleAudioURL = nil
        pendingSubtitleAudioFilename = ""
        if removeTemporaryFile, let temporaryURL {
            try? FileManager.default.removeItem(at: temporaryURL)
        }
    }

    // Removes only the pending audio selection (not the subtitle file) when the user de-selects audio.
    @MainActor
    func removePendingSubtitleAudioSelection() {
        let temporaryURL = pendingSubtitleAudioURL
        pendingSubtitleAudioURL = nil
        pendingSubtitleAudioFilename = ""
        if let temporaryURL {
            try? FileManager.default.removeItem(at: temporaryURL)
        }
    }

    // Distinguishes user-initiated cancellation from real errors so the UI does not show a spurious error message.
    nonisolated static func isUserCancelledFileSelection(_ error: Error) -> Bool {
        let nsError = error as NSError
        return nsError.domain == NSCocoaErrorDomain && nsError.code == NSUserCancelledError
    }

    // Opens the system file importer scoped to the correct file types for the given import target.
    @MainActor
    func presentFileImporter(for target: ReadViewFileImportTarget) {
        activeFileImportTarget = target
        isShowingFileImporter = true
    }

    // Routes a file importer result to the correct handler based on which import flow is active.
    @MainActor
    func handleFileImportSelection(_ result: Result<[URL], Error>, target: ReadViewFileImportTarget?) {
        switch target {
        case .transcriptionAudio:
            handleAudioImportSelection(result)
        case .subtitleAudio:
            handleLyricAlignmentAudioSelection(result)
        case .none:
            break
        }
    }

    // Deletes the note's current subtitle attachment and stops audio so the user can start fresh.
    @MainActor
    func resetCurrentSubtitleAttachment() {
        clearPendingSubtitleAudioSelection()
        lyricAlignmentErrorMessage = ""

        guard let noteID = activeNoteID,
              let attachmentID = notesStore.note(withID: noteID)?.audioAttachmentID else {
            return
        }

        audioController.stop()
        NotesAudioStore.shared.deleteAttachment(attachmentID)
        notesStore.updateAudioAttachment(id: noteID, attachmentID: nil)
        loadAudioAttachmentIfNeeded(attachmentID: nil)
    }

    // Ensures an audio attachment is loaded before opening the subtitle editor so the editor always has cue data.
    @MainActor
    func presentSubtitleEditorIfPossible() {
        if activeAudioAttachmentID == nil,
           let activeNoteID,
           let attachmentID = notesStore.note(withID: activeNoteID)?.audioAttachmentID {
            loadAudioAttachmentIfNeeded(attachmentID: attachmentID)
        }

        if activeAudioAttachmentID != nil {
            isShowingSubtitleEditor = true
        }
    }

    // Validates the staged audio and triggers on-device alignment using the note text as lyrics.
    @MainActor
    func submitPendingSubtitleSelection() async {
        lyricAlignmentErrorMessage = ""

        guard let audioURL = pendingSubtitleAudioURL else {
            lyricAlignmentErrorMessage = "Select an audio file before submitting."
            return
        }

        await generateAlignedSRT(
            fromPreparedAudioURL: audioURL,
            originalAudioFilename: pendingSubtitleAudioFilename
        )
        guard lyricAlignmentErrorMessage.isEmpty else {
            return
        }

        try? FileManager.default.removeItem(at: audioURL)
        clearPendingSubtitleAudioSelection(removeTemporaryFile: false)
        isShowingSubtitleSubmissionSheet = false
    }
}
