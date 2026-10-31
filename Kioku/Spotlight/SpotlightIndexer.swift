import CoreSpotlight
import Foundation
import UniformTypeIdentifiers

// Keeps the system Spotlight index in step with the user's notes and saved words so both are
// findable from the home screen. It is a derived cache: nothing here is persisted by the app, the
// first sync of a launch clears the app's domains and re-adds everything, and later syncs apply
// only the difference (SpotlightIndexPlan).
@MainActor
final class SpotlightIndexer {
    static let shared = SpotlightIndexer()

    private let index: CSSearchableIndex
    private var indexed: [SpotlightIdentifier: SpotlightDocument] = [:]
    private var hasClearedDomains = false
    private var pendingTask: Task<Void, Never>?

    init(index: CSSearchableIndex = .default()) {
        self.index = index
    }

    // Schedules an index update after a short quiet period, so a burst of edits (typing in a note)
    // produces one pass. `store` is nil until the dictionary is ready; words are then skipped
    // rather than indexed without readings, and the next sync (when it loads) adds them.
    func scheduleSync(notes: [Note], words: [SavedWord], store: DictionaryStore?) {
        pendingTask?.cancel()
        pendingTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(1.5))
            } catch is CancellationError {
                return
            } catch {
                AppLog.error(.storage, "[Spotlight] debounce sleep failed: \(error)")
                return
            }
            await self?.sync(notes: notes, words: words, store: store)
        }
    }

    // Builds the documents off the main actor, then applies the plan unless a newer sync superseded this one.
    private func sync(notes: [Note], words: [SavedWord], store: DictionaryStore?) async {
        var documents = notes.map { SpotlightDocumentBuilder.document(for: $0) }
        if let store {
            documents += await Task.detached(priority: .utility) {
                words.map { word in
                    SpotlightDocumentBuilder.document(
                        for: word,
                        content: WordCardContentResolver.resolve(word: word, store: store)
                    )
                }
            }.value
        }
        guard Task.isCancelled == false else { return }

        let domains: Set<String> = store == nil
            ? [SpotlightIdentifier.noteDomain]
            : [SpotlightIdentifier.noteDomain, SpotlightIdentifier.wordDomain]
        if hasClearedDomains == false {
            hasClearedDomains = true
            do {
                try await index.deleteSearchableItems(withDomainIdentifiers: [SpotlightIdentifier.noteDomain, SpotlightIdentifier.wordDomain])
            } catch {
                AppLog.error(.storage, "[Spotlight] clearing stale items failed: \(error)")
            }
            indexed = [:]
        }
        let plan = SpotlightIndexPlan.make(previous: indexed, documents: documents, domains: domains)
        guard plan.isEmpty == false else { return }
        await apply(plan)
    }

    // Sends the plan to CoreSpotlight and records what is now indexed. A failed step leaves the
    // bookkeeping unchanged so the next sync retries it.
    private func apply(_ plan: SpotlightIndexPlan) async {
        if plan.removals.isEmpty == false {
            do {
                try await index.deleteSearchableItems(withIdentifiers: plan.removals.map(\.rawValue))
                for identifier in plan.removals { indexed[identifier] = nil }
            } catch {
                AppLog.error(.storage, "[Spotlight] removing \(plan.removals.count) items failed: \(error)")
            }
        }
        if plan.upserts.isEmpty == false {
            do {
                try await index.indexSearchableItems(plan.upserts.map(Self.searchableItem(for:)))
                for document in plan.upserts { indexed[document.identifier] = document }
            } catch {
                AppLog.error(.storage, "[Spotlight] indexing \(plan.upserts.count) items failed: \(error)")
            }
        }
    }

    // Maps a document onto the CoreSpotlight item the system displays.
    private static func searchableItem(for document: SpotlightDocument) -> CSSearchableItem {
        let attributes = CSSearchableItemAttributeSet(contentType: .text)
        attributes.title = document.title
        attributes.displayName = document.title
        attributes.contentDescription = document.summary
        attributes.keywords = document.keywords
        attributes.textContent = document.bodyText
        attributes.contentModificationDate = document.modifiedAt
        return CSSearchableItem(
            uniqueIdentifier: document.identifier.rawValue,
            domainIdentifier: document.identifier.domain,
            attributeSet: attributes
        )
    }
}
