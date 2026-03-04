import SwiftUI

// Displays the notes list and supports selection, editing, and creation actions.
struct NotesView: View {
    var onSelectNote: ((Note) -> Void)? = nil
    var onCreateNote: (() -> Void)? = nil

    @EnvironmentObject private var store: NotesStore
    @State private var editMode: EditMode = .inactive
    @State private var selectedNoteIDs = Set<UUID>()

    var body: some View {
        NavigationStack {
            // Displays the selectable/reorderable list of notes.
            List(selection: $selectedNoteIDs) {
                ForEach(store.notes) { note in
                    // Renders a single note row with title and content preview.
                    VStack(alignment: .leading, spacing: 4) {
                        Text(note.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "" : note.title)
                            .font(.headline)
                            .lineLimit(1)
                        Text(note.content)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        if editMode == .active {
                            if selectedNoteIDs.contains(note.id) {
                                selectedNoteIDs.remove(note.id)
                            } else {
                                selectedNoteIDs.insert(note.id)
                            }
                        } else {
                            onSelectNote?(note)
                        }
                    }
                    .tag(note.id)
                    .deleteDisabled(editMode == .active)
                }
                .onMove(perform: store.moveNotes)
                .onDelete(perform: store.deleteNotes)
            }
            .listStyle(.plain)
            .navigationBarTitleDisplayMode(.inline)
            .onAppear {
                store.reload()
            }
            .onChange(of: editMode) { _, newValue in
                if newValue == .inactive {
                    selectedNoteIDs.removeAll()
                }
            }
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    // Shows bulk-delete action while edit mode is active.
                    if editMode == .active {
                        Button {
                            store.deleteNotes(ids: selectedNoteIDs)
                            selectedNoteIDs.removeAll()
                        } label: {
                            Image(systemName: "trash")
                                .font(.system(size: 16))
                                .frame(width: 32, height: 32)
                        }
                        .accessibilityLabel("Delete Selected Notes")
                        .disabled(selectedNoteIDs.isEmpty)
                    }

                    // Toggles multi-select editing mode for list operations.
                    Button {
                        editMode = editMode == .active ? .inactive : .active
                    } label: {
                        Image(systemName: editMode == .active ? "checkmark.circle" : "pencil")
                            .font(.system(size: 16))
                            .frame(width: 32, height: 32)
                    }
                    .accessibilityLabel(editMode == .active ? "Done Editing" : "Edit All")

                    // Creates a new note using callback override or store default behavior.
                    Button {
                        if let onCreateNote {
                            onCreateNote()
                        } else {
                            store.addNote()
                        }
                    } label: {
                        Image(systemName: "square.and.pencil")
                            .font(.system(size: 16))
                            .frame(width: 32, height: 32)
                    }
                    .accessibilityLabel("New Note")
                }
            }
            .environment(\.editMode, $editMode)
        }
        .toolbar(.visible, for: .tabBar)
    }
}

#Preview {
    ContentView(selectedTab: .notes)
}
