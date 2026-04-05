import SwiftUI

// Renders the surface title with furigana and lemma subtitle.
// Uses LookupHeaderView (UIKit) so the layout matches the native lookup sheet exactly.
// Used by both SegmentLookupSheet and WordDetailView.
struct SegmentLookupSheetHeader: View {
    let surface: String
    let reading: String?
    let lemma: String?

    var body: some View {
        LookupHeaderView(surface: surface, reading: reading, lemma: lemma)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 20)
    }
}
