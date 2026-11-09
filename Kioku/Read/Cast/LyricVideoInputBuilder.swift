import CryptoKit
import Foundation

// Builds a LyricVideoInput from the song ReadView has loaded: the same word list, breakdown joins,
// meanings and filters the word-by-word view uses, so the video matches the phone.
enum LyricVideoInputBuilder {
    // Nil when the song has no lyrics words to draw.
    static func make(
        cues: [SubtitleCue],
        highlightRanges: [NSRange?],
        noteText: String,
        segmentationRanges: [Range<String.Index>],
        furiganaBySegmentLocation: [Int: String],
        furiganaLengthBySegmentLocation: [Int: Int],
        noteID: UUID?,
        breakdownStore: SongBreakdownStore,
        dictionaryGloss: ((Int, String) -> String?)?,
        isParticle: ((Int, String) -> Bool)?,
        isLoanword: ((String) -> Bool)?,
        audioURL: URL,
        durationSeconds: TimeInterval
    ) -> LyricVideoInput? {
        let placement = noteID.flatMap { breakdownStore.placement(forNoteID: $0, noteText: noteText) }
        let words = WordFocusWordBuilder.words(
            cues: cues,
            highlightRanges: highlightRanges,
            noteText: noteText,
            segmentationRanges: segmentationRanges,
            furiganaBySegmentLocation: furiganaBySegmentLocation,
            furiganaLengthBySegmentLocation: furiganaLengthBySegmentLocation,
            wordRanges: placement?.lines.flatMap { $0.words.map(\.range) } ?? []
        )
        guard words.isEmpty == false else { return nil }
        let defaults = UserDefaults.standard
        // Reads a stored toggle, falling back to its default when never set.
        func flag(_ key: String, _ fallback: Bool) -> Bool { defaults.object(forKey: key) as? Bool ?? fallback }
        let showsFurigana = flag(LyricsPopupSettings.showFuriganaKey, LyricsPopupSettings.defaultShowFurigana)
        let showsMeanings = flag(LyricsPopupSettings.showBubblesKey, LyricsPopupSettings.defaultShowBubbles)
        let filter = LyricWordMeaningFilter(
            showsParticles: flag(BreakdownListenSettings.showParticlesKey, BreakdownListenSettings.defaultShowParticles),
            showsKatakana: flag(BreakdownListenSettings.showKatakanaKey, BreakdownListenSettings.defaultShowKatakana),
            showsVocalizations: flag(BreakdownListenSettings.showVocalizationsKey, BreakdownListenSettings.defaultShowVocalizations),
            showsLoanwords: flag(LyricsPopupSettings.showLoanwordBubblesKey, LyricsPopupSettings.defaultShowLoanwordBubbles),
            isParticle: isParticle,
            isLoanword: isLoanword
        )
        var glosses: [Int: String] = [:]
        for word in words where word.interludeDurationMs == nil {
            glosses[word.id] = WordFocusGlossResolver.gloss(for: word, placement: placement, filter: filter, dictionaryGloss: dictionaryGloss)
        }
        // Everything drawn in the video, hashed: words, timings, meanings, toggles and the audio file.
        var signature = "\(showsFurigana)|\(showsMeanings)|\(audioURL.lastPathComponent)|\(Int(durationSeconds * 1000))"
        for word in words {
            let pieces = word.pieces.map { "\($0.base)/\($0.ruby ?? "")" }.joined(separator: ",")
            signature += "|\(word.id):\(word.startMs):\(word.lineIndex):\(pieces):\(glosses[word.id] ?? "")"
        }
        let digest = SHA256.hash(data: Data(signature.utf8)).map { String(format: "%02x", $0) }.joined().prefix(16)
        return LyricVideoInput(
            noteID: noteID,
            audioURL: audioURL,
            durationMs: Int(durationSeconds * 1000),
            words: words,
            glosses: glosses,
            showsFurigana: showsFurigana,
            showsMeanings: showsMeanings,
            cacheKey: String(digest)
        )
    }
}
