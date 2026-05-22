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
    @EnvironmentObject private var songBreakdownStore: SongBreakdownStore
    @State private var wordsExpandedByLineIndex: Set<Int> = []
    @State private var isRegenerateConfirmationPresented: Bool = false
    // Per-line tap-to-toggle furigana state. Keyed by `line.index` (not array offset) to
    // survive regenerate / breakdown rebuilds, matching how `wordsExpandedByLineIndex`
    // already keys.
    @State private var furiganaEnabledByLineIndex: Set<Int> = []
    @State private var furiganaCacheByLineIndex: [Int: LineFuriganaCache] = [:]
    // Owns audio playback for "play this line" affordances. Stays nil-loaded when the
    // note has no audio attachment or no SRT — the matcher returns an empty map and the
    // cards omit play buttons.
    @StateObject private var audioController = AudioPlaybackController()

    // Convenience init for callers that don't (yet) supply the resolver deps — e.g. previews
    // or any future surface that doesn't have the segmenter in scope. The toggle becomes a
    // visual no-op in that mode.
    init(note: Note,
         segmenter: (any TextSegmenting)? = nil,
         surfaceReadingData: SurfaceReadingDataMap = SurfaceReadingDataMap()) {
        self.note = note
        self.segmenter = segmenter
        self.surfaceReadingData = surfaceReadingData
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
            if songBreakdownStore.breakdown(forNoteID: note.id) != nil {
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
        // regenerate doesn't leave the previous lines visually mid-toggle. Fires only for
        // explicit setBreakdown writes — disk-fault reads go through the non-published
        // memo and don't touch `breakdownsByNoteID`.
        .onChange(of: songBreakdownStore.breakdownsByNoteID[note.id]) { _, newBreakdown in
            guard newBreakdown != nil else { return }
            wordsExpandedByLineIndex = []
            furiganaEnabledByLineIndex = []
            furiganaCacheByLineIndex = [:]
        }
        // Lazily loads the audio + cues for this note (if it has any) so the per-line
        // play buttons have something to seek into. Early-returns when there's no audio
        // attachment, no resolvable file, or empty cue list — all three are normal "no
        // playback available" cases, not errors.
        .task {
            guard let attachmentID = note.audioAttachmentID else { return }
            guard let url = NotesAudioStore.shared.audioURL(for: attachmentID) else { return }
            let cues = NotesAudioStore.shared.loadCues(for: attachmentID)
            try? audioController.load(audioURL: url, cues: cues)
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
                        wordsExpanded: wordsExpandedByLineIndex.contains(line.index),
                        furiganaEnabled: furiganaEnabledByLineIndex.contains(line.index),
                        furiganaCache: furiganaCacheByLineIndex[line.index],
                        playbackRange: lineRangesByIndex[line.index],
                        onToggleWords: { toggleWords(for: line) },
                        onToggleFurigana: { toggleFurigana(for: line) },
                        onPlayLine: {
                            if let range = lineRangesByIndex[line.index] {
                                audioController.playRange(startMs: range.startMs, endMs: range.endMs)
                            }
                        }
                    )
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 14)
        }
    }

    // Flips the per-line "show word explanations" toggle. Default state is collapsed
    // so the page is glanceable; the user opts in per line.
    private func toggleWords(for line: SongLine) {
        if wordsExpandedByLineIndex.contains(line.index) {
            wordsExpandedByLineIndex.remove(line.index)
        } else {
            wordsExpandedByLineIndex.insert(line.index)
        }
    }

    // Flips the per-line furigana toggle and lazily builds the reading cache on first
    // enable. Cache is keyed by `line.index` so repeat toggles for the same line are O(1).
    // Compute lives here (not in `SongLineCard`) because the segmenter, dictionary store,
    // and surfaceReadingData stay scoped to the stepper; the card receives only the result.
    private func toggleFurigana(for line: SongLine) {
        if furiganaEnabledByLineIndex.contains(line.index) {
            furiganaEnabledByLineIndex.remove(line.index)
            return
        }
        if furiganaCacheByLineIndex[line.index] == nil {
            furiganaCacheByLineIndex[line.index] = buildFuriganaCache(for: line.original)
        }
        furiganaEnabledByLineIndex.insert(line.index)
    }

    // Reuses the Read tab's resolver so the breakdown gets the exact same reading
    // selection (okurigana cropping, lemma fallback, projection) as ReadView. When the
    // segmenter is unavailable the cache resolves to "no readings" and the toggle becomes
    // a visual no-op — which matches the "degrade gracefully on pure-kana lines" criterion.
    private func buildFuriganaCache(for text: String) -> LineFuriganaCache {
        guard let segmenter, text.isEmpty == false else {
            return LineFuriganaCache(segmentationRanges: [], furiganaBySegmentLocation: [:], furiganaLengthBySegmentLocation: [:])
        }
        let edges = segmenter.longestMatchEdges(for: text)
        let segmentationRanges = edges.map { $0.start..<$0.end }
        let resolved = FuriganaResolver(segmenter: segmenter).build(
            for: text,
            edges: edges,
            surfaceReadingData: surfaceReadingData
        )
        return LineFuriganaCache(
            segmentationRanges: segmentationRanges,
            furiganaBySegmentLocation: resolved.byLocation,
            furiganaLengthBySegmentLocation: resolved.lengthByLocation
        )
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
