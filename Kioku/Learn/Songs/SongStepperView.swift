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
    @State private var loadState: SongStepperLoadState = .idle
    @State private var wordsExpandedByLineIndex: Set<Int> = []
    @State private var generationTask: Task<Void, Never>? = nil
    @State private var generationStartedAt: Date? = nil
    @State private var generationProviderLabel: String = ""
    @State private var isRegenerateConfirmationPresented: Bool = false
    // Per-line tap-to-toggle furigana state. Keyed by `line.index` (not array offset) to
    // survive regenerate / breakdown rebuilds, matching how `wordsExpandedByLineIndex`
    // already keys.
    @State private var furiganaEnabledByLineIndex: Set<Int> = []
    @State private var furiganaCacheByLineIndex: [Int: LineFuriganaCache] = [:]

    private let service = SongBreakdownService()

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
                    .disabled(loadState == .loading)
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
    }

    // Three-way state: have a breakdown → show scrollable list (with optional stale
    // banner); mid-generation → spinner; idle/error with no breakdown → prompt or retry.
    @ViewBuilder
    private var bodyContent: some View {
        if let breakdown = songBreakdownStore.breakdown(forNoteID: note.id),
           breakdown.lines.isEmpty == false {
            if isStale(breakdown) {
                staleBanner
            }
            scrollList(breakdown: breakdown)
        } else {
            switch loadState {
            case .idle:
                generatePrompt
            case .loading:
                loadingView
            case .error(let message):
                errorView(message)
            }
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
            .disabled(loadState == .loading)
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
    private var loadingView: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { context in
            let elapsed = generationStartedAt.map { context.date.timeIntervalSince($0) } ?? 0
            VStack(spacing: 16) {
                ProgressView()
                    .scaleEffect(1.4)
                VStack(spacing: 4) {
                    Text("Generating breakdown…")
                        .font(.headline)
                    if generationProviderLabel.isEmpty == false {
                        Text("via \(generationProviderLabel)")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    Text(elapsedLabel(elapsed))
                        .font(.footnote.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Text("Full songs typically take 30–180 seconds. Tap Cancel to back out.")
                    .font(.caption)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 32)
                Button("Cancel") {
                    generationTask?.cancel()
                    generationTask = nil
                    loadState = .idle
                    generationStartedAt = nil
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
                        onToggleWords: { toggleWords(for: line) },
                        onToggleFurigana: { toggleFurigana(for: line) }
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

    // Triggers a generation call. Replaces whatever was in the store on success so
    // a re-run from a stale state cleanly overwrites the old breakdown.
    private func startGeneration() {
        generationTask?.cancel()
        loadState = .loading
        generationStartedAt = Date()
        generationProviderLabel = providerLabelForLoading()
        let noteID = note.id
        let lyrics = note.content
        generationTask = Task { @MainActor in
            do {
                let breakdown = try await service.generate(noteID: noteID, lyrics: lyrics)
                try Task.checkCancellation()
                songBreakdownStore.setBreakdown(breakdown)
                loadState = .idle
                wordsExpandedByLineIndex = []
            } catch is CancellationError {
                loadState = .idle
            } catch {
                let message = (error as? LocalizedError)?.errorDescription
                    ?? error.localizedDescription
                loadState = .error(message)
            }
            generationTask = nil
            generationStartedAt = nil
        }
    }

    // Labels which provider will handle the in-flight request. Reflects the same
    // useLLM / active-provider decision the service will make, so the loading view
    // can show "via Claude" or "via stub" without re-implementing the dispatch logic.
    private func providerLabelForLoading() -> String {
        let useLLM = UserDefaults.standard.bool(forKey: LLMSettings.useLLMKey)
        if useLLM == false {
            return "stub mode"
        }
        switch LLMSettings.activeProvider() {
        case .none: return ""
        case .openAI: return "OpenAI"
        case .claude: return "Claude"
        }
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

// Pure data state held by SongStepperView. Kept as a top-level type so the file-scope rule
// (no nested type declarations) is satisfied while still being conceptually owned by the
// stepper. Pure-cases enum — grouping with related code here is allowed by AGENTS.md.
enum SongStepperLoadState: Equatable {
    case idle
    case loading
    case error(String)
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
