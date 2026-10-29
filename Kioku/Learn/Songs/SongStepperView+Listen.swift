import Foundation
import SwiftUI

// Listen-along for SongStepperView: playing a breakdown's script live through
// SongLiveListenController and mapping its published state back onto the cards so the line —
// and the exact clip / sentence / gist / word row — being spoken is highlighted in place. The
// toolbar headphones button plays every line in sequence; each card's play button plays just
// that line's stretch. Split out of SongStepperView to keep the view file within bounds; the
// state it drives lives on the view (internal for that reason).
extension SongStepperView {

    // What the toolbar button shows — see SongListenControlState.
    var listenControlState: SongListenControlState {
        if liveListen.isPlaying { return .playing }
        if liveListen.lastError != nil { return .failed }
        return .idle
    }

    // What a card's audio button shows: play, or pause while this line is the one speaking.
    // Nil (hidden) while there's no breakdown to narrate.
    func cardPlayState(for line: SongLine) -> SongLineCardPlayState? {
        guard hasBreakdown, isStreamingCards == false else { return nil }
        if liveListen.isPlaying, liveListen.currentSegment?.lineIndex == line.index { return .playing }
        return .idle
    }

    // The segment the controller is speaking — or, while paused, the one it stopped on. That
    // highlight is how the place is kept: resuming restarts from the start of this segment
    // (re-saying a word is fine) rather than mid-utterance.
    var activeListenSegment: SongListenSegment? {
        liveListen.currentSegment
    }

    // Fractional progress (0...1) through the currently-active `.sentence` segment — used by
    // SongLineCard to estimate which of the Read tab's segmented words is being spoken right
    // now. Driven by AVSpeechSynthesizer's live per-character callback (see
    // SongLiveListenController.handleWillSpeak), not an interpolated guess.
    var listenSentenceProgress: Double? {
        liveListen.sentenceProgress
    }

    // While a line's sung clip plays, the UTF-16 offset in that line of the character being sung,
    // from the line's alignment (SongLiveListenController.sungLineOffset) — what lets SongLineCard
    // light each word as it's sung, not just as the synthesized voice reads it.
    var listenSungOffset: Int? {
        liveListen.sungLineOffset
    }

    // Toolbar headphones: play the whole song in sequence — the song's own intro first when
    // starting from the top, then every line, then the outro — resuming from wherever it last
    // stopped.
    func playAllListen() {
        if liveListen.currentSegment == nil, hasIntro {
            playIntro()
            return
        }
        isListening = true
        configureLiveListen()
        liveListen.play()
    }

    // A random breakdown opens playing: the whole song from the top, as the toolbar's play-all
    // would from a fresh start. Nothing to play before the breakdown exists.
    func startAutoplay() {
        guard displayItems.isEmpty == false else { return }
        currentPlaybackStep = .intro
        playAllListen()
    }

    // A card's play button: play just this line's clip + narration.
    func playListen(line: SongLine) {
        isListening = true
        configureLiveListen()
        liveListen.playLine(line.index)
    }

    // The mini player's play on a line: that line only when lines pause at their end, else on
    // through the rest of the song from it.
    func playListenFromMiniPlayer(line: SongLine) {
        guard pauseAfterEachLine == false else {
            playListen(line: line)
            return
        }
        isListening = true
        configureLiveListen()
        liveListen.play(fromLine: line.index)
    }

    // Card tap while its line is speaking, or the toolbar pause.
    func pauseListen() {
        liveListen.pause()
    }

    // Retries after a voice-unavailable / session-activation failure.
    func retryListenRender() {
        configureLiveListen()
        liveListen.play()
    }

    // Tears listen-along down (view disappearing, or a regenerate replacing the lines the
    // script narrates): stops playback, rewinds, and releases the audio session.
    func stopListening() {
        liveListen.stop()
        isListening = false
    }

    // Loads (or reloads, if the breakdown/clip inputs changed) the current breakdown's script
    // into the controller. Safe to call on every play/pause tap, or speculatively before one —
    // SongLiveListenController no-ops when the script and source are unchanged from what it
    // already has, and does its expensive one-time setup (opening the note's audio file,
    // resolving voices) in the background rather than on this call. SongStepperView also calls
    // this from `.onAppear`/once `noteCues` loads, well before any tap, so that background
    // work has already finished by the time the user actually presses play.
    func configureLiveListen() {
        guard let breakdown = cachedBreakdown else { return }
        let ranges = effectiveListenLineRanges
        // Word snippets are cut from the same cues the line clips come from, so they exist only
        // when line clips do.
        let lineCues = ranges.isEmpty ? [:] : SongLineCueMatcher.matchedCues(lines: currentLines, cues: noteCues)
        let steps = SongListenScript.build(
            from: breakdown,
            lineRanges: ranges,
            lineCues: lineCues,
            wordRepeatCount: wordRepeatCount,
            repeatEarlierWords: repeatEarlierWords,
            visibility: wordVisibility,
            walksWords: { lineIndex in
                // Listen-along opens cards itself, so a line it already expanded counts by how
                // it stood before it got there.
                let wasExpanded = self.expansionBeforeListen[lineIndex] ?? self.expandedByLineIndex.contains(lineIndex)
                return self.wordWalk.walksWords(lineIsExpanded: wasExpanded)
            },
            outro: ranges.isEmpty ? nil : trailingInstrumentalRange(after: ranges)
        )
        let originalByIndex = Dictionary(breakdown.lines.map { ($0.index, $0.original) }, uniquingKeysWith: { first, _ in first })
        liveListen.pauseAfterEachLine = pauseAfterEachLine
        liveListen.nowPlayingTitle = note.resolvedTitle
        liveListen.configure(steps: steps, sourceAudioURL: listenSourceAudioURL, originalByLineIndex: originalByIndex, lineCues: lineCues)
    }

    // The stretch of music after the last sung line: from where that line's clip ends to the end of
    // the final cue, when every cue in between is an instrumental marker (♪). Nil when the song ends
    // on its last line or something sung follows.
    func trailingInstrumentalRange(after ranges: [Int: (startMs: Int, endMs: Int)]) -> (startMs: Int, endMs: Int)? {
        guard let lastEnd = ranges.values.map(\.endMs).max() else { return nil }
        let tail = noteCues.filter { $0.startMs >= lastEnd }
        guard let start = tail.map(\.startMs).min(), let end = tail.map(\.endMs).max() else { return nil }
        let isMusicOnly = tail.allSatisfy { $0.text.trimmingCharacters(in: CharacterSet(charactersIn: "♪♫ \n")).isEmpty }
        return isMusicOnly ? (start, end) : nil
    }

    // The options menu's word/line visibility choices, as the one value both the cards and
    // listen-along filter by.
    var wordVisibility: SongWordVisibility {
        SongWordVisibility(
            showsParticles: showParticles,
            showsKatakana: showKatakana,
            showsVocalizations: showVocalizations,
            showsPatterns: showPatterns
        )
    }

    // Each line's words as its card shows them: the same list listen-along speaks (visibility
    // options applied, "= line N" repeats borrowing their target's words), minus those covered
    // earlier in the song (SongCoveredWords) when "Show Repeated Words" is off. Built from
    // every line parsed so far, so a word counts as covered even when it came on a hidden line.
    func visibleWordsByLine(for lines: [SongLine]) -> [Int: [SongWord]] {
        let linesByIndex = Dictionary(lines.map { ($0.index, $0) }, uniquingKeysWith: { first, _ in first })
        let words: (SongLine) -> [SongWord] = {
            SongListenScript.effectiveWords(for: $0, linesByIndex: linesByIndex, visibility: self.wordVisibility)
        }
        if repeatEarlierWords == false {
            return SongCoveredWords.uncoveredWords(in: lines, words: words)
        }
        return Dictionary(lines.map { ($0.index, words($0)) }, uniquingKeysWith: { first, _ in first })
    }

    // The clip ranges to actually splice in — none without an audio file.
    private var effectiveListenLineRanges: [Int: (startMs: Int, endMs: Int)] {
        listenSourceAudioURL != nil ? lineRangesByIndex : [:]
    }

    // The note's own audio file, spliced in before each line when its cue range is known.
    var listenSourceAudioURL: URL? {
        note.audioAttachmentID.flatMap { NotesAudioStore.shared.audioURL(for: $0) }
    }
}
