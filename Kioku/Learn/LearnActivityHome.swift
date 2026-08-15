import SwiftUI

// The single start screen behind every Learn activity, rendered from a `LearnActivity` descriptor
// and the activity's persisted `LearnActivityOptions`. Replaces three hand-built Forms that drifted
// apart while offering the same controls — all three now configure identically, so this takes no
// per-activity content at all.
struct LearnActivityHome: View {
    let activity: LearnActivity
    @ObservedObject var options: LearnActivityOptions
    let dictionaryStore: DictionaryStore?
    // Words that pass every filter AND can be asked at least one of the ticked directions.
    let poolCount: Int
    let onStart: () -> Void

    var body: some View {
        LearnHomeForm(
            startTitle: activity.startTitle,
            startEnabled: poolCount >= activity.minimumPoolSize && options.directions.isEmpty == false,
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
                Text("\(poolCount)")
                    .monospacedDigit()
                    .foregroundStyle(poolCount < activity.minimumPoolSize ? .red : .primary)
            }
            LearnCountPicker(label: activity.unitLabel, count: $options.count)
        }
    }
}

// Multiselect dropdown choosing which of the 6 directions a session draws from — the same Menu
// idiom as the note and JLPT pickers it sits beside, rather than a row of toggles. The menu is
// split into Recognition and Production sections because those groups are exactly the Learned and
// Mastered bars, with a header button on each to take or drop the whole tier in one tap.
struct LearnDirectionPicker: View {
    let supported: [QuestionDirection]
    @Binding var selection: DirectionSelection

    var body: some View {
        HStack {
            Text("Directions")
            Spacer()
            Menu(summary) {
                Button { selection = DirectionSelection(directions: Set(supported)) } label: {
                    if selection.directions.count == supported.count {
                        Label("All", systemImage: "checkmark")
                    } else {
                        Text("All")
                    }
                }
                tierSection(QuestionDirection.tier1, title: "Recognition")
                tierSection(QuestionDirection.tier2, title: "Production")
            }
        }
    }

    // One tier: a button that takes or drops the whole tier, then its individual directions.
    @ViewBuilder
    private func tierSection(_ tier: [QuestionDirection], title: String) -> some View {
        let directions = tier.filter(supported.contains)
        Section(title) {
            Button { toggleTier(directions) } label: {
                if directions.allSatisfy(selection.directions.contains) {
                    Label("All \(title)", systemImage: "checkmark")
                } else {
                    Text("All \(title)")
                }
            }
            ForEach(directions) { direction in
                Button { toggle(direction) } label: {
                    if selection.directions.contains(direction) {
                        Label(direction.label, systemImage: "checkmark")
                    } else {
                        Text(direction.label)
                    }
                }
            }
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
