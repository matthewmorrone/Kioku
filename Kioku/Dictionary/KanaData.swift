import Foundation

// Central reference store for Japanese script constants shared across segmentation,
// normalization, and filtering subsystems.
nonisolated enum KanaData {
    // Single-kana and short multi-kana particles used as the default standalone-segment allowlist.
    static let defaultParticles: [String] = [
        "は", "が", "を", "に", "へ", "と", "で", "も", "の", "ね", "よ", "か", "な", "や",
        "ぞ", "さ", "わ", "し", "て", "だ",
        // "から", "まで", "より", "だけ", "ほど", "しか", "こそ", "でも", "なら", "ので", "のに", "って"
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

}
