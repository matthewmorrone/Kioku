import WidgetKit
import SwiftUI

// One rendered moment in the widget's timeline: the word that is "most recent" at `date`.
struct WordOfTheDayWidgetEntry: TimelineEntry {
    let date: Date
    let word: WordOfTheDayMirrorEntry?
}

// Builds the widget's timeline from the App Group mirror written by the app. Because the mirror
// contains every upcoming notification's fire date, the timeline can schedule one entry per fire
// date — WidgetKit then flips the displayed word exactly when each notification fires, with no
// app launch required.
struct WordOfTheDayProvider: TimelineProvider {
    func placeholder(in context: Context) -> WordOfTheDayWidgetEntry {
        WordOfTheDayWidgetEntry(date: Date(), word: .preview)
    }

    func getSnapshot(in context: Context, completion: @escaping (WordOfTheDayWidgetEntry) -> Void) {
        let now = Date()
        let mirror = WordOfTheDayMirror.load()
        let word = WordOfTheDayMirror.mostRecentEntry(in: mirror, asOf: now)
            ?? (context.isPreview ? .preview : nil)
        completion(WordOfTheDayWidgetEntry(date: now, word: word))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<WordOfTheDayWidgetEntry>) -> Void) {
        let now = Date()
        let mirror = WordOfTheDayMirror.load()

        var entries: [WordOfTheDayWidgetEntry] = [
            WordOfTheDayWidgetEntry(date: now, word: WordOfTheDayMirror.mostRecentEntry(in: mirror, asOf: now))
        ]

        // Each future fire date becomes the moment that word turns into the most-recent one.
        for upcoming in mirror.sorted(by: { $0.fireDate < $1.fireDate }) where upcoming.fireDate > now {
            entries.append(WordOfTheDayWidgetEntry(date: upcoming.fireDate, word: upcoming))
        }

        // .atEnd asks WidgetKit to request a fresh timeline once the last entry is reached, so the
        // widget keeps refilling as the app schedules new batches.
        completion(Timeline(entries: entries, policy: .atEnd))
    }
}

// The Word of the Day widget: shows the word from the most recent WOTD notification, tappable to
// open that word in the app.
struct WordOfTheDayWidget: Widget {
    static let kind = "WordOfTheDayWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: Self.kind, provider: WordOfTheDayProvider()) { entry in
            WordOfTheDayWidgetView(entry: entry)
        }
        .configurationDisplayName("Word of the Day")
        .description("Shows the word from your most recent Word of the Day notification.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

extension WordOfTheDayMirrorEntry {
    // Sample content for the widget gallery / placeholder rendering.
    static let preview = WordOfTheDayMirrorEntry(
        fireDate: Date(),
        surface: "勉強",
        kana: "べんきょう",
        meaning: "study; diligence",
        entryID: 0
    )
}
