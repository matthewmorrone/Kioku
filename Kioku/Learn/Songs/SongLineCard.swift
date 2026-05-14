import SwiftUI

// One line of a song breakdown rendered as a card with progressive reveal.
// Tap the card body to advance the reveal stage. Layers from bottom to top:
//   stage 0: Japanese original line only
//   stage 1: + romaji
//   stage 2: + word entries
//   stage 3: + gist and grammar note
//
// Stages that have no content are skipped so a vocalization-only line (no romaji, no
// bullets, no gist) collapses to one tappable stage that shows the bracketed note.
//
// Repeated chorus lines render a prominent "= line N" or "Parallel to line N: X → Y"
// chip above the Japanese, plus the referenced line's content inline below so the
// user can recall the original without leaving the card.
struct SongLineCard: View {
    let line: SongLine
    let referencedLine: SongLine?
    let position: Int
    let total: Int
    let revealStage: Int
    let onAdvance: () -> Void

    var body: some View {
        // Card content scrolls vertically when a line's words + gist + grammar note
        // exceed the visible card height. Without the ScrollView, long entries (common
        // for chorus-heavy songs with rich word definitions) were clipped at the bottom
        // and the page-pager swallowed taps so users could not reach the missing content.
        ScrollView(.vertical, showsIndicators: true) {
            VStack(alignment: .leading, spacing: 16) {
                header
                referenceChipIfNeeded
                originalLine
                if revealStage >= romajiStage, let romaji = line.romaji {
                    romajiText(romaji)
                }
                if revealStage >= wordsStage, line.words.isEmpty == false {
                    wordsList
                }
                if revealStage >= gistStage {
                    gistAndGrammar
                }
                advancePrompt
                    .padding(.top, 4)
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .padding(20)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 18)
                .fill(Color(.secondarySystemBackground))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18)
                .stroke(Color(.separator), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 18))
        .contentShape(RoundedRectangle(cornerRadius: 18))
        // Tap fires on a quick touch; the ScrollView still owns drag gestures so vertical
        // scrolling and horizontal pager swipes both keep working.
        .onTapGesture {
            onAdvance()
        }
        .accessibilityElement(children: .contain)
        .accessibilityHint("Tap to reveal more")
    }

    // Position indicator. Sits above the Japanese so the user always knows where they are.
    private var header: some View {
        HStack(spacing: 8) {
            Text("Line \(line.index)")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
            Text("·")
                .foregroundStyle(.secondary)
            Text("\(position) / \(total)")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    // Repeat indicator chip for chorus lines. For sameAsLine, shows "Same as line N";
    // for parallelTo, shows "Parallel to line N · X → Y". The referenced line's Japanese
    // is shown directly below so the user doesn't have to navigate back.
    @ViewBuilder
    private var referenceChipIfNeeded: some View {
        if let reference = line.reference {
            VStack(alignment: .leading, spacing: 8) {
                referenceChipLabel(reference)
                if let referenced = referencedLine {
                    Text(referenced.original)
                        .font(.callout.italic())
                        .foregroundStyle(.secondary)
                }
            }
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color.accentColor.opacity(0.08))
            )
        }
    }

    // Builds the small accent-coloured label inside the reference chip; switches text based
    // on whether the reference is a pure repeat or a parallel with a substitution clause.
    private func referenceChipLabel(_ reference: LineReference) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "arrow.uturn.backward")
                .font(.footnote)
            switch reference {
            case .sameAsLine(let n):
                Text("Same as line \(n)")
                    .font(.footnote.weight(.semibold))
            case .parallelTo(line: let n, substitution: let sub):
                if sub.isEmpty {
                    Text("Parallel to line \(n)")
                        .font(.footnote.weight(.semibold))
                } else {
                    Text("Parallel to line \(n)  ·  \(sub)")
                        .font(.footnote.weight(.semibold))
                }
            }
        }
        .foregroundStyle(Color.accentColor)
    }

    private var originalLine: some View {
        Text(line.original)
            .font(.system(size: 28, weight: .medium))
            .lineSpacing(4)
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityLabel(line.original)
    }

    // Renders the romaji line in italic at a smaller size than the original so the eye still
    // anchors on the Japanese; size matters for users practising read-aloud.
    private func romajiText(_ romaji: String) -> some View {
        Text(romaji)
            .font(.title3.italic())
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    // Word entries as a vertical list with surface, sungRomaji, and the LLM definition.
    // Non-interactive in v1; a tap-to-lookup follow-up will wire each entry to the
    // existing dictionary lookup card.
    private var wordsList: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(line.words) { word in
                wordEntryRow(word)
            }
        }
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
                Text(word.definition)
                    .font(.footnote)
                    .foregroundStyle(.primary.opacity(0.85))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // Gist + optional grammar note. Grammar note is presented in italic with a margin so
    // it reads as commentary rather than a continuation of the gist.
    @ViewBuilder
    private var gistAndGrammar: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let gist = line.gist, gist.isEmpty == false {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("Gist")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text(gist)
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if let grammar = line.grammarNote, grammar.isEmpty == false {
                Text(grammar)
                    .font(.footnote.italic())
                    .foregroundStyle(.secondary)
                    .padding(.top, 2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // Affordance prompt at the bottom of the card. Hidden once the user has fully
    // revealed everything so the card stops nagging.
    @ViewBuilder
    private var advancePrompt: some View {
        if revealStage < line.revealStageCap {
            HStack(spacing: 6) {
                Image(systemName: "hand.tap")
                    .font(.footnote)
                Text(advanceHintText)
                    .font(.footnote)
            }
            .foregroundStyle(.tertiary)
            .frame(maxWidth: .infinity, alignment: .center)
        }
    }

    private var advanceHintText: String {
        switch revealStage {
        case 0 where line.romaji != nil: return "Tap to reveal romaji"
        case 0 where line.words.isEmpty == false: return "Tap to reveal words"
        case 0: return "Tap to reveal gist"
        case 1 where line.words.isEmpty == false: return "Tap to reveal words"
        case 1: return "Tap to reveal gist"
        default: return "Tap to reveal gist"
        }
    }

    // Stage indices that activate each layer. Computed so layers cleanly skip when a
    // line lacks content for that layer — e.g. a line with no words shifts gist from
    // stage 3 down to stage 2. The maximum cap lives on SongLine.revealStageCap so the
    // stepper and the card share one source of truth.
    private var romajiStage: Int { 1 }

    private var wordsStage: Int {
        line.romaji == nil ? 1 : 2
    }

    private var gistStage: Int {
        var stage = 1
        if line.romaji != nil { stage += 1 }
        if line.words.isEmpty == false { stage += 1 }
        return stage
    }
}
