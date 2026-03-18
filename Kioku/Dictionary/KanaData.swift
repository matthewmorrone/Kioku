import Foundation

// Central reference store for Japanese script constants shared across segmentation,
// normalization, and filtering subsystems.
enum KanaData {
    // Single-kana and short multi-kana particles used as the default standalone-segment allowlist.
    static let defaultParticles: [String] = [
        "は", "が", "を", "に", "へ", "と", "で", "も", "の", "ね", "よ", "か", "な", "や",
        "ぞ", "さ", "わ", "し", "て",
        "から", "まで", "より", "だけ", "ほど", "しか", "こそ", "でも", "なら", "ので", "のに", "って"
    ]

    // Kana variants normalized during furigana alignment so equivalent spellings match.
    // Maps archaic/alternate forms to their modern equivalents (e.g. づ→ず, ヴ→ブ).
    static let alignmentNormalizations: [String: String] = [
        "づ": "ず", "ぢ": "じ", "ゔ": "ぶ",
        "ヅ": "ズ", "ヂ": "ジ", "ヴ": "ブ"
    ]

    // Unvoiced→voiced kana pairs used to expand voiced iteration marks (ゞ ヾ).
    // All pairs follow Unicode +1 except う→ゔ and ウ→ヴ which are irregular.
    static let voicedKanaPairs: [String: String] = [
        "う": "ゔ", "か": "が", "き": "ぎ", "く": "ぐ", "け": "げ", "こ": "ご",
        "さ": "ざ", "し": "じ", "す": "ず", "せ": "ぜ", "そ": "ぞ",
        "た": "だ", "ち": "ぢ", "つ": "づ", "て": "で", "と": "ど",
        "は": "ば", "ひ": "び", "ふ": "ぶ", "へ": "べ", "ほ": "ぼ",
        "ウ": "ヴ", "カ": "ガ", "キ": "ギ", "ク": "グ", "ケ": "ゲ", "コ": "ゴ",
        "サ": "ザ", "シ": "ジ", "ス": "ズ", "セ": "ゼ", "ソ": "ゾ",
        "タ": "ダ", "チ": "ヂ", "ツ": "ヅ", "テ": "デ", "ト": "ド",
        "ハ": "バ", "ヒ": "ビ", "フ": "ブ", "ヘ": "ベ", "ホ": "ボ"
    ]

    // Basic gojūon (五十音): vowel row through n-row.
    static let gojuuon: [KanaRow] = [
        KanaRow(consonant: "∅", entries: [
            KanaEntry(hiragana: "あ", katakana: "ア", romaji: "a",   ipa: "a"),
            KanaEntry(hiragana: "い", katakana: "イ", romaji: "i",   ipa: "i"),
            KanaEntry(hiragana: "う", katakana: "ウ", romaji: "u",   ipa: "ɯ"),
            KanaEntry(hiragana: "え", katakana: "エ", romaji: "e",   ipa: "e"),
            KanaEntry(hiragana: "お", katakana: "オ", romaji: "o",   ipa: "o"),
        ]),
        KanaRow(consonant: "k", entries: [
            KanaEntry(hiragana: "か", katakana: "カ", romaji: "ka",  ipa: "ka"),
            KanaEntry(hiragana: "き", katakana: "キ", romaji: "ki",  ipa: "ki"),
            KanaEntry(hiragana: "く", katakana: "ク", romaji: "ku",  ipa: "kɯ"),
            KanaEntry(hiragana: "け", katakana: "ケ", romaji: "ke",  ipa: "ke"),
            KanaEntry(hiragana: "こ", katakana: "コ", romaji: "ko",  ipa: "ko"),
        ]),
        KanaRow(consonant: "s", entries: [
            KanaEntry(hiragana: "さ", katakana: "サ", romaji: "sa",  ipa: "sa"),
            KanaEntry(hiragana: "し", katakana: "シ", romaji: "shi", ipa: "ɕi"),
            KanaEntry(hiragana: "す", katakana: "ス", romaji: "su",  ipa: "sɯ"),
            KanaEntry(hiragana: "せ", katakana: "セ", romaji: "se",  ipa: "se"),
            KanaEntry(hiragana: "そ", katakana: "ソ", romaji: "so",  ipa: "so"),
        ]),
        KanaRow(consonant: "t", entries: [
            KanaEntry(hiragana: "た", katakana: "タ", romaji: "ta",  ipa: "ta"),
            KanaEntry(hiragana: "ち", katakana: "チ", romaji: "chi", ipa: "tɕi"),
            KanaEntry(hiragana: "つ", katakana: "ツ", romaji: "tsu", ipa: "tsɯ"),
            KanaEntry(hiragana: "て", katakana: "テ", romaji: "te",  ipa: "te"),
            KanaEntry(hiragana: "と", katakana: "ト", romaji: "to",  ipa: "to"),
        ]),
        KanaRow(consonant: "n", entries: [
            KanaEntry(hiragana: "な", katakana: "ナ", romaji: "na",  ipa: "na"),
            KanaEntry(hiragana: "に", katakana: "ニ", romaji: "ni",  ipa: "ɲi"),
            KanaEntry(hiragana: "ぬ", katakana: "ヌ", romaji: "nu",  ipa: "nɯ"),
            KanaEntry(hiragana: "ね", katakana: "ネ", romaji: "ne",  ipa: "ne"),
            KanaEntry(hiragana: "の", katakana: "ノ", romaji: "no",  ipa: "no"),
        ]),
        KanaRow(consonant: "h", entries: [
            KanaEntry(hiragana: "は", katakana: "ハ", romaji: "ha",  ipa: "ha"),
            KanaEntry(hiragana: "ひ", katakana: "ヒ", romaji: "hi",  ipa: "çi"),
            KanaEntry(hiragana: "ふ", katakana: "フ", romaji: "fu",  ipa: "ɸɯ"),
            KanaEntry(hiragana: "へ", katakana: "ヘ", romaji: "he",  ipa: "he"),
            KanaEntry(hiragana: "ほ", katakana: "ホ", romaji: "ho",  ipa: "ho"),
        ]),
        KanaRow(consonant: "m", entries: [
            KanaEntry(hiragana: "ま", katakana: "マ", romaji: "ma",  ipa: "ma"),
            KanaEntry(hiragana: "み", katakana: "ミ", romaji: "mi",  ipa: "mi"),
            KanaEntry(hiragana: "む", katakana: "ム", romaji: "mu",  ipa: "mɯ"),
            KanaEntry(hiragana: "め", katakana: "メ", romaji: "me",  ipa: "me"),
            KanaEntry(hiragana: "も", katakana: "モ", romaji: "mo",  ipa: "mo"),
        ]),
        KanaRow(consonant: "y", entries: [
            KanaEntry(hiragana: "や", katakana: "ヤ", romaji: "ya",  ipa: "ja"),
            nil,
            KanaEntry(hiragana: "ゆ", katakana: "ユ", romaji: "yu",  ipa: "jɯ"),
            nil,
            KanaEntry(hiragana: "よ", katakana: "ヨ", romaji: "yo",  ipa: "jo"),
        ]),
        KanaRow(consonant: "r", entries: [
            KanaEntry(hiragana: "ら", katakana: "ラ", romaji: "ra",  ipa: "ɾa"),
            KanaEntry(hiragana: "り", katakana: "リ", romaji: "ri",  ipa: "ɾi"),
            KanaEntry(hiragana: "る", katakana: "ル", romaji: "ru",  ipa: "ɾɯ"),
            KanaEntry(hiragana: "れ", katakana: "レ", romaji: "re",  ipa: "ɾe"),
            KanaEntry(hiragana: "ろ", katakana: "ロ", romaji: "ro",  ipa: "ɾo"),
        ]),
        KanaRow(consonant: "w", entries: [
            KanaEntry(hiragana: "わ", katakana: "ワ", romaji: "wa",  ipa: "ɰa"),
            nil, nil, nil,
            KanaEntry(hiragana: "を", katakana: "ヲ", romaji: "wo",  ipa: "o"),
        ]),
        KanaRow(consonant: "n̄", entries: [
            KanaEntry(hiragana: "ん", katakana: "ン", romaji: "n",   ipa: "ɴ"),
            nil, nil, nil, nil,
        ]),
    ]

    // Voiced kana (濁音): g, z, d, b rows.
    static let dakuten: [KanaRow] = [
        KanaRow(consonant: "g", entries: [
            KanaEntry(hiragana: "が", katakana: "ガ", romaji: "ga",  ipa: "ɡa"),
            KanaEntry(hiragana: "ぎ", katakana: "ギ", romaji: "gi",  ipa: "ɡi"),
            KanaEntry(hiragana: "ぐ", katakana: "グ", romaji: "gu",  ipa: "ɡɯ"),
            KanaEntry(hiragana: "げ", katakana: "ゲ", romaji: "ge",  ipa: "ɡe"),
            KanaEntry(hiragana: "ご", katakana: "ゴ", romaji: "go",  ipa: "ɡo"),
        ]),
        KanaRow(consonant: "z", entries: [
            KanaEntry(hiragana: "ざ", katakana: "ザ", romaji: "za",  ipa: "za"),
            KanaEntry(hiragana: "じ", katakana: "ジ", romaji: "ji",  ipa: "dʑi"),
            KanaEntry(hiragana: "ず", katakana: "ズ", romaji: "zu",  ipa: "zɯ"),
            KanaEntry(hiragana: "ぜ", katakana: "ゼ", romaji: "ze",  ipa: "ze"),
            KanaEntry(hiragana: "ぞ", katakana: "ゾ", romaji: "zo",  ipa: "zo"),
        ]),
        KanaRow(consonant: "d", entries: [
            KanaEntry(hiragana: "だ", katakana: "ダ", romaji: "da",  ipa: "da"),
            KanaEntry(hiragana: "ぢ", katakana: "ヂ", romaji: "ji",  ipa: "dʑi"),
            KanaEntry(hiragana: "づ", katakana: "ヅ", romaji: "zu",  ipa: "dzɯ"),
            KanaEntry(hiragana: "で", katakana: "デ", romaji: "de",  ipa: "de"),
            KanaEntry(hiragana: "ど", katakana: "ド", romaji: "do",  ipa: "do"),
        ]),
        KanaRow(consonant: "b", entries: [
            KanaEntry(hiragana: "ば", katakana: "バ", romaji: "ba",  ipa: "ba"),
            KanaEntry(hiragana: "び", katakana: "ビ", romaji: "bi",  ipa: "bi"),
            KanaEntry(hiragana: "ぶ", katakana: "ブ", romaji: "bu",  ipa: "bɯ"),
            KanaEntry(hiragana: "べ", katakana: "ベ", romaji: "be",  ipa: "be"),
            KanaEntry(hiragana: "ぼ", katakana: "ボ", romaji: "bo",  ipa: "bo"),
        ]),
    ]

    // Semi-voiced kana (半濁音): p row only.
    static let handakuten: [KanaRow] = [
        KanaRow(consonant: "p", entries: [
            KanaEntry(hiragana: "ぱ", katakana: "パ", romaji: "pa",  ipa: "pa"),
            KanaEntry(hiragana: "ぴ", katakana: "ピ", romaji: "pi",  ipa: "pi"),
            KanaEntry(hiragana: "ぷ", katakana: "プ", romaji: "pu",  ipa: "pɯ"),
            KanaEntry(hiragana: "ぺ", katakana: "ペ", romaji: "pe",  ipa: "pe"),
            KanaEntry(hiragana: "ぽ", katakana: "ポ", romaji: "po",  ipa: "po"),
        ]),
    ]
}
