import SwiftUI

// Shows the timing changes a fresh forced-alignment pass would apply to the existing
// subtitle file. The cue text is identical between old and new (the aligner preserves
// text); only timestamps differ. The user reviews each row and picks Apply or Cancel —
// the editor's SRT is only replaced on Apply. On Cancel the proposed SRT is discarded.
struct RetimeReviewSheet: View {
    let oldSRT: String
    let newSRT: String
    let onApply: () -> Void
    let onCancel: () -> Void

    @Environment(\.dismiss) private var dismiss

    private var oldCues: [SubtitleCue] { SubtitleParser.parse(oldSRT) }
    private var newCues: [SubtitleCue] { SubtitleParser.parse(newSRT) }

    private var rows: [RetimeReviewRow] {
        let old = oldCues
        let new = newCues
        let count = max(old.count, new.count)
        var result: [RetimeReviewRow] = []
        result.reserveCapacity(count)
        for index in 0..<count {
            let oldCue = index < old.count ? old[index] : nil
            let newCue = index < new.count ? new[index] : nil
            result.append(
                RetimeReviewRow(
                    index: index,
                    text: newCue?.text ?? oldCue?.text ?? "",
                    oldStartMs: oldCue?.startMs,
                    oldEndMs: oldCue?.endMs,
                    newStartMs: newCue?.startMs,
                    newEndMs: newCue?.endMs
                )
            )
        }
        return result
    }

    private var changedCount: Int {
        rows.filter { $0.timingChanged }.count
    }

    private var maxStartShiftMs: Int {
        rows.compactMap { $0.startShiftMs }.map(abs).max() ?? 0
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack {
                        Text("\(changedCount) of \(rows.count) cues will change")
                            .font(.subheadline)
                        Spacer()
                        if maxStartShiftMs > 0 {
                            Text("largest shift: \(formatDeltaMs(maxStartShiftMs))")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                Section("Changes") {
                    ForEach(rows.filter { $0.timingChanged || $0.isAddition || $0.isRemoval }) { row in
                        retimeRowView(row)
                    }
                }
            }
            .navigationTitle("Re-time Subtitles")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        onCancel()
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Apply") {
                        onApply()
                        dismiss()
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func retimeRowView(_ row: RetimeReviewRow) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(row.text)
                .font(.subheadline)
                .lineLimit(2)
            HStack(spacing: 6) {
                Text(formatRange(row.oldStartMs, row.oldEndMs))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Image(systemName: "arrow.right")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text(formatRange(row.newStartMs, row.newEndMs))
                    .font(.caption.monospacedDigit())
                if let shift = row.startShiftMs, shift != 0 {
                    Spacer(minLength: 6)
                    Text("(\(shift > 0 ? "+" : "")\(formatDeltaMs(shift)))")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(shift > 0 ? Color.orange : Color.blue)
                }
            }
        }
        .padding(.vertical, 2)
    }

    // Renders a millisecond timestamp range as "0:01.234 → 0:02.456" (m:ss.mmm).
    private func formatRange(_ startMs: Int?, _ endMs: Int?) -> String {
        let s = startMs.map(formatTimestamp) ?? "—"
        let e = endMs.map(formatTimestamp) ?? "—"
        return "\(s) – \(e)"
    }

    // m:ss.mmm.
    private func formatTimestamp(_ ms: Int) -> String {
        let totalSeconds = ms / 1000
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        let millis = ms % 1000
        return String(format: "%d:%02d.%03d", minutes, seconds, millis)
    }

    // Human-readable signed delta: "0.123s" or "1.45s".
    private func formatDeltaMs(_ ms: Int) -> String {
        let absSeconds = abs(Double(ms) / 1000.0)
        return String(format: "%.2fs", absSeconds)
    }
}

private struct RetimeReviewRow: Identifiable {
    let id = UUID()
    let index: Int
    let text: String
    let oldStartMs: Int?
    let oldEndMs: Int?
    let newStartMs: Int?
    let newEndMs: Int?

    var timingChanged: Bool {
        guard let old = oldStartMs, let new = newStartMs, let oldE = oldEndMs, let newE = newEndMs else {
            return false
        }
        return old != new || oldE != newE
    }

    var isAddition: Bool { oldStartMs == nil && newStartMs != nil }
    var isRemoval: Bool { newStartMs == nil && oldStartMs != nil }

    var startShiftMs: Int? {
        guard let old = oldStartMs, let new = newStartMs else { return nil }
        return new - old
    }
}
