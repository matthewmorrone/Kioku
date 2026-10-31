import SwiftUI

extension ReadView {
    // Opens the word detail view for a word named in the lookup sheet's lemma line (the
    // 起こる / そう chips), instead of stacking another lookup sheet on top of the first.
    // The lookup sheet is dismissed first so the detail sheet is presented from Read's own
    // SwiftUI presenter. A lemma with no dictionary entry leaves the sheet as it is.
    func openWordDetailForComponent(lemma: String) {
        guard let entry = resolvedDictionaryEntry(forSurface: lemma) else { return }
        let reading = entry.kanaForms.first?.text
        SegmentLookupSheet.shared.dismissPopover(notifyDismissal: false) {
            DispatchQueue.main.async {
                presentWordDetail(entryID: entry.entryId, surface: lemma, reading: reading, sublatticePaths: [])
            }
        }
    }
}
