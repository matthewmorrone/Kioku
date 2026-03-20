import SwiftUI

// Hosts top-level tab navigation and shared app state wiring.
struct ContentView: View {
    @State private var selectedTab: ContentTab
    @StateObject private var notesStore = NotesStore()
    @StateObject private var wordsStore = WordsStore()
    @StateObject private var wordListsStore = WordListsStore()
    @StateObject private var historyStore = HistoryStore()
    @State private var selectedReadNote: Note?
    @State private var shouldActivateReadEditMode = false
    @State private var segmenter = Segmenter(trie: DictionaryTrie())
    @State private var dictionaryStore: DictionaryStore?
    @State private var lexicon: Lexicon?
    @State private var readingBySurface: [String: String] = [:]
    @State private var readingCandidatesBySurface: [String: [String]] = [:]
    @State private var frequencyDataBySurface: [String: [String: FrequencyData]] = [:]
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
            ReadView(selectedNote: $selectedReadNote, shouldActivateEditModeOnLoad: $shouldActivateReadEditMode, segmenter: segmenter, dictionaryStore: dictionaryStore, lexicon: lexicon, readingBySurface: readingBySurface, readingCandidatesBySurface: readingCandidatesBySurface, frequencyDataBySurface: frequencyDataBySurface, segmenterRevision: segmenterRevision, readResourcesReady: readResourcesReady, onActiveNoteChanged: { id in
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
                // Pass a fresh note directly without adding it to the store so that the note
                // is only persisted once the user types content into the editor.
                let newNote = Note()
                shouldActivateReadEditMode = true
                selectedReadNote = newNote
                lastActiveNoteID = newNote.id.uuidString
                selectedTab = .read
            }, onUpdateSelectedNote: { updatedNote in
                if let currentSelectedReadNote = selectedReadNote, let updatedNote, updatedNote.id == currentSelectedReadNote.id {
                    selectedReadNote = updatedNote
                    lastActiveNoteID = updatedNote.id.uuidString
                    return
                }

                // When the updated note is the currently active note in the read view (selectedReadNote
                // is nil after initial load), re-set it to trigger a reload so in-memory state stays in sync.
                if let updatedNote, let activeNoteID = UUID(uuidString: lastActiveNoteID), updatedNote.id == activeNoteID {
                    selectedReadNote = updatedNote
                    return
                }

                if updatedNote == nil {
                    if let currentSelectedReadNote = selectedReadNote, notesStore.note(withID: currentSelectedReadNote.id) == nil {
                        selectedReadNote = nil
                        lastActiveNoteID = ""
                    } else if let activeNoteID = UUID(uuidString: lastActiveNoteID), notesStore.note(withID: activeNoteID) == nil {
                        lastActiveNoteID = ""
                    }
                }
            })
            .tag(ContentTab.notes)
            .tabItem {
                Label("Notes", systemImage: "text.line.magnify")
            }

            // Renders the Words tab entry point.
            WordsView(dictionaryStore: dictionaryStore)
                .environmentObject(wordsStore)
                .environmentObject(wordListsStore)
                .environmentObject(historyStore)
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
        .environmentObject(wordsStore)
        .environmentObject(wordListsStore)
        .environmentObject(historyStore)
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

        Task(priority: .utility) {
            let readResources = Self.makeReadResources()
            segmenter = readResources.segmenter
            dictionaryStore = readResources.dictionaryStore
            lexicon = readResources.lexicon
            readingBySurface = readResources.readingBySurface
            readingCandidatesBySurface = readResources.readingCandidatesBySurface
            frequencyDataBySurface = readResources.frequencyDataBySurface
            readResourcesReady = true
            segmenterRevision += 1
        }
    }

    // Builds the read-tab segmenter and dictionary store used for furigana lookup.
    private static func makeReadResources() -> (segmenter: Segmenter, dictionaryStore: DictionaryStore?, lexicon: Lexicon?, readingBySurface: [String: String], readingCandidatesBySurface: [String: [String]], frequencyDataBySurface: [String: [String: FrequencyData]]) {
        let trie = DictionaryTrie()
        var dictionaryStore: DictionaryStore?
        var lexicon: Lexicon?
        var readingBySurface: [String: String] = [:]
        var readingCandidatesBySurface: [String: [String]] = [:]
        var frequencyDataBySurface: [String: [String: FrequencyData]] = [:]
        var deinflector: Deinflector?

        do {
            let store = try DictionaryStore()
            dictionaryStore = store

            do { readingBySurface = try store.fetchPreferredReadingsBySurface() }
            catch { print("fetchPreferredReadingsBySurface failed: \(error)") }

            do { readingCandidatesBySurface = try store.fetchReadingCandidatesBySurface() }
            catch { print("fetchReadingCandidatesBySurface failed: \(error)") }

            do { frequencyDataBySurface = try store.fetchFrequencyDataBySurface() }
            catch { print("fetchFrequencyDataBySurface failed: \(error)") }

            do {
                let surfaces = try store.fetchAllSurfaces()
                for surface in surfaces { trie.insert(surface) }
            } catch { print("fetchAllSurfaces failed: \(error)") }

        } catch {
            print("DictionaryStore initialization failed: \(error)")
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

        let segmenter = Segmenter(trie: trie, deinflector: deinflector)

        if let deinflector {
            lexicon = Lexicon(
                dictionaryStore: dictionaryStore,
                segmenter: segmenter,
                deinflector: deinflector,
                readingBySurface: readingBySurface
            )
        } else {
            print("Lexicon data surface initialization failed: missing deinflector")
        }

        return (
            segmenter: segmenter,
            dictionaryStore: dictionaryStore,
            lexicon: lexicon,
            readingBySurface: readingBySurface,
            readingCandidatesBySurface: readingCandidatesBySurface,
            frequencyDataBySurface: frequencyDataBySurface
        )
    }
}

#Preview {
    ContentView()
}
