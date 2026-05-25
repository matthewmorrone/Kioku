import Foundation

// Source-of-truth for what bundled datasets and third-party libraries appear in
// the About screen. Data is hand-curated to mirror Resources/data_manifest.json
// and Packages/, with human-readable descriptions and license / URL strings the
// view can render flat.
//
// Kept separate from AboutView so it's unit-testable — see AttributionsTests
// for the regression guard that catches accidental removals.
nonisolated enum Attributions {

    // One bundled or referenced data resource (dictionary, frequency list,
    // sentence corpus, etc.) with the attribution string we owe its authors.
    struct Dataset: Equatable {
        let name: String
        let description: String
        let license: String
        let sourceURL: String
    }

    // One third-party Swift library linked via SPM.
    struct Library: Equatable {
        let name: String
        let purpose: String
        let sourceURL: String
    }

    // Bundled / referenced datasets. Order is roughly "most user-visible first":
    // the dictionary, then frequency, then sentence + kanji metadata, then
    // specialty data (pitch, radicals, handwriting).
    static let datasets: [Dataset] = [
        Dataset(
            name: "JMdict (English)",
            description: "Japanese–English dictionary, the project's core lexicon.",
            license: "Electronic Dictionary Research and Development Group — CC BY-SA 4.0",
            sourceURL: "https://github.com/scriptin/jmdict-simplified"
        ),
        Dataset(
            name: "KANJIDIC2",
            description: "Kanji metadata: readings, meanings, stroke counts, JLPT levels.",
            license: "EDRDG — CC BY-SA 4.0",
            sourceURL: "https://github.com/scriptin/jmdict-simplified"
        ),
        Dataset(
            name: "Tatoeba Sentence Pairs",
            description: "Bilingual Japanese–English example sentences.",
            license: "CC BY 2.0 FR",
            sourceURL: "https://tatoeba.org"
        ),
        Dataset(
            name: "JPDB Frequency (v2.2)",
            description: "Word-frequency rankings for difficulty grading and ranking.",
            license: "Per Kuuuube/yomitan-dictionaries permalink release",
            sourceURL: "https://github.com/Kuuuube/yomitan-dictionaries"
        ),
        Dataset(
            name: "wordfreq",
            description: "Zipf frequency scores used as a fallback frequency signal.",
            license: "MIT (rspeer/wordfreq)",
            sourceURL: "https://github.com/rspeer/wordfreq"
        ),
        Dataset(
            name: "UniDic Pitch Accent",
            description: "Mora-level pitch-accent annotations derived from UniDic's kana-accent lexicon.",
            license: "BSD / GPL / LGPL (triple-licensed) — National Institute for Japanese Language and Linguistics",
            sourceURL: "https://clrd.ninjal.ac.jp/unidic/"
        ),
        Dataset(
            name: "RADKFILE2 / KRADFILE2",
            description: "Radical ↔ kanji indices powering the multi-radical kanji search.",
            license: "EDRDG — CC BY-SA 4.0",
            sourceURL: "https://www.edrdg.org/wiki/index.php/KRADFILE-KRADFILE2"
        ),
        Dataset(
            name: "Tegaki-Zinnia (Japanese)",
            description: "Handwriting recognition model used for kanji handwriting input.",
            license: "BSD-style (Tegaki / Zinnia project)",
            sourceURL: "https://github.com/tegaki/tegaki"
        ),
    ]

    // Third-party Swift libraries linked via SPM. Mirrors docs/libraries.md
    // "Installed Libraries" section.
    static let libraries: [Library] = [
        Library(
            name: "SwiftWhisper",
            purpose: "On-device Whisper transcription for audio alignment.",
            sourceURL: "https://github.com/exPHAT/SwiftWhisper"
        ),
        Library(
            name: "USearch",
            purpose: "Vector similarity search for semantic lookup.",
            sourceURL: "https://github.com/unum-cloud/USearch"
        ),
        Library(
            name: "SwiftLCS",
            purpose: "Longest-common-subsequence diff for LLM correction reconciliation.",
            sourceURL: "https://github.com/Frugghi/SwiftLCS"
        ),
        Library(
            name: "swift-subtitle-kit",
            purpose: "SRT parsing and resync for the read screen.",
            sourceURL: "https://github.com/dioKaratzas/swift-subtitle-kit"
        ),
        Library(
            name: "SwiftSubtitles",
            purpose: "Broader subtitle-format support complementing swift-subtitle-kit.",
            sourceURL: "https://github.com/dagronf/SwiftSubtitles"
        ),
        Library(
            name: "CodableCSV",
            purpose: "Codable-compatible CSV encoding/decoding for word import/export.",
            sourceURL: "https://github.com/dehesa/CodableCSV"
        ),
        Library(
            name: "swift-audio-marker",
            purpose: "Per-word timing-marker model for Whisper output.",
            sourceURL: "https://github.com/atelier-socle/swift-audio-marker"
        ),
        Library(
            name: "TextFormation",
            purpose: "Text-editing helpers used in the note editor.",
            sourceURL: "https://github.com/ChimeHQ/TextFormation"
        ),
        Library(
            name: "zinnia-swift",
            purpose: "Swift bindings for the Zinnia handwriting recognition engine.",
            sourceURL: "https://github.com/sasakure-uk/zinnia-swift"
        ),
    ]

    // Bundle short version + build for the About header. Falls back to a
    // sentinel so the UI never shows a blank version line in odd build configs.
    static func versionString(bundle: Bundle = .main) -> String {
        let short = bundle.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
        let build = bundle.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        return "\(short) (\(build))"
    }
}
