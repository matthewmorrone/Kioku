import Foundation
import UserNotifications

// Notification content resolved from the live dictionary for a specific saved word.
private struct WordOfTheDayLiveContent {
    let surface: String
    let kana: String?
    let meaning: String
}

// Schedules and manages daily Word of the Day push notifications using saved vocabulary.
// Adapted from Kyouku's WordOfTheDayScheduler; uses SavedWord + DictionaryStore instead of Word + DictionaryEntryDetailsCache.
enum WordOfTheDayScheduler {
    static let enabledKey = "wordOfTheDay.enabled"
    static let hourKey = "wordOfTheDay.hour"
    static let minuteKey = "wordOfTheDay.minute"

    // Notification request identifiers use this prefix for batch filtering.
    static let requestPrefix = "wotd_"

    // Requests push notification authorization for alerts, badges, and sound.
    static func requestAuthorization() async -> Bool {
        await withCheckedContinuation { continuation in
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge, .sound]) { granted, _ in
                continuation.resume(returning: granted)
            }
        }
    }

    // Returns the current notification authorization status without prompting the user.
    static func authorizationStatus() async -> UNAuthorizationStatus {
        await withCheckedContinuation { continuation in
            UNUserNotificationCenter.current().getNotificationSettings { settings in
                continuation.resume(returning: settings.authorizationStatus)
            }
        }
    }

    // Returns the count of pending Word of the Day requests currently queued in the system.
    static func pendingWordOfTheDayRequestCount() async -> Int {
        let ids = await pendingWordOfTheDayIdentifiers()
        return ids.count
    }

    // Removes all pending Word of the Day notification requests from the system queue.
    static func clearPendingWordOfTheDayRequests() async {
        let ids = await pendingWordOfTheDayIdentifiers()
        guard ids.isEmpty == false else { return }
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: ids)
    }

    // Schedules upcoming notifications when the feature is enabled and authorized.
    // Clears pending requests when disabled or unauthorized to keep the system queue clean.
    static func refreshScheduleIfEnabled(
        words: [SavedWord],
        dictionaryStore: DictionaryStore?,
        hour: Int,
        minute: Int,
        enabled: Bool,
        daysToSchedule: Int = 14
    ) async {
        guard enabled else {
            await clearPendingWordOfTheDayRequests()
            return
        }

        let status = await authorizationStatus()
        guard status == .authorized || status == .provisional else {
            await clearPendingWordOfTheDayRequests()
            return
        }

        guard let dictionaryStore else { return }
        await scheduleUpcoming(
            words: words,
            dictionaryStore: dictionaryStore,
            hour: hour,
            minute: minute,
            daysToSchedule: daysToSchedule
        )
    }

    // Sends a test notification immediately with a 1-second delay using a random saved word.
    static func sendTestNotification(word: SavedWord?, dictionaryStore: DictionaryStore?) async {
        guard let word, let dictionaryStore else { return }
        let live = resolveLiveContent(for: [word], using: dictionaryStore)
        guard let liveContent = live[word.canonicalEntryID] else { return }
        let content = makeContent(for: word, liveContent: liveContent)
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)
        let request = UNNotificationRequest(
            identifier: requestPrefix + "test_\(UUID().uuidString)",
            content: content,
            trigger: trigger
        )
        _ = await addRequest(request)
    }

    // MARK: - Internals

    // Clears the existing schedule and rebuilds it from a fresh word shuffle.
    // Schedules up to 30 days (iOS caps pending notifications at 64).
    private static func scheduleUpcoming(
        words: [SavedWord],
        dictionaryStore: DictionaryStore,
        hour: Int,
        minute: Int,
        daysToSchedule: Int
    ) async {
        await clearPendingWordOfTheDayRequests()
        guard words.isEmpty == false else { return }

        let liveContentByEntryID = resolveLiveContent(for: words, using: dictionaryStore)
        // Shuffle once per scheduling run; rotate through shuffled order to avoid
        // bias toward earlier items while keeping the batch varied.
        let shuffled = words.shuffled()
        let calendar = Calendar.current
        let now = Date()
        let count = max(1, min(daysToSchedule, 30))

        for dayOffset in 0..<count {
            guard let day = calendar.date(byAdding: .day, value: dayOffset, to: now) else { continue }
            var comps = calendar.dateComponents([.year, .month, .day], from: day)
            comps.hour = max(0, min(23, hour))
            comps.minute = max(0, min(59, minute))

            let word = pickWord(forDayOffset: dayOffset, from: shuffled)
            guard let liveContent = liveContentByEntryID[word.canonicalEntryID] else { continue }
            let content = makeContent(for: word, liveContent: liveContent)
            let trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)
            let id = requestPrefix + identifierDateString(from: comps)
            let request = UNNotificationRequest(identifier: id, content: content, trigger: trigger)
            _ = await addRequest(request)
        }
    }

    // Rotates through the shuffled list by day offset to reduce duplicates within a batch.
    private static func pickWord(forDayOffset dayOffset: Int, from words: [SavedWord]) -> SavedWord {
        let idx = abs(dayOffset) % max(1, words.count)
        return words[idx]
    }

    // Builds the notification content including surface, optional bracketed kana, and first gloss.
    private static func makeContent(
        for word: SavedWord,
        liveContent: WordOfTheDayLiveContent
    ) -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        content.title = "Word of the Day"

        let surface = liveContent.surface.trimmingCharacters(in: .whitespacesAndNewlines)
        let meaning = liveContent.meaning.trimmingCharacters(in: .whitespacesAndNewlines)
        let kana = liveContent.kana?.trimmingCharacters(in: .whitespacesAndNewlines)

        if let kana, kana.isEmpty == false, kana != surface {
            content.body = "\(surface)【\(kana)】 \(meaning)"
        } else {
            content.body = "\(surface) \(meaning)"
        }
        content.sound = .default

        content.userInfo["surface"] = surface
        if let kana { content.userInfo["kana"] = kana }
        content.userInfo["meaning"] = meaning
        // canonicalEntryID stored as string since SavedWord has no UUID.
        content.userInfo["wordID"] = String(word.canonicalEntryID)

        return content
    }

    // Fetches the preferred display surface, kana reading, and first gloss for each unique entry ID.
    // Runs synchronously on the caller's thread; DictionaryStore serializes access internally.
    private static func resolveLiveContent(
        for words: [SavedWord],
        using dictionaryStore: DictionaryStore
    ) -> [Int64: WordOfTheDayLiveContent] {
        let uniqueIDs = Array(Set(words.map(\.canonicalEntryID)))
        var out: [Int64: WordOfTheDayLiveContent] = [:]
        out.reserveCapacity(uniqueIDs.count)

        for entryID in uniqueIDs {
            guard let entry = try? dictionaryStore.lookupEntry(entryID: entryID) else { continue }

            var surface = ""
            for form in entry.kanjiForms {
                let trimmed = form.text.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.isEmpty == false { surface = trimmed; break }
            }
            if surface.isEmpty {
                for form in entry.kanaForms {
                    let trimmed = form.text.trimmingCharacters(in: .whitespacesAndNewlines)
                    if trimmed.isEmpty == false { surface = trimmed; break }
                }
            }
            guard surface.isEmpty == false else { continue }

            let kana = entry.kanaForms.first.flatMap { form -> String? in
                let trimmed = form.text.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty ? nil : trimmed
            }

            let meaning = entry.senses.first?.glosses.first ?? ""
            out[entryID] = WordOfTheDayLiveContent(surface: surface, kana: kana, meaning: meaning)
        }

        return out
    }

    // Returns identifiers of pending notification requests that belong to this feature.
    private static func pendingWordOfTheDayIdentifiers() async -> [String] {
        await withCheckedContinuation { continuation in
            UNUserNotificationCenter.current().getPendingNotificationRequests { requests in
                let ids = requests.map { $0.identifier }.filter { $0.hasPrefix(requestPrefix) }
                continuation.resume(returning: ids)
            }
        }
    }

    // Formats a DateComponents year/month/day into a compact YYYYMMDD string for use as a request ID.
    private static func identifierDateString(from components: DateComponents) -> String {
        let y = components.year ?? 0
        let m = components.month ?? 0
        let d = components.day ?? 0
        return String(format: "%04d%02d%02d", y, m, d)
    }

    // Adds a notification request and returns any scheduling error.
    private static func addRequest(_ request: UNNotificationRequest) async -> Error? {
        await withCheckedContinuation { continuation in
            UNUserNotificationCenter.current().add(request) { error in
                continuation.resume(returning: error)
            }
        }
    }
}
