import SwiftUI

// One foldable line in a conjugation card: a non-past head row and the negative/past rows tucked under it.
struct ConjugationCluster {
    // Stable key for the expansion state — group name plus the head row's label.
    let id: String
    // The row always shown (e.g. 食べる, 食べます, 食べれば).
    let head: ConjugationRow
    // Negative / past / negative-past variants revealed by the chevron.
    let variants: [ConjugationRow]
}

// Bottom sheet showing all conjugation groups for a word.
// Renders each ConjugationGroup as a rounded card with Japanese on the left
// and the English row label (secondary, small) on the right.
// Each row is tappable — tapping speaks the conjugated form aloud. Negative and past
// rows fold under their non-past form behind a chevron.
// Screen: ConjugationSheetView, presented from WordDetailView.
// Layout sections: drag handle, title bar, scrollable card list, obscure-forms toggle at the bottom.
struct ConjugationSheetView: View {
    // The dictionary form shown in the title bar.
    let dictionaryForm: String
    // All conjugation groups to display.
    let groups: [ConjugationGroup]

    // Cluster ids whose negative/past rows are unfolded.
    @State private var expandedClusters: Set<String> = []
    // Whether literary/archaic rows (ず, ぬ, ん, まい, たろう) are listed.
    @AppStorage("conjugationSheet.showObscure") private var showObscure = false

    // Speaks a conjugated surface aloud via the app-wide shared synthesizer.
    private func speak(_ text: String) {
        SpeechSynthesisHelper.shared.speak(text, languageCode: "ja-JP")
    }

    // True for rows that are the negative or past of the row above them, so they fold under it.
    private func isTenseVariant(_ row: ConjugationRow) -> Bool {
        row.label.hasPrefix("Negative") || row.label.hasPrefix("Past")
    }

    // Splits a group's visible rows into head rows each followed by their negative/past variants.
    // A leading variant with no head above it (after obscure rows are hidden) becomes a head itself.
    private func clusters(for group: ConjugationGroup) -> [ConjugationCluster] {
        let rows = group.rows.filter { showObscure || !$0.isObscure }
        var result: [ConjugationCluster] = []
        for row in rows {
            if isTenseVariant(row), let last = result.last {
                result[result.count - 1] = ConjugationCluster(id: last.id, head: last.head, variants: last.variants + [row])
            } else {
                result.append(ConjugationCluster(id: group.name + "/" + row.label, head: row, variants: []))
            }
        }
        return result
    }

    // One tappable line: surface on the left, English label on the right, optional fold chevron.
    @ViewBuilder
    private func rowView(_ row: ConjugationRow, chevronFor cluster: ConjugationCluster? = nil) -> some View {
        HStack {
            Button {
                speak(row.surface)
            } label: {
                HStack {
                    Text(row.surface)
                        .foregroundStyle(.primary)
                    Spacer()
                    Text(row.label)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            if let cluster {
                let isExpanded = expandedClusters.contains(cluster.id)
                Button {
                    withAnimation {
                        if isExpanded {
                            expandedClusters.remove(cluster.id)
                        } else {
                            expandedClusters.insert(cluster.id)
                        }
                    }
                } label: {
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
            }
        }
    }

    var body: some View {
        NavigationStack {
            List {
                ForEach(groups) { group in
                    let groupClusters = clusters(for: group)
                    if !groupClusters.isEmpty {
                        Section {
                            ForEach(groupClusters, id: \.id) { cluster in
                                rowView(cluster.head, chevronFor: cluster.variants.isEmpty ? nil : cluster)
                                if expandedClusters.contains(cluster.id) {
                                    ForEach(Array(cluster.variants.enumerated()), id: \.offset) { _, variant in
                                        rowView(variant)
                                            .padding(.leading, 16)
                                    }
                                }
                            }
                        } header: {
                            Text(group.name)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .textCase(nil)
                        }
                    }
                }
                Section {
                    Button(showObscure ? "Hide Obscure Forms" : "Show Obscure Forms") {
                        withAnimation { showObscure.toggle() }
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle(dictionaryForm)
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}
