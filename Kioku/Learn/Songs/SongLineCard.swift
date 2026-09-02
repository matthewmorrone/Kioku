import SwiftUI
import UIKit

// One line of a song breakdown rendered as a card inside the per-note vertical scroll.
// Layout (top → bottom):
//   - header (line number)
//   - reference chip (only for repeated/parallel chorus lines)
//   - Japanese original
//   - gist + grammar note  ← falls through to referenced line for chorus repeats
//   - "Show / Hide word explanations" toggle, followed by the word list when expanded
//
// Fall-through for `.sameAsLine` / `.parallelTo` lines: the prompt instructs the model to
// skip the full breakdown on repeats and just emit "= line N". That leaves the SongLine's
// own gist/words/grammar empty. We don't want a chorus line to render as a bare Japanese
// string — the user still wants the explanation — so the card prefers the line's own
// fields when present and falls back to the referenced line's fields when they're empty.
//
// The word list is collapsed by default so a long song stays glanceable; the user opts
// in per line. The card no longer owns a scroll view — the parent SongStepperView
// scrolls the whole song, and nested same-axis ScrollViews fight each other.
struct SongLineCard: View {
    let line: SongLine
    let referencedLine: SongLine?
    // Per-line "expanded" flag controlling the word/grammar explanations below the Japanese
    // row. Furigana on the Japanese row itself is independent of this flag — see
    // `originalLine` — so it's visible whether or not the explanations are open.
    let isExpanded: Bool
    // Lazily-populated cache; nil before the first expansion for this line. Owned by the
    // parent stepper so cache compute happens once per line per session.
    let furiganaCache: LineFuriganaCache?
    // Per-kanji-run readings for word-list headwords, keyed by (line, surface) — not surface
    // alone, since the same word can resolve to a different reading on different lines (see
    // WordFuriganaKey). Owned by the parent stepper (it has the segmenter/surfaceReadingData
    // in scope) and built eagerly alongside furiganaCache so every word in the explanations
    // list can show furigana.
    let wordFurigana: [WordFuriganaKey: [Int: String]]
    // Play-button state for this line's narration (sung clip when available, then the
    // sentence, gist, and words — see SongListenScript). Nil hides the button entirely.
    let playState: SongLineCardPlayState?
    // Streaming state for this row (see SongLineCardPhase). `.streaming` adds an accent border
    // and a spinner in the header and suppresses the recovery notice (an in-progress line
    // legitimately has no content yet); `.playing` adds the border alone.
    let phase: SongLineCardPhase
    // The listen-along segment currently being spoken, when it belongs to this line: tints
    // the matching row (sentence / gist / word) so the card doubles as the transcript.
    let listenHighlight: SongListenSegment?
    let onToggleExpansion: () -> Void
    let onPlayLine: () -> Void
    // Opens the shared lookup sheet for a tapped vocabulary row. The parent owns the dictionary
    // resolution + presentation so this card stays a pure renderer.
    let onWordTapped: (SongWord) -> Void

    @AppStorage(TypographySettings.furiganaGapKey) private var furiganaGap = TypographySettings.defaultFuriganaGap

    // For each field, prefer the line's own value; fall back to the referenced line's
    // when this line is a reference and the field is empty. This is the load-bearing piece
    // for "= line N" repeats: without fall-through they render as empty cards.
    private var effectiveGist: String? {
        if let g = line.gist, g.isEmpty == false { return g }
        if line.reference != nil { return referencedLine?.gist }
        return nil
    }
    private var effectiveGrammarNote: String? {
        if let g = line.grammarNote, g.isEmpty == false { return g }
        if line.reference != nil { return referencedLine?.grammarNote }
        return nil
    }
    private var effectiveWords: [SongWord] {
        if line.words.isEmpty == false { return line.words }
        if line.reference != nil { return referencedLine?.words ?? [] }
        return []
    }
    // The line index whose words `effectiveWords` is actually drawing from — this line's own,
    // or (for a "= line N" chorus fall-through) the referenced line's. Mirrors effectiveWords'
    // own fallback so wordFurigana lookups use the same line identity the cache was built with.
    private var effectiveWordsLineIndex: Int {
        if line.words.isEmpty == false { return line.index }
        if line.reference != nil, let referencedLine { return referencedLine.index }
        return line.index
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            originalLine
            gistSection
            // Pattern note moved into the expanded explanations area below; gist stays
            // up top as the headline. Toggle visibility tracks "anything to expand?" —
            // words OR a pattern note qualifies.
            if hasExpandableDetail {
                expandableDetailToggle
                if isExpanded {
                    expandableDetailContent
                }
            }
            recoveryStubNoticeIfNeeded
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .padding(20)
        .background(
            RoundedRectangle(cornerRadius: 18)
                .fill(Color(.secondarySystemBackground))
        )
        .overlay(cardBorder)
        .clipShape(RoundedRectangle(cornerRadius: 18))
        .animation(.easeInOut(duration: 0.25), value: phase)
        .accessibilityElement(children: .contain)
    }

    // The streaming or playing card gets a 2pt accent ring so the eye lands on the line the
    // model is writing / the narrator is speaking; every other card keeps the plain stroke.
    private var cardBorder: some View {
        let isRinged = phase == .streaming || phase == .playing
        return RoundedRectangle(cornerRadius: 18)
            .stroke(isRinged ? Color.accentColor : Color(.separator), lineWidth: isRinged ? 2 : 1)
    }

    // Whether listen-along is speaking the given kind of row on this line right now.
    private func isSpeaking(_ kind: SongListenSegmentKind) -> Bool {
        listenHighlight?.kind == kind
    }

    // Whether listen-along is speaking this word's surface or definition right now. Matched
    // by text, since the segment carries no word identity — the same text the script was
    // built from (SongListenScript), so a repeated word tints on each occurrence.
    private func isSpeaking(_ word: SongWord) -> Bool {
        guard let listenHighlight else { return false }
        switch listenHighlight.kind {
        case .wordSurface:
            return listenHighlight.text == word.surface.trimmingCharacters(in: .whitespacesAndNewlines)
        case .wordDefinition:
            return listenHighlight.text == SongLineCard.stripInlineMarkdown(word.definition)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        case .sentence, .translation:
            return false
        }
    }

    // Row tint for whatever listen-along is speaking. Applied behind the sentence, gist, or
    // word row; clear otherwise so the layout never shifts when the highlight moves.
    private func speakingBackground(_ isActive: Bool) -> some View {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(isActive ? Color.accentColor.opacity(0.16) : Color.clear)
    }

    // Position indicator + (when this is a chorus repeat) an inline reference annotation.
    // The annotation lives to the right of `Line N` rather than in a styled chip below it:
    // the relationship is metadata about the line, not its own content block. The user
    // sees "Same as line 1" and immediately reads this line's Japanese underneath.
    //
    // The trailing play button plays this line's stretch of the listen-along track (or
    // pauses it while this line is the one speaking); it spins while that track renders.
    private var header: some View {
        HStack(spacing: 8) {
            Text("Line \(line.index)")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .fixedSize()
            if let reference = line.reference {
                inlineReferenceLabel(reference)
            }
            Spacer(minLength: 0)
            if phase == .streaming {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel("Generating line \(line.index)")
            }
            if let playState {
                playButton(playState)
            }
        }
    }

    // Small accent-coloured ▶︎ / ❚❚ that triggers `onPlayLine` (the parent decides whether
    // that means play or pause from the state), or a spinner while the narration track this
    // line needs is still being rendered.
    @ViewBuilder
    private func playButton(_ state: SongLineCardPlayState) -> some View {
        switch state {
        case .loading:
            ProgressView()
                .controlSize(.small)
                .accessibilityLabel("Preparing audio for line \(line.index)")
        case .idle, .playing:
            Button(action: onPlayLine) {
                Image(systemName: state == .playing ? "pause.circle.fill" : "play.circle.fill")
                    .font(.system(size: 22))
                    .foregroundStyle(Color.accentColor)
                    .accessibilityLabel(state == .playing ? "Pause line \(line.index)" : "Play line \(line.index)")
            }
            .buttonStyle(.plain)
        }
    }

    // Compact reference label: small arrow icon + "Same as line N" or "Parallel to line N · X → Y".
    // Accent-coloured so it reads as a link cue without needing its own background panel.
    private func inlineReferenceLabel(_ reference: LineReference) -> some View {
        HStack(spacing: 4) {
            Image(systemName: "arrow.uturn.backward")
                .font(.caption2)
            switch reference {
            case .sameAsLine(let n):
                Text("Same as line \(n)")
                    .font(.footnote.weight(.semibold))
            case .parallelTo(line: let n, substitution: let sub):
                if sub.isEmpty {
                    Text("Parallel to line \(n)")
                        .font(.footnote.weight(.semibold))
                } else {
                    Text("Parallel to line \(n) · \(sub)")
                        .font(.footnote.weight(.semibold))
                }
            }
        }
        .foregroundStyle(Color.accentColor)
        .lineLimit(1)
        .minimumScaleFactor(0.6)
        .allowsTightening(true)
    }

    // Surfaces a note when the line has no gist, no grammar note, no words, and no reference
    // — the shape produced by `SongBreakdownRecovery` for lines that survived as
    // headers-only in a pre-fix cached breakdown. Without this, the user sees a line
    // collapse to just the Japanese and reasonably wonders why it has no explanation.
    @ViewBuilder
    private var recoveryStubNoticeIfNeeded: some View {
        if isRecoveryStub {
            HStack(spacing: 6) {
                Image(systemName: "info.circle")
                    .font(.footnote)
                Text("Recovered from older data — regenerate for full explanation.")
                    .font(.footnote)
            }
            .foregroundStyle(.tertiary)
        }
    }

    private var isRecoveryStub: Bool {
        guard phase == .ready else { return false }
        let hasGist = (line.gist?.isEmpty == false)
        let hasGrammar = (line.grammarNote?.isEmpty == false)
        return hasGist == false
            && hasGrammar == false
            && line.words.isEmpty
            && line.reference == nil
            && line.index > 1
    }

    // Big Japanese row. Furigana shows whenever the cache has readings for this line —
    // independent of `isExpanded`, which now controls only the word/grammar explanations
    // below. (Previously furigana was tied to the same flag, so collapsing the explanations
    // — or simply never expanding a line — hid furigana too; readers want the reading aid
    // available regardless of whether they've opened the explanations for that line.)
    // Tapping the row still toggles the explanations. The two branches share size/leading-
    // alignment so that toggle does not shift the surrounding layout. The plain branch
    // carries its own SwiftUI tap gesture; the renderer branch routes taps through
    // `onSegmentTapped` because a UIViewRepresentable wrapping UITextView intercepts
    // touches before SwiftUI sees them.
    //
    // The cache is only used when it was built from exactly this text: its segmentation
    // ranges are String.Index values into `sourceText`, and applying them to a different
    // string traps inside the CoreText renderer. A stale cache (the parent rebuilds it on the
    // next update) falls through to the plain branch for one frame instead.
    @ViewBuilder
    private var originalLine: some View {
        if let cache = furiganaCache,
           cache.sourceText == line.original,
           cache.furiganaBySegmentLocation.isEmpty == false {
            furiganaRow(cache: cache)
                .background(speakingBackground(isSpeaking(.sentence)))
                .accessibilityLabel(line.original)
                .accessibilityHint(explanationsAccessibilityHint)
        } else {
            Text(line.original)
                .font(.system(size: 28, weight: .medium))
                .lineSpacing(4)
                .multilineTextAlignment(.leading)
                // Matches the CoreText renderer's content inset (top/bottom 8, left/right 4)
                // so this fallback lines up with the furigana-renderer branch above — otherwise
                // lines alternate between the two branches depending on whether furiganaCache
                // resolved any kanji, and the fallback sits ~4pt further left/higher than lines
                // rendered via the renderer.
                .padding(EdgeInsets(top: 8, leading: 4, bottom: 8, trailing: 4))
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(speakingBackground(isSpeaking(.sentence)))
                .contentShape(Rectangle())
                .onTapGesture { onToggleExpansion() }
                .accessibilityLabel(line.original)
                .accessibilityHint(explanationsAccessibilityHint)
        }
    }

    private var explanationsAccessibilityHint: String {
        guard hasExpandableDetail else { return "" }
        return isExpanded ? "Tap to hide explanations" : "Tap to show explanations"
    }

    // Renders the line via the same CoreText renderer the Read tab uses, at the same 28pt
    // size as the plain Text branch. `isScrollEnabled` is false so the renderer's
    // `sizeThatFits` reports a real multi-line height to SwiftUI. Color alternation,
    // highlights, and debug overlays are all off — this is a passive reveal, not
    // interactive read mode.
    private func furiganaRow(cache: LineFuriganaCache) -> some View {
        KiokuCoreTextRendererView(
            text: line.original,
            segmentationRanges: cache.segmentationRanges,
            furiganaBySegmentLocation: cache.furiganaBySegmentLocation,
            furiganaLengthBySegmentLocation: cache.furiganaLengthBySegmentLocation,
            isFuriganaVisible: true,
            isVisualEnhancementsEnabled: true,
            isColorAlternationEnabled: false,
            textSize: .constant(28),
            lineSpacing: 4,
            kerning: 0,
            furiganaGap: furiganaGap,
            evenSegmentColor: .label,
            oddSegmentColor: .label,
            isLineWrappingEnabled: true,
            isRubySpacingEnabled: true,
            selectedHighlightRange: nil,
            playbackHighlightRange: nil,
            selectionHighlightColor: .clear,
            playbackHighlightColor: .clear,
            unknownSegmentLocations: [],
            isHighlightUnknownEnabled: false,
            unknownSegmentColor: .label,
            debugFlags: KiokuDebugOverlayView.Flags(),
            illegalMergeLocation: nil,
            onSegmentTapped: { _, _, _ in onToggleExpansion() },
            isScrollEnabled: false
        )
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // Gist only — italicised so it reads as interpretation/voice rather than continuation
    // of the Japanese line. No label: position (directly below the original) carries the
    // semantic, and italic body text is the visual cue people already associate with
    // "translation/commentary on the thing above."
    @ViewBuilder
    private var gistSection: some View {
        if let gist = effectiveGist, gist.isEmpty == false {
            Text(gist)
                .font(.callout.italic())
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 4)
                .background(speakingBackground(isSpeaking(.translation)))
        }
    }

    // True when expanding this card would reveal anything — words to drill into or a
    // pattern note. Lines with neither don't show the toggle at all.
    private var hasExpandableDetail: Bool {
        effectiveWords.isEmpty == false || (effectiveGrammarNote?.isEmpty == false)
    }

    // Single per-line toggle for the drill-down detail (vocabulary + pattern note).
    // Hidden by default so a long song reads as a clean list of lines.
    private var expandableDetailToggle: some View {
        Button {
            onToggleExpansion()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .font(.footnote.weight(.semibold))
                Text(isExpanded ? "Hide explanations" : "Show explanations")
                    .font(.footnote.weight(.semibold))
                Spacer(minLength: 0)
            }
            .foregroundStyle(Color.accentColor)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isExpanded ? "Hide explanations" : "Show explanations")
    }

    // Words first, then the pattern note at the bottom (matching the user's preferred
    // ordering — vocab is the primary detail, the pattern is supplementary commentary).
    @ViewBuilder
    private var expandableDetailContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            if effectiveWords.isEmpty == false {
                wordsList
            }
            if let grammar = effectiveGrammarNote, grammar.isEmpty == false {
                patternNote(grammar)
            }
        }
        .padding(.top, 2)
    }

    // Word entries as a vertical list with surface, sungRomaji, and the LLM definition.
    // Iterates `effectiveWords` so chorus repeats display the referenced line's vocabulary.
    // Identifies rows by positional offset because a single line can repeat the same word
    // (chorus, refrain) and value-based identity would collide and break SwiftUI's diffing.
    private var wordsList: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(effectiveWords.enumerated()), id: \.offset) { _, word in
                wordEntryRow(word)
            }
        }
    }

    // Pattern-to-bank note (the prompt's "optional grammar pattern worth memorizing").
    // The body is stripped of inline-emphasis markers so `*foo*` / `**bar**` no longer
    // leak literal asterisks, and any leading `Pattern to bank [note]:` prefix the model
    // emitted is removed so the body doesn't repeat the section label above.
    private func patternNote(_ text: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Pattern to Bank")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(SongLineCard.stripInlineMarkdown(SongLineCard.strippingPatternToBankPrefix(text)))
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // Strips inline-emphasis markup so the user doesn't see literal asterisks in body
    // text. `**bold**` and `*italic*` markers are removed while the inner content stays.
    // Bold pass first so the italic pass doesn't try to chew up either half of a bold pair.
    // `nonisolated`: a pure string transform with no view state, also called from the
    // `nonisolated` SongListenScript — without this, View's implicit MainActor isolation
    // would make it callable only from the main actor.
    nonisolated static func stripInlineMarkdown(_ raw: String) -> String {
        var s = raw.replacingOccurrences(
            of: #"\*\*([^*\n]+?)\*\*"#,
            with: "$1",
            options: .regularExpression
        )
        s = s.replacingOccurrences(
            of: #"(?<!\*)\*([^*\n]+?)\*(?!\*)"#,
            with: "$1",
            options: .regularExpression
        )
        return s
    }

    // Strips any leading "Pattern to bank [note]:" prefix the model emitted, regardless of
    // case, bold wrapping, hyphenation, or the presence of the word "note". The label
    // above the body already says "Pattern to Bank" — repeating it inside is noise.
    //
    // Regex breakdown:
    //   ^                              start of string
    //   (?:\*{1,2})?                   optional `*` or `**`
    //   \s*Pattern[\s-]+to[\s-]+bank   "Pattern to bank" or "Pattern-to-bank"
    //   (?:\s+note)?                   optional " note"
    //   \s*(?:\*{1,2})?                optional closing `*` or `**`
    //   \s*:\s*                        the colon
    //   (?:\*{1,2})?\s*                optional asterisks after the colon (e.g. `: **`)
    static func strippingPatternToBankPrefix(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let pattern = #"^(?:\*{1,2})?\s*Pattern[\s-]+to[\s-]+bank(?:\s+note)?\s*(?:\*{1,2})?\s*:\s*(?:\*{1,2})?\s*"#
        if let range = trimmed.range(
            of: pattern,
            options: [.regularExpression, .caseInsensitive]
        ) {
            return String(trimmed[range.upperBound...])
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return trimmed
    }

    // Renders one word entry: surface (with furigana when available), LLM definition wrapped
    // beneath. Tapping the row opens the shared lookup sheet (via onWordTapped) so the
    // breakdown's vocabulary is a jumping-off point into the dictionary, like tapping a
    // segment in the read view.
    private func wordEntryRow(_ word: SongWord) -> some View {
        Button {
            onWordTapped(word)
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                wordHeadword(word)
                if word.definition.isEmpty == false {
                    // Strip inline-emphasis markers so `*foo*` / `**bar**` don't leak literal
                    // asterisks into the rendered definition.
                    Text(SongLineCard.stripInlineMarkdown(word.definition))
                        .font(.footnote)
                        .foregroundStyle(.primary.opacity(0.85))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 4)
            .background(speakingBackground(isSpeaking(word)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityHint("Look up \(word.surface)")
    }

    // A word-list headword: furigana over kanji runs when the stepper resolved a reading for
    // this surface, plain text otherwise (kana-only words, or a surface the resolver couldn't
    // align). Font is a fixed UIFont matching `.title3.weight(.semibold)` since FuriganaLabel
    // is a UIKit view and doesn't take a SwiftUI Font.
    @ViewBuilder
    private func wordHeadword(_ word: SongWord) -> some View {
        let key = WordFuriganaKey(lineIndex: effectiveWordsLineIndex, surface: word.surface)
        // `.fixedSize` forces SwiftUI to propose an unconstrained width, which routes
        // FuriganaLabel.sizeThatFits to its natural-width branch instead of the full row
        // width. Without it, the label reports the entire row as its size and its internal
        // .center paragraph alignment draws the headword centered in the row — inconsistent
        // with the plain-Text branch below, which already hugs its own natural width and sits
        // flush left.
        if let runReadings = wordFurigana[key], runReadings.isEmpty == false {
            FuriganaLabel(
                surface: word.surface,
                reading: "",
                font: .systemFont(ofSize: 20, weight: .semibold),
                gap: CGFloat(furiganaGap),
                explicitRunReadings: runReadings
            )
            .fixedSize(horizontal: true, vertical: false)
        } else {
            Text(word.surface)
                .font(.title3.weight(.semibold))
        }
    }
}
