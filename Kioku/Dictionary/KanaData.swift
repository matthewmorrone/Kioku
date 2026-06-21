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
    //
    // "ゆく"→"いく" is a verb-spelling variant rather than a voicing pair: 行く and its ~てゆく/
    // ~ていく auxiliary are the same morpheme spelled two ways. Surfaces in the wild use 〜ゆく
    // (生きてゆく) while the stored reading is 〜いく (いきていく), so the okurigana suffix きてゆく
    // failed to phonetically match the reading tail きていく — the kanji-run reading was rejected
    // and 生 rendered with NO furigana. Canonicalizing both sides to いく restores the match (the
    // okurigana crop then leaves い over 生). The two-kana key means a stray ゆ alone never matches
    // い — only the 行く-family ゆく/いく alternation does. Applied to both operands, so it is
    // symmetric (surface ゆく ↔ reading いく and vice versa). The katakana ユク→イク form is carried
    // for parity with the voicing pairs above (which all list both scripts); it only matters for
    // the rare kanji-plus-katakana-okurigana surface, but costs nothing and keeps the table
    // script-symmetric.
    static let alignmentNormalizations: [String: String] = [
        "づ": "ず", "ぢ": "じ", "ゔ": "ぶ",
        "ヅ": "ズ", "ヂ": "ジ", "ヴ": "ブ",
        "ゆく": "いく", "ユク": "イク"
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
