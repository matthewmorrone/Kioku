import SwiftUI

// One 1920×1080 frame of the cast lyric video, drawn on black in dark appearance. Sections: either
// the word-by-word strip (the word being sung large, neighbours fading away) or the lyrics view
// (the current line large with furigana, the sung word in orange, lines around it fading).
struct LyricVideoFrameView: View {
    static let canvas = CGSize(width: 1920, height: 1080)
    let input: LyricVideoInput
    let mode: TVCastMode
    // Index into input.words of the word being sung.
    let active: Int

    // How many lines show around the current one in lyrics mode, and each step's scale and opacity.
    private static let lineReach = 2
    private static let lineScale: [CGFloat] = [1, 0.62, 0.45]
    private static let lineOpacity: [Double] = [1, 0.45, 0.2]

    var body: some View {
        ZStack {
            Color.black
            switch mode {
            case .words:
                WordFocusStripView(
                    words: input.words,
                    active: active,
                    glosses: input.glosses,
                    showsMeanings: input.showsMeanings,
                    showsFurigana: input.showsFurigana,
                    size: Self.canvas,
                    isLarge: true
                )
            case .lyrics:
                lyricsStack
            }
        }
        .frame(width: Self.canvas.width, height: Self.canvas.height)
        .environment(\.colorScheme, .dark)
    }

    // The words grouped into lines, in song order: a new line starts wherever the cue index changes.
    private var lines: [[WordFocusWord]] {
        var grouped: [[WordFocusWord]] = []
        for word in input.words {
            if let last = grouped.last?.last, last.lineIndex == word.lineIndex {
                grouped[grouped.count - 1].append(word)
            } else {
                grouped.append([word])
            }
        }
        return grouped
    }

    // The line stack around the line being sung.
    private var lyricsStack: some View {
        let all = lines
        let activeWord = input.words.indices.contains(active) ? input.words[active] : nil
        let currentSlot = all.firstIndex { $0.first?.lineIndex == activeWord?.lineIndex } ?? 0
        return VStack(spacing: 28) {
            ForEach(Array(all.enumerated()).filter { abs($0.offset - currentSlot) <= Self.lineReach }, id: \.offset) { slot, line in
                let distance = abs(slot - currentSlot)
                lineRow(line, isCurrent: distance == 0, activeWordID: activeWord?.id)
                    .scaleEffect(Self.lineScale[distance])
                    .opacity(Self.lineOpacity[distance])
            }
        }
        .padding(.horizontal, 80)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // One line of words side by side; the word being sung is orange on the current line.
    @ViewBuilder
    private func lineRow(_ line: [WordFocusWord], isCurrent: Bool, activeWordID: Int?) -> some View {
        if line.first?.interludeDurationMs != nil {
            Text("♪").font(.system(size: 80)).foregroundStyle(.secondary)
        } else {
            // The first size that fits the width, so a long line shrinks instead of clipping.
            ViewThatFits(in: .horizontal) {
                ForEach([1.0, 0.8, 0.62, 0.48], id: \.self) { scale in
                    HStack(alignment: .lastTextBaseline, spacing: 14 * scale) {
                        ForEach(line) { word in
                            WordSpellingRow(word: word, size: 84 * scale, showsFurigana: input.showsFurigana)
                                .foregroundStyle(isCurrent && word.id == activeWordID ? Color.orange : Color.primary)
                        }
                    }
                }
            }
        }
    }
}
