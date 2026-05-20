import SwiftUI

// Presents the full KANJIDIC2 record for one kanji literal — every meaning, all readings,
// learner metadata, radical/frequency, and a list of common words containing this character.
// Owned by WordDetailView; presented as a sheet from a tap on the inline kanji row.
struct KanjiDetailView: View {
    let info: KanjiInfo
    let dictionaryStore: DictionaryStore?

    @State private var words: [DictionaryEntry] = []
    @State private var isLoadingWords = true
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    headerCard
                        .frame(maxWidth: .infinity)
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                }

                if info.meanings.isEmpty == false {
                    Section("Meanings") {
                        Text(info.meanings.joined(separator: ", "))
                            .font(.body)
                            .textSelection(.enabled)
                    }
                }

                if info.onReadings.isEmpty == false {
                    Section("On'yomi") {
                        Text(info.onReadings.joined(separator: "・"))
                            .font(.body)
                            .textSelection(.enabled)
                    }
                }

                if info.kunReadings.isEmpty == false {
                    Section("Kun'yomi") {
                        Text(info.kunReadings.joined(separator: "・"))
                            .font(.body)
                            .textSelection(.enabled)
                    }
                }

                Section("Common words") {
                    if isLoadingWords {
                        ProgressView().frame(maxWidth: .infinity)
                    } else if words.isEmpty {
                        Text("No dictionary entries found.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(words, id: \.entryId) { entry in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(entry.primarySearchSurface)
                                    .font(.body)
                                if entry.primarySearchGloss.isEmpty == false {
                                    Text(entry.primarySearchGloss)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(2)
                                }
                            }
                            .padding(.vertical, 2)
                        }
                    }
                }
            }
            .navigationTitle(info.literal)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            .task { await loadWords() }
        }
    }

    // Hero card: oversized kanji glyph plus metadata badges.
    @ViewBuilder
    private var headerCard: some View {
        VStack(spacing: 12) {
            Text(info.literal)
                .font(.system(size: 96, weight: .regular))
                .padding(.top, 8)

            HStack(spacing: 8) {
                if let grade = info.grade {
                    metadataPill(grade == 8 ? "Secondary" : "Grade \(grade)")
                }
                if let jlpt = info.jlptLevel {
                    metadataPill("JLPT N\(jlpt)")
                }
                if let strokes = info.strokeCount {
                    metadataPill("\(strokes) strokes")
                }
                if let radical = info.radical {
                    metadataPill("Radical \(radical)")
                }
                if let freq = info.freqMainichi {
                    metadataPill("Freq #\(freq)")
                }
            }
            .frame(maxWidth: .infinity)
        }
        .padding(.vertical, 8)
    }

    // Pill styling for the metadata badges — matches the inline rows in WordDetailView.
    private func metadataPill(_ text: String) -> some View {
        Text(text)
            .font(.caption.weight(.medium))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(
                Capsule().fill(Color.secondary.opacity(0.12))
            )
    }

    // Loads up to 30 common words containing this kanji off the main actor.
    private func loadWords() async {
        let literal = info.literal
        let store = dictionaryStore
        let loaded: [DictionaryEntry] = await Task.detached(priority: .userInitiated) {
            (try? store?.searchEntriesContainingKanji(literal: literal, limit: 30)) ?? []
        }.value
        words = loaded
        isLoadingWords = false
    }
}
