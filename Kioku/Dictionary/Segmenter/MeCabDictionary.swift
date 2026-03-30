import Foundation

// Represents which MeCab dictionary to load at runtime, each with a different morphological model.
enum MeCabDictionary: String, CaseIterable {
    case ipadic
    case unidic

    // Returns a human-readable label for display in the settings picker.
    var displayName: String {
        switch self {
        case .ipadic: return "IPAdic"
        case .unidic: return "UniDic"
        }
    }

    // Returns the subdirectory name under Resources/MeCab/ where compiled dictionary files are stored.
    var bundleDirectoryName: String {
        rawValue
    }

    // Returns the CSV field index that holds the base form (lemma) in MeCab's output.
    // IPAdic: surface\tPOS,sub1,sub2,sub3,conj-type,conj-form,base-form,reading,pronunciation
    // UniDic: surface\tPOS,sub1,sub2,sub3,conj-type,conj-form,lemma-form,lemma-reading,...
    var baseFormFieldIndex: Int {
        switch self {
        case .ipadic: return 6
        case .unidic: return 7
        }
    }
}
