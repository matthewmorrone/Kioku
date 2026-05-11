import Foundation

// One stage in the per-song learning journey. Order matters: `Stage.allCases` is the on-screen
// order from top to bottom, and `nextStage` walks the user from diagnostic through mastery.
enum SongJourneyStage: String, Codable, CaseIterable, Identifiable {
    case diagnostic
    case l1Listen
    case l2Flashcards
    case l3Cloze
    case mastery

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .diagnostic: return "Diagnostic"
        case .l1Listen: return "Listen"
        case .l2Flashcards: return "Flashcards"
        case .l3Cloze: return "Fill in the Blanks"
        case .mastery: return "Mastery"
        }
    }

    var subtitle: String {
        switch self {
        case .diagnostic: return "Suggests where to start"
        case .l1Listen: return "Karaoke playback with tap-to-define"
        case .l2Flashcards: return "Drill saved words from this song"
        case .l3Cloze: return "One blank per line, easy passes"
        case .mastery: return "Stricter mixed test"
        }
    }

    var sfSymbol: String {
        switch self {
        case .diagnostic: return "stethoscope"
        case .l1Listen: return "music.note.list"
        case .l2Flashcards: return "rectangle.on.rectangle.angled"
        case .l3Cloze: return "rectangle.and.pencil.and.ellipsis"
        case .mastery: return "trophy.fill"
        }
    }

    // 0.0...1.0 score required for a stage to be marked completed. Listen is the only stage with
    // no scoring — visiting it is enough.
    var passingScore: Double? {
        switch self {
        case .diagnostic: return nil
        case .l1Listen: return nil
        case .l2Flashcards: return 0.70
        case .l3Cloze: return 0.70
        case .mastery: return 0.85
        }
    }
}
