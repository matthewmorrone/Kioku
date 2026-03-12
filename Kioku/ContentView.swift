import SwiftUI

// Hosts top-level tab navigation and shared app state wiring.
struct ContentView: View {
    @State private var selectedTab: ContentTab
    @StateObject private var notesStore = NotesStore()
    @State private var selectedReadNote: Note?
    @State private var shouldActivateReadEditMode = false
    @State private var segmenter = Segmenter(trie: DictionaryTrie())
    @State private var dictionaryStore: DictionaryStore?
    @State private var readingBySurface: [String: String] = [:]
    @State private var readingCandidatesBySurface: [String: [String]] = [:]
    @State private var readResourcesReady = false
    @State private var segmenterRevision = 0
    @State private var hasLoadedReadResources = false
    @AppStorage("kioku.lastActiveNoteID") private var lastActiveNoteID = ""

    // Initializes the selected tab so previews and deep links can choose an initial section.
    init(selectedTab: ContentTab = .read) {
        _selectedTab = State(initialValue: selectedTab)
    }

    var body: some View {
        TabView(selection: $selectedTab) {
            // Renders the Read tab screen and keeps last-active note tracking in sync.
            ReadView(selectedNote: $selectedReadNote, shouldActivateEditModeOnLoad: $shouldActivateReadEditMode, segmenter: segmenter, dictionaryStore: dictionaryStore, readingBySurface: readingBySurface, readingCandidatesBySurface: readingCandidatesBySurface, segmenterRevision: segmenterRevision, readResourcesReady: readResourcesReady, onActiveNoteChanged: { id in
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

                shouldActivateReadEditMode = true
                selectedReadNote = note
                lastActiveNoteID = note.id.uuidString
                selectedTab = .read
            }, onUpdateSelectedNote: { updatedNote in
                guard let currentSelectedReadNote = selectedReadNote else {
                    return
                }

                if let updatedNote, updatedNote.id == currentSelectedReadNote.id {
                    selectedReadNote = updatedNote
                    lastActiveNoteID = updatedNote.id.uuidString
                    return
                }

                if updatedNote == nil {
                    if notesStore.note(withID: currentSelectedReadNote.id) == nil {
                        selectedReadNote = nil
                        lastActiveNoteID = ""
                    }
                }
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
            loadReadResourcesIfNeeded()
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

    // Loads heavy read resources asynchronously so initial app launch stays responsive.
    private func loadReadResourcesIfNeeded() {
        guard !hasLoadedReadResources else { return }
        hasLoadedReadResources = true

        Task.detached(priority: .utility) {
            let readResources = Self.makeReadResources()
            await MainActor.run {
                segmenter = readResources.segmenter
                dictionaryStore = readResources.dictionaryStore
                readingBySurface = readResources.readingBySurface
                readingCandidatesBySurface = readResources.readingCandidatesBySurface
                readResourcesReady = true
                segmenterRevision += 1
            }
        }
    }

    // Builds the read-tab segmenter and dictionary store used for furigana lookup.
    private static func makeReadResources() -> (segmenter: Segmenter, dictionaryStore: DictionaryStore?, readingBySurface: [String: String], readingCandidatesBySurface: [String: [String]]) {
        let trie = DictionaryTrie()
        var dictionaryStore: DictionaryStore?
        var readingBySurface: [String: String] = [:]
        var readingCandidatesBySurface: [String: [String]] = [:]
        var deinflector: Deinflector?

        do {
            let store = try DictionaryStore()
            dictionaryStore = store
            readingBySurface = try store.fetchPreferredReadingsBySurface()
            readingCandidatesBySurface = try store.fetchReadingCandidatesBySurface()
            let surfaces = try store.fetchAllSurfaces()
            for surface in surfaces {
                trie.insert(surface)
            }
        } catch {
            print("Segmenter initialization failed: \(error)")
        }

        do {
            deinflector = try Deinflector(
                trie: trie,
                bundle: .main,
                resourceName: "deinflection",
                fileExtension: "json"
            )
        } catch {
            print("Deinflector initialization failed: \(error)")
        }

        return (segmenter: Segmenter(trie: trie, deinflector: deinflector), dictionaryStore: dictionaryStore, readingBySurface: readingBySurface, readingCandidatesBySurface: readingCandidatesBySurface)
    }
}

#Preview {
    ContentView()
}
