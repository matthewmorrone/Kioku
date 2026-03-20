import SwiftUI

// Renders one dictionary search result — primary form, reading, part of speech, first gloss, and a save toggle.
struct DictionarySearchResultRow: View {
    let entry: DictionaryEntry
    let isSaved: Bool
    let onToggleSave: () -> Void

    // Picks the best display surface: first kanji form if present, else first kana form.
    private var displaySurface: String {
        entry.kanjiForms.first ?? entry.kanaForms.first ?? entry.matchedSurface
    }

    // Returns the primary kana reading, omitted when the surface is already pure kana.
    private var reading: String? {
        guard entry.kanjiForms.isEmpty == false else { return nil }
        return entry.kanaForms.first
    }

    // Builds a compact POS + gloss label from the first available sense.
    private var primaryGloss: String {
        guard let sense = entry.senses.first else { return "" }
        var parts: [String] = []
        if let pos = sense.pos, pos.isEmpty == false {
            parts.append("[\(pos)]")
        }
        if let gloss = sense.glosses.first {
            parts.append(gloss)
        }
        return parts.joined(separator: " ")
    }

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(displaySurface)
                        .font(.headline)
                    if let reading {
                        Text(reading)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
                if primaryGloss.isEmpty == false {
                    Text(primaryGloss)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }

            Spacer(minLength: 0)

            Button {
                onToggleSave()
            } label: {
                Image(systemName: isSaved ? "star.fill" : "star")
                    .foregroundStyle(isSaved ? Color.yellow : Color.secondary)
                    .font(.system(size: 16, weight: .semibold))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isSaved ? "Unsave Word" : "Save Word")
        }
        .padding(.vertical, 4)
    }
}
