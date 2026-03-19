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
        let snapshotSegmentRanges = segments
        let snapshotActiveNoteID = activeNoteID
        let snapshotReadingOverrides = selectedReadingOverrideByLocation

        pendingPersistenceTask = Task {
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled else { return }

            await MainActor.run {
                guard
                    text == snapshotText,
                    customTitle == snapshotTitle,
                    segments == snapshotSegmentRanges,
                    activeNoteID == snapshotActiveNoteID,
                    selectedReadingOverrideByLocation == snapshotReadingOverrides
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
            loadAudioAttachmentIfNeeded(attachmentID: nil)
            customTitle = ""
            fallbackTitle = ""
            text = ""
            segments = nil
            segmentLatticeEdges = []
            segmentEdges = []
            segmentRanges = []
            unknownSegmentLocations = []
            selectedSegmentLocation = nil
            selectedHighlightRangeOverride = nil
            selectedBounds = nil
            furiganaBySegmentLocation = [:]
            furiganaLengthBySegmentLocation = [:]
            selectedReadingOverrideByLocation = [:]
            illegalMergeBoundaryLocation = nil
            SegmentLookupSheet.shared.dismissPopover()
            isLoadingSelectedNote = false
            return
        }

        pendingPersistenceTask?.cancel()
        pendingPersistenceTask = nil
        let noteToLoad = notesStore.note(withID: selectedNote.id) ?? selectedNote
        isLoadingSelectedNote = true
        activeNoteID = noteToLoad.id
        onActiveNoteChanged?(noteToLoad.id)
        // Load or unload the audio attachment whenever the active note changes.
        loadAudioAttachmentIfNeeded(attachmentID: noteToLoad.audioAttachmentID)
        customTitle = noteToLoad.title
        fallbackTitle = noteToLoad.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? firstLineTitle(from: noteToLoad.content)
            : noteToLoad.title
        text = noteToLoad.content
        segments = normalizedSegmentRanges(
            noteToLoad.segments,
            for: noteToLoad.content
        )
        selectedReadingOverrideByLocation = noteToLoad.readingOverrides ?? [:]
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
        let trimmedTitle = customTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        // Don't create a note when both content and title are blank.
        // For a brand-new note not yet in the store this avoids persisting a completely empty entry.
        // For an existing saved note, allow blank saves so the user can intentionally clear content.
        if trimmedText.isEmpty && trimmedTitle.isEmpty {
            if activeNoteID == nil { return }
            if notesStore.note(withID: activeNoteID!) == nil { return }
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
            segments: segments,
            readingOverrides: selectedReadingOverrideByLocation.isEmpty ? nil : selectedReadingOverrideByLocation
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
