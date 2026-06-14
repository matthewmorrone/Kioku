import SwiftUI
import UniformTypeIdentifiers
import SwiftWhisperAlign

// Thread-safe cancellation flag for alignment. The @State Bool drives UI; this token
// is what we hand to the @Sendable cancellationCheck closure so whisper.cpp can poll
// from inference threads without crossing actor isolation. cancelAlignment() flips both.
nonisolated final class AlignmentCancellationToken: @unchecked Sendable {
    private let lock = NSLock()
    private var _isCancelled = false
    // Thread-safe read of the cancellation flag, polled from whisper.cpp inference threads.
    var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return _isCancelled
    }
    // Signals cancellation so the next abort_callback poll returns true.
    func cancel() {
        lock.lock(); _isCancelled = true; lock.unlock()
    }
    // Clears the flag before starting a new alignment run.
    func reset() {
        lock.lock(); _isCancelled = false; lock.unlock()
    }
}

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
                isShowingSubtitlePopup = true
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

        let totalLines = trimmedLyrics
            .components(separatedBy: "\n")
            .filter { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false }
            .count

        flushPendingNotePersistenceIfNeeded()

        guard let noteID = activeNoteID else {
            lyricAlignmentErrorMessage = "Save or enter note text before generating subtitles."
            return
        }

        isGeneratingLyricAlignment = true
        isCancellingAlignment = false
        alignmentCancellationToken.reset()
        alignmentResultSRT = ""
        lyricAlignmentProgressMessage = "Preparing \(totalLines) lines..."
        lyricAlignmentSourceFilename = originalAudioFilename
        defer {
            isGeneratingLyricAlignment = false
            isCancellingAlignment = false
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
            lyricAlignmentProgressMessage = "Aligning..."

            let srtText = try await OnDeviceLyricAligner.align(
                audioURL: sourceURL,
                lyrics: trimmedLyrics,
                modelURL: modelURL,
                cancellationCheck: { [token = alignmentCancellationToken] in token.isCancelled },
                onProgress: { [self] fraction in
                    let pct = Int((fraction * 100).rounded())
                    if pct > 0 {
                        Task { @MainActor in
                            lyricAlignmentProgressMessage = "Aligning \(totalLines) lines... \(pct)%"
                        }
                    }
                },
                onSegment: { [self] partialLines in
                    let n = partialLines.count
                    let lastText = partialLines.last?.text ?? ""
                    // Build partial SRT from the lines aligned so far.
                    let partial = partialLines.enumerated().map { i, line in
                        let startTs = SwiftWhisperAlign.SRTWriter.timestamp(line.start)
                        let endTs = SwiftWhisperAlign.SRTWriter.timestamp(line.end)
                        return "\(i + 1)\n\(startTs) --> \(endTs)\n\(line.text)"
                    }.joined(separator: "\n\n")
                    Task { @MainActor in
                        lyricAlignmentProgressMessage = "Line \(n)/\(totalLines): \(lastText)"
                        alignmentResultSRT = partial
                    }
                }
            )

            alignmentResultSRT = srtText
            lyricAlignmentProgressMessage = "Saving subtitles..."
            try saveAlignedSubtitles(
                srtText: srtText,
                audioURL: sourceURL,
                originalAudioFilename: originalAudioFilename,
                noteID: noteID
            )
            checkForSubtitleMismatches()
        } catch is CancellationError {
            // User cancelled — no error to show.
            alignmentResultSRT = ""
        } catch {
            lyricAlignmentErrorMessage = error.localizedDescription
        }
    }

    // Checks for mismatches between subtitle cue text and note text after save,
    // and presents a resolution dialog if any are found.
    @MainActor
    func checkForSubtitleMismatches() {
        let count = audioAttachmentCues.enumerated().filter { index, cue in
            guard index < audioAttachmentHighlightRanges.count,
                  let range = audioAttachmentHighlightRanges[index],
                  let swiftRange = Range(range, in: text) else {
                return false
            }
            let noteLineText = String(text[swiftRange])
            return noteLineText != cue.text
                && SubtitleParser.isNonSpeechCue(cue.text) == false
        }.count

        if count > 0 {
            subtitleMismatchCount = count
            isShowingSubtitleMismatchDialog = true
        }
    }

    // Cancels the in-progress alignment. The abort_callback polls this flag.
    @MainActor
    func cancelAlignment() {
        isCancellingAlignment = true
        alignmentCancellationToken.cancel()
    }

    // Writes the on-device alignment SRT and paired audio file to disk and links them to the note.
    @MainActor
    func saveAlignedSubtitles(
        srtText: String,
        audioURL: URL,
        originalAudioFilename: String,
        noteID: UUID,
        textGridURL: URL? = nil
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
            // Optional karaoke checkpoints from a paired TextGrid, folded into the cues before saving.
            // Best-effort: a TextGrid that doesn't bind (wrong format, no matching intervals) just
            // means no per-character timing, never a failed import — so it's gated on a non-empty
            // result and uses `try?` for the read/bind.
            var cuesToSave = cues
            if let textGridURL,
               let content = try? SubtitleSourceLoader.readText(from: textGridURL),
               let timings = SubtitleSourceLoader.bindCheckpoints(textGridContent: content, cues: cues),
               timings.isEmpty == false {
                cuesToSave = cues.applyingCheckpoints(timings)
            }
            try NotesAudioStore.shared.saveCues(cuesToSave, attachmentID: newAttachmentID)
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
            pendingSubtitleAudioURL = try AudioTranscriptionHelpers.copyImportedAudioToTemporaryLocation(sourceURL)
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

    // Distinguishes user-initiated cancellation from real errors so the UI does not show a spurious error message.
    nonisolated static func isUserCancelledFileSelection(_ error: Error) -> Bool {
        let nsError = error as NSError
        return nsError.domain == NSCocoaErrorDomain && nsError.code == NSUserCancelledError
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

    // Receives the lyric-button quick-load picker result: a mixed bag of audio / srt / textgrid.
    // Sorts by kind (first of each wins), then stages and imports in one pass. Audio is required —
    // the lyric view needs something to play — while srt/textgrid are optional companions.
    @MainActor
    func handleLyricMediaSelection(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            var audioURL: URL?
            var srtURL: URL?
            var textGridURL: URL?
            for url in urls {
                switch SubtitleSourceLoader.classify(url) {
                case .audio: if audioURL == nil { audioURL = url }
                case .srt: if srtURL == nil { srtURL = url }
                case .textGrid: if textGridURL == nil { textGridURL = url }
                case .unknown: break
                }
            }

            guard let audioURL else {
                lyricAlignmentErrorMessage = "Pick an audio file (mp3 / m4a) — the lyric view needs something to play."
                return
            }

            clearPendingSubtitleAudioSelection()
            clearPendingSubtitleFileSelection()
            clearPendingSubtitleTextGridSelection()

            preparePendingSubtitleAudioSelection(from: audioURL)
            guard pendingSubtitleAudioURL != nil else { return } // staging error already surfaced

            if let srtURL { stagePendingSidecar(srtURL, as: .srt) }
            if let textGridURL { stagePendingSidecar(textGridURL, as: .textGrid) }

            Task { await submitPendingSubtitleSelection() }

        case .failure(let error):
            if Self.isUserCancelledFileSelection(error) == false {
                lyricAlignmentErrorMessage = error.localizedDescription
            }
        }
    }

    // Copies a security-scoped subtitle/textgrid file to a temporary location and records it as the
    // pending sidecar of the given kind. Shared by the quick-load picker for both companion types.
    @MainActor
    private func stagePendingSidecar(_ sourceURL: URL, as kind: SubtitleSourceLoader.Kind) {
        do {
            let didAccess = sourceURL.startAccessingSecurityScopedResource()
            defer { if didAccess { sourceURL.stopAccessingSecurityScopedResource() } }
            let tempDir = FileManager.default.temporaryDirectory
            let dest = tempDir.appendingPathComponent(UUID().uuidString + "_" + sourceURL.lastPathComponent)
            try FileManager.default.copyItem(at: sourceURL, to: dest)
            switch kind {
            case .srt:
                pendingSubtitleFileURL = dest
                pendingSubtitleFilename = sourceURL.lastPathComponent
            case .textGrid:
                pendingSubtitleTextGridURL = dest
                pendingSubtitleTextGridFilename = sourceURL.lastPathComponent
            default:
                break
            }
        } catch {
            lyricAlignmentErrorMessage = error.localizedDescription
        }
    }

    // Clears any staged TextGrid file selection.
    @MainActor
    func clearPendingSubtitleTextGridSelection() {
        if let url = pendingSubtitleTextGridURL {
            try? FileManager.default.removeItem(at: url)
        }
        pendingSubtitleTextGridURL = nil
        pendingSubtitleTextGridFilename = ""
    }

    // Receives the file picker result for an existing subtitle file and stages it.
    @MainActor
    func handleSubtitleFileSelection(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let sourceURL = urls.first else {
                lyricAlignmentErrorMessage = "No subtitle file was selected."
                return
            }
            do {
                clearPendingSubtitleFileSelection()
                let didAccess = sourceURL.startAccessingSecurityScopedResource()
                defer { if didAccess { sourceURL.stopAccessingSecurityScopedResource() } }
                let tempDir = FileManager.default.temporaryDirectory
                let dest = tempDir.appendingPathComponent(UUID().uuidString + "_" + sourceURL.lastPathComponent)
                try FileManager.default.copyItem(at: sourceURL, to: dest)
                pendingSubtitleFileURL = dest
                pendingSubtitleFilename = sourceURL.lastPathComponent
            } catch {
                lyricAlignmentErrorMessage = error.localizedDescription
            }
        case .failure(let error):
            if Self.isUserCancelledFileSelection(error) == false {
                lyricAlignmentErrorMessage = error.localizedDescription
            }
        }
    }

    // Clears staged subtitle file selection.
    @MainActor
    func clearPendingSubtitleFileSelection() {
        if let url = pendingSubtitleFileURL {
            try? FileManager.default.removeItem(at: url)
        }
        pendingSubtitleFileURL = nil
        pendingSubtitleFilename = ""
    }

    // Validates the staged audio and either imports the provided subtitle file
    // or triggers on-device alignment using the note text as lyrics.
    @MainActor
    func submitPendingSubtitleSelection() async {
        lyricAlignmentErrorMessage = ""

        guard let audioURL = pendingSubtitleAudioURL else {
            lyricAlignmentErrorMessage = "Select an audio file before submitting."
            return
        }

        // Resolve the SRT to import, in priority order:
        //   1. An explicit subtitle file (.srt) — authoritative cue text.
        //   2. A TextGrid's coarsest interval tier, formatted as SRT — lets a `.TextGrid`-only
        //      pick produce a playable note (its finer tiers still bind karaoke checkpoints below).
        //   3. Neither → fall through to on-device forced alignment using the note text as lyrics.
        let resolvedSRT: String?
        if let subtitleURL = pendingSubtitleFileURL {
            resolvedSRT = try? SubtitleSourceLoader.readText(from: subtitleURL)
        } else if let textGridURL = pendingSubtitleTextGridURL,
                  let content = try? SubtitleSourceLoader.readText(from: textGridURL),
                  let cues = try? SubtitleSourceLoader.deriveCues(fromTextGrid: content),
                  cues.isEmpty == false {
            resolvedSRT = SubtitleParser.formatSRT(from: cues)
        } else {
            resolvedSRT = nil
        }

        if let srtText = resolvedSRT {
            // We have cue text (from SRT or a TextGrid) — import directly, skip alignment.
            do {
                flushPendingNotePersistenceIfNeeded()
                guard let noteID = activeNoteID else {
                    lyricAlignmentErrorMessage = "Save or enter note text before importing subtitles."
                    return
                }
                try saveAlignedSubtitles(
                    srtText: srtText,
                    audioURL: audioURL,
                    originalAudioFilename: pendingSubtitleAudioFilename,
                    noteID: noteID,
                    textGridURL: pendingSubtitleTextGridURL
                )
                alignmentResultSRT = srtText
                checkForSubtitleMismatches()
            } catch {
                lyricAlignmentErrorMessage = error.localizedDescription
            }
        } else {
            // No subtitle file or TextGrid — run forced alignment.
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
        clearPendingSubtitleFileSelection()
        clearPendingSubtitleTextGridSelection()
    }

    // Rewrites subtitle cues to use the note text for each line, preserving timestamps.
    // Resolves mismatches caused by Whisper transcription errors in the alignment output.
    @MainActor
    func syncSubtitlesToNote() {
        guard let attachmentID = activeAudioAttachmentID else { return }

        let updatedCues = audioAttachmentCues.enumerated().map { index, cue -> SubtitleCue in
            guard index < audioAttachmentHighlightRanges.count,
                  let range = audioAttachmentHighlightRanges[index],
                  let swiftRange = Range(range, in: text) else {
                return cue
            }
            let noteLineText = String(text[swiftRange])
            return SubtitleCue(index: cue.index, startMs: cue.startMs, endMs: cue.endMs, text: noteLineText)
        }

        do {
            try NotesAudioStore.shared.saveCues(updatedCues, attachmentID: attachmentID)
            let srtText = SubtitleParser.formatSRT(from: updatedCues)
            _ = try NotesAudioStore.shared.saveSRT(srtText, attachmentID: attachmentID)
            audioAttachmentCues = updatedCues
            // Re-resolve highlight ranges now that cue text matches note text exactly.
            audioAttachmentHighlightRanges = SubtitleParser.resolveHighlightRanges(for: updatedCues, in: text)
        } catch {
            print("[SyncSubtitles] failed to save updated cues: \(error)")
        }
    }

    // Replaces note text lines with the corresponding subtitle cue text, preserving timestamps.
    // Useful when the subtitle text is considered authoritative (e.g. from a reference SRT).
    @MainActor
    func syncNoteToSubtitles() {
        var newText = text
        // Apply replacements in reverse order so earlier ranges stay valid.
        let replacements: [(NSRange, String)] = audioAttachmentCues.enumerated().compactMap { index, cue in
            guard index < audioAttachmentHighlightRanges.count,
                  let range = audioAttachmentHighlightRanges[index],
                  let swiftRange = Range(range, in: newText) else { return nil }
            let noteLineText = String(newText[swiftRange])
            guard noteLineText != cue.text else { return nil }
            return (range, cue.text)
        }.reversed()

        for (range, replacement) in replacements {
            guard let swiftRange = Range(range, in: newText) else { continue }
            newText.replaceSubrange(swiftRange, with: replacement)
        }

        text = newText
        // Re-resolve highlight ranges against the updated note text.
        audioAttachmentHighlightRanges = SubtitleParser.resolveHighlightRanges(for: audioAttachmentCues, in: text)
    }
}
