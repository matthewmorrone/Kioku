import SwiftUI

// Provides the primary reading and editing surface for an active note.
struct ReadView: View {
    @Binding var selectedNote: Note?
    let segmenter: Segmenter
    let dictionaryStore: DictionaryStore?
    let readingBySurface: [String: String]
    let readingCandidatesBySurface: [String: [String]]
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
    @State private var segmentationEdges: [LatticeEdge] = []
    @State private var segmentationRanges: [Range<String.Index>] = []
    @State private var selectedSegmentLocation: Int?
    @State private var furiganaBySegmentLocation: [Int: String] = [:]
    @State private var furiganaLengthBySegmentLocation: [Int: Int] = [:]
    @State private var furiganaComputationTask: Task<Void, Never>?
    @State private var activeNoteID: UUID?
    @State private var isLoadingSelectedNote = false
    @State private var isEditMode = false
    @State private var sharedScrollOffsetY: CGFloat = 0

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
                // Keeps both read and edit renderers mounted so mode toggles are instant.
                ZStack {
                    FuriganaTextRenderer(
                        isActive: isEditMode == false,
                        text: text,
                        segmentationRanges: readResourcesReady ? segmentationRanges : [],
                        selectedSegmentLocation: selectedSegmentLocation,
                        furiganaBySegmentLocation: readResourcesReady ? furiganaBySegmentLocation : [:],
                        furiganaLengthBySegmentLocation: readResourcesReady ? furiganaLengthBySegmentLocation : [:],
                        isVisualEnhancementsEnabled: readResourcesReady,
                        externalContentOffsetY: sharedScrollOffsetY,
                        onScrollOffsetYChanged: { newOffsetY in
                            sharedScrollOffsetY = newOffsetY
                        },
                        onSegmentTapped: { tappedSegmentLocation in
                            // Toggles the selected segment highlight for tapped ranges.
                            if selectedSegmentLocation == tappedSegmentLocation {
                                selectedSegmentLocation = nil
                            } else {
                                selectedSegmentLocation = tappedSegmentLocation
                            }
                        },
                        textSize: $textSize,
                        lineSpacing: lineSpacing,
                        kerning: kerning
                    )
                    .opacity(isEditMode ? 0 : 1)
                    .allowsHitTesting(isEditMode == false)

                    RichTextEditor(
                        text: $text,
                        segmentationRanges: readResourcesReady ? segmentationRanges : [],
                        furiganaBySegmentLocation: readResourcesReady ? furiganaBySegmentLocation : [:],
                        furiganaLengthBySegmentLocation: readResourcesReady ? furiganaLengthBySegmentLocation : [:],
                        isVisualEnhancementsEnabled: readResourcesReady,
                        isEditMode: isEditMode,
                        externalContentOffsetY: sharedScrollOffsetY,
                        onScrollOffsetYChanged: { newOffsetY in
                            sharedScrollOffsetY = newOffsetY
                        },
                        textSize: $textSize,
                        lineSpacing: lineSpacing,
                        kerning: kerning
                    )
                    .opacity(isEditMode ? 1 : 0)
                    .allowsHitTesting(isEditMode)
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
            if isEditMode {
                // Clears stale range state while editing so view-mode reactivation never reads mismatched ranges.
                furiganaComputationTask?.cancel()
                segmentationEdges = []
                segmentationRanges = []
                selectedSegmentLocation = nil
                furiganaBySegmentLocation = [:]
                furiganaLengthBySegmentLocation = [:]
                return
            }
            // Recomputes segments only after full read resources are ready.
            if readResourcesReady && isEditMode == false {
                refreshSegmentationRanges()
            }
        }
        .onChange(of: isEditMode) { _, editing in
            if editing {
                // Suspends furigana computation while editing text.
                furiganaComputationTask?.cancel()
                segmentationEdges = []
                segmentationRanges = []
                selectedSegmentLocation = nil
                furiganaBySegmentLocation = [:]
                furiganaLengthBySegmentLocation = [:]
            } else if readResourcesReady {
                // Recomputes once when returning to view mode so furigana matches latest text.
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
            furiganaComputationTask?.cancel()
            segmentationEdges = []
            segmentationRanges = []
            selectedSegmentLocation = nil
            furiganaBySegmentLocation = [:]
            furiganaLengthBySegmentLocation = [:]
            return
        }

        let refreshedEdges = segmenter.longestMatchEdges(for: text)
        segmentationEdges = refreshedEdges
        segmentationRanges = refreshedEdges.map { edge in
            edge.start..<edge.end
        }

        // Clears stale selection if the tapped segment no longer exists after recomputing ranges.
        if let selectedSegmentLocation {
            let hasSelectedSegment = segmentationRanges.contains { segmentRange in
                let nsRange = NSRange(segmentRange, in: text)
                return nsRange.location == selectedSegmentLocation && nsRange.length > 0
            }
            if hasSelectedSegment == false {
                self.selectedSegmentLocation = nil
            }
        }

        scheduleFuriganaGeneration(for: text, edges: refreshedEdges)
    }

    // Computes furigana off-main and applies only the latest result for the current editor text.
    private func scheduleFuriganaGeneration(for sourceText: String, edges: [LatticeEdge]) {
        furiganaComputationTask?.cancel()
        let currentReadingBySurface = readingBySurface
        let currentReadingCandidatesBySurface = readingCandidatesBySurface

        furiganaComputationTask = Task(priority: .utility) {
            let furiganaResult = buildFuriganaBySegmentLocation(
                for: sourceText,
                edges: edges,
                readingBySurface: currentReadingBySurface,
                readingCandidatesBySurface: currentReadingCandidatesBySurface
            )

            guard !Task.isCancelled else {
                return
            }

            await MainActor.run {
                guard text == sourceText else {
                    return
                }

                furiganaBySegmentLocation = furiganaResult.furiganaByLocation
                furiganaLengthBySegmentLocation = furiganaResult.lengthByLocation
            }
        }
    }

    // Resolves per-segment furigana keyed by UTF-16 location so UIKit ranges can apply ruby text.
    private func buildFuriganaBySegmentLocation(
        for sourceText: String,
        edges: [LatticeEdge],
        readingBySurface: [String: String],
        readingCandidatesBySurface: [String: [String]]
    ) -> (furiganaByLocation: [Int: String], lengthByLocation: [Int: Int]) {
        var resolvedFurigana: [Int: String] = [:]
        var resolvedFuriganaLengths: [Int: Int] = [:]

        for edge in edges {
            let segmentRange = edge.start..<edge.end
            let segmentSurface = edge.surface
            // Skip non-kanji segments to avoid redundant ruby annotations.
            guard ScriptClassifier.containsKanji(segmentSurface) else {
                continue
            }

            let annotations = furiganaAnnotations(
                for: segmentSurface,
                segmentRange: segmentRange,
                sourceText: sourceText,
                lemmaReference: edge.lemma,
                readingBySurface: readingBySurface,
                readingCandidatesBySurface: readingCandidatesBySurface
            )
            if annotations.isEmpty {
                continue
            }

            for annotation in annotations {
                guard let localStart = sourceText.index(
                    segmentRange.lowerBound,
                    offsetBy: annotation.localStartOffset,
                    limitedBy: segmentRange.upperBound
                ) else {
                    continue
                }

                guard let localEnd = sourceText.index(
                    localStart,
                    offsetBy: annotation.localLength,
                    limitedBy: segmentRange.upperBound
                ) else {
                    continue
                }

                let nsRange = NSRange(localStart..<localEnd, in: sourceText)
                if nsRange.location == NSNotFound || nsRange.length == 0 {
                    continue
                }

                resolvedFurigana[nsRange.location] = annotation.reading
                resolvedFuriganaLengths[nsRange.location] = nsRange.length
            }
        }

        return (furiganaByLocation: resolvedFurigana, lengthByLocation: resolvedFuriganaLengths)
    }

    // Produces kanji-run furigana annotations, including mixed forms with multiple kanji clusters.
    private func furiganaAnnotations(
        for segmentSurface: String,
        segmentRange: Range<String.Index>,
        sourceText: String,
        lemmaReference: String,
        readingBySurface: [String: String],
        readingCandidatesBySurface: [String: [String]]
    ) -> [(reading: String, localStartOffset: Int, localLength: Int)] {
        let runs = kanjiRuns(in: segmentSurface)
        guard runs.isEmpty == false else {
            return []
        }

        let preferKunyomiForContext = shouldPreferKunyomiForSingleKanji(
            surface: segmentSurface,
            in: sourceText,
            segmentRange: segmentRange
        )

        if runs.count == 1,
              let lemmaReading = readingForSegment(
                     lemmaReference,
                     readingBySurface: readingBySurface,
                     readingCandidatesBySurface: readingCandidatesBySurface,
                preferKunyomiForStandaloneKanji: preferKunyomiForContext
              ),
           let lemmaCoreReading = firstKanjiRunReading(in: lemmaReference, using: lemmaReading) {
            return [
                (
                    reading: lemmaCoreReading,
                    localStartOffset: runs[0].start,
                    localLength: runs[0].end - runs[0].start
                )
            ]
        }

        let lemmaRuns = kanjiRuns(in: lemmaReference)
        var projectedReadings: [String]?
        if let lemmaReading = readingForSegment(
            lemmaReference,
            readingBySurface: readingBySurface,
            readingCandidatesBySurface: readingCandidatesBySurface,
            preferKunyomiForStandaloneKanji: preferKunyomiForContext
        ), lemmaRuns.count == runs.count {
            projectedReadings = projectRunReadings(surface: lemmaReference, reading: lemmaReading)
        }

        if projectedReadings == nil,
           let surfaceReading = readingForSegment(
                segmentSurface,
                readingBySurface: readingBySurface,
                readingCandidatesBySurface: readingCandidatesBySurface,
                preferKunyomiForStandaloneKanji: preferKunyomiForContext
           ) {
            projectedReadings = projectRunReadings(surface: segmentSurface, reading: surfaceReading)
        }

        var annotations: [(reading: String, localStartOffset: Int, localLength: Int)] = []
        if let projectedReadings, projectedReadings.count == runs.count {
            for (index, run) in runs.enumerated() {
                let runSurface = String(Array(segmentSurface)[run.start..<run.end])
                let runReading = projectedReadings[index]
                if runReading.isEmpty || runReading == runSurface {
                    continue
                }
                annotations.append((reading: runReading, localStartOffset: run.start, localLength: run.end - run.start))
            }
        }

        if annotations.isEmpty {
            for run in runs {
                let runSurface = String(Array(segmentSurface)[run.start..<run.end])
                guard let runReading = readingForSegment(
                    runSurface,
                    readingBySurface: readingBySurface,
                    readingCandidatesBySurface: readingCandidatesBySurface,
                    preferKunyomiForStandaloneKanji: false
                ), runReading != runSurface else {
                    continue
                }

                annotations.append((reading: runReading, localStartOffset: run.start, localLength: run.end - run.start))
            }
        }

        return annotations
    }

    // Splits a surface reading into per-kanji-run readings using kana delimiters from the source surface.
    private func projectRunReadings(surface: String, reading: String) -> [String]? {
        let runs = kanjiRuns(in: surface)
        guard runs.isEmpty == false else {
            return nil
        }

        let surfaceCharacters = Array(surface)
        var readingCursor = reading.startIndex

        let prefixSurface = runs[0].start > 0 ? String(surfaceCharacters[0..<runs[0].start]) : ""
        if !prefixSurface.isEmpty, reading[readingCursor...].hasPrefix(prefixSurface) {
            readingCursor = reading.index(readingCursor, offsetBy: prefixSurface.count)
        }

        var runReadings: [String] = []
        for runIndex in runs.indices {
            let run = runs[runIndex]
            let separatorAfterRun: String
            if runIndex + 1 < runs.count {
                separatorAfterRun = String(surfaceCharacters[run.end..<runs[runIndex + 1].start])
            } else {
                separatorAfterRun = run.end < surfaceCharacters.count
                    ? String(surfaceCharacters[run.end..<surfaceCharacters.count])
                    : ""
            }

            if separatorAfterRun.isEmpty {
                let remaining = String(reading[readingCursor...])
                runReadings.append(remaining)
                readingCursor = reading.endIndex
                continue
            }

            guard let separatorRange = reading.range(of: separatorAfterRun, range: readingCursor..<reading.endIndex) else {
                return nil
            }

            let runReading = String(reading[readingCursor..<separatorRange.lowerBound])
            runReadings.append(runReading)
            readingCursor = separatorRange.upperBound
        }

        if readingCursor < reading.endIndex {
            if let last = runReadings.indices.last {
                runReadings[last] += String(reading[readingCursor..<reading.endIndex])
            }
        }

        return runReadings
    }

    // Detects contiguous kanji runs in a surface string and returns character-index ranges.
    private func kanjiRuns(in surface: String) -> [(start: Int, end: Int)] {
        let characters = Array(surface)
        var runs: [(start: Int, end: Int)] = []
        var runStart: Int?

        for (index, character) in characters.enumerated() {
            let isKanji = ScriptClassifier.containsKanji(String(character))
            if isKanji {
                if runStart == nil {
                    runStart = index
                }
            } else if let currentRunStart = runStart {
                runs.append((start: currentRunStart, end: index))
                runStart = nil
            }
        }

        if let runStart {
            runs.append((start: runStart, end: characters.count))
        }

        return runs
    }

    // Extracts the reading that maps to the first contiguous kanji run of a dictionary surface.
    private func firstKanjiRunReading(in surface: String, using reading: String) -> String? {
        let characters = Array(surface)
        var runStart: Int?
        var runEnd: Int?

        for (index, character) in characters.enumerated() {
            let isKanji = ScriptClassifier.containsKanji(String(character))
            if isKanji {
                if runStart == nil {
                    runStart = index
                }
                runEnd = index + 1
            } else if runStart != nil {
                break
            }
        }

        guard let runStart, let runEnd else {
            return nil
        }

        let prefixSurface = String(characters[..<runStart])
        let suffixSurface = runEnd < characters.count
            ? String(characters[runEnd..<characters.count])
            : ""
        var trimmedReading = reading

        if !prefixSurface.isEmpty && trimmedReading.hasPrefix(prefixSurface) {
            trimmedReading.removeFirst(prefixSurface.count)
        }

        if !suffixSurface.isEmpty && trimmedReading.hasSuffix(suffixSurface) {
            trimmedReading.removeLast(suffixSurface.count)
        }

        let kanjiRunSurface = String(characters[runStart..<runEnd])
        guard !trimmedReading.isEmpty, trimmedReading != kanjiRunSurface else {
            return nil
        }

        return trimmedReading
    }

    // Looks up a segment reading and caches it for subsequent furigana rendering passes.
    private func readingForSegment(
        _ segmentSurface: String,
        readingBySurface: [String: String],
        readingCandidatesBySurface: [String: [String]],
        preferKunyomiForStandaloneKanji: Bool
    ) -> String? {
        guard let candidates = readingCandidatesBySurface[segmentSurface], candidates.isEmpty == false else {
            return readingBySurface[segmentSurface]
        }

        if preferKunyomiForStandaloneKanji {
            if let overrideReading = preferredStandaloneKunyomiOverride(for: segmentSurface),
               candidates.contains(overrideReading) {
                return overrideReading
            }

            if let preferred = preferredKunyomiCandidate(from: candidates) {
                return preferred
            }
        }

        return candidates.first ?? readingBySurface[segmentSurface]
    }

    // Detects single-kanji contexts where kunyomi should be preferred (standalone or particle-attached).
    private func shouldPreferKunyomiForSingleKanji(surface: String, in sourceText: String, segmentRange: Range<String.Index>) -> Bool {
        let surfaceCharacters = Array(surface)
        let kanjiCharacterCount = surfaceCharacters.reduce(into: 0) { count, character in
            if ScriptClassifier.containsKanji(String(character)) {
                count += 1
            }
        }

        guard kanjiCharacterCount == 1 else {
            return false
        }

        let particleCharacters: Set<Character> = ["の", "は", "が", "を", "に", "へ", "と", "で", "も", "や", "か", "な", "ね", "よ", "ぞ", "さ", "わ"]

        let hasBoundaryOnLeft: Bool
        let leftCharacter: Character?
        if segmentRange.lowerBound == sourceText.startIndex {
            hasBoundaryOnLeft = true
            leftCharacter = nil
        } else {
            let previousIndex = sourceText.index(before: segmentRange.lowerBound)
            let character = sourceText[previousIndex]
            hasBoundaryOnLeft = ScriptClassifier.isBoundaryCharacter(character)
            leftCharacter = character
        }

        let hasBoundaryOnRight: Bool
        let rightCharacter: Character?
        if segmentRange.upperBound == sourceText.endIndex {
            hasBoundaryOnRight = true
            rightCharacter = nil
        } else {
            let character = sourceText[segmentRange.upperBound]
            hasBoundaryOnRight = ScriptClassifier.isBoundaryCharacter(character)
            rightCharacter = character
        }

        let hasParticleOnLeft = leftCharacter.map { particleCharacters.contains($0) } ?? false
        let hasParticleOnRight = rightCharacter.map { particleCharacters.contains($0) } ?? false

        if hasBoundaryOnLeft && hasBoundaryOnRight {
            return true
        }

        if hasBoundaryOnLeft && hasParticleOnRight {
            return true
        }

        if hasParticleOnLeft && hasBoundaryOnRight {
            return true
        }

        return false
    }

    // Picks a kunyomi-leaning candidate for standalone single-kanji contexts.
    private func preferredKunyomiCandidate(from candidates: [String]) -> String? {
        guard candidates.isEmpty == false else {
            return nil
        }

        let ordered = candidates.enumerated().sorted { lhs, rhs in
            let lhsScore = kunyomiPreferenceScore(lhs.element)
            let rhsScore = kunyomiPreferenceScore(rhs.element)
            if lhsScore != rhsScore {
                return lhsScore > rhsScore
            }

            if lhs.element.count != rhs.element.count {
                return lhs.element.count > rhs.element.count
            }

            // Keep earlier dictionary order as final tie-break to preserve deterministic behavior.
            return lhs.offset < rhs.offset
        }

        return ordered.first?.element
    }

    // Provides deterministic kunyomi picks for high-frequency single-kanji ambiguities.
    private func preferredStandaloneKunyomiOverride(for surface: String) -> String? {
        let overrides: [String: String] = [
            "月": "つき",
            "星": "ほし",
            "日": "ひ",
        ]
        return overrides[surface]
    }

    // Scores readings so standalone-kanji tokens can prefer kunyomi-like options.
    private func kunyomiPreferenceScore(_ reading: String) -> Int {
        let scalarValues = reading.unicodeScalars.map(\.value)
        let hasSmallKana = scalarValues.contains { value in
            value == 0x3083 || value == 0x3085 || value == 0x3087 || value == 0x30E3 || value == 0x30E5 || value == 0x30E7
        }
        let hasSokuon = scalarValues.contains(0x3063) || scalarValues.contains(0x30C3)

        var score = 0
        if hasSmallKana == false {
            score += 15
        }

        if hasSokuon == false {
            score += 10
        }

        if reading.count <= 3 {
            score += 10
        }

        if let terminal = reading.last {
            if terminal == "い" || terminal == "う" {
                score -= 12
            }

            if ["し", "ち", "つ", "く", "む", "る", "り", "さ", "せ", "そ", "な", "の", "ま", "み", "も", "き"].contains(terminal) {
                score += 8
            }
        }

        return score
    }
}

#Preview {
    ReadView(selectedNote: .constant(nil), segmenter: Segmenter(trie: DictionaryTrie()), dictionaryStore: nil, readingBySurface: [:], readingCandidatesBySurface: [:], segmenterRevision: 0, readResourcesReady: false)
}
