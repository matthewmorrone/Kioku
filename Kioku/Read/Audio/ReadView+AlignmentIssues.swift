import SwiftUI
import LyricAlignment

// The places a finished alignment found the note's lyrics and the singing disagree
// (LyricAlignmentIssue): opening their list when a run finds any, playing one, dropping one,
// transcribing one's stretch of the vocals and inserting that text into the note beside the line
// it belongs next to, replacing the lyrics with the edited sung-order preview and re-aligning, and
// handing the note to edit mode so the lyrics can be fixed by hand.
extension ReadView {
    // Records the issues a run found for `attachmentID` (and the sung order it suggests, if any)
    // and opens their list when there are any. A run with none clears whatever an earlier run left.
    @MainActor
    func presentAlignmentIssues(_ issues: [LyricAlignmentIssue], sungOrder: [LyricSungOrderEntry]?, attachmentID: UUID?) {
        lyricAlignment.issues = issues
        lyricAlignment.sungOrder = issues.isEmpty ? nil : sungOrder
        lyricAlignment.issuesAttachmentID = attachmentID
        lyricAlignment.isShowingIssues = issues.isEmpty == false && attachmentID != nil
        if issues.isEmpty == false {
            AppLog.info(.audioAlignment, "alignment issues: \(issues.count)")
        }
    }

    // The issues that belong to the song attached now; empty after switching notes or audio.
    var currentAlignmentIssues: [LyricAlignmentIssue] {
        guard let attachmentID = audioPlayback.activeAudioAttachmentID,
              lyricAlignment.issuesAttachmentID == attachmentID else { return [] }
        return lyricAlignment.issues
    }

    // The sung order suggested for the song attached now; nil after switching notes or audio.
    var currentSungOrder: [LyricSungOrderEntry]? {
        guard let attachmentID = audioPlayback.activeAudioAttachmentID,
              lyricAlignment.issuesAttachmentID == attachmentID else { return nil }
        return lyricAlignment.sungOrder
    }

    // Drives the issue list sheet.
    var alignmentIssuesPresented: Binding<Bool> {
        Binding(
            get: { lyricAlignment.isShowingIssues },
            set: { lyricAlignment.isShowingIssues = $0 }
        )
    }

    // Plays `issue` from a second before it, on the lyrics card, with the list closed.
    @MainActor
    func listenToAlignmentIssue(_ issue: LyricAlignmentIssue) {
        lyricAlignment.isShowingIssues = false
        audioPlayback.isShowingLyricsView = true
        audioPlayback.audioController.seek(toMs: max(0, issue.startMs - 1000))
        audioPlayback.audioController.play()
    }

    // Drops `issue` from the list (ignored, or fixed by an insert); the list closes once nothing is left.
    @MainActor
    func ignoreAlignmentIssue(_ issue: LyricAlignmentIssue) {
        lyricAlignment.issues.removeAll { $0.id == issue.id }
        if lyricAlignment.issues.isEmpty { lyricAlignment.isShowingIssues = false }
    }

    // The words heard in [startMs, endMs) of the isolated vocals (half a second of slack each side),
    // for an issue row or the sung-order preview to offer as lyrics. Nil when transcription isn't
    // available (before iOS 26) or failed; empty when nothing was heard.
    func transcribeSongStretch(startMs: Int, endMs: Int) async -> String? {
        guard #available(iOS 26.0, *),
              let attachmentID = audioPlayback.activeAudioAttachmentID,
              let audioURL = NotesAudioStore.shared.audioURL(for: attachmentID) else { return nil }
        let source = VocalStemCache.playableStemURL(for: audioURL) ?? audioURL
        do {
            return try await AppleSpeechTranscription.transcribeClip(
                of: source,
                startSec: Double(startMs) / 1000 - 0.5,
                endSec: Double(endMs) / 1000 + 0.5
            ).trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            AppLog.error(.audioAlignment, "transcribing \(startMs)-\(endMs) ms failed: \(error)")
            return nil
        }
    }

    // Replaces the note's lyrics (the range alignment reads) with `lyrics`, the edited sung-order
    // preview, closes the list and re-aligns, which also re-checks for issues. False when the note
    // has no lyrics range to replace.
    @MainActor
    func applySungOrder(_ lyrics: String) -> Bool {
        let replacement = lyrics.trimmingCharacters(in: .whitespacesAndNewlines)
        guard replacement.isEmpty == false, let range = lyricsRangeForAlignment else { return false }
        let original = (document.text as NSString).substring(with: range)
        lyricAlignment.isShowingIssues = false
        if original != replacement {
            replaceNoteText([TextConversion(range: range, original: original, replacement: replacement, source: .sungOrder)])
        }
        Task { await realignWholeNote() }
        return true
    }

    // Whether transcription can run here at all, so the row only offers it when it can.
    var canTranscribeAlignmentIssues: Bool {
        if #available(iOS 26.0, *) { return true }
        return false
    }

    // Inserts `text` into the note as its own line, next to the issue's anchor line: before it for
    // singing with no line, after it otherwise. False when the anchor line can't be found in the note
    // any more. The new line has no timing until the song is re-aligned. The issue is dropped once
    // its text is in.
    @MainActor
    func insertAlignmentIssueText(_ text: String, for issue: LyricAlignmentIssue) -> Bool {
        let line = text.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        guard line.isEmpty == false, let anchorStartMs = issue.anchorStartMs,
              let cueIndex = audioPlayback.audioAttachmentCues.firstIndex(where: { $0.startMs == anchorStartMs }),
              cueIndex < audioPlayback.audioAttachmentHighlightRanges.count,
              let anchorRange = audioPlayback.audioAttachmentHighlightRanges[cueIndex] else { return false }
        let note = document.text as NSString
        let location: Int
        let insertion: String
        if issue.insertsBeforeAnchor {
            location = note.lineRange(for: NSRange(location: anchorRange.location, length: 0)).location
            insertion = line + "\n"
        } else {
            let lineEnd = note.range(of: "\n", range: NSRange(location: NSMaxRange(anchorRange), length: note.length - NSMaxRange(anchorRange)))
            location = lineEnd.location == NSNotFound ? note.length : lineEnd.location
            insertion = "\n" + line
        }
        replaceNoteText([TextConversion(
            range: NSRange(location: location, length: 0), original: "", replacement: insertion, source: .transcription
        )])
        // Fixed, so it leaves the list and the banner, as an applied Breakdown fix does.
        ignoreAlignmentIssue(issue)
        return true
    }

    // Closes the list and the lyrics card and turns on edit mode, so the lyrics can be fixed.
    @MainActor
    func editLyricsForAlignmentIssues() {
        lyricAlignment.isShowingIssues = false
        audioPlayback.audioController.pause()
        audioPlayback.isShowingLyricsView = false
        editModeScroll.isEditMode = true
    }

    // The issue list sheet's content.
    var alignmentIssueListSheet: some View {
        NavigationStack {
            LyricAlignmentIssueListView(
                issues: currentAlignmentIssues,
                sungOrder: currentSungOrder,
                canTranscribe: canTranscribeAlignmentIssues,
                onListen: { listenToAlignmentIssue($0) },
                onTranscribe: { await transcribeSongStretch(startMs: $0, endMs: $1) },
                onApplySungOrder: { applySungOrder($0) },
                onInsert: { insertAlignmentIssueText($0, for: $1) },
                onIgnore: { ignoreAlignmentIssue($0) },
                onEditLyrics: { editLyricsForAlignmentIssues() },
                onDone: { lyricAlignment.isShowingIssues = false }
            )
        }
        .presentationDetents([.medium, .large])
    }
}
