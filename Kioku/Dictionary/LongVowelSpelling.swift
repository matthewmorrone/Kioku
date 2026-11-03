import Foundation

// Katakana lyrics often spell a long vowel out instead of with ー: ハレイション for ハレーション,
// ドウゾ for ドーゾ. The dictionary only has the ー spelling.
nonisolated enum LongVowelSpelling {
    // The vowel a kana ends in, by its row (ハ → "a", レ → "e").
    private static let vowelRows: [(vowel: Character, kana: Set<Character>)] = [
        ("a", Set("アカガサザタダナハバパマヤャラワ")),
        ("i", Set("イキギシジチヂニヒビピミリ")),
        ("u", Set("ウクグスズツヅヌフブプムユュルヴ")),
        ("e", Set("エケゲセゼテデネヘベペメレ")),
        ("o", Set("オコゴソゾトドノホボポモヨョロヲ")),
    ]
    // The kana that carries a long vowel on in writing: ア段 + ア, イ段 + イ, ウ段 + ウ, エ段 + イ or エ, オ段 + ウ or オ.
    private static let carriers: [Character: Set<Character>] = [
        "a": ["ア"], "i": ["イ"], "u": ["ウ"], "e": ["イ", "エ"], "o": ["ウ", "オ"],
    ]

    // The surface with every spelled-out long vowel written as ー; nil when it has none.
    static func collapsed(_ surface: String) -> String? {
        let characters = Array(surface)
        var result: [Character] = []
        var changed = false
        for character in characters {
            if let previous = result.last,
               let vowel = vowelRows.first(where: { $0.kana.contains(previous) })?.vowel,
               carriers[vowel]?.contains(character) == true {
                result.append("ー")
                changed = true
            } else {
                result.append(character)
            }
        }
        return changed ? String(result) : nil
    }
}
