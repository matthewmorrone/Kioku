import Foundation

// One blank (dropdown) slot within a cloze question.
// Pure data: correct answer and shuffled distractor options built by ClozeStudyViewModel.
struct ClozeBlank: Identifiable, Equatable {
    let id: UUID
    let correct: String
    let options: [String]
}

// Distinguishes literal text runs from interactive blank slots in a rendered sentence.
// Pure enum — logic lives in ClozeStudyViewModel and ClozeStudyView.
enum ClozeSegmentKind: Equatable {
    case text(String)
    case blank(ClozeBlank)
}

// One display unit in a cloze sentence: either a text run or a blank dropdown.
// Pure data; the kind enum carries the associated values.
struct ClozeSegment: Identifiable, Equatable {
    let id: UUID
    let kind: ClozeSegmentKind
}

// A fully-built cloze question ready for presentation in ClozeStudyView.
// Pure data constructed by ClozeStudyViewModel.buildQuestion.
struct ClozeQuestion: Identifiable, Equatable {
    let id: UUID
    let sentenceIndex: Int
    let sentenceText: String
    let wordCount: Int
    let segments: [ClozeSegment]
    let blanks: [ClozeBlank]
}
