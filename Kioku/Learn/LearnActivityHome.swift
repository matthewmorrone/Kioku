import SwiftUI

// The single start screen behind every Learn activity, rendered from a `LearnActivity` descriptor
// and the activity's persisted `LearnActivityOptions`. Replaces three hand-built Forms that drifted
// apart while offering the same controls — all three now configure identically, so this takes no
// per-activity content at all.
struct LearnActivityHome: View {
    let activity: LearnActivity
    @ObservedObject var options: LearnActivityOptions
    let dictionaryStore: DictionaryStore?
    // Words that pass every filter AND can be asked at least one of the ticked directions, plus
    // how many the learned exclusion held back.
    let pool: StudyWordSelection
    let onStart: () -> Void

    var body: some View {
        LearnHomeForm(
            startTitle: activity.startTitle,
            startEnabled: pool.words.count >= activity.minimumPoolSize && options.directions.isEmpty == false,
            onStart: onStart
        ) {
            Section {
                FlashcardNotePicker(selectedNoteIDs: $options.selectedNoteIDs)
                FlashcardJLPTPicker(dictionaryStore: dictionaryStore, selectedLevels: $options.selectedJLPTLevels)
                LearnDirectionPicker(
                    supported: activity.supportedDirections,
                    selection: $options.directions
                )
            }

            Section {
                Picker("Scope", selection: $options.scope) {
                    ForEach(FlashcardScope.allCases) { scope in
                        Text(scope.label).tag(scope)
                    }
                }
                .pickerStyle(.segmented)
            }

            countsSection
        }
    }

    // How much of the collection this configuration reaches, and the cap on how much of it to run.
    // No third "and so the session will be N long" row: that is just min(pool, limit), readable
    // from the two numbers above it, and it can't be exact anyway — words that can't supply the
    // selected directions only drop out during the dictionary resolution that Start kicks off. The
    // session header reports the real count once it's known.
    private var countsSection: some View {
        Section {
            LabeledContent("Words in pool") {
                Text("\(pool.words.count)")
                    .monospacedDigit()
                    .foregroundStyle(pool.words.count < activity.minimumPoolSize ? .red : .primary)
            }
            LearnCountPicker(label: activity.unitLabel, count: $options.count)
        }
    }
}

// Multiselect popover choosing which of the 6 directions a session draws from. The trigger is a
// plain row; the popover holds every tier and direction row flat and always visible — no folding —
// sized tall enough up front that all 8 rows fit without scrolling. Recognition and Production
// (exactly the Learned and Mastered bars) are themselves the tier-select controls — tapping either
// toggles that whole tier and checkmarks when it's fully selected — with their directions listed
// directly beneath, so there's no separate "All Recognition"/"All Production" row repeating a title
// that's already right there.
struct LearnDirectionPicker: View {
    let supported: [QuestionDirection]
    @Binding var selection: DirectionSelection
    @State private var isPresented = false

    var body: some View {
        HStack {
            Text("Directions")
            Spacer()
            Button(summary) { isPresented = true }
        }
        .popover(isPresented: $isPresented) {
            List {
                tierRows(QuestionDirection.tier1, title: "Recognition")
                tierRows(QuestionDirection.tier2, title: "Production")
            }
            .listStyle(.plain)
            .frame(minWidth: 220, idealHeight: 420)
            .presentationCompactAdaptation(.popover)
        }
    }

    // One tier: a row that takes or drops the whole tier (the tier name doubles as its own "select
    // all" control), followed directly by its individual directions.
    @ViewBuilder
    private func tierRows(_ tier: [QuestionDirection], title: String) -> some View {
        let directions = tier.filter(supported.contains)
        let tierFullySelected = directions.isEmpty == false && directions.allSatisfy(selection.directions.contains)
        Button { toggleTier(directions) } label: {
            HStack {
                Text(title)
                Spacer()
                if tierFullySelected {
                    Image(systemName: "checkmark")
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        ForEach(directions) { direction in
            Button { toggle(direction) } label: {
                HStack {
                    Text(direction.label).padding(.leading, 16)
                    Spacer()
                    if selection.directions.contains(direction) {
                        Image(systemName: "checkmark")
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    // Adds or removes one direction. Writing a whole new `DirectionSelection` (rather than mutating
    // the set through the binding) is what triggers the options object's persistence.
    private func toggle(_ direction: QuestionDirection) {
        var next = selection.directions
        if next.contains(direction) { next.remove(direction) } else { next.insert(direction) }
        selection = DirectionSelection(directions: next)
    }

    // Takes the whole tier, or drops it when it's already fully selected.
    private func toggleTier(_ directions: [QuestionDirection]) {
        var next = selection.directions
        if directions.allSatisfy(next.contains) {
            for direction in directions { next.remove(direction) }
        } else {
            for direction in directions { next.insert(direction) }
        }
        selection = DirectionSelection(directions: next)
    }

    // Short label describing the current selection for the menu's trigger text. Names the tier when
    // the selection is exactly one of them, since "the three that gate Learned" is a selection
    // worth recognising at a glance rather than reading back as a count.
    private var summary: String {
        let chosen = selection.directions
        if chosen.isEmpty { return "None" }
        if chosen.count == supported.count { return "All" }
        if chosen == Set(QuestionDirection.tier1.filter(supported.contains)) { return "Recognition" }
        if chosen == Set(QuestionDirection.tier2.filter(supported.contains)) { return "Production" }
        if chosen.count == 1, let only = chosen.first { return only.label }
        return "\(chosen.count) directions"
    }
}
