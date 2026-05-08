import SwiftUI
import UIKit

// One queued automatic-segmentation invocation awaiting user confirmation. The action enum
// names the deferred work (rather than a closure) so PendingAutoSegRequest can be Identifiable
// and SwiftUI's `.alert(item:)` can drive the dialog. On confirm, dispatch executes the named
// action against current ReadView state.
struct PendingAutoSegRequest: Identifiable {
    let id = UUID()
    let reason: String
    let action: AutoSegAction
}

enum AutoSegAction {
    case refreshSegmentationRanges
    case scheduleFuriganaGeneration(sourceText: String, edges: [LatticeEdge])

    // String fingerprint used to dedupe queue entries. Two requests with the same fingerprint
    // do not deserve two prompts — they're the same work re-requested by a different caller.
    var dedupeKey: String {
        switch self {
        case .refreshSegmentationRanges:
            return "refreshSegmentationRanges"
        case .scheduleFuriganaGeneration(let sourceText, let edges):
            return "scheduleFuriganaGeneration|\(sourceText.utf16.count)|\(edges.count)|\(edges.first?.surface ?? "")|\(edges.last?.surface ?? "")"
        }
    }
}

// Hosts note loading and persistence helpers for the read screen.
extension ReadView {
    // Persists the current note state immediately. Saving is cheap (it just hands off to
    // NotesStore.scheduleReadEditorPersist), so there's no benefit to debouncing here — and a
    // debounce silently drops writes if segments/furigana recompute before the timer fires.
    func scheduleCurrentNotePersistenceIfNeeded(reason: String = #function) {
        guard !isLoadingSelectedNote else { return }
        persistCurrentNoteIfNeeded(reason: reason)
    }

    // Flushes any pending NotesStore write immediately when the screen changes mode or disappears.
    func flushPendingNotePersistenceIfNeeded(reason: String = #function) {
        persistCurrentNoteIfNeeded(reason: reason)
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
        // Mark the value we're about to assign so the deferred onChange(of: text) can skip
        // its recompute path — without this, every note load fires segmentation twice.
        lastLoadedTextSnapshot = noteToLoad.content
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
            furiganaBySegmentLocation = restoredFurigana.byLocation
            furiganaLengthBySegmentLocation = restoredFurigana.lengthByLocation
            // Always schedule a compute pass — backfill semantics in scheduleFuriganaGeneration
            // mean existing entries are preserved while gaps (e.g. a missing per-run annotation
            // on the second kanji of 抜け殻) get filled in. The public scheduleFuriganaGeneration
            // already early-returns on kana-only edge sets, so kana notes don't trigger a prompt.
            scheduleFuriganaGeneration(for: text, edges: edges)
        } else {
            refreshSegmentationRanges()
        }

        // showLoadInfoToast(for: noteToLoad)  // disabled — re-enable to show disk/mem counts on each load
        self.selectedNote = nil
        isLoadingSelectedNote = false
        StartupTimer.mark("loadSelectedNoteIfNeeded finished")
    }

    // Saves the in-memory editor state to storage and maintains active note identity.
    func persistCurrentNoteIfNeeded(reason _: String = #function) {
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

    // Confirm dialog disabled — auto-dispatch the action directly so auto-seg runs as if every
    // prompt were tapped Confirm. To re-enable the dialog: restore the queue-append logic
    // below, restore the `.alert(...)` modifier in ReadView (alertingReadView), and remove the
    // direct switch dispatch.
    func requestAutoSegConfirm(reason _: String, action: AutoSegAction) {
        switch action {
        case .refreshSegmentationRanges:
            performRefreshSegmentationRanges()
        case .scheduleFuriganaGeneration(let sourceText, let edges):
            performScheduleFuriganaGeneration(for: sourceText, edges: edges)
        }
        // let trimmedReason = reason.split(separator: "(").first.map(String.init) ?? reason
        // if pendingAutoSegQueue.contains(where: { $0.action.dedupeKey == action.dedupeKey }) {
        //     return
        // }
        // pendingAutoSegQueue.append(
        //     PendingAutoSegRequest(reason: trimmedReason, action: action)
        // )
    }

    // Dispatches a confirmed auto-segmentation request, then drops it from the queue.
    func commitPendingAutoSeg(_ request: PendingAutoSegRequest) {
        switch request.action {
        case .refreshSegmentationRanges:
            performRefreshSegmentationRanges()
        case .scheduleFuriganaGeneration(let sourceText, let edges):
            performScheduleFuriganaGeneration(for: sourceText, edges: edges)
        }
        dropPendingAutoSeg(request)
    }

    // Discards a queued auto-segmentation request without running its action.
    func cancelPendingAutoSeg(_ request: PendingAutoSegRequest) {
        dropPendingAutoSeg(request)
    }

    private func dropPendingAutoSeg(_ request: PendingAutoSegRequest) {
        if let index = pendingAutoSegQueue.firstIndex(where: { $0.id == request.id }) {
            pendingAutoSegQueue.remove(at: index)
        }
    }

    // Pops a transient overlay showing disk vs. in-memory seg/furigana counts whenever a note
    // loads. Lets the user see at a glance whether persisted data round-trips correctly without
    // having to wait for a confirm prompt to fire. When disk segments fail to concat-validate
    // against disk text, the toast also shows the length mismatch so we can diagnose which side
    // of the persist drifted.
    func showLoadInfoToast(for note: Note) {
        let diskSegs = note.segments?.count ?? 0
        let diskFuri = note.segments?.reduce(0) { $0 + ($1.furigana?.count ?? 0) } ?? 0
        let memSegs = segments?.count ?? 0
        let memFuri = furiganaBySegmentLocation.count
        let titleSnippet = note.title.isEmpty
            ? String(note.content.prefix(12))
            : String(note.title.prefix(12))

        // Length-check the disk data to reveal mismatches that cause normalizedSegmentRanges to
        // reject otherwise-present data.
        let diskTextLen = note.content.utf16.count
        let diskSegLen = note.segments?.reduce(0) { $0 + $1.surface.utf16.count } ?? 0
        let mismatch = (diskSegs > 0 && diskTextLen != diskSegLen)
            ? "  ⚠ text=\(diskTextLen) ≠ segs=\(diskSegLen)"
            : ""

        loadInfoToastMessage = "load \"\(titleSnippet)\" — disk: \(diskSegs)seg/\(diskFuri)furi  mem: \(memSegs)seg/\(memFuri)furi\(mismatch)"
        loadInfoToastClearTask?.cancel()
        loadInfoToastClearTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 8_000_000_000)
            if Task.isCancelled { return }
            loadInfoToastMessage = nil
        }
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
