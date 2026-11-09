import SwiftUI

// The word strip of the word-by-word view: the word being sung with its neighbours in reading
// order, shrinking and fading with distance. Static (no playback of its own), so the live view and
// the cast lyric video's frames draw the same strip. `isLarge` is the TV scale.
struct WordFocusStripView: View {
    let words: [WordFocusWord]
    let active: Int
    let glosses: [Int: String]
    let showsMeanings: Bool
    let showsFurigana: Bool
    let size: CGSize
    var isLarge = false
    // Draws an interlude stop (duration, whether it is the one playing, font size); nil draws a plain ♪.
    var interlude: ((Int, Bool, CGFloat) -> AnyView)? = nil
    // Called when a neighbouring word is tapped, with its index; nil makes words inert.
    var onSelect: ((Int) -> Void)? = nil

    // How many words show on each side of the one being sung, and how much smaller and fainter each
    // step away from it is drawn.
    static let neighborCount = 4
    private static let scaleByDistance: [CGFloat] = [1, 0.55, 0.42, 0.33, 0.26]
    private static let opacityByDistance: [Double] = [1, 0.5, 0.3, 0.17, 0.08]

    // Each word keeps its identity, so on every step the strip slides along and each word grows or
    // shrinks into its new place rather than being redrawn.
    var body: some View {
        let isHorizontal = size.width > size.height
        // The current word's slot: its length along the strip and its breadth across it. A word is laid
        // out at the current word's size, then scaled, so its text never re-wraps as it shrinks.
        let slotLength = isHorizontal ? min(size.width * 0.34, isLarge ? 560 : 280) : min(size.height * 0.24, 170)
        let slotBreadth = isHorizontal ? size.height : size.width - 32
        let slotWidth = isHorizontal ? slotLength : slotBreadth
        let slotHeight = isHorizontal ? slotBreadth : slotLength
        let window = (active - Self.neighborCount)...(active + Self.neighborCount)
        ZStack {
            ForEach(window.filter { words.indices.contains($0) }, id: \.self) { index in
                let distance = index - active
                let scale = Self.scaleByDistance[min(abs(distance), Self.neighborCount)]
                let offset = Self.stripOffset(distance: distance, slotLength: slotLength)
                wordColumn(words[index], isActive: index == active, size: isLarge ? 110 : 56, glossSize: isLarge ? 44 : 22, glossLines: 2)
                    .frame(width: slotWidth, height: slotHeight)
                    .scaleEffect(scale)
                    .frame(width: slotWidth * scale, height: slotHeight * scale)
                    .contentShape(Rectangle())
                    .onTapGesture { onSelect?(index) }
                    .opacity(Self.opacityByDistance[min(abs(distance), Self.neighborCount)])
                    .offset(x: isHorizontal ? offset : 0, y: isHorizontal ? 0 : offset)
                    .transition(.opacity)
            }
            if words.indices.contains(active) == false {
                Text("♪")
                    .scaledFont(size: 40)
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(width: size.width, height: size.height)
        .clipped()
        .animation(.easeInOut(duration: 0.25), value: active)
    }

    // Where a word `distance` steps from the current one sits along the strip, from its centre: half
    // of each slot between them, so neighbouring words touch without overlapping at any size.
    private static func stripOffset(distance: Int, slotLength: CGFloat) -> CGFloat {
        guard distance != 0 else { return 0 }
        var total: CGFloat = 0
        for step in 0..<abs(distance) {
            let near = scaleByDistance[min(step, neighborCount)]
            let far = scaleByDistance[min(step + 1, neighborCount)]
            total += slotLength * (near + far) / 2
        }
        return distance < 0 ? -total : total
    }

    // One word as a column: furigana over its kanji, the spelling, and the meaning underneath. An
    // interlude is its notes instead.
    @ViewBuilder
    private func wordColumn(_ word: WordFocusWord, isActive: Bool, size: CGFloat, glossSize: CGFloat, glossLines: Int) -> some View {
        if let durationMs = word.interludeDurationMs {
            if let interlude {
                interlude(durationMs, isActive, size * 0.8)
            } else {
                Text("♪").font(.system(size: size * 0.8)).foregroundStyle(.tertiary)
            }
        } else {
            VStack(spacing: size * 0.25) {
                // The first size that fits the width, so ruby and spelling shrink together.
                ViewThatFits(in: .horizontal) {
                    ForEach([1.0, 0.75, 0.55, 0.4], id: \.self) { scale in
                        WordSpellingRow(word: word, size: size * scale, showsFurigana: showsFurigana)
                    }
                }
                Text(showsMeanings ? glosses[word.id] ?? "" : "")
                    .font(.system(size: glossSize))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(glossLines)
            }
        }
    }
}
