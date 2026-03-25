import SwiftUI

// The two study modes that live side-by-side in the swipeable cards container.
private enum CardsPage: Int, CaseIterable, Identifiable {
    case flashcards
    case cloze
    var id: Int { rawValue }
}

// Preference key used by FlashcardsView to hide the page dots while a session is active.
struct CardsPageDotsHiddenPreferenceKey: PreferenceKey {
    static var defaultValue: Bool = false
    // OR-reduces so any child requesting hidden wins.
    static func reduce(value: inout Bool, nextValue: () -> Bool) { value = value || nextValue() }
}

// Preference key used by FlashcardsView to disable swipe-between-modes during a session.
struct CardsStudySessionActivePreferenceKey: PreferenceKey {
    static var defaultValue: Bool = false
    static func reduce(value: inout Bool, nextValue: () -> Bool) { value = value || nextValue() }
}

// Renders a paged TabView containing Flashcards and Cloze study modes side by side.
// The middle copy of a three-copy loop is always visible so swiping never hits a hard edge.
// Major sections: infinite-loop TabView, page-dot overlay, gesture lock during sessions.
struct CardsTabView: View {
    let dictionaryStore: DictionaryStore?

    private static let pages: [CardsPage] = CardsPage.allCases
    private static let copies = 3

    private static var totalCount: Int { pages.count * copies }

    // Start at the middle copy so left and right swipes are both available immediately.
    private static func initialIndex(for page: CardsPage) -> Int {
        pages.count + page.rawValue
    }

    @State private var selectedIndex: Int = CardsTabView.initialIndex(for: .flashcards)
    @State private var dotsHidden: Bool = false
    @State private var sessionActive: Bool = false

    private var currentPage: CardsPage {
        CardsTabView.pages[selectedIndex % CardsTabView.pages.count]
    }

    var body: some View {
        TabView(selection: $selectedIndex) {
            ForEach(0..<CardsTabView.totalCount, id: \.self) { index in
                let page = CardsTabView.pages[index % CardsTabView.pages.count]
                Group {
                    switch page {
                    case .flashcards:
                        FlashcardsView(dictionaryStore: dictionaryStore)
                    case .cloze:
                        ClozeStudyHomeView()
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .tag(index)
            }
        }
        .tabViewStyle(.page(indexDisplayMode: .never))
        // Block swipe-between-modes while a flashcard session is running.
        .gesture(sessionActive ? DragGesture() : nil)
        .onChange(of: selectedIndex) { _, newValue in
            let pageCount = CardsTabView.pages.count
            // Jump to the middle copy when the user reaches the first or last copy,
            // creating the illusion of infinite scrolling without layout cost.
            if newValue < pageCount {
                jumpTo(newValue + pageCount)
            } else if newValue >= pageCount * 2 {
                jumpTo(newValue - pageCount)
            }
        }
        .onPreferenceChange(CardsPageDotsHiddenPreferenceKey.self) { dotsHidden = $0 }
        .onPreferenceChange(CardsStudySessionActivePreferenceKey.self) { sessionActive = $0 }
        .overlay {
            if !(currentPage == .flashcards && dotsHidden) {
                CardsPageDotsOverlay(selectedPage: currentPage)
                    .allowsHitTesting(false)
            }
        }
    }

    // Jumps the selection without animation so the copy-wrap is invisible to the user.
    private func jumpTo(_ index: Int) {
        var tx = Transaction(); tx.animation = nil
        withTransaction(tx) { selectedIndex = index }
    }
}

// Renders the two navigation dots at the bottom of the cards container.
private struct CardsPageDotsOverlay: View {
    let selectedPage: CardsPage

    // Dots indicate which mode is active; hit testing is disabled so touches pass through.
    var body: some View {
        HStack(spacing: 8) {
            ForEach(CardsPage.allCases) { page in
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
