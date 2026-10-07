import Foundation

// One JMnedict proper-name reading of a surface: how it is read, what kind of name it is (JMnedict
// type tags such as "surname", "place", "fem") and its English rendering. Read from the dictionary's
// name tables by DictionaryStore.lookupNames; shown by the lookup sheet for words JMdict doesn't have.
nonisolated struct DictionaryName: Sendable, Equatable {
    let reading: String
    let types: [String]
    let gloss: String
    // Whether this is the reading MeCab gives the surface, i.e. the usual reading of a common name
    // (鈴木 すずき, not すすき). Only these show beside a word JMdict does have.
    let isUsualReading: Bool
}
