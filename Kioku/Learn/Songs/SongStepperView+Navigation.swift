import SwiftUI

// Links the breakdown to the same song's lyrics view: opening on a given line (from a lyric cue or
// a word's source note), and sending a line back to the lyrics view. Lines are tied to the note
// through lineNoteRangesByIndex (SongBreakdownLineLocator), the same placement the furigana uses.
extension SongStepperView {
    // Parks the mini player on, expands and scrolls to the line holding focusNoteLocation, once the
    // rows are placed in the note. Runs at most once per view, so later row refreshes (streaming,
    // option toggles) never yank the scroll back.
    func applyFocusIfNeeded() {
        guard hasAppliedFocus == false, let location = focusNoteLocation, lineNoteRangesByIndex.isEmpty == false else { return }
        hasAppliedFocus = true
        let placed = lineNoteRangesByIndex.sorted { $0.value.location < $1.value.location }
        // The line holding the location, else the nearest one before it (a line the breakdown
        // skipped, like a blank or a dropped ad-lib).
        let match = placed.first(where: { NSLocationInRange(location, $0.value) })
            ?? placed.last(where: { $0.value.location <= location })
        guard let lineIndex = match?.key else { return }
        currentPlaybackStep = .line(lineIndex)
        expandedByLineIndex.insert(lineIndex)
        focusScrollLineIndex = lineIndex
    }

    // Brings the focused line to center. Waits a beat first: on open the sheet is still
    // presenting and the lazy stack hasn't laid out, so an immediate scrollTo lands short.
    func scrollToFocusedLine(proxy: ScrollViewProxy, items: [SongLineDisplayItem]) async {
        guard let lineIndex = focusScrollLineIndex,
              let item = items.first(where: { $0.line.index == lineIndex }) else { return }
        try? await Task.sleep(nanoseconds: 350_000_000)
        guard Task.isCancelled == false else { return }
        withAnimation(.easeInOut(duration: 0.3)) {
            proxy.scrollTo(item.id, anchor: .center)
        }
    }

    // A line card's long-press menu: open the line in the lyrics view, when the song has audio.
    @ViewBuilder
    func lineContextMenu(for line: SongLine) -> some View {
        if note.audioAttachmentID != nil {
            Button {
                openLineInLyrics(line)
            } label: {
                Label("Open in Lyrics", systemImage: "music.mic")
            }
        }
    }

    // The line the mini player is parked on, for the options menu's "Open Line in Lyrics".
    var currentStepLine: SongLine? {
        guard case .line(let index) = currentPlaybackStep else { return nil }
        return currentLines.first { $0.index == index }
    }

    // Opens the lyrics view seeked to `line`. Routed through ReadNoteNavigation so it works the
    // same from the Read tab's sheet (which closes) and from the Learn tab (which hands over to
    // Read); the line's text is the fallback when the breakdown couldn't place it in the note.
    func openLineInLyrics(_ line: SongLine) {
        ReadNoteNavigation.shared.pendingTarget = ReadNoteTarget(
            noteID: note.id,
            surface: line.original.trimmingCharacters(in: .whitespacesAndNewlines),
            noteLocation: lineNoteRangesByIndex[line.index]?.location,
            destination: .lyrics
        )
    }
}
