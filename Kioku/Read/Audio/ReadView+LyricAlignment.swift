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
        if audioPlayback.activeAudioAttachmentID != nil {
            return true
        }

        guard let activeNoteID = document.activeNoteID else {
            return false
        }

        return notesStore.note(withID: activeNoteID)?.audioAttachmentID != nil
    }

    var lyricAlignmentErrorPresented: Binding<Bool> {
        Binding(
            get: { subtitleImport.lyricAlignmentErrorMessage.isEmpty == false },
            set: { isPresented in
                if isPresented == false {
                    subtitleImport.lyricAlignmentErrorMessage = ""
                }
            }
        )
    }

    var canOpenSubtitleFlow: Bool {
        subtitleImport.isGeneratingLyricAlignment == false
    }

    var generateSRTButton: some View {
        Group {
            if subtitleImport.isGeneratingLyricAlignment {
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
                if audioPlayback.activeAudioAttachmentID == nil,
                   let activeNoteID = document.activeNoteID,
                   let attachmentID = notesStore.note(withID: activeNoteID)?.audioAttachmentID {
                    loadAudioAttachmentIfNeeded(attachmentID: attachmentID)
                }
                audioPlayback.isShowingLyricsView = true
            } else {
                subtitleImport.isShowingSubtitlePopup = true
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
                subtitleImport.lyricAlignmentErrorMessage = "No audio file was selected."
                return
            }
            preparePendingSubtitleAudioSelection(from: sourceURL)
        case .failure(let error):
            subtitleImport.lyricAlignmentErrorMessage = error.localizedDescription
        }
    }

    // Uses on-device Whisper transcription to align note lyrics to the audio and persists the resulting SRT.
    @MainActor
    func generateAlignedSRT(fromPreparedAudioURL sourceURL: URL, originalAudioFilename: String) async {
        guard subtitleImport.isGeneratingLyricAlignment == false else {
            return
        }

        let trimmedLyrics = lyricsForAlignment
        guard trimmedLyrics.isEmpty == false else {
            subtitleImport.lyricAlignmentErrorMessage = "Add lyrics to the note before generating subtitles."
            return
        }

        let totalLines = trimmedLyrics
            .components(separatedBy: "\n")
            .filter { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false }
            .count

        flushPendingNotePersistenceIfNeeded()

        guard let noteID = document.activeNoteID else {
            subtitleImport.lyricAlignmentErrorMessage = "Save or enter note text before generating subtitles."
            return
        }

        subtitleImport.isGeneratingLyricAlignment = true
        subtitleImport.isCancellingAlignment = false
        subtitleImport.alignmentCancellationToken.reset()
        subtitleImport.alignmentResultSRT = ""
        subtitleImport.lyricAlignmentProgressMessage = "Preparing \(totalLines) lines..."
        subtitleImport.lyricAlignmentSourceFilename = originalAudioFilename
        defer {
            subtitleImport.isGeneratingLyricAlignment = false
            subtitleImport.isCancellingAlignment = false
            subtitleImport.lyricAlignmentProgressMessage = ""
            subtitleImport.lyricAlignmentSourceFilename = ""
        }

        do {
            subtitleImport.lyricAlignmentProgressMessage = "Aligning..."
            let cues = try await WholeSongAlignment.cues(
                audioURL: sourceURL,
                lyrics: trimmedLyrics,
                cancellationCheck: { [token = subtitleImport.alignmentCancellationToken] in token.isCancelled },
                onStage: { [self] stage in
                    Task { @MainActor in subtitleImport.lyricAlignmentProgressMessage = stage }
                }
            )
            subtitleImport.alignmentResultSRT = SubtitleParser.formatSRT(from: cues)
            subtitleImport.lyricAlignmentProgressMessage = "Saving subtitles..."
            try saveAlignedSubtitles(
                cues: cues,
                audioURL: sourceURL,
                originalAudioFilename: originalAudioFilename,
                noteID: noteID
            )
        } catch is CancellationError {
            subtitleImport.alignmentResultSRT = ""
        } catch {
            subtitleImport.lyricAlignmentErrorMessage = error.localizedDescription
        }
    }

    // Drives the Re-align failure alert from the message string.
    var cueRealignErrorPresented: Binding<Bool> {
        Binding(
            get: { lyricRealign.cueRealignErrorMessage.isEmpty == false },
            set: { presented in
                if presented == false { lyricRealign.cueRealignErrorMessage = "" }
            }
        )
    }

    // Cancels the in-progress alignment. The abort_callback polls this flag.
    @MainActor
    func cancelAlignment() {
        subtitleImport.isCancellingAlignment = true
        subtitleImport.alignmentCancellationToken.cancel()
    }

    // Re-runs the whole-song alignment over the note's lyrics against the already-attached
    // audio, then swaps the cue list in place — no wipe / re-import. Backs the karaoke bar's
    // "Re-align" action. Progress + spinner ride on `lyricRealign.isReAligningWholeNote`;
    // cancellation reuses the shared alignment token.
    @MainActor
    func realignWholeNote() async {
        guard lyricRealign.isReAligningWholeNote == false else { return }
        guard let attachmentID = audioPlayback.activeAudioAttachmentID,
              let audioURL = NotesAudioStore.shared.audioURL(for: attachmentID) else { return }

        let lyrics = lyricsForAlignment
        guard lyrics.isEmpty == false else {
            lyricRealign.cueRealignErrorMessage = "Add lyrics to the note before re-aligning."
            return
        }
        let totalLines = lyrics
            .components(separatedBy: "\n")
            .filter { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false }
            .count

        lyricRealign.isReAligningWholeNote = true
        lyricRealign.reAlignProgressMessage = "Re-aligning \(totalLines) lines…"
        subtitleImport.alignmentCancellationToken.reset()
        defer {
            lyricRealign.isReAligningWholeNote = false
            lyricRealign.reAlignProgressMessage = ""
        }

        do {
            let durationMs = audioPlayback.audioController.duration > 0 ? Int(audioPlayback.audioController.duration * 1000) : nil
            let cuesWithMarkers = try await WholeSongAlignment.cues(
                audioURL: audioURL,
                lyrics: lyrics,
                durationMs: durationMs,
                cancellationCheck: { [token = subtitleImport.alignmentCancellationToken] in token.isCancelled },
                // The stage string already carries its own per-phase percent
                // ("Isolating vocals… 73%", "Aligning lyrics… 45%"), so each phase shows
                // a true 0–100% of itself rather than a fudged combined bar.
                onStage: { [self] stage in
                    Task { @MainActor in lyricRealign.reAlignProgressMessage = stage }
                }
            )

            // Persist in place on the SAME attachment (the audio is unchanged), then swap cues
            // live so the karaoke highlight picks up the new timing without a playback reset.
            // cues.json is the single source of truth — the editor projects its SRT text from
            // these cues (♪ markers and all), so no .srt sidecar is written. Per-word checkpoints
            // ride inline on each cue.
            try NotesAudioStore.shared.saveCues(cuesWithMarkers, attachmentID: attachmentID)
            audioPlayback.audioAttachmentCues = cuesWithMarkers
            // Recompute the cue→note-line ranges against the NEW cue list. They map 1:1 with the
            // cues by position, so they must be regenerated whenever the cue list changes shape —
            // inserting ♪ markers shifts every index, and a stale array desyncs the active card,
            // the rows above it, and the mismatch flag (the karaoke view indexes both by the same
            // position).
            audioPlayback.audioAttachmentHighlightRanges = SubtitleParser.resolveHighlightRanges(for: cuesWithMarkers, in: document.text)
            audioPlayback.audioController.updateCues(cuesWithMarkers)
        } catch is CancellationError {
            // User navigated away / cancelled mid-run; nothing to surface.
        } catch {
            lyricRealign.cueRealignErrorMessage = "Couldn't re-align: \(error.localizedDescription)"
        }
    }

    // Writes the on-device alignment SRT and paired audio file to disk and links them to the note.
    @MainActor
    func saveAlignedSubtitles(
        cues: [SubtitleCue],
        audioURL: URL,
        originalAudioFilename: String,
        noteID: UUID,
        textGridURL: URL? = nil
    ) throws {
        guard cues.isEmpty == false else {
            throw NSError(
                domain: "Kioku.LyricAlignment",
                code: 4,
                userInfo: [NSLocalizedDescriptionKey: "Alignment produced no cues."]
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
        } catch {
            NotesAudioStore.shared.deleteAttachment(newAttachmentID)
            throw error
        }

        notesStore.updateAudioAttachment(id: noteID, attachmentID: newAttachmentID)

        if let previousAttachmentID, previousAttachmentID != newAttachmentID {
            NotesAudioStore.shared.deleteAttachment(previousAttachmentID)
        }

        if document.activeNoteID == noteID {
            loadAudioAttachmentIfNeeded(attachmentID: newAttachmentID)
            // loadAudioAttachmentIfNeeded resets audioPlayback.isShowingLyricsView to false (correct on
            // note-open, where the overlay should stay hidden). But this is an *explicit*
            // import/align completion — the user just asked for these cues — so reveal the
            // lyric overlay. Without this the cues load but sit at opacity 0 until the user
            // manually taps the ♪ button, which reads as "the import did nothing."
            audioPlayback.isShowingLyricsView = true
        }
    }

    // Drops a duplicated title line from the alignment payload when the note starts with the title.
    // This keeps alignment tolerant of notes shaped like "Title\n\nlyrics...".
    private var lyricsForAlignment: String {
        let normalizedText = document.text
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
            subtitleImport.pendingSubtitleAudioURL = try AudioTranscriptionHelpers.copyImportedAudioToTemporaryLocation(sourceURL)
            subtitleImport.pendingSubtitleAudioFilename = sourceURL.lastPathComponent
        } catch {
            subtitleImport.lyricAlignmentErrorMessage = error.localizedDescription
        }
    }

    // Clears staged audio selection state, optionally cleaning up the temporary copy.
    @MainActor
    func clearPendingSubtitleAudioSelection(removeTemporaryFile: Bool = true) {
        let temporaryURL = subtitleImport.pendingSubtitleAudioURL
        subtitleImport.pendingSubtitleAudioURL = nil
        subtitleImport.pendingSubtitleAudioFilename = ""
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
        subtitleImport.lyricAlignmentErrorMessage = ""

        guard let noteID = document.activeNoteID,
              let attachmentID = notesStore.note(withID: noteID)?.audioAttachmentID else {
            return
        }

        audioPlayback.audioController.stop()
        NotesAudioStore.shared.deleteAttachment(attachmentID)
        notesStore.updateAudioAttachment(id: noteID, attachmentID: nil)
        loadAudioAttachmentIfNeeded(attachmentID: nil)
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
                subtitleImport.lyricAlignmentErrorMessage = "Pick an audio file (mp3 / m4a) — the lyric view needs something to play."
                return
            }

            clearPendingSubtitleAudioSelection()
            clearPendingSubtitleFileSelection()
            clearPendingSubtitleTextGridSelection()

            preparePendingSubtitleAudioSelection(from: audioURL)
            guard subtitleImport.pendingSubtitleAudioURL != nil else { return } // staging error already surfaced

            if let srtURL { stagePendingSidecar(srtURL, as: .srt) }
            if let textGridURL { stagePendingSidecar(textGridURL, as: .textGrid) }

            Task { await submitPendingSubtitleSelection() }

        case .failure(let error):
            if Self.isUserCancelledFileSelection(error) == false {
                subtitleImport.lyricAlignmentErrorMessage = error.localizedDescription
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
                subtitleImport.pendingSubtitleFileURL = dest
                subtitleImport.pendingSubtitleFilename = sourceURL.lastPathComponent
            case .textGrid:
                subtitleImport.pendingSubtitleTextGridURL = dest
                subtitleImport.pendingSubtitleTextGridFilename = sourceURL.lastPathComponent
            default:
                break
            }
        } catch {
            subtitleImport.lyricAlignmentErrorMessage = error.localizedDescription
        }
    }

    // Clears any staged TextGrid file selection.
    @MainActor
    func clearPendingSubtitleTextGridSelection() {
        if let url = subtitleImport.pendingSubtitleTextGridURL {
            try? FileManager.default.removeItem(at: url)
        }
        subtitleImport.pendingSubtitleTextGridURL = nil
        subtitleImport.pendingSubtitleTextGridFilename = ""
    }

    // Receives the file picker result for an existing subtitle file and stages it.
    @MainActor
    func handleSubtitleFileSelection(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let sourceURL = urls.first else {
                subtitleImport.lyricAlignmentErrorMessage = "No subtitle file was selected."
                return
            }
            do {
                clearPendingSubtitleFileSelection()
                let didAccess = sourceURL.startAccessingSecurityScopedResource()
                defer { if didAccess { sourceURL.stopAccessingSecurityScopedResource() } }
                let tempDir = FileManager.default.temporaryDirectory
                let dest = tempDir.appendingPathComponent(UUID().uuidString + "_" + sourceURL.lastPathComponent)
                try FileManager.default.copyItem(at: sourceURL, to: dest)
                subtitleImport.pendingSubtitleFileURL = dest
                subtitleImport.pendingSubtitleFilename = sourceURL.lastPathComponent
            } catch {
                subtitleImport.lyricAlignmentErrorMessage = error.localizedDescription
            }
        case .failure(let error):
            if Self.isUserCancelledFileSelection(error) == false {
                subtitleImport.lyricAlignmentErrorMessage = error.localizedDescription
            }
        }
    }

    // Clears staged subtitle file selection.
    @MainActor
    func clearPendingSubtitleFileSelection() {
        if let url = subtitleImport.pendingSubtitleFileURL {
            try? FileManager.default.removeItem(at: url)
        }
        subtitleImport.pendingSubtitleFileURL = nil
        subtitleImport.pendingSubtitleFilename = ""
    }

    // Validates the staged audio and either imports the provided subtitle file
    // or triggers on-device alignment using the note text as lyrics.
    @MainActor
    func submitPendingSubtitleSelection() async {
        subtitleImport.lyricAlignmentErrorMessage = ""

        guard let audioURL = subtitleImport.pendingSubtitleAudioURL else {
            subtitleImport.lyricAlignmentErrorMessage = "Select an audio file before submitting."
            return
        }

        // Resolve the SRT to import, in priority order:
        //   1. An explicit subtitle file (.srt) — authoritative cue text.
        //   2. A TextGrid's coarsest interval tier, formatted as SRT — lets a `.TextGrid`-only
        //      pick produce a playable note (its finer tiers still bind karaoke checkpoints below).
        //   3. Neither → fall through to on-device forced alignment using the note text as lyrics.
        let resolvedSRT: String?
        if let subtitleURL = subtitleImport.pendingSubtitleFileURL {
            resolvedSRT = try? SubtitleSourceLoader.readText(from: subtitleURL)
        } else if let textGridURL = subtitleImport.pendingSubtitleTextGridURL,
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
                guard let noteID = document.activeNoteID else {
                    subtitleImport.lyricAlignmentErrorMessage = "Save or enter note text before importing subtitles."
                    return
                }
                let cues = SubtitleParser.parse(srtText)
                guard cues.isEmpty == false else {
                    subtitleImport.lyricAlignmentErrorMessage = "The subtitle file contained no cues."
                    return
                }
                try saveAlignedSubtitles(
                    cues: cues,
                    audioURL: audioURL,
                    originalAudioFilename: subtitleImport.pendingSubtitleAudioFilename,
                    noteID: noteID,
                    textGridURL: subtitleImport.pendingSubtitleTextGridURL
                )
                subtitleImport.alignmentResultSRT = srtText
            } catch {
                subtitleImport.lyricAlignmentErrorMessage = error.localizedDescription
            }
        } else {
            // No subtitle file or TextGrid — run forced alignment.
            await generateAlignedSRT(
                fromPreparedAudioURL: audioURL,
                originalAudioFilename: subtitleImport.pendingSubtitleAudioFilename
            )
            guard subtitleImport.lyricAlignmentErrorMessage.isEmpty else {
                return
            }
        }

        try? FileManager.default.removeItem(at: audioURL)
        clearPendingSubtitleAudioSelection(removeTemporaryFile: false)
        clearPendingSubtitleFileSelection()
        clearPendingSubtitleTextGridSelection()
    }

}
