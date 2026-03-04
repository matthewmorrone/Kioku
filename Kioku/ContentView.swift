import SwiftUI

// Hosts top-level tab navigation and shared app state wiring.
struct ContentView: View {
    @State private var selectedTab: ContentTab
    @StateObject private var notesStore = NotesStore()
    @State private var selectedReadNote: Note?
    @AppStorage("kioku.lastActiveNoteID") private var lastActiveNoteID = ""
    private let segmenter: Segmenter

    // Initializes the selected tab so previews and deep links can choose an initial section.
    init(selectedTab: ContentTab = .read) {
        _selectedTab = State(initialValue: selectedTab)
        segmenter = Self.makeReadSegmenter()
    }

    var body: some View {
        TabView(selection: $selectedTab) {
            // Renders the Read tab screen and keeps last-active note tracking in sync.
            ReadView(selectedNote: $selectedReadNote, segmenter: segmenter, onActiveNoteChanged: { id in
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

    // Builds the read-tab segmenter from bundled dictionary surfaces for live lattice debugging.
    private static func makeReadSegmenter() -> Segmenter {
        let trie = DictionaryTrie()
        var deinflector: Deinflector?

        do {
            let store = try DictionaryStore()
            let surfaces = try store.fetchAllSurfaces()
            for surface in surfaces {
                trie.insert(surface)
            }
        } catch {
            print("Segmenter initialization failed: \(error)")
        }

        do {
            deinflector = try Deinflector(bundle: .main, resourceName: "deinflection", fileExtension: "json")
        } catch {
            print("Deinflector initialization failed: \(error)")
        }

        return Segmenter(trie: trie, deinflector: deinflector)
    }
}

#Preview {
    ContentView()
}
