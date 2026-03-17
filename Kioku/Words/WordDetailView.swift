import SwiftUI

// Renders the full-screen word detail screen shown from Words list rows.
// Major sections: title/header, word list membership.
struct WordDetailView: View {
    let word: SavedWord
    let lists: [WordList]

    // Resolves the names of lists this word belongs to for display.
    private var membershipNames: [String] {
        let memberLists = lists.filter { word.wordListIDs.contains($0.id) }
        return memberLists.map(\.name).sorted()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(word.surface)
                .font(.title2.weight(.semibold))
                .padding(.horizontal, 20)
                .padding(.top, 24)
                .padding(.bottom, 16)

            List {
                Section("Lists") {
                    if membershipNames.isEmpty {
                        Text("Unsorted")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(membershipNames, id: \.self) { name in
                            Text(name)
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
        }
    }
}
