import SwiftUI

// Renders the full-screen word detail screen shown from Words list rows.
// Major sections: title/header and list membership content.
struct WordDetailView: View {
    let word: SavedWord
    let membershipTitles: [String]

    var body: some View {
        NavigationStack {
            List {
                /*
                if membershipTitles.isEmpty {
                    Section("Lists") {
                        Text("Unsorted")
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Section("Lists") {
                        ForEach(membershipTitles, id: \.self) { listTitle in
                            Text(listTitle)
                        }
                    }
                }
                */
            }
            .navigationTitle(word.surface)
            .navigationSubtitle(word.surface)
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}
