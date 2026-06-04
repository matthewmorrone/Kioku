import SwiftUI

// Hosts the learning tab: flashcards, multiple choice, cloze, and the kana chart — all
// swipeable left/right. Major sections: horizontal pager across the modes, page-dot overlay.
struct LearnView: View {
    let dictionaryStore: DictionaryStore?
    let segmenter: (any TextSegmenting)?
    // Read-tab reading maps, forwarded down to WordDetailView for example-sentence furigana.
    var surfaceReadingData: SurfaceReadingDataMap = SurfaceReadingDataMap()
    var kanjiReadingFallback: KanjiReadingFallbackMap = KanjiReadingFallbackMap()

    var body: some View {
        LearnPagerView(dictionaryStore: dictionaryStore, segmenter: segmenter, surfaceReadingData: surfaceReadingData, kanjiReadingFallback: kanjiReadingFallback)
            .toolbar(.visible, for: .tabBar)
    }
}

#Preview {
    ContentView(selectedTab: .learn)
}
