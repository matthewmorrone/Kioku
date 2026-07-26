import Foundation

// One JLPT-level row of a NoteCoverage grid. `level` is the JLPT N-number (5…1) or nil for "No level".
struct NoteCoverageLevel: Equatable {
    let level: Int?
    let stageWords: [MasteryStage: [SavedWord]]

    // Total words at this level across all stages.
    var total: Int {
        MasteryStage.allCases.reduce(0) { $0 + (stageWords[$1]?.count ?? 0) }
    }

    // Words at this level that have reached the Learned or Mastered stage.
    var learnedCount: Int { (stageWords[.learned]?.count ?? 0) + (stageWords[.mastered]?.count ?? 0) }

    // The words at this level in a given stage (empty when none).
    func words(in stage: MasteryStage) -> [SavedWord] { stageWords[stage] ?? [] }
}
