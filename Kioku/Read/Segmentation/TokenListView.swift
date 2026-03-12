import SwiftUI

// Renders the token-management screen for all current paste-area tokens.
struct TokenListView: View {
    @Environment(\.dismiss) private var dismiss

    let text: String
    let edges: [LatticeEdge]
    let sourceNoteID: UUID?
    let onMergeLeft: (Int) -> Void
    let onMergeRight: (Int) -> Void
    let onSplit: (Int, Int) -> Void
    let onReset: () -> Void

    @State private var savedWords: Set<String> = []
    @State private var includesDuplicates = true
    @State private var includesCommonParticles = true
    private let savedWordsStorageKey = "kioku.words.v1"
    private let commonParticles: Set<String> = [
        "は", "が", "を", "に", "へ", "と", "で", "も", "の", "ね", "よ", "か", "な", "や", "ぞ", "さ", "わ",
        "から", "まで", "より", "だけ", "ほど", "しか", "こそ", "でも", "なら", "ので", "のに", "し", "て", "って"
    ]

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Displays every active token in source order.
                List {
                    ForEach(displayRows, id: \.sourceIndex) { row in
                        let index = row.sourceIndex
                        let edge = row.edge
                        // Shows token text with a right-side star toggle and split/merge context actions.
                        HStack(spacing: 10) {
                            Text(edge.surface)
                                .font(.headline)

                            Spacer()

                            Button {
                                toggleSavedWord(edge.surface)
                            } label: {
                                Image(systemName: savedWords.contains(edge.surface) ? "star.fill" : "star")
                                    .foregroundStyle(savedWords.contains(edge.surface) ? Color.yellow : Color.secondary)
                                    .font(.system(size: 16, weight: .semibold))
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(savedWords.contains(edge.surface) ? "Unsave Word" : "Save Word")
                        }
                        .padding(.vertical, 6)
                        .contextMenu {
                            if index > 0 {
                                Button {
                                    onMergeLeft(index)
                                } label: {
                                    Label("Merge Left", systemImage: "arrow.left.to.line.compact")
                                }
                            }

                            if index < edges.count - 1 {
                                Button {
                                    onMergeRight(index)
                                } label: {
                                    Label("Merge Right", systemImage: "arrow.right.to.line.compact")
                                }
                            }

                            let availableOffsets = splitOffsets(for: edge.surface)
                            if availableOffsets.isEmpty == false {
                                Menu("Split") {
                                    ForEach(availableOffsets, id: \.self) { offset in
                                        if let preview = splitPreview(for: edge.surface, offsetUTF16: offset) {
                                            Button("\(preview.left) | \(preview.right)") {
                                                onSplit(index, offset)
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }

                // Keeps basic screen actions available at the bottom.
                HStack(spacing: 10) {
                    optionToggleButton(
                        title: "duplicates",
                        isOn: includesDuplicates,
                        accessibilityLabel: "Include Duplicates"
                    ) {
                        includesDuplicates.toggle()
                    }

                    optionToggleButton(
                        title: "particles",
                        isOn: includesCommonParticles,
                        accessibilityLabel: "Include Common Particles"
                    ) {
                        includesCommonParticles.toggle()
                    }

                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background(Color(.secondarySystemBackground))
            }
        }
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                // Dismisses the token list sheet without depending on scroll-position gesture handoff.
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "chevron.left")
                }
                .accessibilityLabel("Back")
            }
        }
        .onAppear {
            loadSavedWordsFromStorage()
        }
    }

    // Builds valid UTF-16 split offsets for a token by iterating character boundaries.
    private func splitOffsets(for surface: String) -> [Int] {
        guard surface.isEmpty == false else {
            return []
        }

        var offsets: [Int] = []
        var cursor = surface.startIndex
        var utf16Offset = 0

        while cursor < surface.endIndex {
            let nextIndex = surface.index(after: cursor)
            utf16Offset += surface[cursor..<nextIndex].utf16.count
            if nextIndex < surface.endIndex {
                offsets.append(utf16Offset)
            }
            cursor = nextIndex
        }

        return offsets
    }

    // Excludes newline-only rows so the word list mirrors visible lexical token editing intent.
    private var displayRows: [(sourceIndex: Int, edge: LatticeEdge)] {
        var filteredRows = Array(edges.enumerated())
            .filter { _, edge in
                edge.surface.contains("\n") == false && edge.surface.contains("\r") == false
            }

        if includesCommonParticles == false {
            filteredRows = filteredRows.filter { _, edge in
                isCommonParticle(edge.surface) == false
            }
        }

        if includesDuplicates == false {
            var seenSurfaces = Set<String>()
            filteredRows = filteredRows.filter { _, edge in
                let normalizedSurface = normalizedSurfaceForFiltering(edge.surface)
                if seenSurfaces.contains(normalizedSurface) {
                    return false
                }

                seenSurfaces.insert(normalizedSurface)
                return true
            }
        }

        return filteredRows.map { offset, edge in
            (sourceIndex: offset, edge: edge)
        }
    }

    // Detects whether a token surface is one of the common Japanese particles used for extraction filtering.
    private func isCommonParticle(_ surface: String) -> Bool {
        let normalizedSurface = normalizedSurfaceForFiltering(surface)
        return commonParticles.contains(normalizedSurface)
    }

    // Normalizes a token surface for stable duplicate and particle comparisons.
    private func normalizedSurfaceForFiltering(_ surface: String) -> String {
        surface.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // Renders a compact text-only toggle button used by extraction filters in the bottom action bar.
    private func optionToggleButton(title: String, isOn: Bool, accessibilityLabel: String, action: @escaping () -> Void) -> some View {
        Button {
            action()
        } label: {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(isOn ? Color.accentColor : Color.secondary)
                .padding(.horizontal, 10)
                .frame(height: 30)
                .background(
                    Capsule()
                        .fill(isOn ? Color.accentColor.opacity(0.18) : Color(.tertiarySystemFill))
                )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityValue(isOn ? "On" : "Off")
    }

    // Toggles one token surface in the saved-word list storage.
    private func toggleSavedWord(_ surface: String) {
        var entries = loadSavedWordEntriesFromStorage()
        if entries.contains(where: { $0.surface == surface }) {
            entries.removeAll { $0.surface == surface }
        } else {
            entries.append(SavedWord(surface: surface, sourceNoteID: sourceNoteID))
        }

        persistSavedWordEntriesToStorage(entries)
        savedWords = Set(entries.map(\.surface))
    }

    // Loads saved words from persistent storage for star-state rendering.
    private func loadSavedWordsFromStorage() {
        let entries = loadSavedWordEntriesFromStorage()
        savedWords = Set(entries.map(\.surface))
    }

    // Loads saved-word entries while migrating legacy plain-string storage values.
    private func loadSavedWordEntriesFromStorage() -> [SavedWord] {
        if let data = UserDefaults.standard.data(forKey: savedWordsStorageKey),
           let decodedEntries = try? JSONDecoder().decode([SavedWord].self, from: data) {
            return decodedEntries
        }

        if let legacyWords = UserDefaults.standard.array(forKey: savedWordsStorageKey) as? [String] {
            return legacyWords.map { legacyWord in
                SavedWord(surface: legacyWord, sourceNoteID: nil)
            }
        }

        return []
    }

    // Persists saved-word entries including optional source note references.
    private func persistSavedWordEntriesToStorage(_ entries: [SavedWord]) {
        if let encoded = try? JSONEncoder().encode(entries) {
            UserDefaults.standard.set(encoded, forKey: savedWordsStorageKey)
        }
    }

    // Generates preview text for a proposed split boundary.
    private func splitPreview(for surface: String, offsetUTF16: Int) -> (left: String, right: String)? {
        let totalLength = surface.utf16.count
        guard offsetUTF16 > 0, offsetUTF16 < totalLength else {
            return nil
        }

        let splitIndex = String.Index(utf16Offset: offsetUTF16, in: surface)
        let left = String(surface[..<splitIndex])
        let right = String(surface[splitIndex...])
        guard left.isEmpty == false, right.isEmpty == false else {
            return nil
        }

        return (left: left, right: right)
    }
}
