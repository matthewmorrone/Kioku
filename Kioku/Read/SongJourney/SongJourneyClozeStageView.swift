import SwiftUI

// Hosts ClozeStudyView for both the L3 and Mastery stages. The two stages share the same shell —
// the only differences are blank density, ordering mode, and how many blanks must be answered
// before the session is allowed to grade.
//
// The score bar at the top owns the Finish button (rather than a toolbar item) because
// ClozeStudyView declares its own NavigationStack internally, and a parent .toolbar modifier
// is unreliable when the inner view re-establishes the nav bar.
//
// Major sections: stage-aware score bar, Finish button, embedded ClozeStudyView.
struct SongJourneyClozeStageView: View {
    let note: Note
    let stage: SongJourneyStage
    let blanksPerSentence: Int
    let mode: ClozeMode
    let minimumAnswered: Int
    let onFinish: (_ score: Double) -> Void

    @State private var correctCount: Int = 0
    @State private var totalCount: Int = 0

    private var currentScore: Double {
        guard totalCount > 0 else { return 0 }
        return Double(correctCount) / Double(totalCount)
    }

    private var canFinish: Bool {
        totalCount >= minimumAnswered
    }

    var body: some View {
        VStack(spacing: 0) {
            scoreBar
            ClozeStudyView(
                note: note,
                initialMode: mode,
                initialBlanksPerSentence: blanksPerSentence,
                excludeDuplicateLines: true,
                onScoreChange: { c, t in
                    correctCount = c
                    totalCount = t
                }
            )
        }
        .navigationBarBackButtonHidden(false)
    }

    // Persistent banner with stage name, current score, and a Finish button that becomes active
    // once the user has answered enough blanks to grade.
    private var scoreBar: some View {
        HStack(spacing: 10) {
            Image(systemName: stage.sfSymbol)
                .foregroundStyle(Color.accentColor)
            Text(stage.displayName).font(.subheadline.weight(.semibold))
            Spacer()
            scoreText
            Button {
                onFinish(currentScore)
            } label: {
                Label("Finish", systemImage: "checkmark.circle.fill")
                    .font(.subheadline.weight(.semibold))
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .disabled(canFinish == false)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color(.secondarySystemGroupedBackground))
    }

    // Right-aligned progress hint: shows answered-vs-required while below the minimum, then the
    // running percentage with the pass threshold for context once grading is unlocked.
    @ViewBuilder
    private var scoreText: some View {
        let threshold = stage.passingScore ?? 0
        let pct = Int((currentScore * 100).rounded())
        let thresholdPct = Int((threshold * 100).rounded())
        if totalCount == 0 {
            Text("Answer \(minimumAnswered) to grade")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else if canFinish == false {
            Text("\(totalCount)/\(minimumAnswered) answered")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            Text("\(pct)% (pass \(thresholdPct)%)")
                .font(.caption.weight(.medium))
                .foregroundStyle(pct >= thresholdPct ? Color.green : Color.orange)
        }
    }
}
