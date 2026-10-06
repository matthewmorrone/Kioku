import SwiftUI
import UIKit

// Sing mode's row just under the lyrics popup's top bar: the Sing capsule, the Line / Song capsule
// while listening, and a short notice beside them (headphones advice, or why Sing couldn't start). The verdict colours themselves
// are drawn by the active-cue card (LyricsView.swift) through its Saved Highlight slots.
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
                romanize: singRomanize
            )
            guard singSession.isActive else { return }
            singSession.restoreAudioSource = previous
            onSetAudioSource(.instrumental)
        }
    }

    // The Stop summary: heard / graded counts and each missed word once, in song order.
    var singSummarySheet: some View {
        let words = segmentationRanges.map { NSRange($0, in: noteText) }
        let noteNS = noteText as NSString
        var seen = Set<String>()
        let missed: [SingMissedWord] = singMissedLocations.sorted().compactMap { location in
            guard let range = words.first(where: { location >= $0.location && location < NSMaxRange($0) }) else { return nil }
            let surface = noteNS.substring(with: NSRange(location: location, length: NSMaxRange(range) - location))
            return seen.insert(surface).inserted ? SingMissedWord(location: location, surface: surface) : nil
        }
        return SingSummaryView(
            heardCount: singHeardLocations.count,
            gradedCount: singSession.verdicts.count,
            missedWords: missed,
            onLookUp: { location in
                // The lookup sheet belongs to the Read view underneath; let this sheet go first.
                isShowingSingSummary = false
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { onSegmentTapped(location, nil, nil) }
            },
            onDone: { isShowingSingSummary = false }
        )
    }

    // An inactive row's text with Sing verdicts coloured in (green heard, red missed), or nil when
    // the row has no verdicts or its text can't be matched to the note.
    func singColoredText(forCueAt index: Int, text: String) -> AttributedString? {
        guard isShowingSingResults, index < highlightRanges.count, let cueRange = highlightRanges[index] else { return nil }
        let noteNS = noteText as NSString
        guard NSMaxRange(cueRange) <= noteNS.length, noteNS.substring(with: cueRange).hasPrefix(text) else { return nil }
        let textNS = text as NSString
        var attributed = AttributedString(text)
        var colored = false
        for range in segmentationRanges.map({ NSRange($0, in: noteText) }) {
            let start = max(range.location, cueRange.location), end = min(NSMaxRange(range), cueRange.location + textNS.length)
            guard end > start, let heard = singSession.verdicts[start],
                  let local = Range(NSRange(location: start - cueRange.location, length: end - start), in: text),
                  let attributedRange = Range(local, in: attributed) else { continue }
            attributed[attributedRange].foregroundColor = heard ? Color(Self.singHeardColor) : Color(Self.singMissedColor)
            colored = true
        }
        return colored ? attributed : nil
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
