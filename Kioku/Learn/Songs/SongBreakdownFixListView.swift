import SwiftUI

// The Breakdown's fix list: the readings, word breaks and typos the model flagged in the song,
// each with the line it's in, before → after, and Fix / Ignore. Shown when a breakdown finishes
// with suggestions, and from the banner over the Breakdown while any are left.
//
// Layout: a List with one section per suggestion (kind, line, before → after, buttons) and a
// footer explaining what Fix does; toolbar Done and Fix All.
struct SongBreakdownFixListView: View {
    let items: [SongBreakdownFixItem]
    // Whether a fix can be applied here (its line is found in the note and the Read tab is behind
    // the sheet); one that can't shows only Ignore.
    let canApply: (SongBreakdownFixItem) -> Bool
    // Applies a fix; false when the note no longer holds its text or the edit was refused.
    let onFix: (SongBreakdownFixItem) -> Bool
    let onIgnore: (SongBreakdownFixItem) -> Void
    let onFixAll: () -> Void
    let onDone: () -> Void

    @State private var failedIDs: Set<String> = []

    var body: some View {
        List {
            if items.isEmpty {
                Text("No suggestions left.")
                    .foregroundStyle(.secondary)
            }
            ForEach(items) { item in
                Section {
                    row(item)
                }
            }
            Section {
                EmptyView()
            } footer: {
                Text("Suggested by the breakdown, which can be wrong. Fix makes the change in the note, the same as editing it on the Read tab: a reading is pinned, words are merged or split, and a typo is corrected in the text. Ignore drops the suggestion.")
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button("Done", action: onDone)
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button("Fix All", action: onFixAll)
                    .disabled(items.contains(where: canApply) == false)
            }
        }
    }

    // One suggestion: what kind it is, the line, before → after, and its buttons.
    private func row(_ item: SongBreakdownFixItem) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(kindLabel(item.fix.kind))
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(item.lineText)
                .font(.footnote)
                .foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(before(item.fix))
                    .strikethrough(item.fix.kind == .typo)
                Image(systemName: "arrow.right")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(after(item.fix))
                    .fontWeight(.semibold)
            }
            .font(.title3)
            if failedIDs.contains(item.id) {
                Text("Couldn't apply this: the note no longer has this text, or the change isn't allowed there.")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            HStack(spacing: 12) {
                if canApply(item) {
                    Button("Fix") {
                        if onFix(item) == false { failedIDs.insert(item.id) }
                    }
                    .buttonStyle(.borderedProminent)
                }
                Button("Ignore") { onIgnore(item) }
                    .buttonStyle(.bordered)
            }
            .controlSize(.small)
        }
        .padding(.vertical, 4)
    }

    // The section label for a fix's kind.
    private func kindLabel(_ kind: SongLineFixKind) -> String {
        switch kind {
        case .reading: return "Reading"
        case .split: return "Word breaks"
        case .typo: return "Possible typo"
        }
    }

    // The fix's left side: the word and its current reading, the current word breaks, or the text.
    private func before(_ fix: SongLineFix) -> String {
        switch fix.kind {
        case .reading: return "\(fix.originalSurface) \(fix.originalReading)"
        case .split: return fix.originalWords.joined(separator: " | ")
        case .typo: return fix.originalSurface
        }
    }

    // The fix's right side, in the same form as `before`.
    private func after(_ fix: SongLineFix) -> String {
        switch fix.kind {
        case .reading: return fix.replacementReading
        case .split: return fix.replacementWords.joined(separator: " | ")
        case .typo: return fix.replacementSurface
        }
    }
}
