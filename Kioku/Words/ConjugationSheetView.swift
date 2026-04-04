import SwiftUI

// Bottom sheet showing all conjugation groups for a word.
// Renders each ConjugationGroup as a rounded card with Japanese on the left
// and the English row label (secondary, small) on the right.
// Each row is tappable — tapping opens the lookup sheet for that surface form.
// Screen: ConjugationSheetView, presented from WordDetailView.
// Layout sections: drag handle, title bar, scrollable card list.
struct ConjugationSheetView: View {
    // The dictionary form shown in the title bar.
    let dictionaryForm: String
    // All conjugation groups to display.
    let groups: [ConjugationGroup]
    // Called when a conjugated surface is tapped — opens lookup for that form.
    let onLookup: (String) -> Void

    var body: some View {
        NavigationStack {
            List {
                ForEach(groups) { group in
                    Section {
                        ForEach(Array(group.rows.enumerated()), id: \.offset) { _, row in
                            Button {
                                onLookup(row.surface)
                            } label: {
                                HStack {
                                    Text(row.surface)
                                        .foregroundStyle(.primary)
                                    Spacer()
                                    Text(row.label)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    } header: {
                        Text(group.name)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .textCase(nil)
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle(dictionaryForm)
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}
