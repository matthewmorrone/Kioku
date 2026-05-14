import SwiftUI

// Per-note stepper that walks through a song's breakdown one line at a time.
// Tap the card body to advance the progressive reveal (Japanese → romaji → words →
// gist + grammar note); swipe horizontally to move between lines. The view drives the
// generation flow itself so the parent home stays a pure list.
//
// Major sections:
//   1. Toolbar with note title + regenerate action
//   2. Stale banner when source text drifted since generation
//   3. Body state machine: not-generated → loading → ready (pager) → error
//   4. Per-line card pager (TabView .page style)
//
// Audio playback per line and dictionary tap-to-save are deliberately deferred to a
// follow-up: both depend on additional cross-tab plumbing that's not in place for the
// Learn tab yet (LyricAlignmentService URL discovery, Words-route deep linking).
struct SongStepperView: View {
    let note: Note
    @EnvironmentObject private var songBreakdownStore: SongBreakdownStore
    @State private var loadState: SongStepperLoadState = .idle
    @State private var currentIndex: Int = 0
    @State private var revealByLineIndex: [Int: Int] = [:]
    @State private var generationTask: Task<Void, Never>? = nil
    @State private var generationStartedAt: Date? = nil
    @State private var generationProviderLabel: String = ""

    private let service = SongBreakdownService()

    var body: some View {
        VStack(spacing: 0) {
            bodyContent
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Text(displayTitle)
                    .font(.headline)
                    .lineLimit(1)
                    .accessibilityLabel(displayTitle)
            }
            if songBreakdownStore.breakdown(forNoteID: note.id) != nil {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        regenerate()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .disabled(loadState == .loading)
                    .accessibilityLabel("Regenerate breakdown")
                }
            }
        }
        .onAppear {
            // Defensive reset: NavigationStack should recreate the view on push, but if
            // SwiftUI reuses an instance the @State for currentIndex could hold a stale
            // mid-song offset. Always start the stepper at line 1.
            currentIndex = 0
        }
        .onDisappear {
            generationTask?.cancel()
            generationTask = nil
        }
        .preference(key: CardsStudySessionActivePreferenceKey.self, value: true)
        .preference(key: CardsPageDotsHiddenPreferenceKey.self, value: true)
    }

    // Three-way state: have a breakdown → show pager (with optional stale banner);
    // mid-generation → spinner; idle/error with no breakdown → prompt or retry.
    @ViewBuilder
    private var bodyContent: some View {
        if let breakdown = songBreakdownStore.breakdown(forNoteID: note.id),
           breakdown.lines.isEmpty == false {
            if isStale(breakdown) {
                staleBanner
            }
            pager(breakdown: breakdown)
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
                regenerate()
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

    // Horizontal pager over the breakdown's lines. `.page` style binds swipe directly;
    // page dots are suppressed via preference key on the parent so the Learn pager's
    // own dots don't double up with the inner pager's.
    private func pager(breakdown: SongBreakdown) -> some View {
        TabView(selection: $currentIndex) {
            ForEach(Array(breakdown.lines.enumerated()), id: \.offset) { offset, line in
                SongLineCard(
                    line: line,
                    referencedLine: referencedLine(for: line, in: breakdown),
                    position: offset + 1,
                    total: breakdown.lines.count,
                    revealStage: revealByLineIndex[line.index] ?? 0,
                    onAdvance: {
                        advance(for: line)
                    }
                )
                .padding(.horizontal, 18)
                .padding(.vertical, 12)
                .tag(offset)
            }
        }
        .tabViewStyle(.page(indexDisplayMode: .never))
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

    // Advances the reveal stage for one line, capped by the line's revealStageCap (defined
    // on SongLine so the stepper and the card cannot drift on what counts as a stage).
    private func advance(for line: SongLine) {
        let current = revealByLineIndex[line.index] ?? 0
        if current < line.revealStageCap {
            revealByLineIndex[line.index] = current + 1
        }
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
                currentIndex = 0
                revealByLineIndex = [:]
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

    private var displayTitle: String {
        let trimmed = note.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty == false { return trimmed }
        let firstLine = note.content
            .components(separatedBy: .newlines)
            .first?
            .trimmingCharacters(in: .whitespaces) ?? ""
        return firstLine.isEmpty ? "Song" : firstLine
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
