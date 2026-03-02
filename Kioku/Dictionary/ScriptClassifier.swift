import Foundation

enum ScriptClassifier {
    // Determines whether text is composed only of kana code points and prolonged sound marks.
    static func isPureKana(_ text: String) -> Bool {
        guard !text.isEmpty else { return false }

        for scalar in text.unicodeScalars {
            let value = scalar.value
            let isHiragana = (0x3040...0x309F).contains(value) // Hiragana block
            let isKatakana = (0x30A0...0x30FF).contains(value) // Katakana block
            let isProlongedSoundMark = value == 0x30FC // ー

            if !isHiragana && !isKatakana && !isProlongedSoundMark {
                return false
            }
        }

        return true
    }

    // Detects whether any scalar belongs to the supported kanji blocks.
    static func containsKanji(_ text: String) -> Bool {
        for scalar in text.unicodeScalars {
            let value = scalar.value
            let isCJKUnifiedIdeographs = (0x4E00...0x9FFF).contains(value) // CJK Unified Ideographs
            let isCJKExtensionA = (0x3400...0x4DBF).contains(value) // CJK Unified Ideographs Extension A

            if isCJKUnifiedIdeographs || isCJKExtensionA {
                return true
            }
        }

        return false
    }

    // Classifies known Japanese punctuation symbols used by token boundaries.
    static func isJapanesePunctuation(_ character: Character) -> Bool {
        guard !character.unicodeScalars.isEmpty else { return false }

        for scalar in character.unicodeScalars {
            switch scalar.value {
            case 0x3001, // 、
                 0x3002, // 。
                 0x300C, // 「
                 0x300D, // 」
                 0x300E, // 『
                 0x300F, // 』
                 0xFF08, // （
                 0xFF09, // ）
                 0x3010, // 【
                 0x3011, // 】
                 0x300A, // 《
                 0x300B, // 》
                 0x30FB, // ・
                 0x30FC, // ー
                 0x301C, // 〜
                 0xFF01, // ！
                 0xFF1F: // ？
                continue
            default:
                return false
            }
        }

        return true
    }

    // Marks hard-boundary characters used by segmentation to split tokens safely.
    static func isBoundaryCharacter(_ character: Character) -> Bool {
        for scalar in character.unicodeScalars {
            if CharacterSet.whitespacesAndNewlines.contains(scalar) {
                return true
            }
        }

        if isJapanesePunctuation(character) {
            return true
        }

        guard !character.unicodeScalars.isEmpty else { return false }

        for scalar in character.unicodeScalars {
            let value = scalar.value
            let isASCII = value <= 0x7F
            let isASCIIPunctuation =
                (0x21...0x2F).contains(value) || // ! " # $ % & ' ( ) * + , - . /
                (0x3A...0x40).contains(value) || // : ; < = > ? @
                (0x5B...0x60).contains(value) || // [ \ ] ^ _ `
                (0x7B...0x7E).contains(value)    // { | } ~

            if isASCII && isASCIIPunctuation {
                return true
            }
        }

        return false
    }
}
