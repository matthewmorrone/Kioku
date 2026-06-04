import SwiftUI

// The swipeable pages in the Learn tab: Flashcards, Multiple Choice, and Cloze.
// (Breakdown, formerly `songs`, moved to the Read tab as a per-note sheet.) `LearnPagerView`'s
// persisted page index clamps on read, so a stale index from a previous install with a
// different page count snaps back into range on next launch without crashing.
enum LearnPage: Int, CaseIterable, Identifiable {
    case flashcards
    case multipleChoice
    case cloze
    case kanaChart
    var id: Int { rawValue }
}

// Preference key used by FlashcardsView to hide page dots during a session.
struct CardsPageDotsHiddenPreferenceKey: PreferenceKey {
    static var defaultValue: Bool = false
    // Bubbles any true value up the view tree so that the pager hides dots when any child requests it.
    static func reduce(value: inout Bool, nextValue: () -> Bool) { value = value || nextValue() }
}

// Preference key used by FlashcardsView to disable swipe during an active session.
struct CardsStudySessionActivePreferenceKey: PreferenceKey {
    static var defaultValue: Bool = false
    // Merges preference values so a session active flag from any child locks the pager's swipe gesture.
    static func reduce(value: inout Bool, nextValue: () -> Bool) { value = value || nextValue() }
}

// Renders both Learn pages as a manually paged horizontal scroller.
// Uses a high-priority horizontal DragGesture so child NavigationStacks and Forms
// cannot steal the swipe before the pager sees it.
// Major sections: page container, page-dot overlay, gesture lock during sessions.
struct LearnPagerView: View {
    let dictionaryStore: DictionaryStore?
    let segmenter: (any TextSegmenting)?
    // Read-tab reading maps, forwarded to FlashcardsView → WordDetailView for example furigana.
    var surfaceReadingData: SurfaceReadingDataMap = SurfaceReadingDataMap()
    var kanjiReadingFallback: KanjiReadingFallbackMap = KanjiReadingFallbackMap()

    // Durable mirror of the current page — survives navigations and launches so returning to the
    // Learn tab restores the page you were last on. NOT read directly by the offset: @AppStorage
    // writes don't reliably animate inside a withAnimation transaction, which made the page snap a
    // full width instead of gliding. The visual index lives in `pageIndex` (@State) and is synced
    // here whenever it settles.
    @AppStorage("learn.pageIndex") private var storedPageIndex: Int = 0

    // Visual/animated source of truth for the page offset. A plain @State animates under
    // withAnimation where the @AppStorage value did not. Seeded from storage in `.onAppear`.
    @State private var pageIndex: Int = 0

    @State private var dragOffset: CGFloat = 0
    @State private var dotsHidden: Bool = false
    @State private var sessionActive: Bool = false

    // Clamps any index into the valid page range so a stale stored value (e.g. from a build with
    // more pages) can't drive the offset out of bounds.
    private func clampedIndex(_ raw: Int) -> Int {
        max(0, min(LearnPage.allCases.count - 1, raw))
    }

    // Dampens drag past the first/last page so the edge resists (rubber-bands) instead of sliding
    // the row into blank space, which read as a broken transition at the ends.
    private func rubberBanded(_ raw: CGFloat) -> CGFloat {
        let pullingBeforeFirst = pageIndex == 0 && raw > 0
        let pullingPastLast = pageIndex == LearnPage.allCases.count - 1 && raw < 0
        return (pullingBeforeFirst || pullingPastLast) ? raw * 0.3 : raw
    }

    private var currentPage: LearnPage {
        LearnPage.allCases[clampedIndex(pageIndex)]
    }

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width

            HStack(spacing: 0) {
                FlashcardsView(dictionaryStore: dictionaryStore, segmenter: segmenter, surfaceReadingData: surfaceReadingData, kanjiReadingFallback: kanjiReadingFallback)
                    .frame(width: width)
                MultipleChoiceView(dictionaryStore: dictionaryStore, segmenter: segmenter)
                    .frame(width: width)
                ClozeStudyHomeView()
                    .frame(width: width)
                KanaChartView()
                    .frame(width: width)
            }
            .frame(width: width, alignment: .leading)
            .offset(x: -CGFloat(pageIndex) * width + dragOffset)
            // `.simultaneousGesture` (NOT `.highPriorityGesture`) so child ScrollViews and
            // Lists keep their own pan recognisers. The axis filter in `onChanged` decides
            // whether *we* care about a given drag: mostly-horizontal moves drive the pager;
            // mostly-vertical ones leave `dragOffset` at 0 and let the child scroll. A
            // high-priority gesture would starve the child even when we don't act, which
            // is why vertical scrolling in the Breakdown screen wasn't working.
            //
            // `sessionActive` still nils the gesture entirely for in-session Flashcard / song
            // study so a deliberate horizontal flick can't accidentally advance the page.
            .simultaneousGesture(
                sessionActive ? nil :
                DragGesture(minimumDistance: 20)
                    .onChanged { value in
                        guard abs(value.translation.width) > abs(value.translation.height) else { return }
                        dragOffset = rubberBanded(value.translation.width)
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
        // Seed the visual index from storage on first appearance, then mirror every settle back to
        // @AppStorage. Keeping persistence as a side effect (not the animation source) is what lets
        // the swipe glide smoothly.
        .onAppear { pageIndex = clampedIndex(storedPageIndex) }
        .onChange(of: pageIndex) { _, newValue in storedPageIndex = newValue }
        .onPreferenceChange(CardsPageDotsHiddenPreferenceKey.self) { dotsHidden = $0 }
        .onPreferenceChange(CardsStudySessionActivePreferenceKey.self) { sessionActive = $0 }
        .overlay(alignment: .bottom) {
            // Any active session (flashcard, song stepper) bubbles up dotsHidden so the
            // overlay disappears during study. Page-specific suppression isn't needed:
            // the active session also locks the swipe gesture via sessionActive.
            if dotsHidden == false {
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
