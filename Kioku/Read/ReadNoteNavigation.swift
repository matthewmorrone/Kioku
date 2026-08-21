import Combine
import Foundation

// A deep-link target for "open this note in the Read tab, then jump to the first occurrence of
// this surface." Backs the tappable note names in WordDetailView's "Saved" section — routing
// through a shared singleton (mirroring WordOfTheDayNavigation) means the tap works from every
// place WordDetailView is presented without threading a callback through each of those call
// sites' init parameters.
struct ReadNoteTarget: Equatable {
    let noteID: UUID
    let surface: String
}

@MainActor
final class ReadNoteNavigation: ObservableObject {
    static let shared = ReadNoteNavigation()

    @Published var pendingTarget: ReadNoteTarget? = nil
}
