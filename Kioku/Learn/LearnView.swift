import SwiftUI
import Combine

// Hosts the learning tab: kana chart and study modes (flashcards + cloze).
// Major sections: segmented section picker in toolbar, KanaChartView, CardsTabView.
struct LearnView: View {
    let dictionaryStore: DictionaryStore?

    @State private var selectedSection: LearnSection = .kana

    var body: some View {
        Group {
            switch selectedSection {
            case .kana:
                NavigationStack {
                    KanaChartView()
                        .toolbar {
                            ToolbarItem(placement: .principal) { sectionPicker }
                        }
                }
            case .cards:
                CardsTabView(dictionaryStore: dictionaryStore)
                    .overlay(alignment: .top) {
                        // Inject the picker above the cards container without nesting a second
                        // NavigationStack, since CardsTabView's children own their own stacks.
                        sectionPickerBar
                    }
            }
        }
        .toolbar(.visible, for: .tabBar)
    }

    // Segmented picker placed in the navigation bar (kana) or floating bar (cards).
    private var sectionPicker: some View {
        Picker("Section", selection: $selectedSection) {
            ForEach(LearnSection.allCases, id: \.self) { section in
                Text(section.displayName).tag(section)
            }
        }
        .pickerStyle(.segmented)
        .fixedSize()
    }

    // Thin bar that floats above the cards pager so the picker is always reachable.
    private var sectionPickerBar: some View {
        VStack(spacing: 0) {
            sectionPicker
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(.bar)
            Divider()
        }
    }
}

#Preview {
    ContentView(selectedTab: .learn)
}
