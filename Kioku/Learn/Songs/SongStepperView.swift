import Foundation
import SwiftUI

// Per-note breakdown view: every line of the song stacked in one vertical scroll.
// Each line card always shows Japanese / romaji / gist / grammar; the per-line word
// list is collapsed by default and toggled by the user. The view drives the generation
// flow itself so the parent home stays a pure list.
//
// There is no separate loading screen. The Generate button (or, on a regenerate, the toolbar
// icon) spins while the call runs, and as the model streams each line's card appears in the
// scroll with the one being written highlighted and auto-expanded.
//
// Major sections:
//   1. Toolbar with listen / expand-all / regenerate actions (spinner while running)
//   2. Stale banner when source text drifted since generation
//   3. Body state machine: not-generated → streaming cards → ready (scroll) → error
//   4. Vertical scroll of per-line cards
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

    // True once a running generation has produced at least one line — from then on the
    // streamed cards replace whatever was on screen (prompt or old breakdown).
    private var isStreamingCards: Bool {
        isRunning && songBreakdownStore.partialLines(forNoteID: note.id).isEmpty == false
    }

    // Lines currently on screen: the streamed partial parse once it has content, otherwise
    // the cached breakdown (kept visible while a regenerate waits for its first line).
    private var currentLines: [SongLine] {
        if isStreamingCards { return songBreakdownStore.partialLines(forNoteID: note.id) }
        return cachedBreakdown?.lines ?? []
    }

    // Rows for the scroll, with the line being written marked while streaming.
    private var displayItems: [SongLineDisplayItem] {
        SongBreakdownProgressComposer.items(lines: currentLines, isStreaming: isStreamingCards)
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
            bodyContent
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Text("Breakdown")
                    .font(.headline)
                    .accessibilityLabel("Breakdown")
            }
            if isRunning {
                // The regenerate icon's slot becomes a spinner while a call runs; its only
                // menu entry is Cancel.
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button("Cancel", role: .destructive) {
                            songBreakdownStore.cancelGeneration(forNoteID: note.id)
                        }
                    } label: {
                        ProgressView()
                            .controlSize(.small)
                    }
                    .accessibilityLabel("Generating breakdown")
                }
            } else if hasBreakdown {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        isListenSheetPresented = true
                    } label: {
                        Image(systemName: "headphones")
                    }
                    .accessibilityLabel("Listen to breakdown")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        toggleAllExpansion()
                    } label: {
                        Image(systemName: areAllLinesExpanded ? "eye.slash" : "eye")
                    }
                    .accessibilityLabel(areAllLinesExpanded ? "Hide all explanations" : "Show all explanations")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button("Regenerate") {
                            isRegenerateConfirmationPresented = true
                        }
                        Button("Regenerate + Fix Segmentation (Merged)") {
                            isMergedRegenerateConfirmationPresented = true
                        }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .accessibilityLabel("Regenerate breakdown")
                }
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
            // Honest framing: full-song breakdowns are minutes-long and bill per token. The old
            // breakdown stays until the new one finishes, so a failed call costs only the tokens.
            Text("Sends the full lyrics to the configured LLM provider. Takes 30–180 seconds and uses paid tokens. The existing breakdown is replaced.")
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
            Text("Sends the full lyrics to the configured LLM provider in one combined call that both fixes this note's segmentation/readings and regenerates the breakdown. Not supported on Apple Intelligence. Takes 30–180 seconds and uses paid tokens. The existing breakdown is replaced.")
        }
        .preference(key: CardsStudySessionActivePreferenceKey.self, value: true)
        .preference(key: CardsPageDotsHiddenPreferenceKey.self, value: true)
        // A new generation starting collapses everything so the previous run's expansion
        // doesn't leak into the cards about to stream in. Furigana caches are kept: they're
        // keyed by index and validated against the line text (see ensureFuriganaCaches).
        .onChange(of: isRunning) { _, running in
            if running { expandedByLineIndex = [] }
        }
        // Every change to the rows — a streamed line landing, a breakdown finishing, a
        // regenerate replacing the old lines — refreshes furigana and offsets for the new rows
        // and auto-expands the line the model is currently writing.
        .onChange(of: displayItems) { _, items in
            refreshLineDerivedState(for: items)
        }
        // Covers first appearance with an already-cached breakdown — onChange above only fires
        // on a *transition*, not on the initial value.
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

    // State machine, same shape as before streaming existed except that "loading" is no
    // longer a screen of its own: a failed generation shows the error verbatim; streamed
    // cards show as soon as the first line lands; until then a first generation keeps the
    // generate prompt (with its button spinning) and a regenerate keeps the old cards (with
    // the toolbar icon spinning); otherwise the cached breakdown or the first-visit prompt.
    @ViewBuilder
    private var bodyContent: some View {
        if case .failed(let message) = generationState {
            errorView(message)
        } else if isStreamingCards {
            scrollList(items: displayItems)
        } else if hasBreakdown, let breakdown = cachedBreakdown {
            if isStale(breakdown) {
                staleBanner
            }
            scrollList(items: displayItems)
        } else {
            generatePrompt
        }
    }

    // Banner shown when the cached breakdown's hash disagrees with the current note hash.
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
            .disabled(isRunning)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color.orange.opacity(0.12))
    }

    // First-visit state: explain what's about to happen and let the user kick off the call.
    // Costs are LLM-provider-dependent so we let the user make the deliberate choice rather
    // than auto-firing on entry. While the call runs (and before its first line arrives) the
    // primary button shows a spinner in place of its label.
    private var generatePrompt: some View {
        VStack(spacing: 18) {
            Image(systemName: "music.note.list")
                .font(.system(size: 56))
                .foregroundStyle(.secondary)
            Text("Ready to break this song down line by line.")
                .font(.body)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Text("Sends the lyrics to the LLM configured in Settings.")
                .font(.footnote)
                .multilineTextAlignment(.center)
                .foregroundStyle(.tertiary)
            Button {
                startGeneration()
            } label: {
                if isRunning {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                } else {
                    Label("Generate breakdown", systemImage: "wand.and.stars")
                        .frame(maxWidth: .infinity)
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(isRunning)
            .accessibilityLabel(isRunning ? "Generating breakdown" : "Generate breakdown")
            Button {
                startMergedGeneration()
            } label: {
                Label("Generate breakdown + Fix Segmentation", systemImage: "wand.and.stars.inverse")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .disabled(isRunning)
        }
        .padding(.horizontal, 32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // Generation failed. Shows the underlying message verbatim so the user can distinguish
    // missing-key from network errors from parse failures.
    private func errorView(_ message: String) -> some View {
        VStack(spacing: 18) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 48))
                .foregroundStyle(.orange)
            Text("Couldn't generate breakdown")
                .font(.headline)
            Text(message)
                .font(.footnote)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 32)
            Button {
                startGeneration()
            } label: {
                Label("Retry", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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

    // Triggers a generation call via the store. The store owns the Task, so dismissing
    // this sheet does NOT cancel the work — the user can leave, come back, and find the
    // cards still filling in or the result already cached. The existing breakdown is left
    // in place until the new one lands, so a cancelled or failed run loses nothing.
    private func startGeneration() {
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
    // error view render unchanged regardless of which path is in flight.
    private func startMergedGeneration() {
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
