import SwiftUI

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
    // Single per-line "expanded" flag controlling both the word/grammar explanations and
    // whether the Japanese row renders with furigana via `FuriganaTextRenderer`. The two
    // are bound on purpose: a user tapping either affordance opens (or closes) the same
    // detail surface, which keeps the gesture model consistent across the card.
    let isExpanded: Bool
    // Lazily-populated cache; nil before the first expansion for this line. Owned by the
    // parent stepper so cache compute happens once per line per session.
    let furiganaCache: LineFuriganaCache?
    // The audio time-range matched to this line via the cue text-keyed lookup, or nil
    // when there's no audio attached, no SRT, or no cue matched this line's text. Nil
    // hides the play button entirely — "if available" semantics on the play affordance.
    let playbackRange: (startMs: Int, endMs: Int)?
    let onToggleExpansion: () -> Void
    let onPlayLine: () -> Void

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
        .overlay(
            RoundedRectangle(cornerRadius: 18)
                .stroke(Color(.separator), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 18))
        .accessibilityElement(children: .contain)
    }

    // Position indicator + (when this is a chorus repeat) an inline reference annotation.
    // The annotation lives to the right of `Line N` rather than in a styled chip below it:
    // the relationship is metadata about the line, not its own content block. The user
    // sees "Same as line 1" and immediately reads this line's Japanese underneath.
    //
    // The trailing play button appears only when a cue range matched this line. Tapping
    // it seeks the audio to the line's start and auto-stops at its end via the
    // controller's `stopAtMs` watchdog.
    private var header: some View {
        HStack(spacing: 8) {
            Text("Line \(line.index)")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
            if let reference = line.reference {
                inlineReferenceLabel(reference)
            }
            Spacer(minLength: 0)
            if playbackRange != nil {
                playButton
            }
        }
    }

    // Small accent-coloured ▶︎ that triggers `onPlayLine`. Hidden entirely when there's no
    // matched range — no "disabled" greyed-out state, since the typical case is "no audio
    // at all for this note" and a row of disabled buttons would just be visual noise.
    private var playButton: some View {
        Button(action: onPlayLine) {
            Image(systemName: "play.circle.fill")
                .font(.system(size: 22))
                .foregroundStyle(Color.accentColor)
                .accessibilityLabel("Play line \(line.index)")
        }
        .buttonStyle(.plain)
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
        let hasGist = (line.gist?.isEmpty == false)
        let hasGrammar = (line.grammarNote?.isEmpty == false)
        return hasGist == false
            && hasGrammar == false
            && line.words.isEmpty
            && line.reference == nil
            && line.index > 1
    }

    // Big Japanese row. Tapping toggles furigana on/off for this line only. The two
    // branches share size/leading-alignment so toggling does not shift the surrounding
    // layout. The plain branch carries its own SwiftUI tap gesture; the renderer branch
    // routes taps through `onSegmentTapped` because a UIViewRepresentable wrapping
    // UITextView intercepts touches before SwiftUI sees them.
    @ViewBuilder
    private var originalLine: some View {
        if isExpanded, let cache = furiganaCache, cache.furiganaBySegmentLocation.isEmpty == false {
            furiganaRow(cache: cache)
                .accessibilityLabel(line.original)
                .accessibilityHint("Tap to hide furigana and explanations")
        } else {
            Text(line.original)
                .font(.system(size: 28, weight: .medium))
                .lineSpacing(4)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .onTapGesture { onToggleExpansion() }
                .accessibilityLabel(line.original)
                .accessibilityHint(furiganaLikelyAvailable ? "Tap to show furigana and explanations" : "Tap to show explanations")
        }
    }

    // Renders the line via FuriganaTextRenderer at the same 28pt size as the plain Text
    // branch. `isScrollEnabled` is false so the renderer's `sizeThatFits` reports a real
    // multi-line height to SwiftUI. Color alternation, highlights, and debug overlays are
    // all off — this is a passive reveal, not interactive read mode.
    private func furiganaRow(cache: LineFuriganaCache) -> some View {
        FuriganaTextRenderer(
            isActive: true,
            isOverlayFrozen: false,
            text: line.original,
            isLineWrappingEnabled: true,
            segmentationRanges: cache.segmentationRanges,
            selectedSegmentLocation: nil,
            blankSelectedSegmentLocation: nil,
            selectedHighlightRangeOverride: nil,
            playbackHighlightRangeOverride: nil,
            activePlaybackCueIndex: nil,
            illegalMergeBoundaryLocation: nil,
            furiganaBySegmentLocation: cache.furiganaBySegmentLocation,
            furiganaLengthBySegmentLocation: cache.furiganaLengthBySegmentLocation,
            isVisualEnhancementsEnabled: true,
            isRubySpacingEnabled: true,
            isColorAlternationEnabled: false,
            isHighlightUnknownEnabled: false,
            unknownSegmentLocations: [],
            changedSegmentLocations: [],
            changedReadingLocations: [],
            customEvenSegmentColorHex: "",
            customOddSegmentColorHex: "",
            debugFuriganaRects: false,
            debugHeadwordRects: false,
            debugHeadwordLineBands: false,
            debugFuriganaLineBands: false,
            debugBisectorHeadword: false,
            debugBisectorFurigana: false,
            debugEnvelopeRects: false,
            debugLeftInsetGuide: false,
            externalContentOffsetY: 0,
            onScrollOffsetYChanged: { _ in },
            onSegmentTapped: { _, _, _ in onToggleExpansion() },
            textSize: .constant(28),
            lineSpacing: 4,
            kerning: 0,
            furiganaGap: furiganaGap,
            textAlignment: .natural,
            isScrollEnabled: false
        )
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // Heuristic for the VoiceOver hint: suppress "Tap to show furigana" when the line
    // clearly has no kanji to annotate. A tight CJK Unified Ideographs check avoids
    // importing ScriptClassifier just for this string of accessibility text.
    private var furiganaLikelyAvailable: Bool {
        if let cache = furiganaCache {
            return cache.furiganaBySegmentLocation.isEmpty == false
        }
        return line.original.contains(where: { ch in
            ch.unicodeScalars.contains(where: { (0x4E00...0x9FFF).contains($0.value) })
        })
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
    fileprivate static func stripInlineMarkdown(_ raw: String) -> String {
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
    fileprivate static func strippingPatternToBankPrefix(_ raw: String) -> String {
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

    // Renders one word entry: surface and sungRomaji on the same baseline, LLM definition
    // wrapped beneath. Non-interactive in v1 — tap-to-lookup is a follow-up.
    private func wordEntryRow(_ word: SongWord) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(word.surface)
                    .font(.title3.weight(.semibold))
                if word.sungRomaji.isEmpty == false {
                    Text(word.sungRomaji)
                        .font(.footnote.italic())
                        .foregroundStyle(.secondary)
                }
            }
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
    }
}
