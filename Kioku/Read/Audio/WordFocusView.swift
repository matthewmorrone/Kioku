import SwiftUI

// Full-screen word-by-word lyrics: the word being sung large in the middle with its furigana above
// and a short meaning below, the previous and next words dimmed to either side. Sections, top to
// bottom: a close button, the word row, and the transport bar (play/pause + scrubber). The word
// list is the note's own segmentation timed by the cues (WordFocusWordBuilder), so it follows the
// same karaoke timing as the lyrics card; tapping a side word seeks to it.
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
                        jumpButton(systemImage: "list.bullet.rectangle", label: "Show in Breakdown") { onOpenBreakdown(word.id) }
                        jumpButton(systemImage: "character.book.closed", label: "Word Detail") { onOpenWordDetail(word.id, word.surface) }
                    }
                    Spacer()
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
                    wordRow(active: active, width: geo.size.width)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
                    transportButton(systemImage: "shuffle", label: "Play a Random Song")
                        .onTapGesture { onPlayRandom() }
                    // Like the lyrics card's: tap returns to the start of the line, long press to the start of the song.
                    transportButton(systemImage: "backward.end.fill", label: "Return to start of line")
                        .onTapGesture { seekToLineStart() }
                        .onLongPressGesture { controller.seek(toMs: 0) }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 12)
            }
        }
        .task(id: WordListKey(noteID: noteID, textLength: noteText.utf16.count, cueCount: cues.count)) { rebuildWords() }
        .task(id: active &* 100_003 &+ words.count) { await loadGlosses(around: active) }
    }

    // The previous, current and next words side by side. The sides get a fixed share of the width and
    // shrink their text to fit; the current word takes the rest.
    private func wordRow(active: Int, width: CGFloat) -> some View {
        let sideWidth = width * 0.22
        return HStack(alignment: .center, spacing: 8) {
            neighbor(at: active - 1, width: sideWidth, alignment: .trailing)
            if words.indices.contains(active) {
                wordColumn(words[active], size: 56, glossSize: 22, glossLines: 2)
                    .frame(maxWidth: .infinity)
                    .layoutPriority(1)
                    .id(words[active].id)
                    .transition(.opacity)
            } else {
                Text("♪")
                    .scaledFont(size: 40)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity)
            }
            neighbor(at: active + 1, width: sideWidth, alignment: .leading)
        }
        .padding(.horizontal, 12)
        .animation(.easeInOut(duration: 0.18), value: active)
    }

    // A dimmed neighbouring word (or blank space at either end of the song); tapping it jumps there.
    @ViewBuilder
    private func neighbor(at index: Int, width: CGFloat, alignment: Alignment) -> some View {
        if words.indices.contains(index) {
            wordColumn(words[index], size: 30, glossSize: 12, glossLines: 3)
                .opacity(0.3)
                .frame(width: width, alignment: alignment)
                .contentShape(Rectangle())
                .onTapGesture { controller.seek(toMs: words[index].startMs) }
        } else {
            Color.clear.frame(width: width)
        }
    }

    // One word as a column: furigana over its kanji, the spelling, and the meaning underneath.
    private func wordColumn(_ word: WordFocusWord, size: CGFloat, glossSize: CGFloat, glossLines: Int) -> some View {
        VStack(spacing: size * 0.25) {
            // The first size that fits the width, so ruby and spelling shrink together.
            ViewThatFits(in: .horizontal) {
                ForEach([1.0, 0.75, 0.55, 0.4], id: \.self) { scale in
                    spellingRow(word, size: size * scale)
                }
            }
            Text(glosses[word.id] ?? "")
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
                        .opacity(piece.ruby == nil ? 0 : 1)
                    Text(piece.base)
                        .font(Font(ReadingFont.body(size: size)))
                }
            }
        }
        .lineLimit(1)
        .fixedSize(horizontal: true, vertical: false)
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

    // Builds the word list from the note and cues, and forgets glosses of the old one.
    private func rebuildWords() {
        words = WordFocusWordBuilder.words(
            cues: cues,
            highlightRanges: highlightRanges,
            noteText: noteText,
            segmentationRanges: segmentationRanges,
            furiganaBySegmentLocation: furiganaBySegmentLocation,
            furiganaLengthBySegmentLocation: furiganaLengthBySegmentLocation
        )
        breakdownPlacement = noteID.flatMap { songBreakdownStore.placement(forNoteID: $0, noteText: noteText) }
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
        for i in (index - 2)...(index + 2) where words.indices.contains(i) && glosses[words[i].id] == nil {
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
