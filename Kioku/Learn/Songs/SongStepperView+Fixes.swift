import Foundation
import SwiftUI

// The Breakdown's suggested fixes (SongLineFix): which are still pending, applying one through the
// Read tab (`onApplyFix`), and dropping it from the saved breakdown once it's fixed or ignored. A typo
// fix also rewrites the breakdown's copy of the line and its text hash, so correcting the note doesn't
// mark the breakdown stale.
extension SongStepperView {
    // Every fix still waiting in the saved breakdown, in line order.
    var pendingFixItems: [SongBreakdownFixItem] {
        (cachedBreakdown?.lines ?? []).flatMap { line in
            (line.fixes ?? []).map { SongBreakdownFixItem(lineIndex: line.index, lineText: line.original, fix: $0) }
        }
    }

    // Whether `item` can be applied: the Read tab is behind the sheet and the line is found in the note.
    func canApplyFix(_ item: SongBreakdownFixItem) -> Bool {
        guard onApplyFix != nil, let lines = cachedBreakdown?.lines else { return false }
        return SongBreakdownLineLocator.noteRanges(for: lines, in: note.content)[item.lineIndex] != nil
    }

    // Applies `item` in the note and drops it from the breakdown; false when it couldn't be placed.
    @discardableResult
    func applyFix(_ item: SongBreakdownFixItem) -> Bool {
        applyFix(item, noteText: note.content) != nil
    }

    // Applies every pending fix: readings and word breaks first, then typos from the last line up, so
    // text edits never move a line another fix still needs. Ones that can't be placed stay pending.
    func applyAllFixes() {
        let items = pendingFixItems
        var noteText = note.content
        let typos = items.filter { $0.fix.kind == .typo }.sorted { $0.lineIndex > $1.lineIndex }
        for item in items.filter({ $0.fix.kind != .typo }) + typos {
            if let updated = applyFix(item, noteText: noteText) { noteText = updated }
        }
    }

    // Removes `item` from the breakdown without changing the note.
    func ignoreFix(_ item: SongBreakdownFixItem) {
        resolve(item, applied: false, noteText: nil)
    }

    // Applies `item` against `noteText` (the note as the previous fix left it); the note text afterwards,
    // or nil when the line isn't in the note or the Read tab refused the edit.
    private func applyFix(_ item: SongBreakdownFixItem, noteText: String) -> String? {
        guard let onApplyFix, let lines = cachedBreakdown?.lines,
              let lineRange = SongBreakdownLineLocator.noteRanges(for: lines, in: noteText)[item.lineIndex],
              let updated = onApplyFix(item.fix, lineRange) else { return nil }
        resolve(item, applied: true, noteText: updated)
        return updated
    }

    // Saves the breakdown with `item` resolved; after an applied typo the hash follows the new note text.
    private func resolve(_ item: SongBreakdownFixItem, applied: Bool, noteText: String?) {
        guard let breakdown = cachedBreakdown else { return }
        let isTypo = applied && item.fix.kind == .typo
        songBreakdownStore.setBreakdown(SongBreakdown(
            noteID: breakdown.noteID,
            sourceTextHash: isTypo ? noteText.map(SongBreakdownService.sha256) ?? breakdown.sourceTextHash : breakdown.sourceTextHash,
            generatedAt: breakdown.generatedAt,
            provider: breakdown.provider,
            lines: breakdown.lines.map { $0.index == item.lineIndex ? $0.resolving(item.fix, applied: applied) : $0 },
            schemaVersion: breakdown.schemaVersion
        ))
    }

    // The banner over a finished breakdown while suggestions are left; opens the fix list.
    var fixesBanner: some View {
        let count = pendingFixItems.count
        return HStack(spacing: 10) {
            Image(systemName: "wand.and.stars")
                .foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 2) {
                Text(count == 1 ? "1 suggested fix" : "\(count) suggested fixes")
                    .font(.footnote.weight(.semibold))
                Text("Readings, word breaks or typos the breakdown thinks are wrong.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Button("Review") { isFixListPresented = true }
                .font(.footnote.weight(.semibold))
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color.accentColor.opacity(0.1))
    }

    // The fix list sheet's content.
    var fixListSheet: some View {
        NavigationStack {
            SongBreakdownFixListView(
                items: pendingFixItems,
                canApply: { canApplyFix($0) },
                onFix: { applyFix($0) },
                onIgnore: { ignoreFix($0) },
                onFixAll: { applyAllFixes() },
                onDone: { isFixListPresented = false }
            )
        }
    }
}
