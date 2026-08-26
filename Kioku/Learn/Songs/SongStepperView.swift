import Foundation
import SwiftUI

// Per-note breakdown view: every line of the song stacked in one vertical scroll.
// Each line card always shows Japanese / romaji / gist / grammar; the per-line word
// list is collapsed by default and toggled by the user. The view drives the generation
// flow itself so the parent home stays a pure list.
//
// Major sections:
//   1. Toolbar with regenerate action
//   2. Stale banner when source text drifted since generation
//   3. Body state machine: not-generated → loading → ready (scroll) → error
//   4. Vertical scroll of per-line cards
struct SongStepperView: View {
    let note: Note
    // Optional deps for per-line tap-to-toggle furigana. Nil segmenter degrades the toggle
    // to a no-op (cache resolves empty); `surfaceReadingData` defaults to an empty map. The
    // dictionary store was previously plumbed here too — it was carried over from an earlier
    // direct-lookup design and is no longer needed now that `FuriganaResolver` reads through
    // `surfaceReadingData`, so it's been removed to avoid dead state.
    let segmenter: (any TextSegmenting)?
    let surfaceReadingData: SurfaceReadingDataMap
    let kanjiReadingFallback: KanjiReadingFallbackMap
    // Resolves tapped breakdown words to a dictionary entry for the lookup sheet. Optional so the
    // legacy SongsHomeView caller (no dictionary in scope) still compiles; tap-to-lookup no-ops there.
    let dictionaryStore: DictionaryStore?
    @EnvironmentObject private var songBreakdownStore: SongBreakdownStore
    // Drives the lookup sheet's save star for tapped words (globally injected at the app root).
    @EnvironmentObject private var wordsStore: WordsStore
    // Powers the lookup sheet's save button long-press learned-state menu.
    // Per-line expansion state: whether a line's word/grammar explanations are visible.
    // Furigana on the Japanese row is independent of this (see ensureFuriganaCaches / the
    // eager cache build). Keyed by `line.index` (not array offset) so it survives
    // regenerate / breakdown rebuilds.
    @State private var expandedByLineIndex: Set<Int> = []
    @State private var isRegenerateConfirmationPresented: Bool = false
    @State private var furiganaCacheByLineIndex: [Int: LineFuriganaCache] = [:]
    // The note's persisted per-note reading overrides (Note.segments), restored once per
    // breakdown load — see buildFuriganaCache / applyNoteFuriganaOverrides. Nil when the note
    // has no persisted segments or they no longer validate against its current content.
    @State private var noteFuriganaRestoration: (byLocation: [Int: String], lengthByLocation: [Int: Int])?
    // Each breakdown line's starting UTF-16 offset within note.content, so a note-level reading
    // override (keyed by note.content coordinates) can be rebased into a line's local
    // coordinates. See lineStartOffsets.
    @State private var lineStartOffsetsByIndex: [Int: Int] = [:]
    // Per-kanji-run readings for word-list headwords, keyed by (line, surface) — not surface
    // alone, since the same word can appear on multiple lines with a different resolved
    // reading (e.g. a Read-tab correction pinned on one occurrence but not another) and a
    // surface-only key would let the first occurrence's reading leak into every later one.
    // Built alongside furiganaCacheByLineIndex (see ensureFuriganaCaches) and handed to each
    // SongLineCard so its "Show explanations" word list can render furigana too.
    @State private var wordFuriganaByKey: [WordFuriganaKey: [Int: String]] = [:]
    // Owns audio playback for "play this line" affordances. Stays nil-loaded when the
    // note has no audio attachment or no SRT — the matcher returns an empty map and the
    // cards omit play buttons.
    @StateObject private var audioController = AudioPlaybackController()

    // Convenience init for callers that don't (yet) supply the resolver deps — e.g. previews
    // or any future surface that doesn't have the segmenter in scope. The toggle becomes a
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
            if let breakdown = songBreakdownStore.breakdown(forNoteID: note.id),
               breakdown.lines.isEmpty == false {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        toggleAllExpansion(in: breakdown)
                    } label: {
                        Image(systemName: areAllLinesExpanded(in: breakdown) ? "eye.slash" : "eye")
                    }
                    .accessibilityLabel(areAllLinesExpanded(in: breakdown) ? "Hide all explanations" : "Show all explanations")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        isRegenerateConfirmationPresented = true
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .disabled(songBreakdownStore.isGenerating(forNoteID: note.id))
                    .accessibilityLabel("Regenerate breakdown")
                }
            }
        }
        .confirmationDialog(
            "Regenerate this breakdown?",
            isPresented: $isRegenerateConfirmationPresented,
            titleVisibility: .visible
        ) {
            // Destructive role on regenerate reflects what happens: the existing breakdown
            // is cleared from cache before the new request fires. A network/cost error
            // mid-call leaves the user with nothing until the call retries — worth a
            // deliberate tap, not a stray bar-button.
            Button("Regenerate", role: .destructive) {
                regenerate()
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            // Honest framing: full-song breakdowns are minutes-long and bill per token.
            Text("Sends the full lyrics to the configured LLM provider. Takes 30–180 seconds and uses paid tokens. The existing breakdown is replaced.")
        }
        .preference(key: CardsStudySessionActivePreferenceKey.self, value: true)
        .preference(key: CardsPageDotsHiddenPreferenceKey.self, value: true)
        // Reset per-line expansion / furigana caches when a fresh breakdown lands so a
        // regenerate doesn't leave the previous lines visually mid-toggle, then eagerly
        // resolve furigana for the new breakdown (see ensureFuriganaCaches) so lines and
        // word lists show readings immediately rather than only after the user expands them.
        // Fires only for explicit setBreakdown writes — disk-fault reads go through the
        // non-published memo and don't touch `breakdownsByNoteID`.
        .onChange(of: songBreakdownStore.breakdownsByNoteID[note.id]) { _, newBreakdown in
            guard let newBreakdown else { return }
            expandedByLineIndex = []
            furiganaCacheByLineIndex = [:]
            wordFuriganaByKey = [:]
            noteFuriganaRestoration = Self.restoreNoteFurigana(from: note)
            lineStartOffsetsByIndex = Self.lineStartOffsets(for: newBreakdown.lines, in: note.content)
            ensureFuriganaCaches(for: newBreakdown)
        }
        // Covers the case this view appears with an already-cached breakdown on disk — the
        // onChange above only fires on a *transition*, not on the initial value, so without
        // this a breakdown opened straight from cache would show no furigana until some
        // unrelated store write happened to fire the onChange.
        .onAppear {
            noteFuriganaRestoration = Self.restoreNoteFurigana(from: note)
            if let breakdown = songBreakdownStore.breakdown(forNoteID: note.id) {
                lineStartOffsetsByIndex = Self.lineStartOffsets(for: breakdown.lines, in: note.content)
                ensureFuriganaCaches(for: breakdown)
            }
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

    // Maps each breakdown line.index → its matched audio time range. Empty when the note
    // has no audio or the SRT doesn't line up with the breakdown. Computed on each body
    // pass; both inputs are tiny (~30 lines × ~30 cues) so the O(N·M) walk is cheap.
    private var lineRangesByIndex: [Int: (startMs: Int, endMs: Int)] {
        guard let breakdown = songBreakdownStore.breakdown(forNoteID: note.id),
              audioController.cues.isEmpty == false else { return [:] }
        return SongLineCueMatcher.computeRanges(lines: breakdown.lines, cues: audioController.cues)
    }

    // Three-way state: a running/failed generation in the store always wins (the user
    // wants to see the spinner or the error verbatim, even if a previous breakdown is on
    // disk); otherwise a cached breakdown renders the scroll list; otherwise the prompt.
    // Reading the generation state from the store — not local @State — is what makes the
    // task survive sheet dismissal: the spinner re-binds to the same in-flight Task on
    // re-entry, with the original `startedAt` so the elapsed clock keeps counting.
    @ViewBuilder
    private var bodyContent: some View {
        if let generationState = songBreakdownStore.generationStateByNoteID[note.id] {
            switch generationState {
            case .running(let startedAt, let providerLabel):
                loadingView(startedAt: startedAt, providerLabel: providerLabel)
            case .failed(let message):
                errorView(message)
            }
        } else if let breakdown = songBreakdownStore.breakdown(forNoteID: note.id),
                  breakdown.lines.isEmpty == false {
            if isStale(breakdown) {
                staleBanner
            }
            scrollList(breakdown: breakdown)
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
            .disabled(songBreakdownStore.isGenerating(forNoteID: note.id))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color.orange.opacity(0.12))
    }

    // First-visit state: explain what's about to happen and let the user kick off the call.
    // Costs are LLM-provider-dependent so we let the user make the deliberate choice rather
    // than auto-firing on entry.
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
                Label("Generate breakdown", systemImage: "wand.and.stars")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
        .padding(.horizontal, 32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // Generation in flight. Shows elapsed time so the user knows the call is alive — a full
    // song breakdown commonly takes 60-180s; without a running counter the screen feels
    // frozen and people assume it's wedged. Cancellable mid-flight.
    //
    // `startedAt` is sourced from the store, not local @State, so re-entering the sheet
    // mid-generation shows the *same* elapsed clock that was running before dismissal — not
    // a counter that resets to zero each time the sheet remounts.
    private func loadingView(startedAt: Date, providerLabel: String) -> some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { context in
            let elapsed = context.date.timeIntervalSince(startedAt)
            VStack(spacing: 16) {
                ProgressView()
                    .scaleEffect(1.4)
                VStack(spacing: 4) {
                    Text("Generating breakdown…")
                        .font(.headline)
                    if providerLabel.isEmpty == false {
                        Text("via \(providerLabel)")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    Text(elapsedLabel(elapsed))
                        .font(.footnote.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Text("Full songs typically take 30–180 seconds. You can close this sheet — generation will continue in the background.")
                    .font(.caption)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 32)
                Button("Cancel") {
                    songBreakdownStore.cancelGeneration(forNoteID: note.id)
                }
                .padding(.top, 4)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // Formats the elapsed-time counter shown under the spinner.
    private func elapsedLabel(_ elapsed: TimeInterval) -> String {
        let total = Int(elapsed.rounded())
        let minutes = total / 60
        let seconds = total % 60
        if minutes > 0 {
            return String(format: "%d:%02d elapsed", minutes, seconds)
        }
        return "\(seconds)s elapsed"
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

    // Vertical scroll over every line in the breakdown. Each card is independent;
    // expanding/collapsing one line's word list doesn't disturb the others.
    private func scrollList(breakdown: SongBreakdown) -> some View {
        ScrollView(.vertical, showsIndicators: true) {
            LazyVStack(spacing: 14) {
                ForEach(Array(breakdown.lines.enumerated()), id: \.offset) { _, line in
                    SongLineCard(
                        line: line,
                        referencedLine: referencedLine(for: line, in: breakdown),
                        isExpanded: expandedByLineIndex.contains(line.index),
                        furiganaCache: furiganaCacheByLineIndex[line.index],
                        wordFurigana: wordFuriganaByKey,
                        playbackRange: lineRangesByIndex[line.index],
                        onToggleExpansion: { toggleExpansion(for: line) },
                        onPlayLine: {
                            if let range = lineRangesByIndex[line.index] {
                                audioController.playRange(startMs: range.startMs, endMs: range.endMs)
                            }
                        },
                        onWordTapped: { presentWordLookup($0) }
                    )
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 14)
        }
    }

    // Flips the per-line "expanded" state, which now controls only the word/grammar
    // explanations — furigana is resolved eagerly for every line (see ensureFuriganaCaches)
    // and no longer depends on this flag. The defensive rebuild below is a safety net for
    // the (normally unreachable) case a line's cache wasn't populated by the eager pass.
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

    // True when every line in the breakdown is currently expanded. Drives the toolbar
    // eye / eye.slash icon and the "Show all" vs "Hide all" semantics — comparing counts
    // is enough because `expandedByLineIndex` only ever holds valid line indices.
    private func areAllLinesExpanded(in breakdown: SongBreakdown) -> Bool {
        breakdown.lines.isEmpty == false && expandedByLineIndex.count >= breakdown.lines.count
    }

    // Global toolbar action: if any line is collapsed, expand them all (building any
    // missing furigana caches on the fly); otherwise collapse everything. Building caches
    // synchronously is fine here — songs are typically <60 lines and `buildFuriganaCache`
    // is the same work a per-line tap would do, just batched.
    private func toggleAllExpansion(in breakdown: SongBreakdown) {
        if areAllLinesExpanded(in: breakdown) {
            expandedByLineIndex.removeAll()
            return
        }
        for line in breakdown.lines where furiganaCacheByLineIndex[line.index] == nil {
            furiganaCacheByLineIndex[line.index] = buildFuriganaCache(for: line)
        }
        expandedByLineIndex = Set(breakdown.lines.map { $0.index })
    }

    // Eagerly resolves furigana for every line and every word-list headword in the
    // breakdown, so readings are available as soon as a line or word list renders rather
    // than only after the user taps to expand it (see SongLineCard.originalLine — furigana
    // there no longer waits on the expansion toggle). Idempotent: skips any line/surface
    // already cached, so calling this again after a partial build (or "Show all") is cheap.
    private func ensureFuriganaCaches(for breakdown: SongBreakdown) {
        for line in breakdown.lines where furiganaCacheByLineIndex[line.index] == nil {
            furiganaCacheByLineIndex[line.index] = buildFuriganaCache(for: line)
        }
        for line in breakdown.lines {
            for word in line.words {
                let key = WordFuriganaKey(lineIndex: line.index, surface: word.surface)
                guard wordFuriganaByKey[key] == nil else { continue }
                wordFuriganaByKey[key] = buildWordFuriganaRunReadings(for: word, contextLine: line)
            }
        }
    }

    // Resolves per-kanji-run readings for a single word-list headword. Prefers slicing the
    // already-resolved *line* cache (the word's readings as chosen with full sentence
    // context — okurigana, verb-phrase segmentation, etc.) when the word's surface appears
    // verbatim in that line; only isolated words (surface not found in the line, e.g. an
    // LLM-normalized headword) fall back to segmenting the surface on its own, which can
    // pick a different reading than the same characters would get in context.
    private func buildWordFuriganaRunReadings(for word: SongWord, contextLine: SongLine) -> [Int: String] {
        if let lineCache = furiganaCacheByLineIndex[contextLine.index],
           let wordRange = contextLine.original.range(of: word.surface) {
            let wordNSRange = NSRange(wordRange, in: contextLine.original)
            let sliced = lineCache.furiganaBySegmentLocation.compactMap { location, reading -> (Int, String)? in
                guard location >= wordNSRange.location,
                      location < wordNSRange.location + wordNSRange.length else { return nil }
                return (location - wordNSRange.location, reading)
            }
            if sliced.isEmpty == false {
                return Dictionary(uniqueKeysWithValues: sliced)
            }
        }
        return buildWordFuriganaRunReadings(for: word.surface)
    }

    // Resolves per-kanji-run readings for a word's surface in isolation, with no surrounding
    // sentence to segment against. Used as a fallback when the surface can't be located
    // within its source line (e.g. an LLM-normalized headword that doesn't appear verbatim).
    private func buildWordFuriganaRunReadings(for surface: String) -> [Int: String] {
        guard let segmenter, surface.isEmpty == false else { return [:] }
        let edges = segmenter.longestMatchEdges(for: surface)
        return FuriganaResolver(
            segmenter: segmenter,
            kanjiReadingFallback: kanjiReadingFallback
        ).build(
            for: surface,
            edges: edges,
            surfaceReadingData: surfaceReadingData
        ).byLocation
    }

    // Reuses the Read tab's resolver so the breakdown gets the exact same reading
    // selection (okurigana cropping, lemma fallback, projection) as ReadView. When the
    // segmenter is unavailable the cache resolves to "no readings" and the toggle becomes
    // a visual no-op — which matches the "degrade gracefully on pure-kana lines" criterion.
    //
    // The resolver's output is a fresh recompute — it doesn't know about readings the user
    // pinned or corrected on the Read tab (Note.segments). applyNoteFuriganaOverrides overlays
    // those on top so the breakdown always shows the same reading as the underlying page.
    private func buildFuriganaCache(for line: SongLine) -> LineFuriganaCache {
        let text = line.original
        guard let segmenter, text.isEmpty == false else {
            return LineFuriganaCache(segmentationRanges: [], furiganaBySegmentLocation: [:], furiganaLengthBySegmentLocation: [:])
        }
        let edges = segmenter.longestMatchEdges(for: text)
        let segmentationRanges = edges.map { $0.start..<$0.end }
        let resolved = FuriganaResolver(
            segmenter: segmenter,
            kanjiReadingFallback: kanjiReadingFallback
        ).build(
            for: text,
            edges: edges,
            surfaceReadingData: surfaceReadingData
        )
        var byLocation = resolved.byLocation
        var lengthByLocation = resolved.lengthByLocation
        applyNoteFuriganaOverrides(to: &byLocation, lengthByLocation: &lengthByLocation, forLineIndex: line.index)
        return LineFuriganaCache(
            segmentationRanges: segmentationRanges,
            furiganaBySegmentLocation: byLocation,
            furiganaLengthBySegmentLocation: lengthByLocation
        )
    }

    // Overlays any reading the user pinned or corrected on the Read tab (persisted in
    // `note.segments`, restored into `noteFuriganaRestoration`) onto this line's freshly
    // resolved furigana. Only swaps the reading text at a location the fresh segmentation
    // already produced a same-length entry for — a location/length mismatch (e.g. the user
    // manually merged or split segments on the Read tab, shifting boundaries) just falls back
    // to the freshly-resolved default rather than trying to reconcile differing boundaries.
    // Regenerating the breakdown always picks up the correct reading regardless.
    private func applyNoteFuriganaOverrides(
        to byLocation: inout [Int: String],
        lengthByLocation: inout [Int: Int],
        forLineIndex lineIndex: Int
    ) {
        guard let restoration = noteFuriganaRestoration,
              let lineStart = lineStartOffsetsByIndex[lineIndex] else { return }
        for (location, length) in lengthByLocation {
            let globalLocation = lineStart + location
            guard restoration.lengthByLocation[globalLocation] == length,
                  let reading = restoration.byLocation[globalLocation] else { continue }
            byLocation[location] = reading
        }
    }

    // Restores the note's persisted per-note reading overrides (Note.segments), keyed by
    // UTF-16 offset within note.content. Nil when the note has no persisted segments or they
    // no longer validate against its current content (e.g. edited outside the segment-aware
    // editor) — callers degrade to the freshly-resolved default in that case.
    private static func restoreNoteFurigana(from note: Note) -> (byLocation: [Int: String], lengthByLocation: [Int: Int])? {
        guard let normalized = SegmentRangeRestoration.normalizedSegmentRanges(note.segments, for: note.content) else { return nil }
        return SegmentRangeRestoration.furiganaFromSegmentRanges(normalized)
    }

    // Finds each breakdown line's starting UTF-16 offset within note.content, so a note-level
    // reading override can be rebased into that line's local coordinates. Searches in line
    // order, advancing the cursor past each match, so a repeated chorus line resolves to its
    // own occurrence rather than always the first. A line whose text isn't found verbatim
    // (e.g. the LLM normalized it slightly) is simply omitted — its furigana falls back to the
    // freshly-resolved default.
    private static func lineStartOffsets(for lines: [SongLine], in noteContent: String) -> [Int: Int] {
        var offsets: [Int: Int] = [:]
        var searchStart = noteContent.startIndex
        for line in lines where line.original.isEmpty == false {
            guard let range = noteContent.range(of: line.original, range: searchStart..<noteContent.endIndex) else { continue }
            offsets[line.index] = NSRange(range, in: noteContent).location
            searchStart = range.upperBound
        }
        return offsets
    }

    // Resolves the line referenced by `= line N` or `Parallel to line N` so the card can
    // peek the original content without the consumer needing to scan the full breakdown.
    private func referencedLine(for line: SongLine, in breakdown: SongBreakdown) -> SongLine? {
        guard let reference = line.reference else { return nil }
        let target: Int
        switch reference {
        case .sameAsLine(let n): target = n
        case .parallelTo(line: let n, substitution: _): target = n
        }
        return breakdown.lines.first(where: { $0.index == target })
    }

    // Triggers a generation call via the store. The store owns the Task, so dismissing
    // this sheet does NOT cancel the work — the user can leave, come back, and find the
    // spinner still ticking or the result already cached. Clearing any prior `.failed`
    // entry transitions the view back to the loading state cleanly on Retry.
    private func startGeneration() {
        songBreakdownStore.clearGenerationError(forNoteID: note.id)
        songBreakdownStore.startGeneration(
            forNoteID: note.id,
            lyrics: note.content,
            providerLabel: SongBreakdownStore.loadingProviderLabel()
        )
    }

    // Clears the cached breakdown and triggers a fresh generation. Used by the stale banner
    // and the toolbar action; clearing first means the UI shows the loading state cleanly.
    private func regenerate() {
        songBreakdownStore.clearBreakdown(forNoteID: note.id)
        startGeneration()
    }

    // Compares the cached breakdown's hash against the current note text hash.
    private func isStale(_ breakdown: SongBreakdown) -> Bool {
        breakdown.sourceTextHash != SongBreakdownService.sha256(note.content)
    }
}

// Pre-resolved per-line furigana payload. The three fields together are exactly the data
// shape `FuriganaTextRenderer` consumes, so the card hands them straight through with no
// further conversion. Built lazily on first toggle and held in the stepper's @State so
// re-enabling furigana for the same line is instant.
struct LineFuriganaCache: Equatable {
    let segmentationRanges: [Range<String.Index>]
    let furiganaBySegmentLocation: [Int: String]
    let furiganaLengthBySegmentLocation: [Int: Int]
}
