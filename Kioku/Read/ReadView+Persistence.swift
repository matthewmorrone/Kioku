import SwiftUI
import UIKit

// Hosts note loading and persistence helpers for the read screen.
extension ReadView {
    // Schedules the current note state for background persistence so large pastes do not block the UI.
    func scheduleCurrentNotePersistenceIfNeeded() {
        guard !isLoadingSelectedNote else { return }

        pendingPersistenceTask?.cancel()
        let snapshotText = text
        let snapshotTitle = customTitle
        let snapshotTokenRanges = tokenRanges
        let snapshotActiveNoteID = activeNoteID

        pendingPersistenceTask = Task {
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled else { return }

            await MainActor.run {
                guard
                    text == snapshotText,
                    customTitle == snapshotTitle,
                    tokenRanges == snapshotTokenRanges,
                    activeNoteID == snapshotActiveNoteID
                else {
                    return
                }

                persistCurrentNoteIfNeeded()
                pendingPersistenceTask = nil
            }
        }
    }

    // Flushes any pending persistence work immediately when the screen changes mode or disappears.
    func flushPendingNotePersistenceIfNeeded() {
        pendingPersistenceTask?.cancel()
        pendingPersistenceTask = nil
        persistCurrentNoteIfNeeded()
    }

    // Loads the selected note into editor state when navigation targets change.
    func loadSelectedNoteIfNeeded() {
        guard let selectedNote else {
            // Clears stale read content only when the active note was deleted from storage.
            guard let currentActiveNoteID = activeNoteID, notesStore.note(withID: currentActiveNoteID) == nil else {
                return
            }

            pendingPersistenceTask?.cancel()
            pendingPersistenceTask = nil
            isLoadingSelectedNote = true
            activeNoteID = nil
            customTitle = ""
            fallbackTitle = ""
            text = ""
            tokenRanges = nil
            segmentationLatticeEdges = []
            segmentationEdges = []
            segmentationRanges = []
            unknownSegmentLocations = []
            selectedSegmentLocation = nil
            selectedHighlightRangeOverride = nil
            selectedMergedEdgeBounds = nil
            furiganaBySegmentLocation = [:]
            furiganaLengthBySegmentLocation = [:]
            illegalMergeBoundaryLocation = nil
            SegmentDefinitionPopoverPresenter.shared.dismissPopover()
            isLoadingSelectedNote = false
            return
        }

        pendingPersistenceTask?.cancel()
        pendingPersistenceTask = nil
        let noteToLoad = notesStore.note(withID: selectedNote.id) ?? selectedNote
        isLoadingSelectedNote = true
        activeNoteID = noteToLoad.id
        onActiveNoteChanged?(noteToLoad.id)
        customTitle = noteToLoad.title
        fallbackTitle = noteToLoad.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? firstLineTitle(from: noteToLoad.content)
            : noteToLoad.title
        text = noteToLoad.content
        tokenRanges = normalizedTokenRanges(
            noteToLoad.tokenRanges,
            for: noteToLoad.content
        )
        if shouldActivateEditModeOnLoad {
            isEditMode = true
            shouldActivateEditModeOnLoad = false
        }
        refreshSegmentationRanges()
        self.selectedNote = nil
        isLoadingSelectedNote = false
    }

    // Saves the in-memory editor state to storage and maintains active note identity.
    func persistCurrentNoteIfNeeded() {
        guard !isLoadingSelectedNote else { return }

        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // Avoid creating an empty note when the editor has no active note yet.
        if trimmedText.isEmpty && activeNoteID == nil {
            return
        }

        // Prefer explicit titles; otherwise derive one from first content line.
        let titleToSave = customTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? firstLineTitle(from: text)
            : customTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        fallbackTitle = titleToSave

        let savedNoteID = notesStore.scheduleReadEditorPersist(
            id: activeNoteID,
            title: titleToSave,
            content: text,
            tokenRanges: tokenRanges
        )
        activeNoteID = savedNoteID
        onActiveNoteChanged?(savedNoteID)
    }

    var resolvedTitle: String {
        let trimmedCustom = customTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedCustom.isEmpty {
            return trimmedCustom
        }

        return fallbackTitle
    }

    var displayTitle: String {
        resolvedTitle.isEmpty ? " " : resolvedTitle
    }

    // Derives a fallback title from the first line of note content.
    func firstLineTitle(from content: String) -> String {
        let firstLine = content.components(separatedBy: .newlines).first?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return firstLine
    }

}
