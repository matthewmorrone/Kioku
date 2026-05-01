import SwiftUI

// Hosts the learning tab: kana chart, flashcards, and cloze — all swipeable left/right.
// Major sections: infinite-loop TabView across three modes, page-dot overlay.
struct LearnView: View {
    let dictionaryStore: DictionaryStore?
    let segmenter: (any TextSegmenting)?

    var body: some View {
        LearnPagerView(dictionaryStore: dictionaryStore, segmenter: segmenter)
            .toolbar(.visible, for: .tabBar)
    }
}

#Preview {
    ContentView(selectedTab: .learn)
}
