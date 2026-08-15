import SwiftUI

// The single start screen behind every Learn activity, rendered from a `LearnActivity` descriptor
// and the activity's persisted `LearnActivityOptions`. Replaces three hand-built Forms that drifted
// apart while offering the same controls. Activities that need a control of their own (Flashcards'
// typed-answer toggle) pass it as `extraSections`; everything else is shared here.
struct LearnActivityHome<Extra: View>: View {
    let activity: LearnActivity
    @ObservedObject var options: LearnActivityOptions
    let dictionaryStore: DictionaryStore?
    // Words that pass every filter AND can be asked at least one of the ticked directions.
    let poolCount: Int
    let onStart: () -> Void
    @ViewBuilder var extraSections: Extra

    var body: some View {
        LearnHomeForm(
            startTitle: activity.startTitle,
            startEnabled: poolCount >= activity.minimumPoolSize && options.directions.isEmpty == false,
            onStart: onStart
        ) {
            Section {
                FlashcardNotePicker(selectedNoteIDs: $options.selectedNoteIDs)
                FlashcardJLPTPicker(dictionaryStore: dictionaryStore, selectedLevels: $options.selectedJLPTLevels)
            }

            directionSection(QuestionDirection.tier1, header: "Recognition")
            directionSection(QuestionDirection.tier2, header: "Production")

            Section {
                Picker("Scope", selection: $options.scope) {
                    ForEach(FlashcardScope.allCases) { scope in
                        Text(scope.label).tag(scope)
                    }
                }
                .pickerStyle(.segmented)
            }

            Section {
                LearnCountField(label: activity.unitLabel, count: $options.count)
            }

            extraSections

            countsSection
        }
    }

    // One tier's directions as individual toggles. Split across two sections because the tiers are
    // exactly the Learned and Mastered bars — ticking a whole section is how you drill one stage.
    @ViewBuilder
    private func directionSection(_ tier: [QuestionDirection], header: String) -> some View {
        Section {
            ForEach(tier.filter(activity.supportedDirections.contains)) { direction in
                Toggle(direction.label, isOn: binding(for: direction))
            }
        } header: {
            Text(header)
        }
    }

    // Toggling a direction in or out of the persisted selection. Writing through the whole
    // `DirectionSelection` (rather than mutating the set in place) is what triggers the options
    // object's `didSet` persistence.
    private func binding(for direction: QuestionDirection) -> Binding<Bool> {
        Binding(
            get: { options.directions.directions.contains(direction) },
            set: { isOn in
                var next = options.directions.directions
                if isOn { next.insert(direction) } else { next.remove(direction) }
                options.directions = DirectionSelection(directions: next)
            }
        )
    }

    // The pool the session draws from, and how many questions that actually yields once the count
    // cap applies. Two numbers rather than one because they answer different questions: the pool
    // says how much of your collection this configuration reaches, the question count says how long
    // the session will be.
    private var countsSection: some View {
        Section {
            LabeledContent("Words in pool") {
                Text("\(poolCount)")
                    .monospacedDigit()
                    .foregroundStyle(poolCount < activity.minimumPoolSize ? .red : .primary)
            }
            LabeledContent(activity.unitLabel) {
                Text("\(plannedQuestionCount)")
                    .monospacedDigit()
            }
        }
    }

    // How many items the session will run: the whole pool, or the cap when one is set and it bites.
    private var plannedQuestionCount: Int {
        options.count > 0 ? min(poolCount, options.count) : poolCount
    }
}
