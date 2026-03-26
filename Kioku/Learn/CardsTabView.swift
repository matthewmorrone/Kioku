import SwiftUI

// The two swipeable pages in the Learn tab.
enum LearnPage: Int, CaseIterable, Identifiable {
    case flashcards
    case cloze
    var id: Int { rawValue }
}

// Preference key used by FlashcardsView to hide page dots during a session.
struct CardsPageDotsHiddenPreferenceKey: PreferenceKey {
    static var defaultValue: Bool = false
    static func reduce(value: inout Bool, nextValue: () -> Bool) { value = value || nextValue() }
}

// Preference key used by FlashcardsView to disable swipe during an active session.
struct CardsStudySessionActivePreferenceKey: PreferenceKey {
    static var defaultValue: Bool = false
    static func reduce(value: inout Bool, nextValue: () -> Bool) { value = value || nextValue() }
}

// Renders both Learn pages as a manually paged horizontal scroller.
// Uses a high-priority horizontal DragGesture so child NavigationStacks and Forms
// cannot steal the swipe before the pager sees it.
// Major sections: page container, page-dot overlay, gesture lock during sessions.
struct LearnPagerView: View {
    let dictionaryStore: DictionaryStore?

    @State private var pageIndex: Int = 0
    @State private var dragOffset: CGFloat = 0
    @State private var dotsHidden: Bool = false
    @State private var sessionActive: Bool = false

    private var currentPage: LearnPage {
        LearnPage.allCases[pageIndex]
    }

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width

            HStack(spacing: 0) {
                FlashcardsView(dictionaryStore: dictionaryStore)
                    .frame(width: width)
                ClozeStudyHomeView()
                    .frame(width: width)
            }
            .frame(width: width, alignment: .leading)
            .offset(x: -CGFloat(pageIndex) * width + dragOffset)
            .highPriorityGesture(
                sessionActive ? nil :
                DragGesture(minimumDistance: 20)
                    .onChanged { value in
                        // Only track horizontal drags; ignore mostly-vertical ones.
                        guard abs(value.translation.width) > abs(value.translation.height) else { return }
                        dragOffset = value.translation.width
                    }
                    .onEnded { value in
                        let threshold = width * 0.25
                        let velocity = value.predictedEndTranslation.width - value.translation.width
                        let dx = value.translation.width + velocity * 0.3
                        withAnimation(.interactiveSpring(response: 0.35, dampingFraction: 0.86)) {
                            if dx < -threshold, pageIndex < LearnPage.allCases.count - 1 {
                                pageIndex += 1
                            } else if dx > threshold, pageIndex > 0 {
                                pageIndex -= 1
                            }
                            dragOffset = 0
                        }
                    }
            )
        }
        .clipped()
        .onPreferenceChange(CardsPageDotsHiddenPreferenceKey.self) { dotsHidden = $0 }
        .onPreferenceChange(CardsStudySessionActivePreferenceKey.self) { sessionActive = $0 }
        .overlay(alignment: .bottom) {
            if !(currentPage == .flashcards && dotsHidden) {
                LearnPageDotsOverlay(selectedPage: currentPage)
                    .allowsHitTesting(false)
                    .padding(.bottom, 14)
            }
        }
    }
}

// Renders two navigation dots indicating the active page.
private struct LearnPageDotsOverlay: View {
    let selectedPage: LearnPage

    var body: some View {
        HStack(spacing: 8) {
            ForEach(LearnPage.allCases) { page in
                Circle()
                    .fill(page == selectedPage ? Color.primary : Color.secondary.opacity(0.35))
                    .frame(width: 7, height: 7)
                    .accessibilityHidden(true)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(.thinMaterial, in: Capsule())
        .overlay(Capsule().stroke(Color(.separator), lineWidth: 1))
        .opacity(0.9)
    }
}
