import WidgetKit
import SwiftUI

// One rendered moment in the widget's timeline: the word that is "current" at `date`.
struct WordOfTheDayWidgetEntry: TimelineEntry {
    let date: Date
    let word: WordOfTheDayWord?
}

// Builds the widget's timeline from the App Group snapshot the app writes. "Today's word" is a
// deterministic function of the date and the snapshot, so the provider just evaluates it now and at
// each upcoming notification time — no per-day data and no dependency on the app running.
struct WordOfTheDayProvider: TimelineProvider {
    // How many upcoming notification times to precompute so the widget flips on schedule.
    private static let timelineDays = 14

    func placeholder(in context: Context) -> WordOfTheDayWidgetEntry {
        WordOfTheDayWidgetEntry(date: Date(), word: .preview)
    }

    func getSnapshot(in context: Context, completion: @escaping (WordOfTheDayWidgetEntry) -> Void) {
        let now = Date()
        let word = WordOfTheDay.loadSnapshot().flatMap { WordOfTheDay.currentWord(asOf: now, snapshot: $0) }
            ?? (context.isPreview ? .preview : nil)
        completion(WordOfTheDayWidgetEntry(date: now, word: word))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<WordOfTheDayWidgetEntry>) -> Void) {
        let now = Date()
        guard let snapshot = WordOfTheDay.loadSnapshot(), snapshot.enabled, snapshot.words.isEmpty == false else {
            // Nothing to show; the app reloads the timeline when WOTD is enabled.
            completion(Timeline(entries: [WordOfTheDayWidgetEntry(date: now, word: nil)], policy: .never))
            return
        }

        var entries = [WordOfTheDayWidgetEntry(date: now, word: WordOfTheDay.currentWord(asOf: now, snapshot: snapshot))]

        // One entry at each upcoming notification time, where the word rolls over to that day's word.
        var cursor = now
        for _ in 0..<Self.timelineDays {
            guard let next = WordOfTheDay.nextFireDate(after: cursor, hour: snapshot.hour, minute: snapshot.minute) else { break }
            entries.append(WordOfTheDayWidgetEntry(date: next, word: WordOfTheDay.currentWord(asOf: next, snapshot: snapshot)))
            cursor = next
        }

        completion(Timeline(entries: entries, policy: .atEnd))
    }
}

// The Word of the Day widget: shows today's word, tappable to open it in the app. Supports the Home
// Screen and Lock Screen.
struct WordOfTheDayWidget: Widget {
    static let kind = "WordOfTheDayWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: Self.kind, provider: WordOfTheDayProvider()) { entry in
            WordOfTheDayWidgetView(entry: entry)
        }
        .configurationDisplayName("Word of the Day")
        .description("Shows your current Word of the Day.")
        .supportedFamilies([
            .systemSmall,
            .systemMedium,
            // Lock Screen: rectangular slot below the clock, plus the single-line slot above it.
            .accessoryRectangular,
            .accessoryInline,
        ])
    }
}

extension WordOfTheDayWord {
    // Sample content for the widget gallery / placeholder rendering.
    static let preview = WordOfTheDayWord(
        entryID: 0,
        surface: "勉強",
        kana: "べんきょう",
        meaning: "study; diligence"
    )
}
