import SwiftUI
import UniformTypeIdentifiers

// Sheet for the "subtitle file → vocabulary list" flow (Feature A). The user picks an SRT or ASS
// subtitle file; the view segments and lemmatizes every line, extracts the unique dictionary-backed
// vocabulary needed to understand the episode, and saves it to a new or existing word list — with an
// option to also keep the subtitle text as a note. Mirrors CSVImportView's structure (file picker →
// list assignment → preview → import) and its off-main-thread resolution so a full episode's
// segmentation never blocks the UI.
struct SubtitleImportView: View {
    let dictionaryStore: DictionaryStore?
    let segmenter: (any TextSegmenting)?
    // Reading maps for furigana precompute, so the saved note stores furigana too and opens with
    // zero recomputation (not just segmentation). Default-empty for callers/previews without them.
    var surfaceReadingData: SurfaceReadingDataMap = SurfaceReadingDataMap()
    var kanjiReadingFallback: KanjiReadingFallbackMap = KanjiReadingFallbackMap()
    // When set (the online-search handoff), this file is processed automatically on appear and the
    // manual file picker is hidden — the user arrived here with a file already chosen.
    var initialFileURL: URL? = nil

    @EnvironmentObject private var wordsStore: WordsStore
    @EnvironmentObject private var wordListsStore: WordListsStore
    @EnvironmentObject private var notesStore: NotesStore

    @Environment(\.dismiss) private var dismiss

    @State private var isFileImporterPresented = false
    @State private var fileName: String = ""
    @State private var cueCount: Int = 0
    @State private var assembledText: String = ""
    @State private var extracted: [SubtitleVocabExtractor.ExtractedVocab] = []
    // Whole-body segmentation computed at import time and persisted on the saved note so it opens
    // via ReadView's synchronous fast path instead of re-segmenting a large episode on first open.
    @State private var precomputedSegments: [SegmentRange] = []
    @State private var isProcessing = false
    @State private var errorText: String? = nil

    @State private var addToListMode: CSVImportListMode = .new
    @State private var selectedExistingListID: UUID? = nil
    @State private var newListName: String = ""
    @State private var saveAsNote = true

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                if initialFileURL == nil {
                    filePicker
                }
                if extracted.isEmpty == false || cueCount > 0 {
                    summary
                    listControls
                    Toggle("Also save subtitles as a note", isOn: $saveAsNote)
                }
                if let errorText {
                    Text(errorText)
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                Spacer()
                importButton
            }
            .padding()
            .navigationTitle("Import Subtitles")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            .fileImporter(
                isPresented: $isFileImporterPresented,
                allowedContentTypes: [
                    UTType(filenameExtension: "srt") ?? .plainText,
                    UTType(filenameExtension: "ass") ?? .plainText,
                    UTType(filenameExtension: "ssa") ?? .plainText,
                    .plainText,
                ],
                allowsMultipleSelection: false
            ) { result in
                handlePickedFile(result)
            }
            .task {
                // Online-search handoff: a file was already chosen, so process it immediately.
                if let initialFileURL, fileName.isEmpty {
                    processFile(at: initialFileURL)
                }
            }
        }
    }

    private var filePicker: some View {
        Button {
            isFileImporterPresented = true
        } label: {
            Label(fileName.isEmpty ? "Choose Subtitle File (.srt / .ass)" : fileName,
                  systemImage: "doc.text")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
    }

    private var summary: some View {
        VStack(alignment: .leading, spacing: 4) {
            if isProcessing {
                HStack(spacing: 8) {
                    ProgressView()
                    Text("Segmenting…")
                }
            } else {
                Text("\(cueCount) subtitle lines")
                Text("\(extracted.count) vocabulary words to save")
                    .fontWeight(.semibold)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var listControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("Save to", selection: $addToListMode) {
                Text("New list").tag(CSVImportListMode.new)
                Text("Existing list").tag(CSVImportListMode.existing)
                Text("No list").tag(CSVImportListMode.none)
            }
            .pickerStyle(.segmented)

            switch addToListMode {
            case .new:
                TextField("List name", text: $newListName)
                    .textFieldStyle(.roundedBorder)
            case .existing:
                if wordListsStore.lists.isEmpty {
                    Text("No lists yet — switch to “New list”.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    Picker("List", selection: $selectedExistingListID) {
                        Text("Select…").tag(UUID?.none)
                        ForEach(wordListsStore.lists) { list in
                            Text(list.name).tag(UUID?.some(list.id))
                        }
                    }
                }
            case .none:
                EmptyView()
            }
        }
    }

    private var importButton: some View {
        Button {
            performImport()
        } label: {
            Text("Save \(extracted.count) Words")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .disabled(extracted.isEmpty || isProcessing)
    }

    // Reads the picked subtitle file, parses it by format, assembles the note body, and runs vocab
    // extraction on a detached task so segmentation never blocks the main actor. Populates the
    // preview state on completion.
    private func handlePickedFile(_ result: Result<[URL], Error>) {
        errorText = nil
        guard let url = try? result.get().first else {
            errorText = "Couldn't open that file."
            return
        }
        processFile(at: url)
    }

    // Parses the subtitle file by format, assembles the note body, and extracts vocab on a detached
    // task (off the main actor) so a full episode's segmentation never blocks the UI. Shared by the
    // manual file picker and the online-search handoff.
    private func processFile(at url: URL) {
        errorText = nil
        fileName = url.lastPathComponent
        let stem = url.deletingPathExtension().lastPathComponent
        if newListName.isEmpty { newListName = stem }

        let isASS = ["ass", "ssa"].contains(url.pathExtension.lowercased())
        let segmenter = segmenter
        let store = dictionaryStore
        let surfaceReadingData = surfaceReadingData
        let kanjiReadingFallback = kanjiReadingFallback
        isProcessing = true

        Task.detached(priority: .userInitiated) {
            guard let text = try? SubtitleSourceLoader.readText(from: url) else {
                await MainActor.run {
                    errorText = "Couldn't read that file."
                    isProcessing = false
                }
                return
            }
            let cues = isASS ? ASSParser.parse(text) : SubtitleParser.parse(text)
            let body = SubtitleParser.assembleNoteContent(from: cues)
            // Segment the body ONCE: the same selected edges drive vocab extraction AND the note's
            // persisted segmentation+furigana. Resolving furigana here too means the saved note opens
            // with ZERO recomputation — segmentation and readings are both restored, not recomputed.
            let edges = segmenter?.longestMatchEdges(for: body) ?? []
            let vocab = SubtitleVocabExtractor.extract(fromEdges: edges, dictionaryStore: store)
            var furiganaByLocation: [Int: String] = [:]
            var furiganaLengthByLocation: [Int: Int] = [:]
            if let segmenter {
                let resolved = FuriganaResolver(segmenter: segmenter, kanjiReadingFallback: kanjiReadingFallback)
                    .build(for: body, edges: edges, surfaceReadingData: surfaceReadingData)
                furiganaByLocation = resolved.byLocation
                furiganaLengthByLocation = resolved.lengthByLocation
            }
            let noteSegments = SegmentRange.ranges(
                from: edges,
                in: body,
                furiganaByLocation: furiganaByLocation,
                furiganaLengthByLocation: furiganaLengthByLocation
            )

            await MainActor.run {
                cueCount = cues.count
                assembledText = body
                extracted = vocab
                precomputedSegments = noteSegments
                isProcessing = false
                if cues.isEmpty {
                    errorText = "No subtitle lines found in that file."
                }
            }
        }
    }

    // Saves the extracted vocab to the chosen list (creating it if needed) and, when enabled, stores
    // the subtitle text as a note. One batched WordsStore.add so the persist cost is paid once.
    private func performImport() {
        guard extracted.isEmpty == false else { return }
        let listIDs = resolveListIDs()

        // Create the note FIRST (when requested) so its id can attribute the saved words. Attribution
        // drives both the in-note highlight (isSavedForNote → filled star + glow) and the
        // note-deletion "associated words" cascade — without it, imported words render hollow and the
        // delete prompt finds nothing to offer.
        var noteIDs: [UUID] = []
        if saveAsNote, assembledText.isEmpty == false {
            // Title from the subtitle's name (extension stripped), preferring the user's list name.
            // Never falls back to a raw filename-with-extension or an empty title.
            let stem = (fileName as NSString).deletingPathExtension
            let title = newListName.isEmpty ? (stem.isEmpty ? "Imported Subtitles" : stem) : newListName
            // Persist the precomputed segmentation so the note opens via ReadView's fast path.
            let noteID = notesStore.upsertNote(
                id: nil,
                title: title,
                content: assembledText,
                segments: precomputedSegments.isEmpty ? nil : precomputedSegments,
                // Precompute persists the *computed* segmentation, not a user edit — keep the
                // marker false so the read screen's reset button stays disabled on first open.
                segmentsAreUserEdited: false
            )
            noteIDs = [noteID]
        }

        let words = extracted.map { item in
            SavedWord(
                canonicalEntryID: item.canonicalEntryID,
                surface: item.lemma,
                sourceNoteIDs: noteIDs,
                wordListIDs: listIDs,
                // Include the lemma alongside the encountered conjugated surfaces so both the lemma
                // row and the surface rows match in the segment list / highlight.
                encounteredSurfaces: item.encounteredSurfaces.union([item.lemma])
            )
        }
        wordsStore.add(words)

        dismiss()
    }

    // Resolves the target list ids, creating a new list when in `.new` mode. `.none` and an
    // unselected `.existing` both yield no membership.
    private func resolveListIDs() -> [UUID] {
        switch addToListMode {
        case .new:
            let name = newListName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard name.isEmpty == false else { return [] }
            return [wordListsStore.create(name: name)]
        case .existing:
            return selectedExistingListID.map { [$0] } ?? []
        case .none:
            return []
        }
    }
}
