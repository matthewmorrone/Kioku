import SwiftUI

// The entry point for the song-learning activity in the Learn tab. Lists notes that have
// content, shows whether each has a generated breakdown (and whether it's stale), and
// pushes the per-note stepper on selection. Generation happens inside SongStepperView so
// the home stays a pure list.
//
// Major sections: principal toolbar branding, notes list grouped by status, empty state.
struct SongsHomeView: View {
    @EnvironmentObject private var notesStore: NotesStore
    @EnvironmentObject private var songBreakdownStore: SongBreakdownStore
    @State private var selectedNote: Note? = nil

    var body: some View {
        NavigationStack {
            listContent
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .principal) {
                        HStack(spacing: 6) {
                            Image(systemName: "music.note.list")
                            Text("Breakdowns")
                        }
                        .font(.headline)
                        .foregroundStyle(.primary)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("Breakdowns")
                    }
                }
                .navigationDestination(item: $selectedNote) { note in
                    SongStepperView(note: note)
                }
        }
    }

    // Lists notes with non-empty content. Sorted to match NotesStore ordering so the user's
    // expectations from the Notes tab carry over (most recently inserted at top).
    @ViewBuilder
    private var listContent: some View {
        let candidates = notesStore.notes.filter { hasStudiableContent($0) }
        if candidates.isEmpty {
            emptyState
        } else {
            List {
                ForEach(candidates) { note in
                    Button {
                        selectedNote = note
                    } label: {
                        row(for: note)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    // Shown when the user has no notes with content yet. Points back at Notes for the obvious
    // next step — adding lyrics — rather than offering shortcuts that conflict with the
    // existing import flows.
    private var emptyState: some View {
        ContentUnavailableView(
            "No notes to study",
            systemImage: "music.note.list",
            description: Text("Add a note containing song lyrics on the Notes tab, then come back here to step through it line by line.")
        )
    }

    // One row: title + status indicator. Status is computed against the current note text
    // hash so a stale breakdown is reflected immediately when the user edits lyrics elsewhere.
    private func row(for note: Note) -> some View {
        let status = currentStatus(for: note)
        return HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(displayTitle(for: note))
                    .font(.body)
                    .foregroundStyle(.primary)
                statusLabel(for: status)
                    .font(.footnote)
            }
            Spacer(minLength: 8)
            Image(systemName: "chevron.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
        }
        .contentShape(Rectangle())
    }

    // Surfaces the breakdown state. Only the abnormal states get a label — not-generated and
    // stale are actionable, fresh is the default and needs no annotation. Dropping the
    // "Generated X ago" timer also stops the row from re-rendering on a minute cadence.
    @ViewBuilder
    private func statusLabel(for status: SongBreakdownStatus) -> some View {
        switch status {
        case .notGenerated:
            Text("Not generated yet")
                .foregroundStyle(.secondary)
        case .fresh:
            EmptyView()
        case .stale:
            Text("Lyrics changed since generation")
                .foregroundStyle(.orange)
        }
    }

    // Determines whether the note's cached breakdown matches its current text. Used to drive
    // the row's status label.
    private func currentStatus(for note: Note) -> SongBreakdownStatus {
        let hash = SongBreakdownService.sha256(note.content)
        guard let breakdown = songBreakdownStore.breakdown(forNoteID: note.id) else {
            return .notGenerated
        }
        if breakdown.sourceTextHash == hash {
            return .fresh(provider: breakdown.provider, generatedAt: breakdown.generatedAt)
        }
        return .stale
    }

    // Excludes empty notes from the list since there's nothing to break down.
    private func hasStudiableContent(_ note: Note) -> Bool {
        note.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    }

    // Builds the row's headline: prefers the note title, falls back to the first content line
    // so untitled lyric notes still identify themselves usefully.
    private func displayTitle(for note: Note) -> String {
        let trimmed = note.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty == false { return trimmed }
        // Fall back to the first content line so empty-titled lyric notes are still identifiable.
        let firstLine = note.content
            .components(separatedBy: .newlines)
            .first?
            .trimmingCharacters(in: .whitespaces) ?? ""
        return firstLine.isEmpty ? "Untitled" : firstLine
    }
}

// Tri-state used by the home row and the stepper banner. Pure data — kept in the same file
// because it only exists for SongsHomeView/SongStepperView display logic.
enum SongBreakdownStatus: Equatable {
    case notGenerated
    case fresh(provider: SongBreakdownProvider, generatedAt: Date)
    case stale
}
