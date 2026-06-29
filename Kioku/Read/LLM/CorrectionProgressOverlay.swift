import SwiftUI

// Floating overlay that tracks the LLM correction queue's progress from
// anywhere in the app. Mounted at the TabView level in ContentView so it
// follows the user between tabs while a batch is running. Three visual
// states: hidden (no activity), expanded card (full details), and
// collapsed chip (compact pill with spinner + count). The user can toggle
// between expanded and collapsed; dismissing acknowledges the results
// and hides the overlay until the next batch starts.
struct CorrectionProgressOverlay: View {
    @EnvironmentObject private var queue: LLMCorrectionQueue
    @State private var isCollapsed = false

    var body: some View {
        Group {
            if shouldShow {
                if isCollapsed {
                    collapsedChip
                } else {
                    expandedCard
                }
            }
        }
        .animation(.easeInOut(duration: 0.2), value: isCollapsed)
        .animation(.easeInOut(duration: 0.25), value: shouldShow)
        // Re-expand whenever a new batch starts so the user gets a clear
        // signal that work is underway, even if they collapsed the
        // previous batch's overlay. Without this, a collapsed chip would
        // silently consume a fresh batch's status updates.
        .onChange(of: queue.runTotal) { _, newValue in
            if newValue > 0, queue.isProcessing {
                isCollapsed = false
            }
        }
    }

    // Visible whenever there's something to report — queue work in flight or
    // completed queue results the user hasn't dismissed. Direct AI requests
    // (Read-tab sparkles button) deliberately do NOT show the popup; their
    // progress is conveyed by the in-line per-line highlight in ReadView,
    // which the user is already looking at when they tap sparkles.
    private var shouldShow: Bool {
        if queue.isProcessing { return true }
        if queue.failedNoteIDs.isEmpty == false { return true }
        return queue.successCount > 0
    }

    // Compact pill shown when the user minimizes the expanded card.
    // Spinner + a brief "X/Y" so progress is still visible.
    private var collapsedChip: some View {
        Button {
            isCollapsed = false
        } label: {
            HStack(spacing: 8) {
                statusGlyph
                Text(collapsedLabel)
                    .font(.subheadline.weight(.semibold))
                    .monospacedDigit()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(Capsule().fill(.thinMaterial))
            .overlay(Capsule().strokeBorder(Color.primary.opacity(0.08), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("AI correction progress — tap to expand")
    }

    // Full status card: headline, optional detail line, and action buttons
    // (Minimize while running; Dismiss when results are settled).
    private var expandedCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 10) {
                statusGlyph
                VStack(alignment: .leading, spacing: 2) {
                    Text(headline)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(2)
                    if let detail {
                        Text(detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(3)
                    }
                }
                Spacer(minLength: 8)
                Button {
                    isCollapsed = true
                } label: {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Minimize")
            }

            if queue.isProcessing == false {
                HStack {
                    Spacer()
                    Button("Dismiss") {
                        queue.acknowledgeFailures()
                        queue.resetSuccessCount()
                    }
                    .font(.subheadline.weight(.medium))
                    .buttonStyle(.borderless)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: 360)
        .background(RoundedRectangle(cornerRadius: 14).fill(.thinMaterial))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.primary.opacity(0.08), lineWidth: 1))
    }

    // Status icon for both visual states. Spinner during work; check on
    // pure success; warning when any failure is in the latest batch.
    @ViewBuilder
    private var statusGlyph: some View {
        if queue.isProcessing {
            ProgressView()
                .controlSize(.small)
        } else if queue.failedNoteIDs.isEmpty {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
        } else {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
        }
    }

    private var collapsedLabel: String {
        if queue.isProcessing {
            let done = queue.runCompletedCount + 1
            let total = max(queue.runTotal, done)
            return "\(done)/\(total)"
        }
        let succeeded = queue.successCount
        let failed = queue.failedNoteIDs.count
        if failed == 0 { return "\(succeeded) done" }
        if succeeded == 0 { return "\(failed) failed" }
        return "\(succeeded) · \(failed) failed"
    }

    private var headline: String {
        if queue.isProcessing {
            let done = queue.runCompletedCount + 1
            let total = max(queue.runTotal, done)
            return "AI correcting note \(done) of \(total)…"
        }
        let succeeded = queue.successCount
        let failed = queue.failedNoteIDs.count
        if failed == 0 {
            return "AI correction finished — \(succeeded) note\(succeeded == 1 ? "" : "s") updated"
        }
        if succeeded == 0 {
            return "AI correction failed for \(failed) note\(failed == 1 ? "" : "s")"
        }
        return "AI correction: \(succeeded) updated, \(failed) failed"
    }

    private var detail: String? {
        if queue.isProcessing { return nil }
        return queue.lastFailureMessage
    }
}
