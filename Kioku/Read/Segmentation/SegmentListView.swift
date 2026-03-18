import SwiftUI

// Renders the segment-management screen for all current paste-area segments.
struct SegmentListView: View {
    @Environment(\.dismiss) private var dismiss
    // Injected so that save/unsave operations trigger a refresh in WordsView without duplicating storage logic.
    @EnvironmentObject private var wordsStore: WordsStore

    let text: String
    let edges: [LatticeEdge]
    let latticeEdges: [LatticeEdge]
    let dictionaryStore: DictionaryStore?
    let sourceNoteID: UUID?
    let lemmaForSurface: (String) -> String?
    let onMergeLeft: (Int) -> Void
    let onMergeRight: (Int) -> Void
    let onSplit: (Int, Int) -> Void
    let onReset: () -> Void

    @State private var savedWordEntryIDs: Set<Int64> = []
    @State private var savedWordSurfaces: Set<String> = []
    @State private var savedWordSourceNoteIDsByEntryID: [Int64: Set<UUID>] = [:]
    @State private var savedWordSourceNoteIDsBySurface: [String: Set<UUID>] = [:]
    @State private var canonicalEntryIDBySurface: [String: Int64] = [:]
    @State private var includesDuplicates = true
    @State private var includesCommonParticles = true
    @State private var hydrationGeneration: Int = 0
    @State private var orderedSplitOffsetsBySourceIndex: [Int: [Int]] = [:]
    @State private var latticeBackedSplitOffsetsBySourceIndex: [Int: Set<Int>] = [:]
    @State private var addAllFeedbackMessage: String?
    @State private var addAllFeedbackTask: Task<Void, Never>?
    private let savedWordsStorageKey = "kioku.words.v1"
    // Read at view init time so a settings change takes effect on the next sheet presentation.
    private let commonParticles = ParticleSettings.allowed()

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Displays every active segment in source order.
                List {
                    ForEach(displayRows, id: \.sourceIndex) { row in
                        let index = row.sourceIndex
                        let edge = row.edge
                        // Shows segment text with a right-side star toggle and split/merge context actions.
                        HStack(spacing: 10) {
                            Text(edge.surface)
                                .font(.headline)

                            Spacer()

                            Button {
                                toggleSavedWord(edge.surface, lemma: lemmaForSurface(edge.surface) ?? "")
                            } label: {
                                let normalizedSurface = normalizedSurfaceForFiltering(edge.surface)
                                let isSavedForCurrentNote = isSavedForCurrentNote(normalizedSurface: normalizedSurface)
                                let isSavedForOtherNotes = isSavedForOtherNotes(normalizedSurface: normalizedSurface)
                                let showsFilledStar = isSavedForCurrentNote || (isSavedSurface(normalizedSurface: normalizedSurface) && isSavedForOtherNotes == false)
                                Image(systemName: showsFilledStar ? "star.fill" : "star")
                                    .foregroundStyle(showsFilledStar ? Color.yellow : Color.secondary)
                                    .font(.system(size: 16, weight: isSavedForOtherNotes ? .black : .semibold))
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(
                                isSavedForCurrentNote(normalizedSurface: normalizedSurfaceForFiltering(edge.surface)) ? "Unsave Word" : "Save Word"
                            )
                        }
                        .padding(.vertical, 6)
                        .contextMenu {
                            if index > 0 {
                                Button {
                                    onMergeLeft(index)
                                } label: {
                                    Label("Merge Left", systemImage: "arrow.left.to.line.compact")
                                }
                            }

                            if index < edges.count - 1 {
                                Button {
                                    onMergeRight(index)
                                } label: {
                                    Label("Merge Right", systemImage: "arrow.right.to.line.compact")
                                }
                            }

                            let latticeBackedOffsets = latticeBackedSplitOffsetsBySourceIndex[index] ?? []
                            let orderedOffsets = orderedSplitOffsetsBySourceIndex[index] ?? []

                            if orderedOffsets.isEmpty == false {
                                Menu("Split") {
                                    ForEach(orderedOffsets, id: \.self) { offset in
                                        if let preview = splitPreview(for: edge.surface, offsetUTF16: offset) {
                                            let labelPrefix = latticeBackedOffsets.contains(offset) ? "Suggested: " : "Manual: "
                                            Button("\(labelPrefix)\(preview.left) | \(preview.right)") {
                                                onSplit(index, offset)
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }

                // Keeps basic screen actions available at the bottom.
                VStack(spacing: 4) {
                    HStack(spacing: 10) {
                        optionToggleButton(
                            title: "duplicates",
                            isOn: includesDuplicates,
                            accessibilityLabel: "Include Duplicates"
                        ) {
                            includesDuplicates.toggle()
                        }

                        optionToggleButton(
                            title: "particles",
                            isOn: includesCommonParticles,
                            accessibilityLabel: "Include Common Particles"
                        ) {
                            includesCommonParticles.toggle()
                        }

                        Spacer(minLength: 0)

                        Button {
                            addAllVisibleWords()
                        } label: {
                            Text("Add All")
                                .font(.system(size: 13, weight: .semibold))
                                .padding(.horizontal, 12)
                                .frame(height: 30)
                        }
                        .buttonStyle(.borderedProminent)
                        .accessibilityLabel("Add All Visible Words")
                    }

                    if let addAllFeedbackMessage {
                        Text(addAllFeedbackMessage)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Color.secondary)
                            .frame(maxWidth: .infinity, alignment: .trailing)
                            .transition(.opacity)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background(Color(.secondarySystemBackground))
            }
        }
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                // Dismisses the segment list sheet without depending on scroll-position gesture handoff.
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "chevron.left")
                }
                .accessibilityLabel("Back")
            }
        }
        .onAppear {
            loadSavedWordsFromStorage()
            scheduleCanonicalEntryIDHydrationForVisibleRows()
            rebuildSplitMenuCaches()
        }
        .onChange(of: edges.map(\.surface)) { _, _ in
            scheduleCanonicalEntryIDHydrationForVisibleRows()
            rebuildSplitMenuCaches()
        }
        .onChange(of: latticeEdges.map(\.start)) { _, _ in
            rebuildSplitMenuCaches()
        }
        .onChange(of: latticeEdges.map(\.end)) { _, _ in
            rebuildSplitMenuCaches()
        }
        .onChange(of: includesDuplicates) { _, _ in
            scheduleCanonicalEntryIDHydrationForVisibleRows()
        }
        .onChange(of: includesCommonParticles) { _, _ in
            scheduleCanonicalEntryIDHydrationForVisibleRows()
        }
        .onDisappear {
            addAllFeedbackTask?.cancel()
            addAllFeedbackTask = nil
        }
    }

    // Builds valid UTF-16 split offsets for a segment by iterating source-text character boundaries.
    private func splitOffsets(for edge: LatticeEdge) -> [Int] {
        guard edge.start < edge.end else {
            return []
        }

        var offsets: [Int] = []
        var cursor = edge.start
        var utf16Offset = 0

        while cursor < edge.end {
            let nextIndex = text.index(after: cursor)
            utf16Offset += text[cursor..<nextIndex].utf16.count
            if nextIndex < edge.end {
                offsets.append(utf16Offset)
            }
            cursor = nextIndex
        }

        return offsets
    }

    // Identifies indices that are both a lattice start and end so split options can prefer graph-supported boundaries.
    private func latticeBoundaryIndices() -> Set<String.Index> {
        var latticeStarts = Set<String.Index>()
        var latticeEnds = Set<String.Index>()

        for latticeEdge in latticeEdges {
            latticeStarts.insert(latticeEdge.start)
            latticeEnds.insert(latticeEdge.end)
        }

        return latticeStarts.intersection(latticeEnds)
    }

    // Collects split offsets that align to lattice-supported boundaries inside the selected segment span.
    private func latticeBackedSplitOffsetSet(for edge: LatticeEdge, boundaryIndices: Set<String.Index>) -> Set<Int> {
        guard edge.start < edge.end else {
            return []
        }

        var supportedOffsets = Set<Int>()
        var cursor = edge.start
        var utf16Offset = 0

        while cursor < edge.end {
            let nextIndex = text.index(after: cursor)
            utf16Offset += text[cursor..<nextIndex].utf16.count

                if nextIndex > edge.start,
                    nextIndex < edge.end,
                    boundaryIndices.contains(nextIndex) {
                supportedOffsets.insert(utf16Offset)
            }

            cursor = nextIndex
        }

        return supportedOffsets
    }

    // Rebuilds split-menu caches to keep row rendering light even for large segment lists.
    private func rebuildSplitMenuCaches() {
        let boundaryIndices = latticeBoundaryIndices()
        var orderedOffsetsByIndex: [Int: [Int]] = [:]
        var latticeBackedOffsetsByIndex: [Int: Set<Int>] = [:]

        orderedOffsetsByIndex.reserveCapacity(edges.count)
        latticeBackedOffsetsByIndex.reserveCapacity(edges.count)

        for (sourceIndex, edge) in edges.enumerated() {
            let latticeBackedOffsets = latticeBackedSplitOffsetSet(for: edge, boundaryIndices: boundaryIndices)
            let availableOffsets = splitOffsets(for: edge)
            let orderedOffsets = availableOffsets.sorted { lhs, rhs in
                let lhsIsLatticeBacked = latticeBackedOffsets.contains(lhs)
                let rhsIsLatticeBacked = latticeBackedOffsets.contains(rhs)
                if lhsIsLatticeBacked != rhsIsLatticeBacked {
                    return lhsIsLatticeBacked
                }

                return lhs < rhs
            }

            orderedOffsetsByIndex[sourceIndex] = orderedOffsets
            latticeBackedOffsetsByIndex[sourceIndex] = latticeBackedOffsets
        }

        orderedSplitOffsetsBySourceIndex = orderedOffsetsByIndex
        latticeBackedSplitOffsetsBySourceIndex = latticeBackedOffsetsByIndex
    }

    // Excludes newline-only rows so the word list mirrors visible lexical segment editing intent.
    private var displayRows: [(sourceIndex: Int, edge: LatticeEdge)] {
        var filteredRows = Array(edges.enumerated())
            .filter { _, edge in
                edge.surface.contains("\n") == false && edge.surface.contains("\r") == false
            }

        if includesCommonParticles == false {
            filteredRows = filteredRows.filter { _, edge in
                isCommonParticle(edge.surface) == false
            }
        }

        if includesDuplicates == false {
            var seenSurfaces = Set<String>()
            filteredRows = filteredRows.filter { _, edge in
                let normalizedSurface = normalizedSurfaceForFiltering(edge.surface)
                if seenSurfaces.contains(normalizedSurface) {
                    return false
                }

                seenSurfaces.insert(normalizedSurface)
                return true
            }
        }

        return filteredRows.map { offset, edge in
            (sourceIndex: offset, edge: edge)
        }
    }

    // Detects whether a segment surface is one of the common Japanese particles used for extraction filtering.
    private func isCommonParticle(_ surface: String) -> Bool {
        let normalizedSurface = normalizedSurfaceForFiltering(surface)
        return commonParticles.contains(normalizedSurface)
    }

    // Normalizes a segment surface for stable duplicate and particle comparisons.
    private func normalizedSurfaceForFiltering(_ surface: String) -> String {
        surface.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // Renders a compact text-only toggle button used by extraction filters in the bottom action bar.
    private func optionToggleButton(title: String, isOn: Bool, accessibilityLabel: String, action: @escaping () -> Void) -> some View {
        Button {
            action()
        } label: {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(isOn ? Color.accentColor : Color.secondary)
                .padding(.horizontal, 10)
                .frame(height: 30)
                .background(
                    Capsule()
                        .fill(isOn ? Color.accentColor.opacity(0.18) : Color(.tertiarySystemFill))
                )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityValue(isOn ? "On" : "Off")
    }

    // Toggles one segment surface in the saved-word list storage.
    // lemma is the dictionary headword and is tried as a fallback when the surface has no direct dictionary entry.
    private func toggleSavedWord(_ surface: String, lemma: String = "") {
        let normalizedSurface = normalizedSurfaceForFiltering(surface)
        let wasSaved = savedWordSurfaces.contains(normalizedSurface)
        let previousSavedWordSurfaces = savedWordSurfaces
        let previousSourceNoteIDsBySurface = savedWordSourceNoteIDsBySurface

        // Applies immediate visual feedback so star taps feel responsive even when canonical lookup is pending.
        if let sourceNoteID {
            var sourceNoteIDs = savedWordSourceNoteIDsBySurface[normalizedSurface] ?? Set<UUID>()
            if sourceNoteIDs.contains(sourceNoteID) {
                sourceNoteIDs.remove(sourceNoteID)
            } else {
                sourceNoteIDs.insert(sourceNoteID)
            }

            if sourceNoteIDs.isEmpty {
                savedWordSourceNoteIDsBySurface.removeValue(forKey: normalizedSurface)
            } else {
                savedWordSourceNoteIDsBySurface[normalizedSurface] = sourceNoteIDs
            }

            if sourceNoteIDs.isEmpty {
                savedWordSurfaces.remove(normalizedSurface)
            } else {
                savedWordSurfaces.insert(normalizedSurface)
            }
        } else if wasSaved {
            savedWordSurfaces.remove(normalizedSurface)
        } else {
            savedWordSurfaces.insert(normalizedSurface)
        }

        if let canonicalEntryID = canonicalEntryIDBySurface[normalizedSurface] {
            toggleSavedWord(canonicalEntryID: canonicalEntryID, normalizedSurface: normalizedSurface)
            return
        }

        let normalizedLemma = normalizedSurfaceForFiltering(lemma)
        hydrateCanonicalEntryIDs(for: [(surface: normalizedSurface, lemma: normalizedLemma)]) { hydratedEntryIDs in
            guard let canonicalEntryID = hydratedEntryIDs[normalizedSurface] else {
                // Reverts optimistic UI state when no canonical entry is available for persistence.
                savedWordSurfaces = previousSavedWordSurfaces
                savedWordSourceNoteIDsBySurface = previousSourceNoteIDsBySurface
                return
            }

            canonicalEntryIDBySurface.merge(hydratedEntryIDs) { current, _ in
                current
            }
            toggleSavedWord(canonicalEntryID: canonicalEntryID, normalizedSurface: normalizedSurface)
        }
    }

    // Applies save or unsave state for one canonical dictionary entry id.
    private func toggleSavedWord(canonicalEntryID: Int64, normalizedSurface: String) {
        var entries = loadSavedWordEntriesFromStorage()
        if let existingIndex = entries.firstIndex(where: { $0.canonicalEntryID == canonicalEntryID }) {
            var existingEntry = entries[existingIndex]

            if let sourceNoteID {
                var noteIDs = Set(existingEntry.sourceNoteIDs)
                if noteIDs.contains(sourceNoteID) {
                    noteIDs.remove(sourceNoteID)
                } else {
                    noteIDs.insert(sourceNoteID)
                }

                if noteIDs.isEmpty {
                    entries.remove(at: existingIndex)
                } else {
                    let orderedNoteIDs = noteIDs.sorted { lhs, rhs in
                        lhs.uuidString < rhs.uuidString
                    }
                    existingEntry = SavedWord(
                        canonicalEntryID: existingEntry.canonicalEntryID,
                        surface: normalizedSurface,
                        sourceNoteIDs: orderedNoteIDs
                    )
                    entries[existingIndex] = existingEntry
                }
            } else {
                entries.remove(at: existingIndex)
            }
        } else {
            let noteIDs: [UUID] = sourceNoteID.map { [$0] } ?? []
            entries.append(
                SavedWord(
                    canonicalEntryID: canonicalEntryID,
                    surface: normalizedSurface,
                    sourceNoteIDs: noteIDs
                )
            )
        }

        let normalizedEntries = SavedWordStorageMigrator.normalizedEntries(entries)
        persistSavedWordEntriesToStorage(normalizedEntries)
        applySavedWordState(entries: normalizedEntries)
    }

    // Saves every currently visible segment row to favorites while updating each star in real time.
    private func addAllVisibleWords() {
        let rows = displayRows
        guard rows.isEmpty == false else {
            return
        }

        Task {
            var entries = loadSavedWordEntriesFromStorage()
            var addedCount = 0

            for row in rows {
                let normalizedSurface = normalizedSurfaceForFiltering(row.edge.surface)
                guard normalizedSurface.isEmpty == false else {
                    continue
                }

                let entryID: Int64
                if let cached = canonicalEntryIDBySurface[normalizedSurface] {
                    entryID = cached
                } else if let store = dictionaryStore {
                    let surface = normalizedSurface
                    let lemma = normalizedSurfaceForFiltering(lemmaForSurface(row.edge.surface) ?? "")
                    // Try the surface form first; fall back to the lemma so conjugated verbs resolve correctly.
                    guard let resolved = await withCheckedContinuation({ continuation in
                        DispatchQueue.global(qos: .userInitiated).async {
                            let id = (try? store.lookup(surface: surface, mode: .kanjiAndKana).first?.entryId)
                                ?? (lemma.isEmpty == false && lemma != surface
                                    ? try? store.lookup(surface: lemma, mode: .kanjiAndKana).first?.entryId
                                    : nil)
                            continuation.resume(returning: id)
                        }
                    }) else {
                        continue
                    }
                    entryID = resolved
                    canonicalEntryIDBySurface[normalizedSurface] = entryID
                } else {
                    continue
                }

                if let existingIndex = entries.firstIndex(where: { $0.canonicalEntryID == entryID }) {
                    guard let noteID = sourceNoteID else {
                        continue
                    }

                    var existingEntry = entries[existingIndex]
                    var noteIDs = Set(existingEntry.sourceNoteIDs)
                    if noteIDs.contains(noteID) {
                        continue
                    }

                    noteIDs.insert(noteID)
                    existingEntry = SavedWord(
                        canonicalEntryID: existingEntry.canonicalEntryID,
                        surface: existingEntry.surface,
                        sourceNoteIDs: noteIDs.sorted { $0.uuidString < $1.uuidString }
                    )
                    entries[existingIndex] = existingEntry
                } else {
                    let noteIDs: [UUID] = sourceNoteID.map { [$0] } ?? []
                    entries.append(
                        SavedWord(
                            canonicalEntryID: entryID,
                            surface: normalizedSurface,
                            sourceNoteIDs: noteIDs
                        )
                    )
                }

                addedCount += 1
                savedWordSurfaces.insert(normalizedSurface)
                savedWordEntryIDs.insert(entryID)
            }

            let normalizedEntries = SavedWordStorageMigrator.normalizedEntries(entries)
            persistSavedWordEntriesToStorage(normalizedEntries)
            applySavedWordState(entries: normalizedEntries)
            showAddAllFeedback(addedCount: addedCount)
        }
    }

    // Shows a short-lived status message after attempting to favorite all visible words.
    private func showAddAllFeedback(addedCount: Int) {
        addAllFeedbackTask?.cancel()

        if addedCount == 0 {
            addAllFeedbackMessage = "No new words added"
        } else if addedCount == 1 {
            addAllFeedbackMessage = "Added 1 word"
        } else {
            addAllFeedbackMessage = "Added \(addedCount) words"
        }

        addAllFeedbackTask = Task {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            if Task.isCancelled {
                return
            }

            await MainActor.run {
                withAnimation(.easeOut(duration: 0.2)) {
                    addAllFeedbackMessage = nil
                }
            }
        }
    }

    // Loads saved words from persistent storage for star-state rendering.
    private func loadSavedWordsFromStorage() {
        let entries = loadSavedWordEntriesFromStorage()
        applySavedWordState(entries: entries)
    }

    // Applies saved-word state used by star rendering from one canonical storage snapshot.
    private func applySavedWordState(entries: [SavedWord]) {
        savedWordEntryIDs = Set(entries.map(\.canonicalEntryID))
        savedWordSurfaces = Set(entries.map { normalizedSurfaceForFiltering($0.surface) })

        var sourceNoteIDsByEntryID: [Int64: Set<UUID>] = [:]
        var sourceNoteIDsBySurface: [String: Set<UUID>] = [:]

        for entry in entries {
            sourceNoteIDsByEntryID[entry.canonicalEntryID] = Set(entry.sourceNoteIDs)

            let normalizedSurface = normalizedSurfaceForFiltering(entry.surface)
            if normalizedSurface.isEmpty {
                continue
            }

            let mergedSourceNoteIDs = sourceNoteIDsBySurface[normalizedSurface, default: Set<UUID>()]
                .union(entry.sourceNoteIDs)
            sourceNoteIDsBySurface[normalizedSurface] = mergedSourceNoteIDs
        }

        savedWordSourceNoteIDsByEntryID = sourceNoteIDsByEntryID
        savedWordSourceNoteIDsBySurface = sourceNoteIDsBySurface
    }

    // Loads canonical saved-word entries from shared storage.
    private func loadSavedWordEntriesFromStorage() -> [SavedWord] {
        SavedWordStorageMigrator.loadSavedWords(storageKey: savedWordsStorageKey)
    }

    // Persists saved-word entries including optional source note references, then notifies WordsStore so WordsView reflects the change.
    private func persistSavedWordEntriesToStorage(_ entries: [SavedWord]) {
        SavedWordStorageMigrator.persist(entries: entries, storageKey: savedWordsStorageKey)
        wordsStore.reload()
    }

    // Resolves star state from hydrated canonical ids to keep row rendering non-blocking.
    private func isSavedSurface(normalizedSurface: String) -> Bool {
        if savedWordSurfaces.contains(normalizedSurface) {
            return true
        }

        guard let canonicalEntryID = canonicalEntryIDBySurface[normalizedSurface] else {
            return false
        }

        return savedWordEntryIDs.contains(canonicalEntryID)
    }

    // Detects whether a surface is currently saved for the active note context.
    private func isSavedForCurrentNote(normalizedSurface: String) -> Bool {
        guard let sourceNoteID else {
            return isSavedSurface(normalizedSurface: normalizedSurface)
        }

        if let canonicalEntryID = canonicalEntryIDBySurface[normalizedSurface],
           let sourceNoteIDs = savedWordSourceNoteIDsByEntryID[canonicalEntryID] {
            return sourceNoteIDs.contains(sourceNoteID)
        }

        if let sourceNoteIDs = savedWordSourceNoteIDsBySurface[normalizedSurface] {
            return sourceNoteIDs.contains(sourceNoteID)
        }

        return false
    }

    // Detects whether a surface is saved in one or more other notes but not the active note.
    private func isSavedForOtherNotes(normalizedSurface: String) -> Bool {
        guard let sourceNoteID else {
            return false
        }

        if let canonicalEntryID = canonicalEntryIDBySurface[normalizedSurface],
           let sourceNoteIDs = savedWordSourceNoteIDsByEntryID[canonicalEntryID] {
            return sourceNoteIDs.isEmpty == false && sourceNoteIDs.contains(sourceNoteID) == false
        }

        if let sourceNoteIDs = savedWordSourceNoteIDsBySurface[normalizedSurface] {
            return sourceNoteIDs.isEmpty == false && sourceNoteIDs.contains(sourceNoteID) == false
        }

        return false
    }

    // Schedules canonical-id hydration for visible rows so lookups never block sheet presentation.
    private func scheduleCanonicalEntryIDHydrationForVisibleRows() {
        var seenSurfaces = Set<String>()
        var pairs: [(surface: String, lemma: String)] = []

        for row in displayRows {
            let surface = normalizedSurfaceForFiltering(row.edge.surface)
            guard surface.isEmpty == false,
                  canonicalEntryIDBySurface[surface] == nil,
                  seenSurfaces.contains(surface) == false else { continue }
            seenSurfaces.insert(surface)
            pairs.append((surface: surface, lemma: normalizedSurfaceForFiltering(lemmaForSurface(row.edge.surface) ?? "")))
        }

        guard pairs.isEmpty == false else { return }

        hydrationGeneration += 1
        let targetGeneration = hydrationGeneration

        hydrateCanonicalEntryIDs(for: pairs) { hydratedEntryIDs in
            guard targetGeneration == hydrationGeneration else { return }
            canonicalEntryIDBySurface.merge(hydratedEntryIDs) { current, _ in current }
        }
    }

    // Resolves canonical dictionary ids in the background and returns a surface-keyed map of successful matches.
    // For each pair, tries the surface form first and falls back to the lemma so conjugated forms resolve correctly.
    private func hydrateCanonicalEntryIDs(
        for pairs: [(surface: String, lemma: String)],
        onComplete: @escaping ([String: Int64]) -> Void
    ) {
        guard pairs.isEmpty == false, let dictionaryStore else {
            onComplete([:])
            return
        }

        DispatchQueue.global(qos: .userInitiated).async {
            var resolvedEntryIDs: [String: Int64] = [:]
            resolvedEntryIDs.reserveCapacity(pairs.count)

            for pair in pairs {
                guard pair.surface.isEmpty == false else { continue }

                if let match = try? dictionaryStore.lookup(surface: pair.surface, mode: .kanjiAndKana).first {
                    // Surface form found directly in the dictionary.
                    resolvedEntryIDs[pair.surface] = match.entryId
                } else if pair.lemma.isEmpty == false,
                          pair.lemma != pair.surface,
                          let match = try? dictionaryStore.lookup(surface: pair.lemma, mode: .kanjiAndKana).first {
                    // Conjugated surface not in dictionary — use the lemma (dictionary headword) instead.
                    resolvedEntryIDs[pair.surface] = match.entryId
                }
            }

            DispatchQueue.main.async {
                onComplete(resolvedEntryIDs)
            }
        }
    }

    // Generates preview text for a proposed split boundary.
    private func splitPreview(for surface: String, offsetUTF16: Int) -> (left: String, right: String)? {
        let totalLength = surface.utf16.count
        guard offsetUTF16 > 0, offsetUTF16 < totalLength else {
            return nil
        }

        let splitIndex = String.Index(utf16Offset: offsetUTF16, in: surface)
        let left = String(surface[..<splitIndex])
        let right = String(surface[splitIndex...])
        guard left.isEmpty == false, right.isEmpty == false else {
            return nil
        }

        return (left: left, right: right)
    }
}
