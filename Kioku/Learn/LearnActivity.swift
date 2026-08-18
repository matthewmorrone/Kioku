import Combine
import Foundation
import SwiftUI

// Which slice of the saved-word collection feeds the next session. Shared by every Learn activity
// (it predates them as `FlashcardScope`, hence the name kept here to avoid churning the picker's
// persisted values).
enum FlashcardScope: String, CaseIterable, Identifiable {
    case all
    case dueNow
    case markedWrong
    var id: String { rawValue }
    var label: String {
        switch self {
        case .all: "All"
        case .dueNow: "Due"
        case .markedWrong: "Wrong"
        }
    }
}

// The declarative description of one Learn activity — everything that differs between Flashcards,
// Multiple Choice, and Fill in the Blank once they share a pool, a direction model, and a start
// screen. Each activity keeps its own page and its own session UI (a card stack, an option list,
// and a text field are genuinely different things); what this collapses is the configuration
// surface, which was four hand-built Forms over the same handful of controls.
struct LearnActivity: Identifiable {
    // Stable key prefix for this activity's persisted options. Must not change without orphaning
    // the user's saved selections.
    let id: String
    let title: String
    let systemImage: String
    let startTitle: String
    // What one item is called in this activity — "Cards" for Flashcards, "Questions" elsewhere.
    let unitLabel: String
    // Smallest pool the activity can build a session from. Multiple Choice needs enough words to
    // draw distractors from; the others need one.
    let minimumPoolSize: Int
    // Directions this activity can actually present and grade. All six everywhere now that typed
    // English answers are graded against the word's gloss set rather than one expected string.
    let supportedDirections: [QuestionDirection]

    static let flashcards = LearnActivity(
        id: "flashcards",
        title: "Flashcards",
        systemImage: "rectangle.on.rectangle.angled",
        startTitle: "Start Flashcards",
        unitLabel: "Cards",
        minimumPoolSize: 1,
        supportedDirections: QuestionDirection.allCases
    )

    static let multipleChoice = LearnActivity(
        id: "multipleChoice",
        title: "Multiple Choice",
        systemImage: "list.bullet.circle",
        startTitle: "Start Quiz",
        unitLabel: "Questions",
        minimumPoolSize: 4,
        supportedDirections: QuestionDirection.allCases
    )

    static let fillInBlank = LearnActivity(
        id: "fillInBlank",
        title: "Fill in the Blank",
        systemImage: "square.and.pencil",
        startTitle: "Start Quiz",
        unitLabel: "Questions",
        minimumPoolSize: 1,
        supportedDirections: QuestionDirection.allCases
    )
}

// The user's persisted answer to "what should this session contain?", scoped to one activity by
// its `LearnActivity.id`. Replaces the per-view `@State` option soup, which reset to defaults every
// time the view was recreated — so a session's setup never survived leaving the tab, let alone a
// launch. Reads and writes UserDefaults directly rather than via `@AppStorage` so all five options
// share one keyspace and one load path instead of five property wrappers per activity.
@MainActor
final class LearnActivityOptions: ObservableObject {
    // Which of the 6 directions this session draws from; a word is asked whichever of these it's
    // eligible for (see `DirectionSelection`).
    @Published var directions: DirectionSelection { didSet { persist(directions.rawValue, "directions") } }
    // Notes to draw words from; empty means every note.
    @Published var selectedNoteIDs: Set<UUID> { didSet { persistNoteIDs() } }
    // JLPT levels (N-number 5…1) to include; empty means no level filter.
    @Published var selectedJLPTLevels: Set<Int> { didSet { persistJLPTLevels() } }
    @Published var scope: FlashcardScope { didSet { persist(scope.rawValue, "scope") } }
    // Cap on session length. 0 (blank field) means "everything in the pool".
    @Published var count: Int { didSet { persist(String(count), "count") } }

    private let keyPrefix: String
    private let defaults: UserDefaults

    // Loads this activity's saved options, falling back to defaults for anything never set.
    init(activity: LearnActivity, defaults: UserDefaults = .standard) {
        self.keyPrefix = "learn.\(activity.id)."
        self.defaults = defaults
        let prefix = self.keyPrefix

        // An empty stored selection would leave Start permanently disabled with no way to tell it
        // apart from "never configured", so it falls back to everything.
        let storedDirections = defaults.string(forKey: prefix + "directions")
            .map(DirectionSelection.init(rawValue:))
        directions = (storedDirections?.isEmpty == false ? storedDirections : nil) ?? .all

        selectedNoteIDs = Set(
            (defaults.stringArray(forKey: prefix + "noteIDs") ?? []).compactMap(UUID.init(uuidString:))
        )
        selectedJLPTLevels = Set(defaults.array(forKey: prefix + "jlptLevels") as? [Int] ?? [])
        scope = FlashcardScope(rawValue: defaults.string(forKey: prefix + "scope") ?? "") ?? .all
        count = defaults.object(forKey: prefix + "count") as? Int ?? 20
    }

    // Stores one string-valued option under this activity's prefix.
    private func persist(_ value: String, _ key: String) {
        defaults.set(value, forKey: keyPrefix + key)
    }

    // Note ids round-trip as strings, since UserDefaults has no UUID plist type.
    private func persistNoteIDs() {
        defaults.set(selectedNoteIDs.map(\.uuidString), forKey: keyPrefix + "noteIDs")
    }

    // Levels are stored sorted so the persisted array doesn't churn on every Set reordering.
    private func persistJLPTLevels() {
        defaults.set(selectedJLPTLevels.sorted(), forKey: keyPrefix + "jlptLevels")
    }
}
