import Foundation

// Pushed destinations inside SongJourneyView's NavigationStack. Listen (L1) is not a route —
// it dismisses the journey sheet and re-uses the existing LyricsView overlay in ReadView.
enum SongJourneyRoute: Hashable {
    case diagnostic
    case l2Flashcards
    case l3Cloze
    case mastery
}
