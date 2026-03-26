import SwiftUI

// The three swipeable pages in the Learn tab.
enum LearnPage: Int, CaseIterable, Identifiable {
    case kana
    case flashcards
    case cloze
    var id: Int { rawValue }

    // Label shown in the page-dot overlay.
    var displayName: String {
        switch self {
        case .kana: return "Kana"
        case .flashcards: return "Flashcards"
        case .cloze: return "Cloze"
        }
    }
}

// Preference key used by FlashcardsView to disable swipe during an active session.
struct CardsStudySessionActivePreferenceKey: PreferenceKey {
    static var defaultValue: Bool = false
    static func reduce(value: inout Bool, nextValue: () -> Bool) { value = value || nextValue() }
}

// Preference key used by FlashcardsView to hide page dots during a session.
struct CardsPageDotsHiddenPreferenceKey: PreferenceKey {
    static var defaultValue: Bool = false
    static func reduce(value: inout Bool, nextValue: () -> Bool) { value = value || nextValue() }
}

// Renders all three Learn pages in a cyclic swipe container.
// The middle copy of a three-copy loop is always visible so swiping never hits a hard edge.
// Major sections: infinite-loop TabView, page-dot overlay, gesture lock during sessions.
struct LearnPagerView: View {
    let dictionaryStore: DictionaryStore?

    private static let pages: [LearnPage] = LearnPage.allCases
    private static let copies = 3
    private static var totalCount: Int { pages.count * copies }

    // Start at the middle copy so left and right swipes are both available immediately.
    @State private var selectedIndex: Int = LearnPage.allCases.count
    @State private var dotsHidden: Bool = false
    @State private var sessionActive: Bool = false

    private var currentPage: LearnPage {
        LearnPagerView.pages[selectedIndex % LearnPagerView.pages.count]
    }

    var body: some View {
        TabView(selection: $selectedIndex) {
            ForEach(0..<LearnPagerView.totalCount, id: \.self) { index in
                let page = LearnPagerView.pages[index % LearnPagerView.pages.count]
                pageView(for: page)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .tag(index)
            }
        }
        .tabViewStyle(.page(indexDisplayMode: .never))
        // Block swipe during an active flashcard session.
        .gesture(sessionActive ? DragGesture() : nil)
        .onChange(of: selectedIndex) { _, newValue in
            let count = LearnPagerView.pages.count
            if newValue < count {
                jumpTo(newValue + count)
            } else if newValue >= count * 2 {
                jumpTo(newValue - count)
            }
        }
        .onPreferenceChange(CardsPageDotsHiddenPreferenceKey.self) { dotsHidden = $0 }
        .onPreferenceChange(CardsStudySessionActivePreferenceKey.self) { sessionActive = $0 }
        .overlay {
            if !(currentPage == .flashcards && dotsHidden) {
                LearnPageDotsOverlay(selectedPage: currentPage)
                    .allowsHitTesting(false)
            }
        }
    }

    // Builds the content view for each page, each owning its own NavigationStack.
    @ViewBuilder
    private func pageView(for page: LearnPage) -> some View {
        switch page {
        case .kana:
            NavigationStack { KanaChartView() }
        case .flashcards:
            FlashcardsView(dictionaryStore: dictionaryStore)
        case .cloze:
            ClozeStudyHomeView()
        }
    }

    // Jumps without animation so the copy-wrap is invisible to the user.
    private func jumpTo(_ index: Int) {
        var tx = Transaction(); tx.animation = nil
        withTransaction(tx) { selectedIndex = index }
    }
}

// Renders three navigation dots at the bottom of the pager.
private struct LearnPageDotsOverlay: View {
    let selectedPage: LearnPage

    var body: some View {
        HStack(spacing: 8) {
            ForEach(LearnPage.allCases) { page in
                Circle()
                    .fill(page == selectedPage
                          ? Color.primary
                          : Color.secondary.opacity(0.35))
                    .frame(width: 7, height: 7)
                    .accessibilityHidden(true)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(.thinMaterial, in: Capsule())
        .overlay(Capsule().stroke(Color(.separator), lineWidth: 1))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .padding(.bottom, 14)
        .opacity(0.9)
    }
}
