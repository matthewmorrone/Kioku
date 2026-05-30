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
    // Evaluated lazily inside the context menu (built on long-press) so "Choose Lemma…" only
    // appears when the surface resolves to more than one lemma.
    var lemmaCandidateCount: () -> Int = { 0 }
    var onChooseLemma: () -> Void = {}

    var body: some View {
        HStack(spacing: 12) {
            Text(word.surface)
                .font(.headline)

            Spacer(minLength: 0)

            Button {
                onRemove()
            } label: {
                Image(systemName: "star.fill")
                    .foregroundStyle(Color.yellow)
                    .font(.system(size: 16, weight: .semibold))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Unsave")
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

            // Re-point this card to a different lemma when the surface is ambiguous
            // (e.g. した saved as 下 → re-point to する). Only shown when an alternative exists.
            if lemmaCandidateCount() > 1 {
                Button {
                    onChooseLemma()
                } label: {
                    Label("Choose Lemma…", systemImage: "arrow.triangle.2.circlepath")
                }
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
