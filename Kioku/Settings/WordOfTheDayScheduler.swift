import Foundation
import UserNotifications
import WidgetKit

// Notification content resolved from the live dictionary for a specific saved word.
private struct WordOfTheDayLiveContent {
    let kana: String?
    let meaning: String
}

private struct WordOfTheDayCachedContent: Codable {
    let kana: String?
    let meaning: String
}

private struct WordOfTheDayScheduleState: Codable {
    let signature: String
    let requestCount: Int
    let updatedAt: Date
}

// Schedules and manages daily Word of the Day push notifications using saved vocabulary.
// Adapted from Kyouku's WordOfTheDayScheduler; uses SavedWord + DictionaryStore instead of Word + DictionaryEntryDetailsCache.
enum WordOfTheDayScheduler {
    static let enabledKey = "wordOfTheDay.enabled"
    static let hourKey = "wordOfTheDay.hour"
    static let minuteKey = "wordOfTheDay.minute"
    private static let liveContentCacheKey = "wordOfTheDay.liveContentCache.v1"
    private static let scheduleStateKey = "wordOfTheDay.scheduleState.v1"
    private static let snapshotSignatureKey = "wordOfTheDay.snapshotSignature.v1"
    private static let scheduleSignatureVersion = 1

    // Notification request identifiers use this prefix for batch filtering.
    nonisolated static let requestPrefix = "wotd_"

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
        daysToSchedule: Int = 14,
        forceRefresh: Bool = false
    ) async {
        StartupTimer.mark("WOTD.refreshScheduleIfEnabled entered enabled=\(enabled) words=\(words.count) force=\(forceRefresh)")
        guard enabled else {
            await clearPendingWordOfTheDayRequests()
            clearPersistedScheduleState()
            clearWidgetSnapshot()
            StartupTimer.mark("WOTD.refreshScheduleIfEnabled cleared pending because disabled")
            return
        }

        let status = await authorizationStatus()
        StartupTimer.mark("WOTD.authorizationStatus = \(status.rawValue)")
        guard status == .authorized || status == .provisional else {
            await clearPendingWordOfTheDayRequests()
            clearPersistedScheduleState()
            clearWidgetSnapshot()
            StartupTimer.mark("WOTD.refreshScheduleIfEnabled cleared pending because unauthorized")
            return
        }

        // Keep the widget snapshot — the single deterministic source the widget reads — in sync with
        // the current saved words and schedule time. Resolving content is gated by a signature so an
        // unchanged launch does no dictionary work. The resolved list is reused for scheduling below.
        var orderedResolved: [WordOfTheDayWord]?
        if let dictionaryStore {
            orderedResolved = refreshWidgetSnapshotIfNeeded(
                words: words,
                dictionaryStore: dictionaryStore,
                hour: hour,
                minute: minute,
                forceRefresh: forceRefresh
            )
        }

        let pendingCount = await pendingWordOfTheDayRequestCount()
        if forceRefresh == false, pendingCount > 0 {
            StartupTimer.mark("WOTD.refreshScheduleIfEnabled skipping because pending requests already exist (\(pendingCount))")
            return
        }

        let expectedRequestCount = expectedScheduledRequestCount(words: words, daysToSchedule: daysToSchedule)
        let signature = scheduleSignature(words: words, hour: hour, minute: minute, daysToSchedule: daysToSchedule)
        if forceRefresh == false,
           isExistingScheduleFresh(signature: signature, expectedRequestCount: expectedRequestCount, pendingCount: pendingCount) {
            StartupTimer.mark("WOTD.refreshScheduleIfEnabled keeping existing schedule pending=\(pendingCount)")
            return
        }

        guard let dictionaryStore else {
            StartupTimer.mark("WOTD.refreshScheduleIfEnabled missing dictionaryStore")
            return
        }
        let resolved = orderedResolved ?? orderedResolvedWords(words, using: dictionaryStore)
        await scheduleUpcoming(
            words: resolved,
            hour: hour,
            minute: minute,
            daysToSchedule: daysToSchedule,
            scheduleSignature: signature
        )
        StartupTimer.mark("WOTD.refreshScheduleIfEnabled completed scheduleUpcoming")
    }

    // Sends a test notification with a 10-second delay using a random saved word. The delay is
    // long enough to fully quit the app before it fires, so the tap exercises the real cold-launch
    // deep-link path (dictionary still loading) — a 1-second delay only ever fired while the app
    // was still foregrounded, which can't reproduce the cold-launch detail-load behavior.
    static func sendTestNotification(word: SavedWord?, dictionaryStore: DictionaryStore?) async {
        guard let word, let dictionaryStore else { return }
        let live = resolveLiveContent(for: [word], using: dictionaryStore)
        guard let liveContent = live[word.canonicalEntryID] else { return }
        let testWord = WordOfTheDayWord(
            entryID: word.canonicalEntryID,
            surface: word.surface.trimmingCharacters(in: .whitespacesAndNewlines),
            kana: liveContent.kana,
            meaning: liveContent.meaning
        )
        let content = makeContent(for: testWord)
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 10, repeats: false)
        let request = UNNotificationRequest(
            identifier: requestPrefix + "test_\(UUID().uuidString)",
            content: content,
            trigger: trigger
        )
        _ = await addRequest(request)
    }

    // MARK: - Widget snapshot

    // Rebuilds and writes the widget snapshot when the saved words or schedule time have changed
    // (always when forceRefresh). Returns the resolved, ordered word list when it (re)built one so
    // the caller can reuse it for scheduling, or nil when nothing changed. Gating on a signature
    // keeps unchanged launches free of dictionary work.
    private static func refreshWidgetSnapshotIfNeeded(
        words: [SavedWord],
        dictionaryStore: DictionaryStore,
        hour: Int,
        minute: Int,
        forceRefresh: Bool
    ) -> [WordOfTheDayWord]? {
        let signature = snapshotSignature(words: words, hour: hour, minute: minute)
        let isFresh = signature == loadPersistedSnapshotSignature() && WordOfTheDay.loadSnapshot() != nil
        guard forceRefresh || isFresh == false else { return nil }

        let resolved = orderedResolvedWords(words, using: dictionaryStore)
        let snapshot = WordOfTheDaySnapshot(enabled: true, hour: hour, minute: minute, words: resolved)
        WordOfTheDay.write(snapshot)
        persistSnapshotSignature(signature)
        WidgetCenter.shared.reloadAllTimelines()
        StartupTimer.mark("WOTD.refreshWidgetSnapshot wrote \(resolved.count) words")
        return resolved
    }

    // Clears the snapshot (and refreshes the widget) when WOTD is disabled or unauthorized, so the
    // widget shows its empty state instead of a stale word.
    private static func clearWidgetSnapshot() {
        WordOfTheDay.clear()
        UserDefaults.standard.removeObject(forKey: snapshotSignatureKey)
        WidgetCenter.shared.reloadAllTimelines()
    }

    // Resolves the saved words to display content in a stable, de-duplicated order (sorted by entry
    // id) so the day→word rotation is deterministic and identical on the app and widget sides.
    private static func orderedResolvedWords(_ words: [SavedWord], using dictionaryStore: DictionaryStore) -> [WordOfTheDayWord] {
        let ordered = words.sorted { $0.canonicalEntryID < $1.canonicalEntryID }
        var seen = Set<Int64>()
        var unique: [SavedWord] = []
        unique.reserveCapacity(ordered.count)
        for word in ordered where seen.insert(word.canonicalEntryID).inserted {
            unique.append(word)
        }

        let live = StartupTimer.measure("WOTD.resolveLiveContent") {
            resolveLiveContent(for: unique, using: dictionaryStore)
        }
        return unique.compactMap { word in
            guard let content = live[word.canonicalEntryID] else { return nil }
            return WordOfTheDayWord(
                entryID: word.canonicalEntryID,
                surface: word.surface.trimmingCharacters(in: .whitespacesAndNewlines),
                kana: content.kana,
                meaning: content.meaning
            )
        }
    }

    // MARK: - Internals

    // Clears the existing notification queue and rebuilds it deterministically: each upcoming day's
    // notification announces the same word the widget computes for that day. Up to 30 days (iOS caps
    // pending notifications at 64).
    private static func scheduleUpcoming(
        words: [WordOfTheDayWord],
        hour: Int,
        minute: Int,
        daysToSchedule: Int,
        scheduleSignature: String
    ) async {
        StartupTimer.mark("WOTD.scheduleUpcoming entered words=\(words.count) days=\(daysToSchedule)")
        await clearPendingWordOfTheDayRequests()
        guard words.isEmpty == false else {
            persistScheduleState(signature: scheduleSignature, requestCount: 0)
            return
        }

        let calendar = Calendar.current
        let now = Date()
        let count = max(1, min(daysToSchedule, 30))
        var scheduled = 0

        for dayOffset in 0..<count {
            guard let day = calendar.date(byAdding: .day, value: dayOffset, to: now) else { continue }
            var comps = calendar.dateComponents([.year, .month, .day], from: day)
            comps.hour = max(0, min(23, hour))
            comps.minute = max(0, min(59, minute))

            // Same deterministic selection the widget uses, so notification and widget agree.
            let dayNumber = WordOfTheDay.dayNumber(for: day, calendar: calendar)
            guard let word = WordOfTheDay.word(forDayNumber: dayNumber, in: words) else { continue }
            let content = makeContent(for: word)
            let trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)
            let id = requestPrefix + identifierDateString(from: comps)
            let request = UNNotificationRequest(identifier: id, content: content, trigger: trigger)
            _ = await addRequest(request)
            scheduled += 1
        }
        persistScheduleState(signature: scheduleSignature, requestCount: scheduled)
        StartupTimer.mark("WOTD.scheduleUpcoming enqueued \(scheduled) requests")
    }

    // The number of notifications a refresh will schedule: one per day in the horizon when there are
    // words to announce, else none.
    private static func expectedScheduledRequestCount(words: [SavedWord], daysToSchedule: Int) -> Int {
        guard words.isEmpty == false else { return 0 }
        return max(1, min(daysToSchedule, 30))
    }

    // Computes a stable signature so the scheduler can keep existing notifications when nothing relevant changed.
    private static func scheduleSignature(words: [SavedWord], hour: Int, minute: Int, daysToSchedule: Int) -> String {
        let uniqueEntryIDs = Array(Set(words.map(\.canonicalEntryID))).sorted()
        let idsPart = uniqueEntryIDs.map(String.init).joined(separator: ",")
        return "v\(scheduleSignatureVersion)|h:\(hour)|m:\(minute)|d:\(min(daysToSchedule, 30))|ids:\(idsPart)"
    }

    // Signature of the widget snapshot's inputs (saved words + schedule time). The snapshot does not
    // depend on how many days are scheduled, so it has its own signature distinct from the schedule.
    private static func snapshotSignature(words: [SavedWord], hour: Int, minute: Int) -> String {
        let uniqueEntryIDs = Array(Set(words.map(\.canonicalEntryID))).sorted()
        let idsPart = uniqueEntryIDs.map(String.init).joined(separator: ",")
        return "v\(scheduleSignatureVersion)|h:\(hour)|m:\(minute)|ids:\(idsPart)"
    }

    // Loads the signature of the inputs the last-written snapshot was built from.
    private static func loadPersistedSnapshotSignature() -> String? {
        UserDefaults.standard.string(forKey: snapshotSignatureKey)
    }

    // Persists the snapshot signature so unchanged launches can skip rebuilding it.
    private static func persistSnapshotSignature(_ signature: String) {
        UserDefaults.standard.set(signature, forKey: snapshotSignatureKey)
    }

    // Returns true when the persisted schedule metadata still matches the current configuration and system queue.
    private static func isExistingScheduleFresh(signature: String, expectedRequestCount: Int, pendingCount: Int) -> Bool {
        guard let state = loadPersistedScheduleState() else { return false }
        guard state.signature == signature else { return false }
        return state.requestCount == expectedRequestCount && pendingCount == expectedRequestCount
    }

    // Builds the notification content for a resolved word. userInfo carries the fields the deep-link
    // handler reads when the notification is tapped.
    private static func makeContent(for word: WordOfTheDayWord) -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        content.title = "Word of the Day"

        let surface = word.surface.trimmingCharacters(in: .whitespacesAndNewlines)
        let meaning = word.meaning.trimmingCharacters(in: .whitespacesAndNewlines)
        let kana = word.kana?.trimmingCharacters(in: .whitespacesAndNewlines)

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
        content.userInfo["wordID"] = String(word.entryID)

        return content
    }

    // Fetches the kana reading and first gloss for each unique entry ID.
    // Runs synchronously on the caller's thread; DictionaryStore serializes access internally.
    private static func resolveLiveContent(
        for words: [SavedWord],
        using dictionaryStore: DictionaryStore
    ) -> [Int64: WordOfTheDayLiveContent] {
        let uniqueIDs = Array(Set(words.map(\.canonicalEntryID)))
        var cached = loadCachedLiveContent()
        var out: [Int64: WordOfTheDayLiveContent] = [:]
        out.reserveCapacity(uniqueIDs.count)
        var missingIDs: [Int64] = []

        for entryID in uniqueIDs {
            if let cachedContent = cached[entryID] {
                out[entryID] = WordOfTheDayLiveContent(
                    kana: cachedContent.kana,
                    meaning: cachedContent.meaning
                )
            } else {
                missingIDs.append(entryID)
            }
        }

        guard missingIDs.isEmpty == false else { return out }

        StartupTimer.mark("WOTD.resolveLiveContent missing cache entries=\(missingIDs.count)")
        for entryID in missingIDs {
            guard let entry = try? dictionaryStore.lookupEntry(entryID: entryID) else { continue }

            let kana = entry.kanaForms.first.flatMap { form -> String? in
                let trimmed = form.text.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty ? nil : trimmed
            }

            let meaning = entry.senses.first?.glosses.first ?? ""
            out[entryID] = WordOfTheDayLiveContent(kana: kana, meaning: meaning)
            cached[entryID] = WordOfTheDayCachedContent(kana: kana, meaning: meaning)
        }

        persistCachedLiveContent(cached)
        return out
    }

    // Loads cached dictionary-derived notification content keyed by entry id.
    private static func loadCachedLiveContent() -> [Int64: WordOfTheDayCachedContent] {
        guard
            let data = UserDefaults.standard.data(forKey: liveContentCacheKey),
            let decoded = try? JSONDecoder().decode([String: WordOfTheDayCachedContent].self, from: data)
        else {
            return [:]
        }

        var result: [Int64: WordOfTheDayCachedContent] = [:]
        result.reserveCapacity(decoded.count)
        for (key, value) in decoded {
            if let id = Int64(key) {
                result[id] = value
            }
        }
        return result
    }

    // Persists cached notification content so subsequent schedule refreshes can skip dictionary lookups.
    private static func persistCachedLiveContent(_ cache: [Int64: WordOfTheDayCachedContent]) {
        var encoded: [String: WordOfTheDayCachedContent] = [:]
        encoded.reserveCapacity(cache.count)
        for (key, value) in cache {
            encoded[String(key)] = value
        }
        guard let data = try? JSONEncoder().encode(encoded) else { return }
        UserDefaults.standard.set(data, forKey: liveContentCacheKey)
    }

    // Loads the last successfully scheduled batch metadata.
    private static func loadPersistedScheduleState() -> WordOfTheDayScheduleState? {
        guard
            let data = UserDefaults.standard.data(forKey: scheduleStateKey),
            let decoded = try? JSONDecoder().decode(WordOfTheDayScheduleState.self, from: data)
        else {
            return nil
        }
        return decoded
    }

    // Persists schedule metadata so launch-time validation can keep an unchanged batch.
    private static func persistScheduleState(signature: String, requestCount: Int) {
        let state = WordOfTheDayScheduleState(signature: signature, requestCount: requestCount, updatedAt: Date())
        guard let data = try? JSONEncoder().encode(state) else { return }
        UserDefaults.standard.set(data, forKey: scheduleStateKey)
    }

    // Clears persisted schedule metadata when WOTD is disabled or unauthorized.
    private static func clearPersistedScheduleState() {
        UserDefaults.standard.removeObject(forKey: scheduleStateKey)
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
