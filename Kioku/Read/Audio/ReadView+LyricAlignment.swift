import SwiftUI
import UniformTypeIdentifiers

// Hosts the note-level lyric-alignment flow that uploads audio plus note text and saves returned subtitles.
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

    var subtitleImportErrorPresented: Binding<Bool> {
        Binding(
            get: { subtitleImportErrorMessage.isEmpty == false },
            set: { isPresented in
                if isPresented == false {
                    subtitleImportErrorMessage = ""
                }
            }
        )
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

    // Receives the file picker result for a subtitle file and stages it for import or surfaces an error.
    @MainActor
    func handleSubtitleImportSelection(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let selectedURLs):
            guard let sourceURL = selectedURLs.first else {
                subtitleImportErrorMessage = "No subtitle file was selected."
                return
            }
            pendingSubtitleFileURL = sourceURL
            pendingSubtitleFilename = sourceURL.lastPathComponent
        case .failure(let error):
            guard Self.isUserCancelledFileSelection(error) == false else {
                return
            }
            subtitleImportErrorMessage = error.localizedDescription
        }
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

    // Parses an SRT file and persists its cues and optionally its paired audio file to the current note.
    @MainActor
    func importSubtitles(
        from sourceURL: URL,
        audioURL: URL?,
        originalAudioFilename: String?
    ) async {
        do {
            let importedText = try Self.readImportedSubtitleText(from: sourceURL)
            let cues = SubtitleParser.parse(importedText)
            guard cues.isEmpty == false else {
                subtitleImportErrorMessage = "No subtitle cues were found in the selected file."
                return
            }

            let importedContent = SubtitleParser.assembleNoteContent(from: cues)
            let noteID = ensureNoteExistsForSubtitleImport(prefilledContent: importedContent)
            try saveImportedSubtitles(
                srtText: importedText,
                cues: cues,
                preferredFilename: sourceURL.lastPathComponent,
                noteID: noteID,
                audioURL: audioURL,
                originalAudioFilename: originalAudioFilename
            )
        } catch {
            subtitleImportErrorMessage = error.localizedDescription
        }
    }

    // Sends note lyrics and the staged audio to the alignment service and persists the resulting SRT.
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
        lyricAlignmentProgressMessage = "Uploading audio and lyrics..."
        lyricAlignmentSourceFilename = originalAudioFilename
        defer {
            isGeneratingLyricAlignment = false
            lyricAlignmentProgressMessage = ""
            lyricAlignmentSourceFilename = ""
        }

        do {
            let configuration = try LyricAlignmentSettings.configuration()
            lyricAlignmentProgressMessage = "Aligning lyrics..."
            let srtText = try await LyricAlignmentService.align(
                audioURL: sourceURL,
                lyrics: trimmedLyrics,
                configuration: configuration
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

    // Writes the server-returned SRT and paired audio file to disk and links them to the note.
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
                userInfo: [NSLocalizedDescriptionKey: "The alignment server returned text, but it was not valid SRT."]
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

    // Atomically persists a user-imported SRT (and optional audio) to a note attachment, auto-populating note text when empty.
    @MainActor
    func saveImportedSubtitles(
        srtText: String,
        cues: [SubtitleCue],
        preferredFilename: String,
        noteID: UUID,
        audioURL: URL?,
        originalAudioFilename: String?
    ) throws {
        let existingAttachmentID = notesStore.note(withID: noteID)?.audioAttachmentID
        let shouldReplaceAttachment = audioURL != nil
        let attachmentID = shouldReplaceAttachment ? UUID() : (existingAttachmentID ?? UUID())
        let importedContent = SubtitleParser.assembleNoteContent(from: cues)
        let shouldPopulateNoteText = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

        do {
            if let audioURL {
                _ = try NotesAudioStore.shared.saveAudio(from: audioURL, attachmentID: attachmentID)
            }
            try NotesAudioStore.shared.saveCues(cues, attachmentID: attachmentID)
            _ = try NotesAudioStore.shared.saveSRT(
                srtText,
                attachmentID: attachmentID,
                preferredFilename: preferredFilename.isEmpty
                    ? (originalAudioFilename.map(NotesAudioStore.preferredSubtitleFilename(forAudioFilename:)) ?? preferredFilename)
                    : preferredFilename
            )
        } catch {
            if existingAttachmentID == nil || shouldReplaceAttachment {
                NotesAudioStore.shared.deleteAttachment(attachmentID)
            }
            throw error
        }

        if existingAttachmentID == nil || shouldReplaceAttachment {
            notesStore.updateAudioAttachment(id: noteID, attachmentID: attachmentID)
        }

        if shouldReplaceAttachment, let existingAttachmentID, existingAttachmentID != attachmentID {
            NotesAudioStore.shared.deleteAttachment(existingAttachmentID)
        }

        if shouldPopulateNoteText {
            text = importedContent
            segments = nil
            if customTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                fallbackTitle = firstLineTitle(from: importedContent)
            }
            persistCurrentNoteIfNeeded()
            notesStore.flushPendingSave()
        }

        if activeNoteID == noteID {
            loadAudioAttachmentIfNeeded(attachmentID: attachmentID)
        }
    }

    var lyricAlignmentProgressOverlay: some View {
        ZStack {
            Color.black.opacity(0.15)
                .ignoresSafeArea()

            VStack(spacing: 10) {
                ProgressView()
                    .controlSize(.regular)
                Text(lyricAlignmentProgressMessage.isEmpty ? "Generating subtitles..." : lyricAlignmentProgressMessage)
                    .font(.headline)
                if lyricAlignmentSourceFilename.isEmpty == false {
                    Text(lyricAlignmentSourceFilename)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
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

    // Returns an existing note ID or creates a new note so subtitle import always has a target note to attach to.
    @MainActor
    private func ensureNoteExistsForSubtitleImport(prefilledContent: String) -> UUID {
        flushPendingNotePersistenceIfNeeded()

        if let activeNoteID {
            return activeNoteID
        }

        text = prefilledContent
        fallbackTitle = firstLineTitle(from: prefilledContent)
        flushPendingNotePersistenceIfNeeded()

        if let activeNoteID {
            return activeNoteID
        }

        let newNote = Note(content: prefilledContent)
        notesStore.addNote(newNote)
        activeNoteID = newNote.id
        selectedNote = newNote
        return newNote.id
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

    // Clears all staged subtitle and audio selection state, optionally cleaning up the temporary audio copy.
    @MainActor
    func clearPendingSubtitleAudioSelection(removeTemporaryFile: Bool = true) {
        let temporaryURL = pendingSubtitleAudioURL
        pendingSubtitleAudioURL = nil
        pendingSubtitleAudioFilename = ""
        pendingSubtitleFileURL = nil
        pendingSubtitleFilename = ""
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

    // Reads a subtitle file with security-scoped access and decodes it trying common encodings in order.
    nonisolated static func readImportedSubtitleText(from sourceURL: URL) throws -> String {
        let didStartAccess = sourceURL.startAccessingSecurityScopedResource()
        defer {
            if didStartAccess {
                sourceURL.stopAccessingSecurityScopedResource()
            }
        }

        let data = try Data(contentsOf: sourceURL)

        if let utf8 = String(data: data, encoding: .utf8) {
            return utf8
        }
        if let utf16 = String(data: data, encoding: .utf16) {
            return utf16
        }
        if let latin1 = String(data: data, encoding: .isoLatin1) {
            return latin1
        }
        return String(decoding: data, as: UTF8.self)
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
        guard let target else {
            return
        }

        switch target {
        case .transcriptionAudio:
            handleAudioImportSelection(result)
        case .subtitleAudio:
            handleLyricAlignmentAudioSelection(result)
        case .subtitleFile:
            handleSubtitleImportSelection(result)
        }
    }

    // Deletes the note's current subtitle attachment and stops audio so the user can start fresh.
    @MainActor
    func resetCurrentSubtitleAttachment() {
        clearPendingSubtitleAudioSelection()
        lyricAlignmentErrorMessage = ""
        subtitleImportErrorMessage = ""

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

    // Validates and submits both the staged audio and subtitle file, then triggers alignment or import accordingly.
    @MainActor
    func submitPendingSubtitleSelection() async {
        subtitleImportErrorMessage = ""
        lyricAlignmentErrorMessage = ""

        guard let audioURL = pendingSubtitleAudioURL else {
            lyricAlignmentErrorMessage = "Select an audio file before submitting."
            return
        }

        if let subtitleURL = pendingSubtitleFileURL {
            await importSubtitles(
                from: subtitleURL,
                audioURL: audioURL,
                originalAudioFilename: pendingSubtitleAudioFilename
            )
            guard subtitleImportErrorMessage.isEmpty else {
                return
            }
        } else {
            await generateAlignedSRT(
                fromPreparedAudioURL: audioURL,
                originalAudioFilename: pendingSubtitleAudioFilename
            )
            guard lyricAlignmentErrorMessage.isEmpty else {
                return
            }
        }

        try? FileManager.default.removeItem(at: audioURL)
        clearPendingSubtitleAudioSelection(removeTemporaryFile: false)
        isShowingSubtitleSubmissionSheet = false
    }
}
