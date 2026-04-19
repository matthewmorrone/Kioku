import SwiftUI
import UIKit

// Hosts note loading and persistence helpers for the read screen.
extension ReadView {
    // Persists the current note state immediately. Saving is cheap (it just hands off to
    // NotesStore.scheduleReadEditorPersist), so there's no benefit to debouncing here — and a
    // debounce silently drops writes if segments/furigana recompute before the timer fires.
    func scheduleCurrentNotePersistenceIfNeeded() {
        guard !isLoadingSelectedNote else { return }
        persistCurrentNoteIfNeeded()
    }

    // Flushes any pending NotesStore write immediately when the screen changes mode or disappears.
    func flushPendingNotePersistenceIfNeeded() {
        persistCurrentNoteIfNeeded()
        notesStore.flushPendingSave()
    }

    // Loads the selected note into editor state when navigation targets change.
    func loadSelectedNoteIfNeeded() {
        StartupTimer.mark("loadSelectedNoteIfNeeded called")
        guard let selectedNote else {
            // Clears stale read content only when the active note was deleted from storage.
            guard let currentActiveNoteID = activeNoteID, notesStore.note(withID: currentActiveNoteID) == nil else {
                return
            }

            segmentationRefreshTask?.cancel()
            furiganaComputationTask?.cancel()
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

        // If the selection re-publishes the note that's already active, skip the full reload —
        // otherwise in-flight edits in `text`/`customTitle` would be clobbered by the stored copy
        // before the next save lands.
        if selectedNote.id == activeNoteID {
            self.selectedNote = nil
            return
        }

        segmentationRefreshTask?.cancel()
        furiganaComputationTask?.cancel()
        pendingLLMChangedLocations = []
        pendingLLMChangedReadingLocations = []
        preLLMSegmentEntries = []
        hasPendingLLMChanges = false
        let noteToLoad = notesStore.note(withID: selectedNote.id) ?? selectedNote
        StartupTimer.mark("loadSelectedNoteIfNeeded preparing note")
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
        // if let encoded = try? JSONEncoder().encode(noteToLoad), let json = String(data: encoded, encoding: .utf8) {
        //     print("[NOTE LOAD] \(json)")
        // }
        if shouldActivateEditModeOnLoad {
            isEditMode = true
            shouldActivateEditModeOnLoad = false
        }
        // When segments are already persisted, apply them directly without running the segmenter.
        // If furigana annotations are present on the segments, restore them directly too.
        // The trie is still loaded in the background for lookup and new notes.
        if let loadedSegments, let edges = edgesFromSegmentRanges(loadedSegments, in: text) {
            StartupTimer.mark("loadSelectedNoteIfNeeded restoring persisted segments")
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
        StartupTimer.mark("loadSelectedNoteIfNeeded finished")
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
