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

        pendingPersistenceTask = Task {
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled else { return }

            await MainActor.run {
                guard
                    text == snapshotText,
                    customTitle == snapshotTitle,
                    segments == snapshotSegmentRanges,
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
    // Cancels any in-flight text-change debounce and writes the current state to disk now.
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
            illegalMergeBoundaryLocation = nil
            pendingLLMChangedLocations = []
            pendingLLMChangedReadingLocations = []
            preLLMSegmentEntries = []
            hasPendingLLMChanges = false
            SegmentLookupSheet.shared.dismissPopover()
            isLoadingSelectedNote = false
            return
        }

        pendingPersistenceTask?.cancel()
        pendingPersistenceTask = nil
        pendingLLMChangedLocations = []
        pendingLLMChangedReadingLocations = []
        preLLMSegmentEntries = []
        hasPendingLLMChanges = false
        let noteToLoad = notesStore.note(withID: selectedNote.id) ?? selectedNote
        isLoadingSelectedNote = true
        activeNoteID = noteToLoad.id
        sharedScrollOffsetY = 0
        onActiveNoteChanged?(noteToLoad.id)
        // Load or unload the audio attachment whenever the active note changes.
        loadAudioAttachmentIfNeeded(attachmentID: noteToLoad.audioAttachmentID)
        customTitle = noteToLoad.title
        fallbackTitle = noteToLoad.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? firstLineTitle(from: noteToLoad.content)
            : noteToLoad.title
        text = noteToLoad.content
        let loadedSegments = normalizedSegmentRanges(
            noteToLoad.segments,
            for: noteToLoad.content
        )
        segments = loadedSegments
        if let encoded = try? JSONEncoder().encode(noteToLoad), let json = String(data: encoded, encoding: .utf8) {
            print("[NOTE LOAD] \(json)")
        }
        if shouldActivateEditModeOnLoad {
            isEditMode = true
            shouldActivateEditModeOnLoad = false
        }
        // When segments are already persisted, apply them directly without running the segmenter.
        // If furigana annotations are present on the segments, restore them directly too.
        // The trie is still loaded in the background for lookup and new notes.
        if let loadedSegments, let edges = edgesFromSegmentRanges(loadedSegments, in: text) {
            segmentEdges = edges
            segmentRanges = edges.map { $0.start..<$0.end }
            unknownSegmentLocations = []
            let restoredFurigana = furiganaFromSegmentRanges(loadedSegments)
            if restoredFurigana.byLocation.isEmpty == false {
                furiganaBySegmentLocation = restoredFurigana.byLocation
                furiganaLengthBySegmentLocation = restoredFurigana.lengthByLocation
            } else {
                scheduleFuriganaGeneration(for: text, edges: edges)
            }
        } else {
            refreshSegmentationRanges()
        }
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
            segments: segments
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
