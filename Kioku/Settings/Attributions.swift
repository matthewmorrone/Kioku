import Foundation

// Source-of-truth for what bundled datasets and third-party libraries appear in
// the About screen. Data is hand-curated to mirror Resources/data-manifest.json's
// license fields and Package.resolved, with human-readable descriptions and license / URL strings the
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
        // Bundled .txt (name without extension, under Kioku/Settings/Licenses) holding the full
        // license text, for licenses that require the text itself to ship with the app.
        var licenseTextFile: String? = nil
    }

    // One third-party Swift library linked via SPM.
    struct Library: Equatable {
        let name: String
        let purpose: String
        let license: String
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
            description: "Bilingual Japanese–English example sentences; its word-split Japanese index also trains the segmenter's word-transition costs.",
            license: "CC BY 2.0 FR",
            sourceURL: "https://tatoeba.org"
        ),
        Dataset(
            name: "Jiten Frequency List",
            description: "Word-frequency rankings from anime, drama, film, novels and visual novels, for difficulty grading and ranking.",
            license: "Jiten — CC BY-SA 4.0",
            sourceURL: "https://jiten.moe"
        ),
        Dataset(
            name: "wordfreq",
            description: "Zipf frequency scores used as a fallback frequency signal.",
            license: "Robyn Speer — Apache-2.0 (code), CC BY-SA 4.0 (data)",
            sourceURL: "https://github.com/rspeer/wordfreq"
        ),
        Dataset(
            name: "UniDic Pitch Accent",
            description: "Mora-level pitch-accent annotations derived from UniDic's kana-accent lexicon.",
            license: "The UniDic Consortium — used under BSD-3-Clause (also offered under GPL or LGPL)",
            sourceURL: "https://clrd.ninjal.ac.jp/unidic/",
            licenseTextFile: "UniDic-BSD"
        ),
        Dataset(
            name: "RADKFILE2 / KRADFILE2",
            description: "Radical ↔ kanji indices powering the multi-radical kanji search.",
            license: "EDRDG — CC BY-SA 4.0",
            sourceURL: "https://www.edrdg.org/wiki/index.php/KRADFILE-KRADFILE2"
        ),
        Dataset(
            name: "KanjiVG",
            description: "Kanji stroke-order paths driving the stroke-order animation in kanji detail.",
            license: "Ulrich Apel / KanjiVG — CC BY-SA 3.0",
            sourceURL: "https://kanjivg.tagaini.net"
        ),
        Dataset(
            name: "Tegaki-Zinnia (Japanese)",
            description: "Handwriting recognition model used for kanji handwriting input.",
            license: "Tegaki project — LGPL 2.1",
            sourceURL: "https://github.com/tegaki/tegaki",
            licenseTextFile: "LGPL-2.1"
        ),
        Dataset(
            name: "JLPT Vocabulary Lists",
            description: "Per-word JLPT level estimates.",
            license: "Jonathan Waller (tanos.co.uk) — CC BY; CSV mirror by Bluskyo, MIT",
            sourceURL: "https://www.tanos.co.uk/jlpt/"
        ),
        Dataset(
            name: "OpenCC Japanese Shinjitai Table",
            description: "Modern ↔ old-form kanji correspondences, so prewar spellings find their entries.",
            license: "BYVoid/OpenCC — Apache-2.0",
            sourceURL: "https://github.com/BYVoid/OpenCC"
        ),
        Dataset(
            name: "キャラメルと飴玉 (sample note)",
            description: "夢野久作's 1922 story and its reading, attached to the sample note. Text from Aozora Bunko.",
            license: "Text and LibriVox recording — public domain",
            sourceURL: "https://archive.org/details/multilingual_shorts_008_1306"
        ),
        Dataset(
            name: "さくら さくら (sample note recording)",
            description: "The sung recording attached to the sample note. Song and lyrics are traditional and in the public domain.",
            license: "Kanohara, Wikimedia Commons — CC BY-SA 3.0",
            sourceURL: "https://commons.wikimedia.org/wiki/File:Sakura_Sakura.song.ogg"
        ),
    ]

    // Speech models the app downloads on first use (lyric alignment and vocal isolation). Listed
    // with their licenses because they ship to the device even though they aren't bundled.
    static let models: [Dataset] = [
        Dataset(
            name: "Japanese HuBERT Phoneme Aligner",
            description: "Aligns lyrics to a song's vocals (HuBERT + CTC over Japanese phonemes), converted to CoreML.",
            license: "prj-beatrice, rinna — Apache-2.0; trained on ReazonSpeech",
            sourceURL: "https://huggingface.co/prj-beatrice/japanese-hubert-base-phoneme-ctc-v4"
        ),
        Dataset(
            name: "HTDemucs",
            description: "Separates a song's vocals from its instrumental, converted to CoreML.",
            license: "Meta — MIT",
            sourceURL: "https://github.com/facebookresearch/demucs"
        ),
    ]

    // Third-party Swift libraries actually linked into the app. Mirrors
    // docs/libraries.md "Installed Libraries" — entries here MUST have a real
    // SPM pin in Package.resolved. Do not list aspirational deps.
    static let libraries: [Library] = debugOnlyLibraries + [
        Library(
            name: "zinnia-swift",
            purpose: "Swift bindings for the Zinnia handwriting recognition engine, which it vendors.",
            license: "shinjukunian — MIT; Zinnia engine by Taku Kudo — BSD",
            sourceURL: "https://github.com/shinjukunian/zinnia-swift"
        ),
    ]

    // Libraries linked only into Debug builds' code (Release compiles out every use, so the
    // linker leaves them out of the shipped app).
    #if DEBUG
    private static let debugOnlyLibraries: [Library] = [
        Library(
            name: "dagre-swift",
            purpose: "Graph layout for the word detail screen's Paths diagram (debug builds only).",
            license: "lukilabs — MIT",
            sourceURL: "https://github.com/lukilabs/dagre-swift"
        ),
    ]
    #else
    private static let debugOnlyLibraries: [Library] = []
    #endif

    // Bundle short version + build for the About header. Falls back to a
    // sentinel so the UI never shows a blank version line in odd build configs.
    static func versionString(bundle: Bundle = .main) -> String {
        let short = bundle.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
        let build = bundle.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        return "\(short) (\(build))"
    }
}
