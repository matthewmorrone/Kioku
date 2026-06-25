import WidgetKit
import SwiftUI

// One rendered moment in the widget's timeline: the word that is "most recent" at `date`, plus the
// preceding days' words (used only by the large family's recent-words list).
struct WordOfTheDayWidgetEntry: TimelineEntry {
    let date: Date
    let word: WordOfTheDayMirrorEntry?
    let recent: [WordOfTheDayMirrorEntry]

    init(date: Date, word: WordOfTheDayMirrorEntry?, recent: [WordOfTheDayMirrorEntry] = []) {
        self.date = date
        self.word = word
        self.recent = recent
    }
}

// Builds the widget's timeline from the App Group mirror written by the app. Because the mirror
// contains every upcoming notification's fire date, the timeline can schedule one entry per fire
// date — WidgetKit then flips the displayed word exactly when each notification fires, with no
// app launch required.
struct WordOfTheDayProvider: TimelineProvider {
    // How many prior days to surface in the large family's list.
    private static let recentLimit = 4

    func placeholder(in context: Context) -> WordOfTheDayWidgetEntry {
        WordOfTheDayWidgetEntry(date: Date(), word: .preview, recent: WordOfTheDayMirrorEntry.previewRecent)
    }

    func getSnapshot(in context: Context, completion: @escaping (WordOfTheDayWidgetEntry) -> Void) {
        let now = Date()
        let mirror = WordOfTheDayMirror.load()
        let word = WordOfTheDayMirror.currentEntry(in: mirror, asOf: now)
            ?? (context.isPreview ? .preview : nil)
        let recent = mirror.isEmpty && context.isPreview
            ? WordOfTheDayMirrorEntry.previewRecent
            : WordOfTheDayMirror.recentEntries(in: mirror, asOf: now, excluding: word, limit: Self.recentLimit)
        completion(WordOfTheDayWidgetEntry(date: now, word: word, recent: recent))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<WordOfTheDayWidgetEntry>) -> Void) {
        let now = Date()
        let mirror = WordOfTheDayMirror.load()

        // Build one timeline entry at "now" and one at each future fire date, each carrying the word
        // current at that moment plus the days preceding it.
        var moments: [Date] = [now]
        moments.append(contentsOf: mirror.map(\.fireDate).filter { $0 > now }.sorted())

        let entries = moments.map { moment -> WordOfTheDayWidgetEntry in
            let word = WordOfTheDayMirror.currentEntry(in: mirror, asOf: moment)
            let recent = WordOfTheDayMirror.recentEntries(in: mirror, asOf: moment, excluding: word, limit: Self.recentLimit)
            return WordOfTheDayWidgetEntry(date: moment, word: word, recent: recent)
        }

        // .atEnd asks WidgetKit to request a fresh timeline once the last entry is reached, so the
        // widget keeps refilling as the app schedules new batches.
        completion(Timeline(entries: entries, policy: .atEnd))
    }
}

// The Word of the Day widget: shows the word from the most recent WOTD notification, tappable to
// open that word in the app. Scales content by size — Small is the app mark only, Medium adds the
// meaning, Large adds the recent-days list. Also supports the two Lock Screen accessory slots.
struct WordOfTheDayWidget: Widget {
    static let kind = "WordOfTheDayWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: Self.kind, provider: WordOfTheDayProvider()) { entry in
            WordOfTheDayWidgetView(entry: entry)
        }
        .configurationDisplayName("Word of the Day")
        .description("Shows the word from your most recent Word of the Day notification.")
        .supportedFamilies([
            .systemSmall,
            .systemMedium,
            .systemLarge,
            // Lock Screen: rectangular slot below the clock, plus the single-line slot above it.
            .accessoryRectangular,
            .accessoryInline,
        ])
    }
}

extension WordOfTheDayMirrorEntry {
    // Sample content for the widget gallery / placeholder rendering.
    static let preview = WordOfTheDayMirrorEntry(
        fireDate: Date(),
        surface: "掬いあげる",
        kana: "すくいあげる",
        meaning: "to scoop up",
        entryID: 0
    )

    // Sample prior-days list for the large family's gallery preview.
    static let previewRecent: [WordOfTheDayMirrorEntry] = [
        WordOfTheDayMirrorEntry(fireDate: Date(timeIntervalSinceNow: -86_400), surface: "夕映", kana: "ゆうばえ", meaning: "evening glow", entryID: 1),
        WordOfTheDayMirrorEntry(fireDate: Date(timeIntervalSinceNow: -172_800), surface: "揺蕩う", kana: "たゆたう", meaning: "to sway", entryID: 2),
        WordOfTheDayMirrorEntry(fireDate: Date(timeIntervalSinceNow: -259_200), surface: "朧", kana: "おぼろ", meaning: "haze; dim", entryID: 3),
    ]
}
