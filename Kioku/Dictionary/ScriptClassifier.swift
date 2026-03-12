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
        switch scalar.value {
        case 0x3046: return UnicodeScalar(0x3094) // う -> ゔ
        case 0x304B: return UnicodeScalar(0x304C) // か -> が
        case 0x304D: return UnicodeScalar(0x304E) // き -> ぎ
        case 0x304F: return UnicodeScalar(0x3050) // く -> ぐ
        case 0x3051: return UnicodeScalar(0x3052) // け -> げ
        case 0x3053: return UnicodeScalar(0x3054) // こ -> ご
        case 0x3055: return UnicodeScalar(0x3056) // さ -> ざ
        case 0x3057: return UnicodeScalar(0x3058) // し -> じ
        case 0x3059: return UnicodeScalar(0x305A) // す -> ず
        case 0x305B: return UnicodeScalar(0x305C) // せ -> ぜ
        case 0x305D: return UnicodeScalar(0x305E) // そ -> ぞ
        case 0x305F: return UnicodeScalar(0x3060) // た -> だ
        case 0x3061: return UnicodeScalar(0x3062) // ち -> ぢ
        case 0x3064: return UnicodeScalar(0x3065) // つ -> づ
        case 0x3066: return UnicodeScalar(0x3067) // て -> で
        case 0x3068: return UnicodeScalar(0x3069) // と -> ど
        case 0x306F: return UnicodeScalar(0x3070) // は -> ば
        case 0x3072: return UnicodeScalar(0x3073) // ひ -> び
        case 0x3075: return UnicodeScalar(0x3076) // ふ -> ぶ
        case 0x3078: return UnicodeScalar(0x3079) // へ -> べ
        case 0x307B: return UnicodeScalar(0x307C) // ほ -> ぼ
        case 0x30A6: return UnicodeScalar(0x30F4) // ウ -> ヴ
        case 0x30AB: return UnicodeScalar(0x30AC) // カ -> ガ
        case 0x30AD: return UnicodeScalar(0x30AE) // キ -> ギ
        case 0x30AF: return UnicodeScalar(0x30B0) // ク -> グ
        case 0x30B1: return UnicodeScalar(0x30B2) // ケ -> ゲ
        case 0x30B3: return UnicodeScalar(0x30B4) // コ -> ゴ
        case 0x30B5: return UnicodeScalar(0x30B6) // サ -> ザ
        case 0x30B7: return UnicodeScalar(0x30B8) // シ -> ジ
        case 0x30B9: return UnicodeScalar(0x30BA) // ス -> ズ
        case 0x30BB: return UnicodeScalar(0x30BC) // セ -> ゼ
        case 0x30BD: return UnicodeScalar(0x30BE) // ソ -> ゾ
        case 0x30BF: return UnicodeScalar(0x30C0) // タ -> ダ
        case 0x30C1: return UnicodeScalar(0x30C2) // チ -> ヂ
        case 0x30C4: return UnicodeScalar(0x30C5) // ツ -> ヅ
        case 0x30C6: return UnicodeScalar(0x30C7) // テ -> デ
        case 0x30C8: return UnicodeScalar(0x30C9) // ト -> ド
        case 0x30CF: return UnicodeScalar(0x30D0) // ハ -> バ
        case 0x30D2: return UnicodeScalar(0x30D3) // ヒ -> ビ
        case 0x30D5: return UnicodeScalar(0x30D6) // フ -> ブ
        case 0x30D8: return UnicodeScalar(0x30D9) // ヘ -> ベ
        case 0x30DB: return UnicodeScalar(0x30DC) // ホ -> ボ
        default:
            return nil
        }
    }
}
