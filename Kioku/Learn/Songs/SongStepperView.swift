import Foundation
import SwiftUI

// Per-note breakdown view: every line of the song stacked in one vertical scroll.
// Each line card always shows Japanese / romaji / gist / grammar; the per-line word
// list is collapsed by default and toggled by the user. The view drives the generation
// flow itself so the parent home stays a pure list.
//
// There is no separate loading screen. The scroll always shows one card per note line;
// while the model streams, cards fill in from the top (the one being written is highlighted
// and auto-expanded, the rest still show the note text) and the toolbar wand becomes a
// spinner; failures surface as a banner above the list.
//
// Major sections:
//   1. Toolbar: listen / expand-all / generate-or-cancel control
//   2. Banners: generation error, stale breakdown, or "not generated yet" prompt
//   3. Vertical scroll of per-line cards (SongBreakdownProgressComposer decides the rows)
// Furigana cache building lives in SongStepperView+Furigana.
struct SongStepperView: View {
    let note: Note
    // Optional deps for per-line furigana. Nil segmenter degrades to "no readings" (cache
    // resolves empty); `surfaceReadingData` defaults to an empty map.
    let segmenter: (any TextSegmenting)?
    let surfaceReadingData: SurfaceReadingDataMap
    let kanjiReadingFallback: KanjiReadingFallbackMap
    // Resolves tapped breakdown words to a dictionary entry for the lookup sheet. Optional so the
    // legacy SongsHomeView caller (no dictionary in scope) still compiles; tap-to-lookup no-ops there.
    let dictionaryStore: DictionaryStore?
    @EnvironmentObject private var songBreakdownStore: SongBreakdownStore
    // Drives the lookup sheet's save star for tapped words (globally injected at the app root).
    @EnvironmentObject private var wordsStore: WordsStore
    // Only needed for the merged generate+correct path (see startMergedGeneration), which
    // persists the corrected segmentation directly to the note. The plain breakdown path never
    // touches notesStore.
    @EnvironmentObject private var notesStore: NotesStore
    // Per-line expansion state: whether a line's word/grammar explanations are visible.
    // Keyed by `line.index` (not array offset) so it survives regenerate / breakdown rebuilds.
    // Lines are auto-expanded as they stream in; reset when a new generation starts.
    @State private var expandedByLineIndex: Set<Int> = []
    @State private var isRegenerateConfirmationPresented: Bool = false
    // Drives the confirmation for the merged generate+correct path — kept separate from
    // isRegenerateConfirmationPresented so the two dialogs' distinct messages (and
    // destinations: startGeneration vs startMergedGeneration) can't cross-wire.
    @State private var isMergedRegenerateConfirmationPresented: Bool = false
    @State private var isListenSheetPresented: Bool = false
    // Remembers which path the user last chose so the error banner's Retry re-runs the same one.
    @State private var lastGenerationWasMerged: Bool = false
    // Furigana state shared with SongStepperView+Furigana (internal, not private, for that reason).
    @State var furiganaCacheByLineIndex: [Int: LineFuriganaCache] = [:]
    // The note's persisted per-note reading overrides (Note.segments), restored once on appear
    // — see buildFuriganaCache / applyNoteFuriganaOverrides. Nil when the note has no persisted
    // segments or they no longer validate against its current content.
    @State var noteFuriganaRestoration: (byLocation: [Int: String], lengthByLocation: [Int: Int])?
    // Each displayed line's starting UTF-16 offset within note.content, so a note-level reading
    // override (keyed by note.content coordinates) can be rebased into a line's local
    // coordinates. See lineStartOffsets.
    @State var lineStartOffsetsByIndex: [Int: Int] = [:]
    // Per-kanji-run readings for word-list headwords, keyed by (line, surface) — not surface
    // alone, since the same word can appear on multiple lines with a different resolved
    // reading. Built alongside furiganaCacheByLineIndex (see ensureFuriganaCaches).
    @State var wordFuriganaByKey: [WordFuriganaKey: [Int: String]] = [:]
    // Owns audio playback for "play this line" affordances. Stays nil-loaded when the
    // note has no audio attachment or no SRT — the matcher returns an empty map and the
    // cards omit play buttons.
    @StateObject private var audioController = AudioPlaybackController()

    // Convenience init for callers that don't (yet) supply the resolver deps — e.g. previews
    // or any future surface that doesn't have the segmenter in scope. Furigana becomes a
    // visual no-op in that mode.
    init(note: Note,
         segmenter: (any TextSegmenting)? = nil,
         surfaceReadingData: SurfaceReadingDataMap = SurfaceReadingDataMap(),
         kanjiReadingFallback: KanjiReadingFallbackMap = KanjiReadingFallbackMap(),
         dictionaryStore: DictionaryStore? = nil) {
        self.note = note
        self.segmenter = segmenter
        self.surfaceReadingData = surfaceReadingData
        self.kanjiReadingFallback = kanjiReadingFallback
        self.dictionaryStore = dictionaryStore
    }

    // MARK: - Derived state

    // The store-owned generation state for this note, read (not copied to local @State) so the
    // spinner and streamed cards survive sheet dismissal and re-bind to the same in-flight Task.
    private var generationState: SongBreakdownGenerationState? {
        songBreakdownStore.generationStateByNoteID[note.id]
    }

    private var isRunning: Bool {
        songBreakdownStore.isGenerating(forNoteID: note.id)
    }

    private var cachedBreakdown: SongBreakdown? {
        songBreakdownStore.breakdown(forNoteID: note.id)
    }

    private var hasBreakdown: Bool {
        (cachedBreakdown?.lines.isEmpty == false)
    }

    // Lines currently on screen: the streamed partial parse while running (a running
    // generation always wins, even over a cached breakdown, so the user watches the new one
    // arrive), otherwise the cached breakdown.
    private var currentLines: [SongLine] {
        if isRunning { return songBreakdownStore.partialLines(forNoteID: note.id) }
        return cachedBreakdown?.lines ?? []
    }

    // Rows for the scroll: streamed/cached lines merged over the note's own lines.
    private var displayItems: [SongLineDisplayItem] {
        SongBreakdownProgressComposer.items(
            noteContent: note.content,
            streamedLines: currentLines,
            isRunning: isRunning
        )
    }

    // Identity of the card the model is currently writing, for auto-scroll + auto-expand.
    private var streamingItemID: String? {
        displayItems.first(where: { $0.phase == .streaming })?.id
    }

    // Maps each displayed line.index → its matched audio time range. Empty when the note
    // has no audio or the SRT doesn't line up with the lines. Computed on each body pass;
    // both inputs are tiny (~30 lines × ~30 cues) so the O(N·M) walk is cheap.
    private var lineRangesByIndex: [Int: (startMs: Int, endMs: Int)] {
        guard audioController.cues.isEmpty == false else { return [:] }
        return SongLineCueMatcher.computeRanges(lines: displayItems.map(\.line), cues: audioController.cues)
    }

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            if case .failed(let message) = generationState {
                errorBanner(message)
            } else if isRunning == false, let breakdown = cachedBreakdown, isStale(breakdown) {
                staleBanner
            } else if isRunning == false, hasBreakdown == false {
                generateBar
            }
            scrollList(items: displayItems)
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Text("Breakdown")
                    .font(.headline)
                    .accessibilityLabel("Breakdown")
            }
            if isRunning == false, hasBreakdown {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        isListenSheetPresented = true
                    } label: {
                        Image(systemName: "headphones")
                    }
                    .accessibilityLabel("Listen to breakdown")
                }
            }
            if displayItems.isEmpty == false {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        toggleAllExpansion()
                    } label: {
                        Image(systemName: areAllLinesExpanded ? "eye.slash" : "eye")
                    }
                    .accessibilityLabel(areAllLinesExpanded ? "Hide all explanations" : "Show all explanations")
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                generationControl
            }
        }
        .sheet(isPresented: $isListenSheetPresented) {
            if let breakdown = cachedBreakdown {
                SongListenSheet(
                    breakdown: breakdown,
                    sourceAudioURL: note.audioAttachmentID.flatMap { NotesAudioStore.shared.audioURL(for: $0) },
                    lineRanges: lineRangesByIndex
                )
            }
        }
        .confirmationDialog(
            "Regenerate this breakdown?",
            isPresented: $isRegenerateConfirmationPresented,
            titleVisibility: .visible
        ) {
            Button("Regenerate", role: .destructive) {
                startGeneration()
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            // Honest framing: full-song breakdowns bill per token. The old breakdown stays
            // until the new one finishes, so a failed call costs nothing but the tokens.
            Text("Sends the full lyrics to the configured LLM provider and uses paid tokens. The existing breakdown is replaced when the new one finishes.")
        }
        .confirmationDialog(
            "Regenerate with merged segmentation correction?",
            isPresented: $isMergedRegenerateConfirmationPresented,
            titleVisibility: .visible
        ) {
            Button("Regenerate + Fix Segmentation", role: .destructive) {
                startMergedGeneration()
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("One combined call that both fixes this note's segmentation/readings and regenerates the breakdown. Not supported on Apple Intelligence. Uses paid tokens; the existing breakdown is replaced when the new one finishes.")
        }
        .preference(key: CardsStudySessionActivePreferenceKey.self, value: true)
        .preference(key: CardsPageDotsHiddenPreferenceKey.self, value: true)
        // A new generation starting collapses everything so the previous run's expansion
        // doesn't leak into the cards about to stream in. Furigana caches are kept: they're
        // keyed by index and validated against the line text (see ensureFuriganaCaches).
        .onChange(of: isRunning) { _, running in
            if running { expandedByLineIndex = [] }
        }
        // Every change to the rows — a streamed line landing, a breakdown finishing, a cached
        // breakdown replacing the bare note lines — refreshes furigana and offsets for the new
        // rows and auto-expands the line the model is currently writing.
        .onChange(of: displayItems) { _, items in
            refreshLineDerivedState(for: items)
        }
        // Covers first appearance with an already-cached breakdown (or bare note lines) — onChange
        // above only fires on a *transition*, not on the initial value.
        .onAppear {
            noteFuriganaRestoration = Self.restoreNoteFurigana(from: note)
            refreshLineDerivedState(for: displayItems)
        }
        // Lazily loads the audio + cues for this note (if it has any) so the per-line
        // play buttons have something to seek into. Early-returns when there's no audio
        // attachment, no resolvable file, or empty cue list — all three are normal "no
        // playback available" cases, not errors.
        .task {
            guard let attachmentID = note.audioAttachmentID else { return }
            guard let url = NotesAudioStore.shared.audioURL(for: attachmentID) else { return }
            let cues = NotesAudioStore.shared.loadCues(for: attachmentID)
            do {
                try audioController.load(audioURL: url, cues: cues)
            } catch {
                print("[SongStepperView] audio load failed for \(url.lastPathComponent): \(error.localizedDescription)")
            }
        }
        .onDisappear {
            // Release the audio file + deactivate the session when the sheet/screen leaves.
            // Without this, the controller would hold its `AVAudioPlayer` (and the audio
            // session) until SwiftUI deallocates the @StateObject, which is non-deterministic.
            audioController.unload()
        }
    }

    // MARK: - Toolbar

    // The single generate affordance. While running it is a spinner whose menu offers
    // Cancel; otherwise a wand whose menu offers the plain and merged paths (labelled
    // Generate or Regenerate depending on whether a breakdown already exists).
    @ViewBuilder
    private var generationControl: some View {
        if isRunning {
            Menu {
                Button("Cancel generation", role: .destructive) {
                    songBreakdownStore.cancelGeneration(forNoteID: note.id)
                }
            } label: {
                ProgressView()
                    .controlSize(.small)
            }
            .accessibilityLabel("Generating breakdown")
        } else {
            Menu {
                Button(hasBreakdown ? "Regenerate" : "Generate") {
                    requestGeneration(merged: false)
                }
                Button(hasBreakdown ? "Regenerate + Fix Segmentation" : "Generate + Fix Segmentation") {
                    requestGeneration(merged: true)
                }
            } label: {
                Image(systemName: "wand.and.stars")
            }
            .accessibilityLabel(hasBreakdown ? "Regenerate breakdown" : "Generate breakdown")
        }
    }

    // MARK: - Banners

    // Shown when the cached breakdown's hash disagrees with the current note hash.
    // We never auto-invalidate — the breakdown remains usable so a typo fix doesn't
    // throw away an expensive LLM run — but the user is told and offered Regenerate.
    private var staleBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text("Lyrics changed")
                    .font(.footnote.weight(.semibold))
                Text("This breakdown was generated from earlier lyrics.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Button("Regenerate") {
                isRegenerateConfirmationPresented = true
            }
            .font(.footnote.weight(.semibold))
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color.orange.opacity(0.12))
    }

    // First-visit bar above the cards. Generation is a paid, deliberate action, so it never
    // auto-fires on entry; the merged variant lives in the toolbar menu.
    private var generateBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "wand.and.stars")
                .foregroundStyle(Color.accentColor)
            Text("No breakdown yet")
                .font(.footnote.weight(.semibold))
            Spacer(minLength: 8)
            Button("Generate") {
                startGeneration()
            }
            .font(.footnote.weight(.semibold))
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color.accentColor.opacity(0.08))
    }

    // Generation failed. Shows the underlying message verbatim so the user can distinguish
    // missing-key from network errors from parse failures; Retry re-runs the same path
    // (plain or merged) that failed, and the close button just clears the error.
    private func errorBanner(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text("Couldn't generate breakdown")
                    .font(.footnote.weight(.semibold))
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(4)
            }
            Spacer(minLength: 8)
            Button("Retry") {
                if lastGenerationWasMerged {
                    startMergedGeneration()
                } else {
                    startGeneration()
                }
            }
            .font(.footnote.weight(.semibold))
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            Button {
                songBreakdownStore.clearGenerationError(forNoteID: note.id)
            } label: {
                Image(systemName: "xmark")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss error")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color.orange.opacity(0.12))
    }

    // MARK: - Scroll

    // Vertical scroll over every row. Each card is independent; expanding/collapsing one
    // line's word list doesn't disturb the others. The reader follows the streaming card so
    // the user sees the model work its way down the song without scrolling by hand.
    private func scrollList(items: [SongLineDisplayItem]) -> some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: true) {
                LazyVStack(spacing: 14) {
                    ForEach(items) { item in
                        SongLineCard(
                            line: item.line,
                            referencedLine: referencedLine(for: item.line),
                            isExpanded: expandedByLineIndex.contains(item.line.index),
                            furiganaCache: furiganaCacheByLineIndex[item.line.index],
                            wordFurigana: wordFuriganaByKey,
                            playbackRange: lineRangesByIndex[item.line.index],
                            phase: item.phase,
                            onToggleExpansion: { toggleExpansion(for: item.line) },
                            onPlayLine: {
                                if let range = lineRangesByIndex[item.line.index] {
                                    audioController.playRange(startMs: range.startMs, endMs: range.endMs)
                                }
                            },
                            onWordTapped: { presentWordLookup($0) }
                        )
                        .id(item.id)
                    }
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 14)
            }
            .onChange(of: streamingItemID) { _, newID in
                guard let newID else { return }
                withAnimation(.easeInOut(duration: 0.3)) {
                    proxy.scrollTo(newID, anchor: .center)
                }
            }
        }
    }

    // MARK: - Row-derived state

    // Rebuilds everything keyed off the current rows: line offsets for note-level reading
    // overrides, furigana caches for lines and headwords, and — while streaming — expansion
    // of the line being written so its words appear as they arrive.
    private func refreshLineDerivedState(for items: [SongLineDisplayItem]) {
        let lines = items.map(\.line)
        lineStartOffsetsByIndex = Self.lineStartOffsets(for: lines, in: note.content)
        ensureFuriganaCaches(for: lines)
        if let streaming = items.first(where: { $0.phase == .streaming }) {
            expandedByLineIndex.insert(streaming.line.index)
        }
    }

    // MARK: - Expansion

    // Flips the per-line "expanded" state, which controls only the word/grammar
    // explanations — furigana is resolved eagerly for every line (see ensureFuriganaCaches).
    // The defensive rebuild is a safety net for the (normally unreachable) case a line's
    // cache wasn't populated by the eager pass.
    private func toggleExpansion(for line: SongLine) {
        if expandedByLineIndex.contains(line.index) {
            expandedByLineIndex.remove(line.index)
            return
        }
        if furiganaCacheByLineIndex[line.index] == nil {
            furiganaCacheByLineIndex[line.index] = buildFuriganaCache(for: line)
        }
        expandedByLineIndex.insert(line.index)
    }

    // True when every displayed line is currently expanded. Drives the toolbar
    // eye / eye.slash icon and the "Show all" vs "Hide all" semantics.
    private var areAllLinesExpanded: Bool {
        let indices = displayItems.map { $0.line.index }
        return indices.isEmpty == false && indices.allSatisfy { expandedByLineIndex.contains($0) }
    }

    // Global toolbar action: if any line is collapsed, expand them all; otherwise collapse
    // everything. Caches are already built eagerly, so this is just a set write.
    private func toggleAllExpansion() {
        if areAllLinesExpanded {
            expandedByLineIndex.removeAll()
            return
        }
        expandedByLineIndex = Set(displayItems.map { $0.line.index })
    }

    // Resolves the line referenced by `= line N` or `Parallel to line N` so the card can
    // peek the original content without the consumer needing to scan the full breakdown.
    private func referencedLine(for line: SongLine) -> SongLine? {
        guard let reference = line.reference else { return nil }
        let target: Int
        switch reference {
        case .sameAsLine(let n): target = n
        case .parallelTo(line: let n, substitution: _): target = n
        }
        return currentLines.first(where: { $0.index == target })
    }

    // MARK: - Generation

    // Routes a menu tap: a first generation fires immediately, a regenerate (which will
    // replace a paid-for breakdown) goes through the matching confirmation dialog first.
    private func requestGeneration(merged: Bool) {
        if hasBreakdown {
            if merged {
                isMergedRegenerateConfirmationPresented = true
            } else {
                isRegenerateConfirmationPresented = true
            }
        } else if merged {
            startMergedGeneration()
        } else {
            startGeneration()
        }
    }

    // Triggers a generation call via the store. The store owns the Task, so dismissing
    // this sheet does NOT cancel the work — the user can leave, come back, and find the
    // cards still filling in or the result already cached. The existing breakdown is left
    // in place until the new one lands, so a cancelled or failed run loses nothing.
    private func startGeneration() {
        lastGenerationWasMerged = false
        songBreakdownStore.clearGenerationError(forNoteID: note.id)
        songBreakdownStore.startGeneration(
            forNoteID: note.id,
            lyrics: note.content,
            providerLabel: SongBreakdownStore.loadingProviderLabel()
        )
    }

    // Merged alternative to startGeneration(): one LLM call returns both the breakdown and a
    // corrected segmentation, applied via SongBreakdownStore.startMergedGeneration. Shares the
    // same store-owned running/failed state as the plain path, so the streaming cards and
    // error banner render unchanged regardless of which path is in flight.
    private func startMergedGeneration() {
        lastGenerationWasMerged = true
        songBreakdownStore.clearGenerationError(forNoteID: note.id)
        songBreakdownStore.startMergedGeneration(
            forNote: note,
            notesStore: notesStore,
            providerLabel: SongBreakdownStore.loadingProviderLabel()
        )
    }

    // Compares the cached breakdown's hash against the current note text hash.
    private func isStale(_ breakdown: SongBreakdown) -> Bool {
        breakdown.sourceTextHash != SongBreakdownService.sha256(note.content)
    }

    // MARK: - Word lookup

    // Resolves a tapped breakdown word to a dictionary entry and opens the shared lookup sheet.
    // Tries the sung surface first, then the segmenter's lemma for conjugated forms (歌った → 歌う)
    // that don't resolve directly; silently no-ops when there's no dictionary or no entry.
    private func presentWordLookup(_ word: SongWord) {
        let surface = word.surface.trimmingCharacters(in: .whitespacesAndNewlines)
        guard surface.isEmpty == false, let dictionaryStore else { return }

        let entryID: Int64?
        if let direct = dictionaryStore.lookupFirstEntryID(surface: surface) {
            entryID = direct
        } else if let lemma = segmenter?.preferredLemma(for: surface), lemma.isEmpty == false {
            entryID = dictionaryStore.lookupFirstEntryID(surface: lemma)
        } else {
            entryID = nil
        }
        guard let entryID else { return }

        SegmentLookupSheet.shared.presentSheet(
            surface: surface,
            leftNeighborSurface: nil,
            rightNeighborSurface: nil,
            sheetReadingsProvider: {
                guard let entry = try? dictionaryStore.lookupEntry(entryID: entryID) else { return [] }
                return entry.kanaForms.map(\.text)
            },
            sheetDictionaryEntryProvider: {
                try? dictionaryStore.lookupEntry(entryID: entryID)
            },
            sheetIsSavedProvider: {
                wordsStore.words.contains { $0.canonicalEntryID == entryID }
            },
            sheetSaveToggle: {
                toggleSavedWord(canonicalEntryID: entryID, surface: surface)
            },
            sheetLearnedStateProvider: {
                wordsStore.learnedState(for: entryID)
            },
            sheetSetLearnedState: { state in
                wordsStore.setLearnedState(state, for: entryID, ensureSavedWithSurface: surface)
            }
        )
    }

    // Flips saved state for a looked-up breakdown word, attributing it to this note. Mirrors the
    // segment-list toggle: only pay the SQL sense-materialization on a word's first-ever save.
    private func toggleSavedWord(canonicalEntryID: Int64, surface: String) {
        let cardExists = wordsStore.words.contains { $0.canonicalEntryID == canonicalEntryID }
        let senseIDs: [Int64]
        if cardExists {
            senseIDs = []
        } else if let dictionaryStore, let resolved = try? dictionaryStore.lookupEntry(entryID: canonicalEntryID) {
            senseIDs = DefaultSenseSelection.defaultSelectedSenseIDs(for: resolved)
        } else {
            senseIDs = []
        }
        wordsStore.toggle(
            canonicalEntryID: canonicalEntryID,
            storedSurface: surface,
            encounteredSurface: surface,
            sourceNoteID: note.id,
            defaultSenseIDs: senseIDs
        )
    }
}

// Pre-resolved per-line furigana payload. The three renderer fields together are exactly
// the data shape `KiokuCoreTextRendererView` consumes, so the card hands them straight
// through with no further conversion. `sourceText` records which line text the cache was
// built from: rows are keyed by line index, and a bare note line's index can later be taken
// by a streamed line with different text, so the cache must be re-validated, not trusted.
struct LineFuriganaCache: Equatable {
    let sourceText: String
    let segmentationRanges: [Range<String.Index>]
    let furiganaBySegmentLocation: [Int: String]
    let furiganaLengthBySegmentLocation: [Int: Int]
}
