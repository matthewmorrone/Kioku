import SwiftUI

// Full-screen word-by-word lyrics: the word being sung large in the middle with its furigana above
// and a short meaning below, its neighbours shrinking and fading away from it — above and below in
// portrait, left and right in landscape. Sections, top to bottom: the top bar (jumps to lyrics,
// breakdown and word detail; shuffle; the settings gear; close), the word strip, and the transport bar (play/pause + scrubber, rewind). The word
// list is the note's own segmentation timed by the cues (WordFocusWordBuilder), so it follows the
// same karaoke timing as the lyrics card; tapping a neighbouring word seeks to it.
struct WordFocusView: View {
    @ObservedObject var controller: AudioPlaybackController
    let cues: [SubtitleCue]
    let highlightRanges: [NSRange?]
    let noteText: String
    let segmentationRanges: [Range<String.Index>]
    let furiganaBySegmentLocation: [Int: String]
    let furiganaLengthBySegmentLocation: [Int: Int]
    // A word's dictionary meaning given its note location and surface; supplied by the Read view,
    // which owns the dictionary. Nil (previews) shows no meanings.
    var dictionaryGloss: ((Int, String) -> String?)? = nil
    // Whether the dictionary counts a word as a particle (given its note location and surface), and
    // whether a word is a katakana loanword — the Read view's checks the lyrics card uses too, for
    // hiding the meanings of the kinds of word the shared filters hide. Nil (previews) counts none.
    var isParticle: ((Int, String) -> Bool)? = nil
    var isLoanword: ((String) -> Bool)? = nil
    // The note's id, to find its song breakdown, whose meanings come before the dictionary's.
    var noteID: UUID? = nil
    @EnvironmentObject private var songBreakdownStore: SongBreakdownStore
    // The word filters shared with the lyrics card's bubbles and the Breakdown (LyricWordMeaningFilter):
    // a hidden kind of word still takes its turn here, without its meaning.
    @AppStorage(BreakdownListenSettings.showParticlesKey) private var showsParticles = BreakdownListenSettings.defaultShowParticles
    @AppStorage(BreakdownListenSettings.showKatakanaKey) private var showsKatakana = BreakdownListenSettings.defaultShowKatakana
    @AppStorage(BreakdownListenSettings.showVocalizationsKey) private var showsVocalizations = BreakdownListenSettings.defaultShowVocalizations
    @AppStorage(LyricsPopupSettings.showLoanwordBubblesKey) private var showsLoanwords = LyricsPopupSettings.defaultShowLoanwordBubbles
    // Whether meanings and furigana show at all: the same choices as the lyrics card's Bubbles and
    // Furigana toggles, set from either view's settings popup.
    @AppStorage(LyricsPopupSettings.showBubblesKey) private var showsMeanings = LyricsPopupSettings.defaultShowBubbles
    @AppStorage(LyricsPopupSettings.showFuriganaKey) private var showsFurigana = LyricsPopupSettings.defaultShowFurigana
    @State private var isShowingSettings = false
    // Plays a random other song, keeping this view open.
    var onPlayRandom: () -> Void = {}
    // Top-bar jumps from the current word: its place in the lyrics view, the breakdown (given the
    // word's note location), and its detail page (given location and surface). Supplied by the Read view.
    var onOpenLyrics: () -> Void = {}
    var onOpenBreakdown: (Int) -> Void = { _ in }
    var onOpenWordDetail: (Int, String) -> Void = { _, _ in }
    let onDismiss: () -> Void

    @State private var words: [WordFocusWord] = []
    // Short meanings by word id, filled for the words on screen ("" = none), so body never queries the dictionary.
    @State private var glosses: [Int: String] = [:]
    // The note's breakdown placed on its text, whose word meanings come before the dictionary's.
    @State private var breakdownPlacement: SongBreakdownPlacement?
    @State private var isScrubbing = false

    // Index of the word being sung: the last one whose start has passed, the first before any.
    private var activeIndex: Int {
        guard words.isEmpty == false else { return 0 }
        let now = controller.currentTimeMs
        var low = 0
        var high = words.count
        while low < high {
            let mid = (low + high) / 2
            if words[mid].startMs <= now { low = mid + 1 } else { high = mid }
        }
        return max(0, low - 1)
    }

    var body: some View {
        let active = activeIndex
        ZStack {
            Color(.systemBackground).ignoresSafeArea()
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    if words.indices.contains(active) {
                        let word = words[active]
                        jumpButton(systemImage: "music.note.list", label: "Show in Lyrics", action: onOpenLyrics)
                        // An interlude has no place in the note, so only the lyrics jump applies to it.
                        if word.interludeDurationMs == nil {
                            jumpButton(systemImage: "list.bullet.rectangle", label: "Show in Breakdown") { onOpenBreakdown(word.id) }
                            jumpButton(systemImage: "character.book.closed", label: "Word Detail") { onOpenWordDetail(word.id, word.surface) }
                        }
                    }
                    Spacer()
                    // Up here, away from the transport the thumb rests on, so a stray tap doesn't change the song.
                    jumpButton(systemImage: "shuffle", label: "Play a Random Song", action: onPlayRandom)
                    jumpButton(systemImage: "gearshape", label: "Settings") { isShowingSettings = true }
                        .popover(isPresented: $isShowingSettings) {
                            settingsPopup
                                .presentationCompactAdaptation(.popover)
                        }
                    Button(action: onDismiss) {
                        Image(systemName: "xmark")
                            .scaledFont(size: 15, weight: .semibold)
                            .foregroundStyle(.secondary)
                            .frame(width: 36, height: 36)
                            .background(Color(.systemFill))
                            .clipShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Close")
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)

                GeometryReader { geo in
                    wordStrip(active: active, size: geo.size)
                        .frame(width: geo.size.width, height: geo.size.height)
                        .clipped()
                }

                HStack(spacing: 10) {
                    Button {
                        if controller.isPlaying { controller.pause() } else { controller.play() }
                    } label: {
                        Circle()
                            .fill(Color(.systemOrange).opacity(0.2))
                            .frame(width: 44, height: 44)
                            .overlay(
                                Image(systemName: controller.isPlaying ? "pause.fill" : "play.fill")
                                    .scaledFont(size: 17, weight: .semibold)
                                    .foregroundStyle(Color(.systemOrange))
                            )
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(controller.isPlaying ? "Pause" : "Play")
                    LyricsScrubber(controller: controller, isScrubbing: $isScrubbing)
                    // Like the lyrics card's: tap returns to the start of the line, long press to the start of the song.
                    transportButton(systemImage: "backward.end.fill", label: "Return to start of line")
                        .onTapGesture { seekToLineStart() }
                        .onLongPressGesture { controller.seek(toMs: 0) }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 12)
            }
        }
        .task(id: WordListKey(
            noteID: noteID,
            textLength: noteText.utf16.count,
            cueCount: cues.count,
            breakdownGeneratedAt: noteID.flatMap { songBreakdownStore.breakdown(forNoteID: $0)?.generatedAt }
        )) { rebuildWords() }
        .task(id: active &* 100_003 &+ words.count) { await loadGlosses(around: active) }
        // A filter change re-decides which words have a meaning.
        .onChange(of: filterSignature) { _, _ in
            glosses = [:]
            Task { await loadGlosses(around: activeIndex) }
        }
    }

    // How many words show on each side of the one being sung, and how much smaller and fainter each
    // step away from it is drawn.
    private static let neighborCount = 4
    private static let scaleByDistance: [CGFloat] = [1, 0.55, 0.42, 0.33, 0.26]
    private static let opacityByDistance: [Double] = [1, 0.5, 0.3, 0.17, 0.08]

    // The word being sung with its neighbours in reading order, shrinking and fading with distance:
    // top to bottom when the screen is taller than wide, left to right when wider. Each word keeps
    // its identity, so on every step the strip slides along and each word grows or shrinks into its
    // new place rather than being redrawn.
    private func wordStrip(active: Int, size: CGSize) -> some View {
        let isHorizontal = size.width > size.height
        // The current word's slot: its length along the strip and its breadth across it. A word is laid
        // out at the current word's size, then scaled, so its text never re-wraps as it shrinks.
        let slotLength = isHorizontal ? min(size.width * 0.34, 280) : min(size.height * 0.24, 170)
        let slotBreadth = isHorizontal ? size.height : size.width - 32
        let slotWidth = isHorizontal ? slotLength : slotBreadth
        let slotHeight = isHorizontal ? slotBreadth : slotLength
        let window = (active - Self.neighborCount)...(active + Self.neighborCount)
        return ZStack {
            ForEach(window.filter { words.indices.contains($0) }, id: \.self) { index in
                let distance = index - active
                let scale = Self.scaleByDistance[min(abs(distance), Self.neighborCount)]
                let offset = Self.stripOffset(distance: distance, slotLength: slotLength)
                wordColumn(words[index], isActive: index == active, size: 56, glossSize: 22, glossLines: 2)
                    .frame(width: slotWidth, height: slotHeight)
                    .scaleEffect(scale)
                    .frame(width: slotWidth * scale, height: slotHeight * scale)
                    .contentShape(Rectangle())
                    .onTapGesture { controller.seek(toMs: words[index].startMs) }
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
    // interlude is its notes instead (InterludeNotes, as on the lyrics card), pulsing to the music
    // while it's the stop playing.
    @ViewBuilder
    private func wordColumn(_ word: WordFocusWord, isActive: Bool, size: CGFloat, glossSize: CGFloat, glossLines: Int) -> some View {
        if let durationMs = word.interludeDurationMs {
            InterludeNotes(
                controller: controller,
                durationMs: durationMs,
                isActive: isActive && controller.isPlaying,
                fontSize: size * 0.8
            )
        } else {
            spelledWordColumn(word, size: size, glossSize: glossSize, glossLines: glossLines)
        }
    }

    // A sung word's column: furigana over its kanji, the spelling, and the meaning underneath.
    private func spelledWordColumn(_ word: WordFocusWord, size: CGFloat, glossSize: CGFloat, glossLines: Int) -> some View {
        VStack(spacing: size * 0.25) {
            // The first size that fits the width, so ruby and spelling shrink together.
            ViewThatFits(in: .horizontal) {
                ForEach([1.0, 0.75, 0.55, 0.4], id: \.self) { scale in
                    spellingRow(word, size: size * scale)
                }
            }
            Text(showsMeanings ? glosses[word.id] ?? "" : "")
                .font(.system(size: glossSize))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineLimit(glossLines)
        }
    }

    // The word's pieces in one line at one size: furigana over each kanji run, plain text between.
    private func spellingRow(_ word: WordFocusWord, size: CGFloat) -> some View {
        HStack(alignment: .lastTextBaseline, spacing: 0) {
            ForEach(Array(word.pieces.enumerated()), id: \.offset) { _, piece in
                VStack(spacing: 2) {
                    Text(piece.ruby ?? " ")
                        .font(Font(ReadingFont.body(size: size * 0.45)))
                        .opacity(piece.ruby == nil || showsFurigana == false ? 0 : 1)
                    Text(piece.base)
                        .font(Font(ReadingFont.body(size: size)))
                }
            }
        }
        .lineLimit(1)
        .fixedSize(horizontal: true, vertical: false)
    }

    // The gear's popover: the lyrics card's playback toggles, whether meanings show (with the menu of
    // which kinds of word get one), and furigana. Every choice is shared with the lyrics card.
    private var settingsPopup: some View {
        VStack(alignment: .leading, spacing: 14) {
            LyricsPlaybackOptions()
            Divider()
            HStack {
                Text("Meanings")
                Menu {
                    LyricWordFilterMenuItems()
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.title3)
                }
                .disabled(showsMeanings == false)
                Spacer()
                Toggle("Meanings", isOn: $showsMeanings)
                    .labelsHidden()
            }
            Toggle("Furigana", isOn: $showsFurigana)
        }
        .padding(16)
        .frame(width: 270)
    }

    // The word filters as one value, so a change to any of them refreshes the meanings shown.
    private var filterSignature: [Bool] {
        [showsParticles, showsKatakana, showsVocalizations, showsLoanwords]
    }

    // A small round top-bar button.
    private func jumpButton(systemImage: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .scaledFont(size: 15, weight: .semibold)
                .foregroundStyle(.secondary)
                .frame(width: 36, height: 36)
                .background(Color(.systemFill))
                .clipShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    // A round grey transport button face (the caller attaches the gestures).
    private func transportButton(systemImage: String, label: String) -> some View {
        Circle()
            .fill(Color(.systemFill))
            .frame(width: 44, height: 44)
            .overlay(
                Image(systemName: systemImage)
                    .scaledFont(size: 16, weight: .semibold)
                    .foregroundStyle(Color.secondary)
            )
            .accessibilityLabel(label)
            .accessibilityAddTraits(.isButton)
    }

    // Seeks to the start of the lyric line playing now (the song's start before the first line).
    private func seekToLineStart() {
        let now = controller.currentTimeMs
        controller.seek(toMs: cues.last(where: { $0.startMs <= now })?.startMs ?? 0)
    }

    // Builds the word list from the note and cues, joined into the breakdown's words where it has
    // them, and forgets glosses of the old one.
    private func rebuildWords() {
        breakdownPlacement = noteID.flatMap { songBreakdownStore.placement(forNoteID: $0, noteText: noteText) }
        words = WordFocusWordBuilder.words(
            cues: cues,
            highlightRanges: highlightRanges,
            noteText: noteText,
            segmentationRanges: segmentationRanges,
            furiganaBySegmentLocation: furiganaBySegmentLocation,
            furiganaLengthBySegmentLocation: furiganaLengthBySegmentLocation,
            wordRanges: breakdownPlacement?.lines.flatMap { $0.words.map(\.range) } ?? []
        )
        glosses = [:]
    }

    // Looks up the meanings of the words on screen (and one further each way, so the next
    // step has its meaning ready), once each: the breakdown's, else the dictionary's, each only
    // where the shared filter lets that word have one (the same words that get a bubble).
    private func loadGlosses(around index: Int) async {
        let filter = LyricWordMeaningFilter(
            showsParticles: showsParticles,
            showsKatakana: showsKatakana,
            showsVocalizations: showsVocalizations,
            showsLoanwords: showsLoanwords,
            isParticle: isParticle,
            isLoanword: isLoanword
        )
        let reach = Self.neighborCount + 1
        for i in (index - reach)...(index + reach)
        where words.indices.contains(i) && words[i].interludeDurationMs == nil && glosses[words[i].id] == nil {
            let word = words[i]
            let wordRange = NSRange(location: word.id, length: (word.surface as NSString).length)
            let placed = breakdownPlacement?.words(overlapping: wordRange) ?? []
            let fromBreakdown = placed.lazy
                .filter { filter.allows(breakdownWord: $0.word) }
                .compactMap { LyricsView.shortGloss($0.word.definition) }.first
            // A word the breakdown covers but whose kind is hidden gets no dictionary meaning either;
            // one whose breakdown meaning is just too long for here falls back to the dictionary's.
            let isHidden = placed.contains { filter.allows(breakdownWord: $0.word) == false }
            let fromDictionary = isHidden == false && filter.allows(dictionaryWord: word.surface, at: word.id)
                ? dictionaryGloss?(word.id, word.surface).flatMap(LyricsView.shortGloss)
                : nil
            glosses[word.id] = fromBreakdown ?? fromDictionary ?? ""
        }
    }
}
