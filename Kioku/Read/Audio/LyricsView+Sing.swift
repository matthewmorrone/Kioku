import SwiftUI
import UIKit

// Sing mode's row just under the lyrics popup's top bar: the Sing capsule, the options gear, the
// Line / Song capsule while listening, and a short notice beside them (headphones advice, or why
// Sing couldn't start). The verdict colours themselves are drawn by the active-cue card
// (LyricsView.swift) through its Saved Highlight slots; hidden words are masked here.
extension LyricsView {
    static let singHeardColor = UIColor.systemGreen
    static let singMissedColor = UIColor.systemRed

    // True while there are verdicts to show: during a session and after Stop, until Clear or
    // the next start.
    var isShowingSingResults: Bool { singSession.isActive || singSession.hasResults(for: noteText) }

    // Note locations of words Sing mode heard.
    var singHeardLocations: Set<Int> { Set(singSession.verdicts.filter { $0.value }.keys) }

    // Note locations of words Sing mode listened for and didn't hear.
    var singMissedLocations: Set<Int> { Set(singSession.verdicts.filter { $0.value == false }.keys) }

    @ViewBuilder
    var singControls: some View {
        Button {
            toggleSing()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: singSession.isActive ? "mic.fill" : "mic")
                    .scaledFont(size: 12, weight: .semibold)
                Text(singSession.isActive ? "Singing" : "Sing")
                    .scaledFont(size: 12, weight: .semibold)
                    .lineLimit(1)
            }
            .foregroundStyle(singSession.isActive ? Color(.systemRed) : Color.secondary)
            .padding(.horizontal, 12)
            .frame(height: 28)
            .background((singSession.isActive ? Color(.systemRed) : Color.secondary).opacity(0.16))
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(singSession.isActive ? "Stop singing" : "Sing along")

        Button {
            isShowingSingOptions = true
        } label: {
            Image(systemName: "slider.horizontal.3")
                .scaledFont(size: 12, weight: .semibold)
                .foregroundStyle(Color.secondary)
                .padding(.horizontal, 12)
                .frame(height: 28)
                .background(Color.secondary.opacity(0.16))
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Sing options")

        if singSession.isActive == false, singSession.hasResults(for: noteText) {
            Button {
                isShowingSingSummary = true
            } label: {
                Image(systemName: "list.bullet")
                    .scaledFont(size: 12, weight: .semibold)
                    .foregroundStyle(Color.secondary)
                    .padding(.horizontal, 12)
                    .frame(height: 28)
                    .background(Color.secondary.opacity(0.16))
                    .clipShape(Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Show Sing results")

            Button {
                singSession.clearResults()
            } label: {
                Image(systemName: "xmark")
                    .scaledFont(size: 12, weight: .semibold)
                    .foregroundStyle(Color.secondary)
                    .padding(.horizontal, 12)
                    .frame(height: 28)
                    .background(Color.secondary.opacity(0.16))
                    .clipShape(Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Clear Sing results")
        }

        if singSession.isActive {
            Button {
                singSession.scope = singSession.scope == .song ? .line : .song
            } label: {
                Image(systemName: singSession.scope == .line ? "repeat.1" : "repeat")
                    .scaledFont(size: 12, weight: .semibold)
                    .foregroundStyle(singSession.scope == .line ? Color.accentColor : Color.secondary)
                    .padding(.horizontal, 12)
                    .frame(height: 28)
                    .background((singSession.scope == .line ? Color.accentColor : Color.secondary).opacity(0.16))
                    .clipShape(Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(singSession.scope == .line ? "Looping this line. Tap to sing the whole song." : "Singing the whole song. Tap to loop this line.")
        }
    }

    // The row under the top bar: Sing's capsules, then a start-up problem or, for a few seconds,
    // the headphones advice. Hidden for notes without timing (nothing to grade against).
    @ViewBuilder
    var singRow: some View {
        if singRomanize != nil, cues.isEmpty == false, isReAligning == false {
            HStack(spacing: 8) {
                singControls
                if let message = singSession.statusMessage ?? (singSession.isShowingHeadphonesNotice ? "Headphones recommended: the speaker leaks into the mic." : nil) {
                    Text(message)
                        .scaledFont(size: 11)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .minimumScaleFactor(0.8)
                        .transition(.opacity)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 6)
        }
    }

    // Starts or stops listening. Starting switches playback to the instrumental and stopping puts
    // back whatever was playing before.
    private func toggleSing() {
        if singSession.isActive {
            if let previous = singSession.restoreAudioSource { onSetAudioSource(previous) }
            singSession.stop()
            controller.pause()
            saveSingSession()
            if singSession.verdicts.isEmpty == false { isShowingSingSummary = true }
            return
        }
        guard let singRomanize else { return }
        let segmentRanges = segmentationRanges.map { NSRange($0, in: noteText) }
        let previous = audioSource
        Task {
            await singSession.start(
                controller: controller,
                cues: cues,
                noteText: noteText,
                highlightRanges: highlightRanges,
                segmentRanges: segmentRanges,
                furigana: furiganaBySegmentLocation,
                furiganaLengths: furiganaLengthBySegmentLocation,
                strictness: SingStrictness(rawValue: singStrictnessRaw) ?? .normal,
                romanize: singRomanize
            )
            guard singSession.isActive else { return }
            singSession.restoreAudioSource = previous
            onSetAudioSource(.instrumental)
        }
    }

    // The Stop summary: heard / graded counts and each missed word once, in song order.
    var singSummarySheet: some View {
        SingSummaryView(
            heardCount: singHeardLocations.count,
            gradedCount: singSession.verdicts.count,
            strictness: singSession.strictness,
            missedWords: singMissedWords,
            history: noteID.map { SingHistoryStore.shared.sessions(for: $0) } ?? [],
            onLookUp: { location in
                // The lookup sheet belongs to the Read view underneath; let this sheet go first.
                isShowingSingSummary = false
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { onSegmentTapped(location, nil, nil) }
            },
            onDone: { isShowingSingSummary = false }
        )
    }

    // An inactive row's text with Sing applied: hidden words masked, graded words coloured
    // (green heard, red missed). Plain when Sing has nothing to show or the row's text can't be
    // matched to the note.
    func singInactiveText(forCueAt index: Int, text: String) -> AttributedString {
        guard isShowingSingResults, index < highlightRanges.count, let cueRange = highlightRanges[index] else { return AttributedString(text) }
        let noteNS = noteText as NSString
        guard NSMaxRange(cueRange) <= noteNS.length, noteNS.substring(with: cueRange).hasPrefix(text) else { return AttributedString(text) }
        let shown = singMasked(text, origin: cueRange.location)
        let length = (shown as NSString).length
        var attributed = AttributedString(shown)
        for range in segmentationRanges.map({ NSRange($0, in: noteText) }) {
            let start = max(range.location, cueRange.location), end = min(NSMaxRange(range), cueRange.location + length)
            guard end > start, let heard = singSession.verdicts[start],
                  let local = Range(NSRange(location: start - cueRange.location, length: end - start), in: shown),
                  let attributedRange = Range(local, in: attributed) else { continue }
            attributed[attributedRange].foregroundColor = heard ? Color(Self.singHeardColor) : Color(Self.singMissedColor)
        }
        return attributed
    }

    // The note ranges of the words the reveal option currently hides: every word Sing listens for
    // that isn't graded yet, or all of them until Stop with "Reveal at end".
    var singHiddenRanges: [NSRange] {
        let reveal = SingReveal(rawValue: singRevealRaw) ?? .show
        guard singSession.isActive, reveal != .show else { return [] }
        let words = segmentationRanges.map { NSRange($0, in: noteText) }
        return singSession.targetIDs.compactMap { id in
            guard reveal == .atEnd || singSession.verdicts[id] == nil,
                  let word = words.first(where: { NSLocationInRange(id, $0) }) else { return nil }
            return NSRange(location: id, length: NSMaxRange(word) - id)
        }
    }

    // `text`, which starts at note offset `origin`, with every hidden word replaced by 〇, one per
    // UTF-16 unit so offsets into it still line up with the note.
    func singMasked(_ text: String, origin: Int) -> String {
        let hidden = singHiddenRanges
        guard hidden.isEmpty == false else { return text }
        let masked = NSMutableString(string: text)
        for range in hidden {
            let start = max(range.location, origin), end = min(NSMaxRange(range), origin + masked.length)
            guard end > start else { continue }
            masked.replaceCharacters(in: NSRange(location: start - origin, length: end - start), with: String(repeating: "〇", count: end - start))
        }
        return masked as String
    }

    // The active card's render input with hidden words masked and their furigana dropped, so
    // neither spelling nor reading gives them away.
    func singMasked(_ input: ActiveCueRenderInput, origin: Int) -> ActiveCueRenderInput {
        let hidden = singHiddenRanges
        guard hidden.isEmpty == false else { return input }
        let isHidden: (Int) -> Bool = { local in hidden.contains { NSLocationInRange(origin + local, $0) } }
        let text = singMasked(input.text, origin: origin)
        // Segment ranges are String.Index ranges into the original text; rebuild them on the masked one.
        let segments = input.segmentationRanges.compactMap { Range(NSRange($0, in: input.text), in: text) }
        return ActiveCueRenderInput(
            text: text,
            furiganaBySegmentLocation: input.furiganaBySegmentLocation.filter { isHidden($0.key) == false },
            furiganaLengthBySegmentLocation: input.furiganaLengthBySegmentLocation.filter { isHidden($0.key) == false },
            segmentationRanges: segments
        )
    }

    // Missed words in song order, one per distinct surface, for the summary and the history.
    private var singMissedWords: [SingMissedWord] {
        let words = segmentationRanges.map { NSRange($0, in: noteText) }
        let noteNS = noteText as NSString
        var seen = Set<String>()
        return singMissedLocations.sorted().compactMap { location in
            guard let range = words.first(where: { location >= $0.location && location < NSMaxRange($0) }) else { return nil }
            let surface = noteNS.substring(with: NSRange(location: location, length: NSMaxRange(range) - location))
            return seen.insert(surface).inserted ? SingMissedWord(location: location, surface: surface) : nil
        }
    }

    // Records the session that just stopped in the song's Sing history.
    private func saveSingSession() {
        guard let noteID, singSession.verdicts.isEmpty == false else { return }
        SingHistoryStore.shared.append(SingSessionRecord(
            noteID: noteID,
            date: singSession.startedAt ?? Date(),
            scope: singSession.scope.rawValue,
            strictness: singSession.strictness,
            heardCount: singHeardLocations.count,
            gradedCount: singSession.verdicts.count,
            missedSurfaces: singMissedWords.map(\.surface)
        ))
    }

    // The options sheet: reveal and strictness, kept across sessions. Strictness is fixed while
    // a session runs so its words are all graded the same way.
    var singOptionsSheet: some View {
        SingOptionsView(
            reveal: Binding(get: { SingReveal(rawValue: singRevealRaw) ?? .show }, set: { singRevealRaw = $0.rawValue }),
            strictness: Binding(get: { SingStrictness(rawValue: singStrictnessRaw) ?? .normal }, set: { singStrictnessRaw = $0.rawValue }),
            isStrictnessLocked: singSession.isActive,
            onDone: { isShowingSingOptions = false }
        )
    }

    // While singing: under the active card, what the model heard for each graded word of the line
    // it graded last (green heard, red missed, "–" when it heard nothing).
    @ViewBuilder
    var singHeardPanel: some View {
        if singSession.isActive, let heardLine = singHeardLine {
            Text(heardLine)
                .scaledFont(size: 13)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .frame(maxWidth: .infinity)
        }
    }

    // The heard kana of the last graded word's line, one run per word, coloured by verdict.
    private var singHeardLine: AttributedString? {
        guard let last = singSession.lastGradedID,
              let cueRange = highlightRanges.compactMap({ $0 }).first(where: { NSLocationInRange(last, $0) }) else { return nil }
        let ids = singSession.heard.keys.filter { NSLocationInRange($0, cueRange) }.sorted()
        var line = AttributedString()
        for (i, id) in ids.enumerated() {
            if i > 0 { line += AttributedString(" ") }
            let kana = singSession.heard[id].flatMap { $0.isEmpty ? nil : $0 } ?? "–"
            var run = AttributedString(kana)
            run.foregroundColor = singSession.verdicts[id] == true ? Color(Self.singHeardColor) : Color(Self.singMissedColor)
            line += run
        }
        return ids.isEmpty ? nil : line
    }

    // The active card's highlight range, cue-local. While singing, the band steps mora by mora
    // straight from the cue's karaoke checkpoints (whatever the Line / Word setting), so the singer
    // can follow each syllable; otherwise it's the usual granularity-driven range.
    func activeCardHighlightRange(cueIndex: Int, cueOriginInNote: Int, cueLength: Int) -> NSRange? {
        guard singSession.isActive else {
            return cueLocalPlaybackHighlightRange(cueOriginInNote: cueOriginInNote, cueLength: cueLength)
        }
        guard controller.isPlaying, cueIndex == activeIndex, cueIndex < cues.count else { return nil }
        let now = controller.currentTimeMs
        guard let current = cues[cueIndex].checkpoints
            .filter({ $0.timeMs <= now })
            .max(by: { $0.timeMs < $1.timeMs }) else { return nil }
        let start = min(max(0, current.charOffsetInCue), cueLength)
        let end = min(start + max(1, current.charLength), cueLength)
        return end > start ? NSRange(location: start, length: end - start) : nil
    }
}
