import Foundation

// What the full-screen word view's top-bar buttons do: take the user from the word being sung to
// the same place in the lyrics view, the breakdown sheet, or the word's detail page.
extension ReadView {
    // Closes the full-screen word view, then runs `action` once its dismissal has finished — a
    // sheet or tab change raised in the same moment is dropped by SwiftUI.
    private func leaveWordFocus(then action: @escaping () -> Void) {
        audioPlayback.isShowingWordFocus = false
        Task {
            try? await Task.sleep(for: .milliseconds(450))
            action()
        }
    }

    // The lyrics view, already at the word: playback is where the word is, so nothing is seeked.
    func openLyricsFromWordFocus() {
        audioPlayback.isShowingWordFocus = false
        audioPlayback.isShowingLyricsView = true
    }

    // The breakdown sheet scrolled to the line holding the word.
    func openBreakdownFromWordFocus(atNoteLocation location: Int) {
        leaveWordFocus { openNoteDestination(.breakdown, atNoteLocation: location) }
    }

    // The word's detail page, for the entry the lookup sheet would show for it; nothing opens for a
    // word the dictionary doesn't know.
    func openWordDetailFromWordFocus(atNoteLocation location: Int, surface: String) {
        guard let entry = displayedDictionaryEntry(forSurface: surface, at: location) else {
            AppLog.info(.audioPlayback, "[ReadView] word detail requested from the word view for a word with no entry")
            return
        }
        leaveWordFocus { presentWordDetail(entryID: entry.entryId, surface: surface, reading: nil, sublatticePaths: []) }
    }
}
