import Foundation

// Names every on-screen control a first-visit tour can point at. Views tag themselves with
// `.tourTarget(_:)`; TourCatalog refers to the same cases when it lists each tab's steps.
enum TourTargetID: String, Hashable {
    case readText
    case readCorrection
    case readBreakdown
    case readLyrics
    case readExtractWords
    case readReset
    case readEdit
    case notesImport
    case notesSort
    case notesNew
    case notesList
    case wordsMore
    case wordsSearch
    case wordsFilter
    case learnPages
}

// One callout in a tour: the control it points at and what it says about it.
struct TourStep: Equatable {
    let target: TourTargetID
    let title: String
    let message: String
}
