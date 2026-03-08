import SwiftUI

// Provides the primary reading and editing surface for an active note.
struct ReadView: View {
    @Binding var selectedNote: Note?
    let segmenter: Segmenter
    let dictionaryStore: DictionaryStore?
    let segmenterRevision: Int
    let readResourcesReady: Bool
    var onActiveNoteChanged: ((UUID) -> Void)? = nil

    @AppStorage(TypographySettings.textSizeKey) 
    private var textSize = TypographySettings.defaultTextSize
    @AppStorage(TypographySettings.lineSpacingKey) 
    private var lineSpacing = TypographySettings.defaultLineSpacing
    @AppStorage(TypographySettings.kerningKey) 
    private var kerning = TypographySettings.defaultKerning

    @State private var customTitle = ""
    @State private var fallbackTitle = ""
    @State private var titleDraft = ""
    @State private var isShowingTitleAlert = false
    @State private var text = ""
    @State private var segmentationRanges: [Range<String.Index>] = []
    @State private var furiganaBySegmentLocation: [Int: String] = [:]
    @State private var furiganaCache: [String: String?] = [:]
    @State private var activeNoteID: UUID?
    @State private var isLoadingSelectedNote = false
    @State private var isEditMode = false

    private let storageKey = "kioku.notes.v1"

    var body: some View {
        NavigationStack {
            // Displays the editable note title at the top of the reading screen.
            Text(displayTitle)
                .font(.system(size: 24, weight: .bold))
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.vertical, 8)
                .onTapGesture {
                    titleDraft = resolvedTitle
                    isShowingTitleAlert = true
                }
                .alert("Edit Title", isPresented: $isShowingTitleAlert) {
                    TextField("Title", text: $titleDraft)
                    Button("Cancel", role: .cancel) {}
                    Button("Save") {
                        customTitle = titleDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                        persistCurrentNoteIfNeeded()
                    }
                }
            VStack(spacing: 10) {
                // Displays either the custom furigana reading renderer or editable text surface.
                Group {
                    if isEditMode {
                        RichTextEditor(
                            text: $text,
                            segmentationRanges: readResourcesReady ? segmentationRanges : [],
                            furiganaBySegmentLocation: readResourcesReady ? furiganaBySegmentLocation : [:],
                            isVisualEnhancementsEnabled: readResourcesReady,
                            isEditMode: isEditMode,
                            textSize: $textSize,
                            lineSpacing: lineSpacing,
                            kerning: kerning
                        )
                    } else {
                        FuriganaTextRenderer(
                            text: text,
                            segmentationRanges: readResourcesReady ? segmentationRanges : [],
                            furiganaBySegmentLocation: readResourcesReady ? furiganaBySegmentLocation : [:],
                            isVisualEnhancementsEnabled: readResourcesReady,
                            textSize: $textSize,
                            lineSpacing: lineSpacing,
                            kerning: kerning
                        )
                    }
                }
                    .padding(8)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(
                        RoundedRectangle(cornerRadius: 16)
                            .fill(isEditMode ? Color(.systemBackground) : Color(.secondarySystemBackground))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 16)
                            .stroke(
                                isEditMode ? Color.accentColor.opacity(0.45) : Color.secondary.opacity(0.3),
                                lineWidth: isEditMode ? 2 : 1
                            )
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                    .padding(.horizontal, 8)

                // Renders a single unlabeled button that toggles between view and edit modes.
                HStack {
                    Spacer()
                    // Uses one icon button whose visual treatment reflects active edit state.
                    Button {
                        isEditMode.toggle()
                    } label: {
                        Image(systemName: "pencil")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(isEditMode ? Color.white : Color.secondary)
                            .frame(width: 36, height: 36)
                            .background(
                                Circle()
                                    .fill(isEditMode ? Color.accentColor : Color(.tertiarySystemFill))
                            )
                    }
                    .buttonStyle(PlainButtonStyle())
                    .opacity(isEditMode ? 1 : 0.7)
                    .accessibilityLabel(isEditMode ? "Disable Edit Mode" : "Enable Edit Mode")
                }
                .padding(.horizontal, 8)
            }
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 12)
        .toolbar(.visible, for: .tabBar)
        .onAppear {
            // Syncs editor state when this screen first appears.
            loadSelectedNoteIfNeeded()
        }
        .onChange(of: selectedNote?.id) { _, _ in
            // Syncs editor state when Notes tab selects a different note.
            loadSelectedNoteIfNeeded()
        }
        .onChange(of: text) { _, _ in
            // Persists edits as content changes.
            persistCurrentNoteIfNeeded()
            // Recomputes segments only after full read resources are ready.
            if readResourcesReady {
                refreshSegmentationRanges()
            }
        }
        .onChange(of: segmenterRevision) { _, _ in
            // Recomputes segmentation after background dictionary loading completes.
            refreshSegmentationRanges()
        }
    }

    // Loads the selected note into editor state when navigation targets change.
    private func loadSelectedNoteIfNeeded() {
        guard let selectedNote else { return }
        isLoadingSelectedNote = true
        activeNoteID = selectedNote.id
        onActiveNoteChanged?(selectedNote.id)
        customTitle = selectedNote.title
        fallbackTitle = selectedNote.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? firstLineTitle(from: selectedNote.content)
            : selectedNote.title
        text = selectedNote.content
        refreshSegmentationRanges()
        self.selectedNote = nil
        isLoadingSelectedNote = false
    }

    // Saves the in-memory editor state to storage and maintains active note identity.
    private func persistCurrentNoteIfNeeded() {
        guard !isLoadingSelectedNote else { return }

        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // Avoid creating an empty note when the editor has no active note yet.
        if trimmedText.isEmpty && activeNoteID == nil {
            return
        }

        var notes = loadNotesFromStorage()
        // Prefer explicit titles; otherwise derive one from first content line.
        let titleToSave = customTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? firstLineTitle(from: text)
            : customTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        fallbackTitle = titleToSave

        if let activeNoteID, let index = notes.firstIndex(where: { $0.id == activeNoteID }) {
            // Update the existing note in place when editing an active item.
            notes[index].title = titleToSave
            notes[index].content = text
        } else {
            // Insert a new note only when no active note identity exists.
            let newNote = Note(title: titleToSave, content: text)
            notes.insert(newNote, at: 0)
            activeNoteID = newNote.id
            onActiveNoteChanged?(newNote.id)
        }

        if let activeNoteID {
            onActiveNoteChanged?(activeNoteID)
        }

        saveNotesToStorage(notes)
    }

    // Reads note payloads from user defaults storage.
    private func loadNotesFromStorage() -> [Note] {
        guard
            let data = UserDefaults.standard.data(forKey: storageKey),
            let decoded = try? JSONDecoder().decode([Note].self, from: data)
        else {
            return []
        }

        return decoded
    }

    // Writes note payloads to user defaults storage.
    private func saveNotesToStorage(_ notes: [Note]) {
        guard let encoded = try? JSONEncoder().encode(notes) else { return }
        UserDefaults.standard.set(encoded, forKey: storageKey)
    }

    private var resolvedTitle: String {
        let trimmedCustom = customTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedCustom.isEmpty {
            return trimmedCustom
        }

        return fallbackTitle
    }

    private var displayTitle: String {
        resolvedTitle.isEmpty ? " " : resolvedTitle
    }

    // Derives a fallback title from the first line of note content.
    private func firstLineTitle(from content: String) -> String {
        let firstLine = content.components(separatedBy: .newlines).first?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return firstLine
    }

    // Rebuilds greedy segmentation ranges used by alternating segment colors in the editor.
    private func refreshSegmentationRanges() {
        guard readResourcesReady else {
            segmentationRanges = []
            furiganaBySegmentLocation = [:]
            return
        }

        let refreshedSegments = segmenter.longestMatchSegments(for: text)
        segmentationRanges = refreshedSegments
        furiganaBySegmentLocation = buildFuriganaBySegmentLocation(for: text, segments: refreshedSegments)
    }

    // Resolves per-segment furigana keyed by UTF-16 location so UIKit ranges can apply ruby text.
    private func buildFuriganaBySegmentLocation(for sourceText: String, segments: [Range<String.Index>]) -> [Int: String] {
        var resolvedFurigana: [Int: String] = [:]

        for segmentRange in segments {
            let segmentSurface = String(sourceText[segmentRange])
            // Skip non-kanji segments to avoid redundant ruby annotations.
            guard ScriptClassifier.containsKanji(segmentSurface) else {
                continue
            }

            guard let reading = readingForSegment(segmentSurface), !reading.isEmpty, reading != segmentSurface else {
                continue
            }

            let nsRange = NSRange(segmentRange, in: sourceText)
            if nsRange.location == NSNotFound || nsRange.length == 0 {
                continue
            }

            resolvedFurigana[nsRange.location] = reading
        }

        return resolvedFurigana
    }

    // Looks up a segment reading and caches it for subsequent furigana rendering passes.
    private func readingForSegment(_ segmentSurface: String) -> String? {
        if let cachedReading = furiganaCache[segmentSurface] {
            return cachedReading
        }

        guard let dictionaryStore else {
            furiganaCache[segmentSurface] = nil
            return nil
        }

        do {
            let entries = try dictionaryStore.lookup(surface: segmentSurface, mode: .kanjiAndKana)
            let bestReading = entries.first?.kanaForms.first
            furiganaCache[segmentSurface] = bestReading
            return bestReading
        } catch {
            print("Furigana lookup failed for \(segmentSurface): \(error)")
            furiganaCache[segmentSurface] = nil
            return nil
        }
    }
}

#Preview {
    ReadView(selectedNote: .constant(nil), segmenter: Segmenter(trie: DictionaryTrie()), dictionaryStore: nil, segmenterRevision: 0, readResourcesReady: false)
}
