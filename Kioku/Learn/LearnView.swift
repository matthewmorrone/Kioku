import SwiftUI

// Hosts the learning tab: flashcards, multiple choice, matching, fill in the blank, cloze, and the kana chart — all
// swipeable left/right. Major sections: horizontal pager across the modes, page-dot overlay.
struct LearnView: View {
    let dictionaryStore: DictionaryStore?
    let segmenter: (any TextSegmenting)?
    // Cloze uses it to inflect distractors like the blank.
    let lexicon: Lexicon?
    // Read-tab reading maps, forwarded down to WordDetailView for example-sentence furigana.
    var surfaceReadingData: SurfaceReadingDataMap = SurfaceReadingDataMap()
    var kanjiReadingFallback: KanjiReadingFallbackMap = KanjiReadingFallbackMap()

    var body: some View {
        LearnPagerView(
            dictionaryStore: dictionaryStore,
            segmenter: segmenter,
            lexicon: lexicon,
            surfaceReadingData: surfaceReadingData,
            kanjiReadingFallback: kanjiReadingFallback
        )
            .toolbar(.visible, for: .tabBar)
    }
}

#Preview {
    ContentView(selectedTab: .learn)
}
