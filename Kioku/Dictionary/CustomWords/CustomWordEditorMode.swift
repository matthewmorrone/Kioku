import Foundation

// The editor's two kinds of custom word: extra spellings of an existing entry, or a word of its own.
enum CustomWordEditorMode: Hashable {
    case sameWord
    case newWord
}

// One sense as the editor holds it while typing: glosses separated by semicolons, codes by commas.
struct CustomWordSenseDraft: Identifiable, Equatable {
    var id = UUID()
    var glosses: String
    var partOfSpeech: String
    var misc: String
}
