import SwiftUI

// Single row card on the Song Journey screen. Shows status, best score, and a Continue button.
struct SongJourneyStageCard: View {
    let stage: SongJourneyStage
    let state: SongJourneyState
    let isRecommended: Bool
    let action: () -> Void

    private var bestScoreText: String? {
        guard let score = state.bestScore(for: stage), stage.passingScore != nil else { return nil }
        return "Best: \(Int((score * 100).rounded()))%"
    }

    private var statusLabel: String {
        if state.isCompleted(stage) { return "Complete" }
        if state.visitedStages.contains(stage) { return "In progress" }
        return "Not started"
    }

    private var statusColor: Color {
        if state.isCompleted(stage) { return .green }
        if state.visitedStages.contains(stage) { return .orange }
        return .secondary
    }

    var body: some View {
        Button(action: action) {
            HStack(alignment: .center, spacing: 14) {
                ZStack {
                    Circle()
                        .fill(statusColor.opacity(0.15))
                        .frame(width: 44, height: 44)
                    Image(systemName: stage.sfSymbol)
                        .font(.system(size: 19, weight: .semibold))
                        .foregroundStyle(statusColor)
                }

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(stage.displayName)
                            .font(.headline)
                            .foregroundStyle(.primary)
                        if isRecommended {
                            Text("Start here")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Capsule().fill(Color.accentColor))
                        }
                    }
                    Text(stage.subtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                    HStack(spacing: 8) {
                        Text(statusLabel)
                            .font(.caption.weight(.medium))
                            .foregroundStyle(statusColor)
                        if let bestScoreText {
                            Text("•")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text(bestScoreText)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                Spacer(minLength: 0)

                Image(systemName: "chevron.right")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(14)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 14)
                    .fill(Color(.secondarySystemGroupedBackground))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .stroke(isRecommended ? Color.accentColor : Color(.separator), lineWidth: isRecommended ? 1.5 : 0.5)
            )
        }
        .buttonStyle(.plain)
    }
}
