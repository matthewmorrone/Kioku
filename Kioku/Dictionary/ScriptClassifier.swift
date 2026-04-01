import Foundation
import Combine

nonisolated enum ScriptClassifier {
    private static let voicedKanaMap = loadVoicedKanaMap()

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

    // Determines whether text is composed only of katakana code points and prolonged sound marks.
    static func isPureKatakana(_ text: String) -> Bool {
        guard !text.isEmpty else { return false }

        for scalar in text.unicodeScalars {
            let value = scalar.value
            let isKatakana = (0x30A0...0x30FF).contains(value)
            let isProlongedSoundMark = value == 0x30FC

            if !isKatakana && !isProlongedSoundMark {
                return false
            }
        }

        return true
    }

    // Determines whether text is composed only of hiragana code points.
    static func isPureHiragana(_ text: String) -> Bool {
        guard !text.isEmpty else { return false }

        for scalar in text.unicodeScalars {
            let value = scalar.value
            let isHiragana = (0x3040...0x309F).contains(value)

            if !isHiragana {
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

    // Classifies known Japanese punctuation symbols used by segment boundaries.
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

    // Marks hard-boundary characters used by segmentation to split segments safely.
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

    // Classifies a character into coarse script groups used for unknown-segment fallback coalescing.
    static func unknownGrouping(for character: Character) -> String? {
        guard let scalar = character.unicodeScalars.first else {
            return nil
        }

        let value = scalar.value
        if (0x3040...0x309F).contains(value) {
            return "hiragana"
        }

        if (0x30A0...0x30FF).contains(value) {
            return "katakana"
        }

        if (0x0030...0x0039).contains(value) || (0xFF10...0xFF19).contains(value) {
            return "number"
        }

        if (0x0041...0x005A).contains(value) ||
           (0x0061...0x007A).contains(value) ||
           (0xFF21...0xFF3A).contains(value) ||
           (0xFF41...0xFF5A).contains(value) {
            return "latin"
        }

        return nil
    }

    // Expands Japanese iteration-mark variants into concrete surfaces used by lookup and deinflection.
    static func iterationExpandedCandidates(for surface: String) -> Set<String> {
        guard surface.isEmpty == false else {
            return []
        }

        var resolvedScalars: [UnicodeScalar] = []
        var changed = false

        for scalar in surface.unicodeScalars {
            switch scalar.value {
            case 0x3005: // 々
                guard let previousScalar = resolvedScalars.last, isKanjiScalar(previousScalar) else {
                    return []
                }
                resolvedScalars.append(previousScalar)
                changed = true
            case 0x309D: // ゝ
                guard let previousScalar = resolvedScalars.last, isHiraganaScalar(previousScalar) else {
                    return []
                }
                resolvedScalars.append(previousScalar)
                changed = true
            case 0x309E: // ゞ
                guard let previousScalar = resolvedScalars.last,
                      isHiraganaScalar(previousScalar),
                      let voicedScalar = voicedKanaScalar(for: previousScalar) else {
                    return []
                }
                resolvedScalars.append(voicedScalar)
                changed = true
            case 0x30FD: // ヽ
                guard let previousScalar = resolvedScalars.last, isKatakanaScalar(previousScalar) else {
                    return []
                }
                resolvedScalars.append(previousScalar)
                changed = true
            case 0x30FE: // ヾ
                guard let previousScalar = resolvedScalars.last,
                      isKatakanaScalar(previousScalar),
                      let voicedScalar = voicedKanaScalar(for: previousScalar) else {
                    return []
                }
                resolvedScalars.append(voicedScalar)
                changed = true
            default:
                resolvedScalars.append(scalar)
            }
        }

        guard changed else {
            return []
        }

        return [String(String.UnicodeScalarView(resolvedScalars))]
    }

    // Detects whether one scalar belongs to supported CJK Unified Ideograph blocks.
    private static func isKanjiScalar(_ scalar: UnicodeScalar) -> Bool {
        let value = scalar.value
        return (0x4E00...0x9FFF).contains(value) || (0x3400...0x4DBF).contains(value)
    }

    // Detects whether one scalar is in the hiragana block.
    private static func isHiraganaScalar(_ scalar: UnicodeScalar) -> Bool {
        (0x3040...0x309F).contains(scalar.value)
    }

    // Detects whether one scalar is in the katakana block.
    private static func isKatakanaScalar(_ scalar: UnicodeScalar) -> Bool {
        (0x30A0...0x30FF).contains(scalar.value)
    }

    // Maps one kana scalar to its dakuten counterpart where a voiced pair exists.
    private static func voicedKanaScalar(for scalar: UnicodeScalar) -> UnicodeScalar? {
        guard let mappedValue = voicedKanaMap[scalar.value] else {
            return nil
        }

        return UnicodeScalar(mappedValue)
    }

    // Builds the voiced kana scalar map from KanaData so iteration-mark expansion stays data-driven.
    private static func loadVoicedKanaMap() -> [UInt32: UInt32] {
        var scalarMap: [UInt32: UInt32] = [:]
        for (source, target) in KanaData.voicedKanaPairs {
            guard
                let sourceScalar = source.unicodeScalars.first,
                let targetScalar = target.unicodeScalars.first
            else {
                continue
            }
            scalarMap[sourceScalar.value] = targetScalar.value
        }
        return scalarMap
    }
}
