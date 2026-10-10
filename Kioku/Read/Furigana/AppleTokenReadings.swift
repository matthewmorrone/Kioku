import Foundation

// Apple's own reading of each word in a text, from the system Japanese tokenizer
// (CFStringTokenizer's Latin transcription, turned back into hiragana), which reads a word in its
// context: 時 after a number as じ, 中 after a noun as ちゅう. FuriganaResolver takes it only for
// readings JMdict tags as a suffix or counter (SurfaceReadingData.suffixOrCounterReadings), because
// elsewhere it misreads common words (私 is always わたくし). On device, no network, no model of ours.
nonisolated enum AppleTokenReadings {
    // Each token's single kanji run, keyed by the run's UTF-16 location: its UTF-16 length and the
    // hiragana reading of just the run (the token's reading less its kana before and after).
    static func runReadings(in text: String) -> [Int: (length: Int, reading: String)] {
        let string = text as CFString
        let length = CFStringGetLength(string)
        guard length > 0 else { return [:] }
        let tokenizer = CFStringTokenizerCreate(
            nil, string, CFRangeMake(0, length), kCFStringTokenizerUnitWord, Locale(identifier: "ja") as CFLocale
        )
        let nsText = text as NSString
        var readings: [Int: (length: Int, reading: String)] = [:]
        var tokenType = CFStringTokenizerAdvanceToNextToken(tokenizer)
        while tokenType != [] {
            let range = CFStringTokenizerGetCurrentTokenRange(tokenizer)
            if let latin = CFStringTokenizerCopyCurrentTokenAttribute(tokenizer, kCFStringTokenizerAttributeLatinTranscription) as? String {
                let token = nsText.substring(with: NSRange(location: range.location, length: range.length))
                if let run = kanjiRunReading(token: token, reading: hiragana(latin)) {
                    readings[range.location + run.offset] = (run.length, run.reading)
                }
            }
            tokenType = CFStringTokenizerAdvanceToNextToken(tokenizer)
        }
        return readings
    }

    // Hiragana for the tokenizer's Latin transcription, by the system transform.
    private static func hiragana(_ latin: String) -> String {
        let text = NSMutableString(string: latin)
        CFStringTransform(text, nil, kCFStringTransformLatinHiragana, false)
        return text as String
    }

    // The reading of a token's one kanji run, with its UTF-16 offset and length in the token; nil
    // when the token has no kanji, more than one run, or a reading whose kana don't match the token's.
    private static func kanjiRunReading(token: String, reading: String) -> (offset: Int, length: Int, reading: String)? {
        let runs = FuriganaAttributedString.kanjiRuns(in: token)
        guard runs.count == 1 else { return nil }
        let characters = Array(token)
        let before = KanaNormalizer.katakanaToHiragana(String(characters[..<runs[0].start]))
        let after = KanaNormalizer.katakanaToHiragana(String(characters[runs[0].end...]))
        let hiraganaReading = KanaNormalizer.katakanaToHiragana(reading)
        guard hiraganaReading.hasPrefix(before), hiraganaReading.hasSuffix(after),
              hiraganaReading.count > before.count + after.count else { return nil }
        let runReading = String(hiraganaReading.dropFirst(before.count).dropLast(after.count))
        let offset = String(characters[..<runs[0].start]).utf16.count
        let runLength = String(characters[runs[0].start..<runs[0].end]).utf16.count
        return (offset, runLength, runReading)
    }
}
