import Foundation

// The steps of each tab's first-visit tour, in the order they're shown, and the per-tab "seen"
// flags. Steps run top to bottom, left to right, so the cutout moves down the screen.
enum TourCatalog {
    // Tabs that have a tour; Settings has none, so it carries no seen flag either.
    static let touredTabs: [ContentTab] = [.read, .notes, .words, .learn]

    // The steps for a tab's tour; empty for a tab without one.
    static func steps(for tab: ContentTab) -> [TourStep] {
        switch tab {
        case .read:
            return [
                TourStep(target: .readText, title: "Tap a Word",
                         message: "Tap any word to look it up. The alternating colors show where Kioku split the text into words."),
                TourStep(target: .readCorrection, title: "AI Correction",
                         message: "Ask an AI to fix word boundaries and readings. You review each change before it's applied."),
                TourStep(target: .readBreakdown, title: "Breakdown",
                         message: "Generate a line-by-line explanation of the note's vocabulary and grammar."),
                TourStep(target: .readLyrics, title: "Audio & Lyrics",
                         message: "Attach a song or recording. Kioku lines the lyrics up with the audio so you can follow along."),
                TourStep(target: .readExtractWords, title: "Word List",
                         message: "Every word in the note, ready to save for study. Long-press to see what you've changed."),
                TourStep(target: .readReset, title: "Reset",
                         message: "Undo your segmentation and reading edits and go back to Kioku's own split."),
                TourStep(target: .readEdit, title: "Edit",
                         message: "Tap to edit the text. Long-press for display options like furigana, line wrapping and colors."),
            ]
        case .notes:
            return [
                TourStep(target: .notesImport, title: "Import",
                         message: "Bring in text from files, audio, the camera, a photo or a web page."),
                TourStep(target: .notesSort, title: "Sort",
                         message: "Order notes by date, length, difficulty, or how many of their words you still have to learn."),
                TourStep(target: .notesNew, title: "New Note",
                         message: "Start a blank note and type or paste Japanese into it."),
                TourStep(target: .notesList, title: "Your Notes",
                         message: "Tap a note to read it. Long-press for rename, share, export and more."),
            ]
        case .words:
            return [
                TourStep(target: .wordsSearch, title: "Search",
                         message: "Look up Japanese or English. Above the keyboard you can switch to radical lookup or handwriting."),
                TourStep(target: .wordsFilter, title: "Saved & History",
                         message: "Switch between your saved words and your lookup history, and filter by note or list."),
                TourStep(target: .wordsMore, title: "More",
                         message: "Edit, import word lists or subtitles, and browse words by frequency or JLPT level."),
            ]
        case .learn:
            return [
                TourStep(target: .learnPages, title: "Study Modes",
                         message: "Swipe left or right to switch between flashcards, multiple choice, matching, fill in the blank, cloze and the kana chart."),
            ]
        case .settings:
            return []
        }
    }

    // UserDefaults key recording that a tab's tour has been shown.
    static func seenKey(for tab: ContentTab) -> String {
        "kioku.tour.seen.\(tab)"
    }
}
