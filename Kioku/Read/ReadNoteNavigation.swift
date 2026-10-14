import Combine
import Foundation

// A deep-link target for "open this note in the Read tab, then jump to the first occurrence of
// this surface." Backs the tappable note names in WordDetailView's "Saved" section — routing
// through a shared singleton (mirroring WordOfTheDayNavigation) means the tap works from every
// place WordDetailView is presented without threading a callback through each of those call
// sites' init parameters.
//
// `destination` picks which of the note's views opens on that spot: the Read text itself, the
// lyrics view seeked to the line, or the breakdown scrolled to the line. `noteLocation` (UTF-16,
// in the note's text) pins the exact spot when the caller knows it — a breakdown line or lyric
// cue — and otherwise the first occurrence of `surface` is used; with neither, the destination
// opens wherever it was.
struct ReadNoteTarget: Equatable {
    var noteID: UUID
    var surface: String
    var noteLocation: Int? = nil
    var destination: ReadNoteDestination = .text
    // Starts the breakdown playing from the top once it opens (a random breakdown).
    var autoplay: Bool = false
}

// Which of a note's views a ReadNoteTarget opens. Pure data.
enum ReadNoteDestination: Equatable {
    case text
    case lyrics
    case breakdown
}

@MainActor
final class ReadNoteNavigation: ObservableObject {
    static let shared = ReadNoteNavigation()

    @Published var pendingTarget: ReadNoteTarget? = nil
    // Raised by PlayRandomNoteIntent ("Sing with Kioku"); ContentView picks a note with audio, opens it
    // in Read with autoplay, and lowers the flag.
    @Published var isRandomPlaybackRequested = false
    // Raised by the breakdown's shuffle button when it's shown over the Read tab; ContentView picks
    // a note that has a breakdown, opens it in Read with its breakdown sheet up, and lowers the flag.
    @Published var isRandomBreakdownRequested = false
    // Raised by the Read tab's shuffle button; ContentView opens a random other note in Read and
    // lowers the flag.
    @Published var isRandomNoteRequested = false
}
