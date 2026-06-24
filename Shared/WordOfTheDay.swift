import Foundation

// One saved word with its display content resolved from the dictionary. Compiled into BOTH the app
// and widget targets; plain Foundation so it is directly unit testable.
nonisolated struct WordOfTheDayWord: Codable, Equatable, Sendable {
    let entryID: Int64
    let surface: String
    let kana: String?
    let meaning: String
}

// The single shared payload the app writes and the widget reads: the saved-word list (in a stable
// order) plus the schedule configuration. "Today's word" is a deterministic function of the date
// and this snapshot, so the app's notification and the widget always agree without any per-day
// bookkeeping.
nonisolated struct WordOfTheDaySnapshot: Codable, Equatable, Sendable {
    let enabled: Bool
    let hour: Int
    let minute: Int
    // Stable, de-duplicated order. Index `dayNumber % words.count` selects the day's word.
    let words: [WordOfTheDayWord]
}

// App-Group storage plus the pure date→word logic shared by the scheduler and the widget.
nonisolated enum WordOfTheDay {
    // Must match the App Group declared in both targets' entitlements.
    static let appGroupID = "group.matthewmorrone.Kioku"
    private static let snapshotKey = "wordOfTheDay.snapshot.v1"

    static var sharedDefaults: UserDefaults? {
        UserDefaults(suiteName: appGroupID)
    }

    // MARK: - Storage

    static func write(_ snapshot: WordOfTheDaySnapshot) {
        guard let defaults = sharedDefaults, let data = try? JSONEncoder().encode(snapshot) else { return }
        defaults.set(data, forKey: snapshotKey)
    }

    static func loadSnapshot() -> WordOfTheDaySnapshot? {
        guard
            let defaults = sharedDefaults,
            let data = defaults.data(forKey: snapshotKey),
            let snapshot = try? JSONDecoder().decode(WordOfTheDaySnapshot.self, from: data)
        else {
            return nil
        }
        return snapshot
    }

    static func clear() {
        sharedDefaults?.removeObject(forKey: snapshotKey)
    }

    // MARK: - Deterministic selection (pure)

    // A stable absolute day index: the number of whole days from the reference date to `date`'s day.
    // Adjacent calendar days differ by exactly 1, which is what makes the day→word rotation stable.
    static func dayNumber(for date: Date, calendar: Calendar = .current) -> Int {
        let day = calendar.startOfDay(for: date)
        let reference = calendar.startOfDay(for: Date(timeIntervalSinceReferenceDate: 0))
        return calendar.dateComponents([.day], from: reference, to: day).day ?? 0
    }

    // The word announced for an absolute day number, rotating through the list. Handles negative day
    // numbers (dates before the reference) and returns nil for an empty list.
    static func word(forDayNumber dayNumber: Int, in words: [WordOfTheDayWord]) -> WordOfTheDayWord? {
        guard words.isEmpty == false else { return nil }
        let index = ((dayNumber % words.count) + words.count) % words.count
        return words[index]
    }

    // The day whose word is "current" as of `now`: today once the notification time has passed,
    // otherwise yesterday (the most recent word actually announced). This makes the widget match the
    // notification — it rolls over to the new word exactly when the notification fires, not at
    // midnight.
    static func effectiveDayNumber(asOf now: Date, hour: Int, minute: Int, calendar: Calendar = .current) -> Int {
        let base = dayNumber(for: now, calendar: calendar)
        let fireToday = calendar.date(
            bySettingHour: max(0, min(23, hour)),
            minute: max(0, min(59, minute)),
            second: 0,
            of: now
        ) ?? now
        return now >= fireToday ? base : base - 1
    }

    // The word the widget should display right now, or nil when WOTD is disabled or has no words.
    static func currentWord(asOf now: Date, snapshot: WordOfTheDaySnapshot, calendar: Calendar = .current) -> WordOfTheDayWord? {
        guard snapshot.enabled else { return nil }
        let day = effectiveDayNumber(asOf: now, hour: snapshot.hour, minute: snapshot.minute, calendar: calendar)
        return word(forDayNumber: day, in: snapshot.words)
    }

    // The next notification fire time strictly after `date`. Used to build the widget timeline so it
    // flips to the new word at each day's notification time.
    static func nextFireDate(after date: Date, hour: Int, minute: Int, calendar: Calendar = .current) -> Date? {
        var components = DateComponents()
        components.hour = max(0, min(23, hour))
        components.minute = max(0, min(59, minute))
        return calendar.nextDate(after: date, matching: components, matchingPolicy: .nextTime)
    }

    // MARK: - Deep link

    // Builds the widget tap URL, e.g. kioku://word?id=123&surface=勉強.
    static func deepLinkURL(entryID: Int64, surface: String) -> URL? {
        var components = URLComponents()
        components.scheme = "kioku"
        components.host = "word"
        components.queryItems = [
            URLQueryItem(name: "id", value: String(entryID)),
            URLQueryItem(name: "surface", value: surface),
        ]
        return components.url
    }

    // Parses a kioku://word?id=…&surface=… URL into its components, or nil if it is not a valid word
    // deep link. Surface is optional (the entry ID alone is enough to navigate).
    static func parseDeepLink(_ url: URL) -> (entryID: Int64, surface: String?)? {
        guard
            url.scheme == "kioku",
            url.host == "word",
            let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        else {
            return nil
        }
        let items = components.queryItems ?? []
        guard
            let idString = items.first(where: { $0.name == "id" })?.value,
            let entryID = Int64(idString)
        else {
            return nil
        }
        let surface = items.first(where: { $0.name == "surface" })?.value
        return (entryID, surface)
    }
}
