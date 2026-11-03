import Foundation

// Rewrites kanji numerals as Arabic digits (五日 → 5日, 二十五日 → 25日) so a headword written with
// kanji numerals can be found in a sentence that spells the number in digits, the way Tatoeba does.
enum KanjiNumeralDigits {
    private static let digitValues: [Character: Int] = [
        "〇": 0, "一": 1, "二": 2, "三": 3, "四": 4, "五": 5, "六": 6, "七": 7, "八": 8, "九": 9,
    ]
    private static let unitValues: [Character: Int] = ["十": 10, "百": 100, "千": 1000]

    // The surface with every run of kanji numerals replaced by its digits; nil when it has none.
    static func digitForm(of surface: String) -> String? {
        var result = ""
        var run = ""
        var changed = false
        for character in surface {
            if digitValues[character] != nil || unitValues[character] != nil {
                run.append(character)
            } else {
                if run.isEmpty == false { result += digits(of: run); changed = true; run = "" }
                result.append(character)
            }
        }
        if run.isEmpty == false { result += digits(of: run); changed = true }
        return changed ? result : nil
    }

    // One run's value: positional when it has no 十/百/千 (二〇二四 → 2024), else summed with the
    // units (二十五 → 25, 十 → 10).
    private static func digits(of run: String) -> String {
        if run.contains(where: { unitValues[$0] != nil }) == false {
            return run.compactMap { digitValues[$0] }.map(String.init).joined()
        }
        var total = 0
        var current = 0
        for character in run {
            if let digit = digitValues[character] {
                current = digit
            } else if let unit = unitValues[character] {
                total += (current == 0 ? 1 : current) * unit
                current = 0
            }
        }
        return String(total + current)
    }
}
