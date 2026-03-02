import SwiftUI

// Hosts top-level tab navigation and shared app state wiring.
struct ContentView: View {
    @State private var selectedTab: ContentTab
    @StateObject private var notesStore = NotesStore()
    @State private var selectedReadNote: Note?
    @AppStorage("kioku.lastActiveNoteID") private var lastActiveNoteID = ""

    // Initializes the selected tab so previews and deep links can choose an initial section.
    init(selectedTab: ContentTab = .read) {
        _selectedTab = State(initialValue: selectedTab)
    }

    var body: some View {
        TabView(selection: $selectedTab) {
            // Renders the Read tab screen and keeps last-active note tracking in sync.
            ReadView(selectedNote: $selectedReadNote, onActiveNoteChanged: { id in
                lastActiveNoteID = id.uuidString
            })
            .tag(ContentTab.read)
            .tabItem {
                Label("Read", systemImage: "book")
            }

            // Renders the Notes tab list and routes selected/new notes into the Read tab.
            NotesView(onSelectNote: { note in
                selectedReadNote = note
                lastActiveNoteID = note.id.uuidString
                selectedTab = .read
            }, onCreateNote: {
                notesStore.addNote()
                guard let note = notesStore.notes.first else { return }

                selectedReadNote = note
                lastActiveNoteID = note.id.uuidString
                selectedTab = .read
            })
            .tag(ContentTab.notes)
            .tabItem {
                Label("Notes", systemImage: "text.line.magnify")
            }

            // Renders the Words tab entry point.
            WordsView()
            .tag(ContentTab.words)
            .tabItem {
                Label("Words", systemImage: "text.page.badge.magnifyingglass")
            }

            // Renders the Learn tab entry point.
            LearnView()
            .tag(ContentTab.learn)
            .tabItem {
                Label("Learn", systemImage: "rectangle.on.rectangle.angled")
            }

            // Renders the Settings tab entry point.
            SettingsView()
            .tag(ContentTab.settings)
            .tabItem {
                Label("Settings", systemImage: "gear")
            }
        }
        .environmentObject(notesStore)
        .onAppear {
            restoreLastActiveNote()
        }
    }

    // Restores the previously active note so users return to their last reading context.
    private func restoreLastActiveNote() {
        guard let noteID = UUID(uuidString: lastActiveNoteID) else { return }

        notesStore.reload()
        guard let note = notesStore.notes.first(where: { $0.id == noteID }) else { return }

        selectedReadNote = note
        selectedTab = .read
    }
}

#Preview {
    ContentView()
}
