import WidgetKit
import SwiftUI

// Renders a single Word of the Day entry. Mirrors the notification body (surface + kana + meaning)
// and adapts density to the widget family. Falls back to a prompt when no word has been scheduled.
struct WordOfTheDayWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: WordOfTheDayWidgetEntry

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .containerBackground(.fill.tertiary, for: .widget)
            .widgetURL(deepLink)
    }

    @ViewBuilder
    private var content: some View {
        if let word = entry.word {
            wordView(word)
        } else {
            emptyState
        }
    }

    private func wordView(_ word: WordOfTheDayMirrorEntry) -> some View {
        VStack(alignment: .leading, spacing: family == .systemSmall ? 4 : 6) {
            Text("WORD OF THE DAY")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)

            if let kana = word.kana, kana.isEmpty == false, kana != word.surface {
                Text(kana)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Text(word.surface)
                .font(family == .systemSmall ? .title2.weight(.bold) : .largeTitle.weight(.bold))
                .minimumScaleFactor(0.6)
                .lineLimit(1)

            Text(word.meaning)
                .font(family == .systemSmall ? .caption : .subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(family == .systemSmall ? 2 : 3)

            Spacer(minLength: 0)
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Word of the Day")
                .font(.headline)
            Text("Enable Word of the Day in Settings to see your latest word here.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
    }

    private var deepLink: URL? {
        guard let word = entry.word else { return nil }
        return WordOfTheDayMirror.deepLinkURL(entryID: word.entryID, surface: word.surface)
    }
}
