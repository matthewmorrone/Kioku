import SwiftUI
import Combine

// Renders a single row in the Words list with swipe-to-delete and a context menu.
// Major sections: row label, swipe action, context menu with Lists submenu.
struct WordRowView: View {
    let word: SavedWord
    let lists: [WordList]
    let onOpenDetails: () -> Void
    let onToggleList: (UUID) -> Void
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Text(word.surface)
                .font(.headline)

            Spacer()
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onTapGesture {
            onOpenDetails()
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            // Matches existing swipe-to-delete behavior; remove confirmation handled by WordsView.
            Button(role: .destructive) {
                onRemove()
            } label: {
                Label("Remove", systemImage: "trash")
            }
        }
        .contextMenu {
            // Copies the word surface to the system clipboard for quick lookup in other apps.
            Button {
                UIPasteboard.general.string = word.surface
            } label: {
                Label("Copy", systemImage: "doc.on.doc")
            }

            // Opens the word detail sheet; duplicated as "Look Up" for discoverability.
            Button {
                onOpenDetails()
            } label: {
                Label("Look Up", systemImage: "magnifyingglass")
            }

            Button {
                onOpenDetails()
            } label: {
                Label("Open Details", systemImage: "info.circle")
            }

            // Shows each word list as a toggle so the user can assign membership inline.
            if !lists.isEmpty {
                Menu("Lists") {
                    ForEach(lists) { list in
                        Button {
                            onToggleList(list.id)
                        } label: {
                            if word.wordListIDs.contains(list.id) {
                                Label(list.name, systemImage: "checkmark")
                            } else {
                                Text(list.name)
                            }
                        }
                    }
                }
            }

            Divider()

            // Destructive removal; confirmation dialog is presented by WordsView.
            Button(role: .destructive) {
                onRemove()
            } label: {
                Label("Remove", systemImage: "trash")
            }
        }
    }
}
