import SwiftUI

// Renders a single pitch accent record as a kana string with H/L pattern labels.
// Major sections: a horizontal row of mora columns, each showing its pitch label (H/L)
// above the kana character, with dividers marking the downstep position.
// The accent value is the downstep position (0 = flat/heiban, N = drop after mora N).
struct PitchAccentView: View {
    let accent: PitchAccent

    // Splits kana into individual mora strings (handles digraphs like きゃ, っ, ー).
    private var morae: [String] {
        moraeSplit(accent.kana)
    }

    // Returns H or L for each mora position given the downstep.
    private var pattern: [String] {
        let n = accent.accent
        let count = morae.count
        return (0..<count).map { i in
            if n == 0 {
                // Heiban: mora 0 is L, rest are H
                return i == 0 ? "L" : "H"
            } else {
                // Atamadaka (n==1): mora 0 is H, rest L
                // Nakadaka/Odaka: mora 0 L, 1..<n H, n onward L
                if n == 1 { return i == 0 ? "H" : "L" }
                return i == 0 ? "L" : (i < n ? "H" : "L")
            }
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(morae.enumerated()), id: \.offset) { i, mora in
                VStack(spacing: 1) {
                    Text(pattern.indices.contains(i) ? pattern[i] : "")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.secondary)
                    Text(mora)
                        .font(.subheadline)
                }
                .frame(minWidth: 20)
                if i < morae.count - 1 {
                    Divider()
                        .frame(height: 28)
                        .opacity(accent.accent > 0 && i == accent.accent - 1 ? 1 : 0)
                }
            }
            if accent.accent == 0 {
                // Heiban: show a trailing marker to indicate no drop
                Text("→")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .padding(.leading, 2)
            }
        }
        .padding(.vertical, 2)
    }

    // Splits a kana string into mora units, keeping digraphs (ゃゅょャュョ) and
    // special characters (っッー) attached to their preceding mora.
    // This is needed because SwiftUI iterates over Character, but digraphs must
    // stay with their base kana for correct mora counting and display.
    private func moraeSplit(_ kana: String) -> [String] {
        let combining: Set<Character> = ["ゃ", "ゅ", "ょ", "ャ", "ュ", "ョ"]
        var result: [String] = []
        for ch in kana {
            if combining.contains(ch), result.isEmpty == false {
                result[result.count - 1].append(ch)
            } else {
                result.append(String(ch))
            }
        }
        return result
    }
}
