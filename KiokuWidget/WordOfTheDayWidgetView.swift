import WidgetKit
import SwiftUI

// Renders a single Word of the Day entry. Mirrors the notification body (surface + kana + meaning)
// and adapts to the widget family — including the Lock Screen accessory families, which use the
// system's vibrant rendering and far tighter layouts. Falls back to a prompt when no word has been
// scheduled.
struct WordOfTheDayWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: WordOfTheDayWidgetEntry

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .containerBackground(for: .widget) { background }
            .widgetURL(deepLink)
    }

    // MARK: - Family routing

    @ViewBuilder
    private var content: some View {
        switch family {
        case .accessoryInline:
            inlineContent
        case .accessoryRectangular:
            rectangularContent
        default:
            homeScreenContent
        }
    }

    @ViewBuilder
    private var background: some View {
        switch family {
        case .accessoryRectangular, .accessoryCircular, .accessoryInline:
            // Subtle system backdrop that adapts to the Lock Screen tint; transparent for inline.
            AccessoryWidgetBackground()
        default:
            Rectangle().fill(.fill.tertiary)
        }
    }

    // MARK: - Home screen (systemSmall / systemMedium)

    @ViewBuilder
    private var homeScreenContent: some View {
        if let word = entry.word {
            VStack(alignment: .leading, spacing: family == .systemSmall ? 4 : 6) {
                Text("WORD OF THE DAY")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)

                if let kana = displayKana(for: word) {
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
        } else {
            VStack(alignment: .leading, spacing: 6) {
                Text("Word of the Day")
                    .font(.headline)
                Text("Enable Word of the Day in Settings to see your latest word here.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
        }
    }

    // MARK: - Lock Screen rectangular

    @ViewBuilder
    private var rectangularContent: some View {
        if let word = entry.word {
            VStack(alignment: .leading, spacing: 1) {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(word.surface)
                        .font(.headline)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                    if let kana = displayKana(for: word) {
                        Text(kana)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Text(word.meaning)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        } else {
            VStack(alignment: .leading, spacing: 1) {
                Text("Word of the Day")
                    .font(.headline)
                Text("Enable in Settings")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Lock Screen inline (single line above the clock)

    private var inlineContent: some View {
        // The inline slot renders only one Text/Label; richer layout is flattened by the system.
        Text(inlineText)
    }

    private var inlineText: String {
        guard let word = entry.word else { return "Word of the Day" }
        return "\(word.surface) · \(word.meaning)"
    }

    // MARK: - Helpers

    // Kana worth showing: present, non-empty, and not identical to the surface (kana-only words).
    private func displayKana(for word: WordOfTheDayMirrorEntry) -> String? {
        guard let kana = word.kana, kana.isEmpty == false, kana != word.surface else { return nil }
        return kana
    }

    private var deepLink: URL? {
        guard let word = entry.word else { return nil }
        return WordOfTheDayMirror.deepLinkURL(entryID: word.entryID, surface: word.surface)
    }
}
