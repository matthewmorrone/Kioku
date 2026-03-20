import SwiftUI

// Renders the full-screen word detail screen shown from Words list rows.
// Major sections: title/header, kanji breakdown, word list membership.
struct WordDetailView: View {
    let word: SavedWord
    let lists: [WordList]
    let dictionaryStore: DictionaryStore?

    @State private var kanjiInfoByLiteral: [String: KanjiInfo] = [:]

    // Resolves the names of lists this word belongs to for display.
    private var membershipNames: [String] {
        let memberLists = lists.filter { word.wordListIDs.contains($0.id) }
        return memberLists.map(\.name).sorted()
    }

    // Extracts unique kanji scalars from the surface in source order.
    private var kanjiCharacters: [String] {
        var seen = Set<String>()
        return word.surface.unicodeScalars.compactMap { scalar in
            let value = scalar.value
            guard (0x4E00...0x9FFF).contains(value) || (0x3400...0x4DBF).contains(value) else {
                return nil
            }
            let char = String(scalar)
            guard seen.insert(char).inserted else { return nil }
            return char
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(word.surface)
                .font(.title2.weight(.semibold))
                .padding(.horizontal, 20)
                .padding(.top, 24)
                .padding(.bottom, 16)

            List {
                if kanjiCharacters.isEmpty == false {
                    Section("Kanji") {
                        ForEach(kanjiCharacters, id: \.self) { char in
                            if let info = kanjiInfoByLiteral[char] {
                                kanjiRow(info)
                            }
                        }
                    }
                }

                Section("Lists") {
                    if membershipNames.isEmpty {
                        Text("Unsorted")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(membershipNames, id: \.self) { name in
                            Text(name)
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
        }
        .task {
            await loadKanjiInfo()
        }
    }

    // Renders one kanji character with its on/kun readings, meanings, and learner metadata.
    @ViewBuilder
    private func kanjiRow(_ info: KanjiInfo) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 14) {
                Text(info.literal)
                    .font(.system(size: 36, weight: .light))
                    .frame(width: 44)

                VStack(alignment: .leading, spacing: 3) {
                    if info.onReadings.isEmpty == false {
                        HStack(alignment: .firstTextBaseline, spacing: 4) {
                            Text("音")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.secondary)
                            Text(info.onReadings.joined(separator: "・"))
                                .font(.subheadline)
                        }
                    }

                    if info.kunReadings.isEmpty == false {
                        HStack(alignment: .firstTextBaseline, spacing: 4) {
                            Text("訓")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.secondary)
                            Text(info.kunReadings.joined(separator: "・"))
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }

                    if info.meanings.isEmpty == false {
                        Text(info.meanings.joined(separator: ", "))
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .lineLimit(2)
                    }
                }

                Spacer(minLength: 0)

                VStack(alignment: .trailing, spacing: 3) {
                    if let strokes = info.strokeCount {
                        Text("\(strokes) strokes")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }

                    if let jlpt = info.jlptLevel {
                        Text("N\(jlpt)")
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(.tertiary)
                    }
                }
            }
        }
        .padding(.vertical, 4)
    }

    // Loads KANJIDIC2 data for each kanji character in the surface off the main thread.
    private func loadKanjiInfo() async {
        guard let dictionaryStore, kanjiCharacters.isEmpty == false else { return }

        let characters = kanjiCharacters
        let result = await Task.detached(priority: .userInitiated) {
            var loaded: [String: KanjiInfo] = [:]
            for char in characters {
                if let info = try? dictionaryStore.fetchKanjiInfo(for: char) {
                    loaded[char] = info
                }
            }
            return loaded
        }.value

        kanjiInfoByLiteral = result
    }
}
