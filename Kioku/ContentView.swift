import SwiftUI

struct ContentView: View {
    enum Tab: Hashable {
        case read
        case notes
        case words
        case learn
        case settings
    }

    @State private var selectedTab: Tab
    @StateObject private var notesStore = NotesStore()
    @State private var selectedReadNote: Note?
    @AppStorage("kioku.lastActiveNoteID") private var lastActiveNoteID = ""

    init(selectedTab: Tab = .read) {
        _selectedTab = State(initialValue: selectedTab)
    }

    var body: some View {
        TabView(selection: $selectedTab) {
            ReadView(selectedNote: $selectedReadNote, onActiveNoteChanged: { id in
                lastActiveNoteID = id.uuidString
            })
            .tag(Tab.read)
            .tabItem {
                Label("Read", systemImage: "book")
            }

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
            .tag(Tab.notes)
            .tabItem {
                Label("Notes", systemImage: "text.line.magnify")
            }

            WordsView()
            .tag(Tab.words)
            .tabItem {
                Label("Words", systemImage: "text.page.badge.magnifyingglass")
            }

            LearnView()
            .tag(Tab.learn)
            .tabItem {
                Label("Learn", systemImage: "rectangle.on.rectangle.angled")
            }

            SettingsView()
            .tag(Tab.settings)
            .tabItem {
                Label("Settings", systemImage: "gear")
            }
        }
        .environmentObject(notesStore)
        .onAppear {
            restoreLastActiveNote()
        }
    }

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
