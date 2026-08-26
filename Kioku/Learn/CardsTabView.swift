import SwiftUI

// The swipeable pages in the Learn tab: Flashcards, Multiple Choice, and Cloze.
// (Breakdown, formerly `songs`, moved to the Read tab as a per-note sheet. Coverage moved to the
// Read tab's Extract Words sheet as a third mode alongside Lines/Vocab, since it's scoped to one
// note and the Learn tab's note-picker entry point was redundant with reaching it from Read.)
// `LearnPagerView`'s persisted page index clamps on read, so a stale index from a previous
// install with a different page count snaps back into range on next launch without crashing.
enum LearnPage: Int, CaseIterable, Identifiable {
    case flashcards
    case multipleChoice
    case fillInBlank
    case cloze
    case kanaChart
    var id: Int { rawValue }
}

// Preference key an activity page sets to hide page dots during a session. `reduce` only matters
// within one page's own subtree (an activity page plus whatever it presents) — `LearnPagerView`
// reads each page's value separately at that page's mount site rather than off the merged bubble
// reaching its own body, so an active session on one page can't hide dots for another.
struct CardsPageDotsHiddenPreferenceKey: PreferenceKey {
    static var defaultValue: Bool = false
    // Bubbles any true value up within the setting page's own subtree.
    static func reduce(value: inout Bool, nextValue: () -> Bool) { value = value || nextValue() }
}

// Preference key an activity page sets to disable swipe during an active session. Read the same
// per-page way as CardsPageDotsHiddenPreferenceKey above — see that key's comment.
struct CardsStudySessionActivePreferenceKey: PreferenceKey {
    static var defaultValue: Bool = false
    // Bubbles any true value up within the setting page's own subtree.
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
    // Keyed per page rather than a single flattened Bool: all 5 pages stay mounted simultaneously
    // for the swipe animation, so a plain `.onPreferenceChange` at this view's own level would OR
    // every page's flag together — an active Flashcards session left running in the background
    // would then hide dots and lock swipe while looking at, say, Multiple Choice's untouched home
    // screen. Each page's value is instead captured where that page is mounted below (see the
    // per-child `.onPreferenceChange` calls in `body`), so only the page actually on screen can
    // hide dots or lock the gesture.
    @State private var dotsHiddenByPage: [LearnPage: Bool] = [:]
    @State private var sessionActiveByPage: [LearnPage: Bool] = [:]
    private var dotsHidden: Bool { dotsHiddenByPage[currentPage] ?? false }
    private var sessionActive: Bool { sessionActiveByPage[currentPage] ?? false }

    // The axis a drag committed to, decided once on its first movement and held for the rest of the
    // gesture. Without this lock a mostly-vertical scroll that wobbles horizontally (or ends with a
    // diagonal flick) could still drive the pager, since the old per-frame axis test could flip
    // mid-drag and `onEnded` didn't consult the axis at all.
    @State private var dragAxis: DragAxis?

    private enum DragAxis { case horizontal, vertical }

    // How much more horizontal than vertical a drag's first movement must be to claim the pager.
    // A deliberate left/right swipe sits within ~20° of flat; requiring 2:1 (~27°) leaves those
    // untouched while rejecting the diagonal drift of an up/down scroll.
    private static let horizontalClaimRatio: CGFloat = 2

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
                    .onPreferenceChange(CardsPageDotsHiddenPreferenceKey.self) { dotsHiddenByPage[.flashcards] = $0 }
                    .onPreferenceChange(CardsStudySessionActivePreferenceKey.self) { sessionActiveByPage[.flashcards] = $0 }
                MultipleChoiceView(dictionaryStore: dictionaryStore, segmenter: segmenter)
                    .frame(width: width)
                    .onPreferenceChange(CardsPageDotsHiddenPreferenceKey.self) { dotsHiddenByPage[.multipleChoice] = $0 }
                    .onPreferenceChange(CardsStudySessionActivePreferenceKey.self) { sessionActiveByPage[.multipleChoice] = $0 }
                FillInBlankView(dictionaryStore: dictionaryStore)
                    .frame(width: width)
                    .onPreferenceChange(CardsPageDotsHiddenPreferenceKey.self) { dotsHiddenByPage[.fillInBlank] = $0 }
                    .onPreferenceChange(CardsStudySessionActivePreferenceKey.self) { sessionActiveByPage[.fillInBlank] = $0 }
                ClozeStudyHomeView()
                    .frame(width: width)
                KanaChartView()
                    .frame(width: width)
            }
            .frame(width: width, alignment: .leading)
            .offset(x: -CGFloat(pageIndex) * width + dragOffset)
            // `.simultaneousGesture` (NOT `.highPriorityGesture`) so child ScrollViews and
            // Lists keep their own pan recognisers. Each drag locks to one axis on its first
            // movement (see `dragAxis`): only a clearly horizontal one drives the pager, and a
            // drag that went to the child leaves `dragOffset` at 0 and can't page on release. A
            // high-priority gesture would starve the child even when we don't act, which
            // is why vertical scrolling in the Breakdown screen wasn't working.
            //
            // `sessionActive` still nils the gesture entirely for in-session Flashcard / song
            // study so a deliberate horizontal flick can't accidentally advance the page.
            .simultaneousGesture(
                sessionActive ? nil :
                DragGesture(minimumDistance: 20)
                    .onChanged { value in
                        // The first callback arrives only after 20pt of travel, so its translation
                        // is a reliable direction sample to lock the axis on.
                        if dragAxis == nil {
                            dragAxis = abs(value.translation.width)
                                > abs(value.translation.height) * Self.horizontalClaimRatio
                                ? .horizontal : .vertical
                        }
                        guard dragAxis == .horizontal else { return }
                        dragOffset = rubberBanded(value.translation.width)
                    }
                    .onEnded { value in
                        let axis = dragAxis
                        dragAxis = nil
                        // A drag that never claimed the horizontal axis belongs to the child scroll
                        // view; it must not page even if its flick predicts far to one side.
                        guard axis == .horizontal else {
                            dragOffset = 0
                            return
                        }
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
        .overlay(alignment: .bottom) {
            // dotsHidden/sessionActive above are keyed to `currentPage`, so a session left active
            // on a page the user has since swiped away from can't hide dots or lock swipe here.
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
