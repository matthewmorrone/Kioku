import Foundation

// The compact segmentation format an LLM segmentation correction is written in — "1|(流)[なが]されて|…|"
// per note line — and the prompt that teaches it. The song breakdown's merged request
// (MergedCorrectionBreakdownService) asks for a corrected segmentation in this format
// alongside the breakdown; this type holds the instructions for that half and parses what comes
// back into [LLMSegmentEntry] for ReadView's pending-changes review.
enum LLMCorrectionFormat {
    // The segmentation-correction instructions sent in the merged breakdown request.
    static let systemPrompt = """
        You are an expert Japanese linguist. \
        You will be given Japanese text with a proposed morphological segmentation and readings. \
        The proposed segmentation is produced by an automated tool and may contain errors — treat it as a rough draft, not ground truth. \
        Re-segment the text from scratch using your full understanding of Japanese grammar and context. \
        The goal is the segmentation a skilled native reader would consider correct.
        - DO NOT HESITATE TO SPLIT OR MERGE SEGMENTS WHEN WRONG OR NOT QUITE RIGHT — BE AGGRESSIVE AND ERR ON THE SIDE OF MAKING CHANGES

        SEGMENT FORMAT:
        - Each source line maps to exactly one output line with the same line number
        - Each line starts with its line number N followed by | then the segments: N|seg1|seg2|
        - Example line: 3|(食)[た]べる|は|
        - A blank source line is encoded as N| (line number followed by a bare |)
        - Kanji within a segment are annotated as (kanji)[reading] where reading is hiragana only
        - Okurigana (trailing/internal kana) are left outside the parentheses, e.g. 食べる → (食)[た]べる, 生き方 → (生)[い]き(方)[かた]
        - Pure kana, numbers, punctuation, and whitespace: no annotation, just the text
        - Whitespace characters and punctuation must each be their own segment

        SEGMENTATION GUIDELINES:
        - Compound nouns that form a single lexical unit must stay together: 中学校, 高校生, 東京都, etc.
        - Particles (は, が, を, に, で, も, と, から, まで, より, など, か, ね, よ, な, わ, ぞ, ぜ) must each be their own segment with no exceptions — には, では, とは, からは, etc. are always two separate segments, never one: 時には → (時)[とき]|に|は, 中では → (中)[なか]|で|は
        - Numerals followed by counter words must stay together based on meaning in context: 中二人 → (中)[なか]|(二人)[ふたり] not |(中二)[ちゅうに]|(人)[ひと]|
        - Verb stem and inflectional suffix must stay in one segment: 食べる not 食べ|る, 書いた not 書い|た
        - Compound verbs (verb + verb, or verb + auxiliary) are one segment: 追いつづける, 飛び込む, 言い続ける, 走り出す — never split at the connective 〜い or 〜き form
        - When a sequence can be read as a known verb, prefer that reading over splitting it into a suffix + another word: とじてたしかめて → とじて|たしかめて not とじてた|しかめて (たしかめる is the verb, not しかめる)
        - DO NOT HESITATE TO SPLIT OR MERGE SEGMENTS WHEN WRONG OR NOT QUITE RIGHT — BE AGGRESSIVE AND ERR ON THE SIDE OF MAKING CHANGES

        OUTPUT RULES:
        - Return ONLY the corrected compact format, nothing else — no explanation, no markdown
        - Every output line must start with its line number N followed by | and end with |
        - Output exactly one line per input line, with the same line number — do not merge or reorder lines
        - Segments MUST NOT cross line boundaries — all segments on line N come only from source line N
        - All segment surfaces within a line must concatenate in order to reproduce that source line exactly, character-for-character
        - Never add, remove, or alter any character from the original text — do not convert kana to kanji or kanji to kana, do not normalize, do not substitute
        - Do not insert spaces between segments or anywhere else — if the original has no space, the output must have no space

        CHARACTER PRESERVATION (CRITICAL):
        - If the input writes a word in hiragana that could also be written with kanji, KEEP THE HIRAGANA. Do not "normalize." Examples that MUST be preserved as-is:
            なる (do NOT change to 成る); ある (do NOT change to 有る); いる (do NOT change to 居る); こと (do NOT change to 事); もの (do NOT change to 物); とき (do NOT change to 時); ところ (do NOT change to 所); わたし (do NOT change to 私); あなた (do NOT change to 貴方)
        - Likewise if the input uses kanji, do not strip them down to kana.
        - WRONG: input "なりたくて" → output "成りたくて" (substituted な → 成). This is forbidden — every character in your output surfaces must come from the source verbatim.

        EXAMPLES:

        Example 1 — verb mistakenly split, MERGE:
        Input:  1|(食)[た]|べる|の|が|(好)[す]き|です|
        Output: 1|(食)[た]べる|の|が|(好)[す]き|です|
        Reason: 食 and べる together are the verb 食べる. Stem + inflection stay in one segment.

        Example 2 — compound noun mistakenly split, MERGE:
        Input:  1|(中)[ちゅう]|(学校)[がっこう]|で|
        Output: 1|(中学校)[ちゅうがっこう]|で|
        Reason: 中学校 is one lexical unit (middle school), not 中 + 学校.

        Example 3 — already correct, OUTPUT UNCHANGED:
        Input:  1|(涙)[なみだ]|(出)[で]る|ほど|(笑)[わら]って|
        Output: 1|(涙)[なみだ]|(出)[で]る|ほど|(笑)[わら]って|
        Reason: Each segment is a standalone word. 涙 and 出る are separate; "涙出" is NOT a word — do not invent it.

        Example 4 — uncertain, OUTPUT UNCHANGED:
        Input:  1|(花)[はな]びら|に|(黄昏)[たそがれ]|の|(翅)[はね]|が|
        Output: 1|(花)[はな]びら|に|(黄昏)[たそがれ]|の|(翅)[はね]|が|
        Reason: Even if a poetic compound is plausible, the segmentation as given is reasonable. When uncertain, leave it alone.

        Example 5 — trailing kana belongs to the NEXT verb, SPLIT-AND-MERGE across boundaries:
        Input:  1|(流)[なが]されてた|ゆた|う|の|このまま|
        Output: 1|(流)[なが]されて|たゆたう|の|このまま|
        Reason: たゆたう is one verb (to sway). The た at the end of 流されてた actually belongs with ゆた+う to form たゆたう; the segmenter mis-attached it. Split the trailing た off the preceding segment, then merge it with ゆた and う.

        """

    // Parses the compact format string returned by the LLM into [LLMSegmentEntry].
    // Each content line `N|seg1|seg2|` encodes segments followed by an implicit `\n`.
    // A bare `N|` line encodes an extra blank line (an additional `\n` beyond the implicit one).
    //
    // Lenient by line, not all-or-nothing: models occasionally prepend a conversational
    // sentence ("The song is confirmed as...") despite the system prompt's "output ONLY the
    // corrected format" instruction, or mangle a single line's trailing `|`. The old parser
    // threw on the FIRST such line, discarding every line after it too — one bad sentence
    // anywhere killed the whole correction. This version treats the response as a list of
    // independent numbered records instead of one monolithic blob:
    //   - a line with a leading `N|` is a data record for note-line N, well-formed or not
    //   - a line that's merely `|...|` with no number is a legacy positional record (old
    //     stub-file format, kept for backward compat)
    //   - anything else (prose, headers, blank commentary) has no recognizable record shape
    //     and is discarded as noise rather than aborting the parse
    // A numbered line that IS malformed (no trailing `|`) still reserves its slot as empty
    // content rather than being dropped — dropping it would shift every later line's position
    // out of alignment. mergeResponsePerLine (ReadView+LLMCorrection.swift) already falls back
    // to the pre-correction baseline for any line whose parsed surfaces don't reconstruct the
    // source text, so an empty/missing slot degrades to "no change for this line" for free —
    // this parser just has to stop letting one bad record poison every record after it.
    // Only throws when NOTHING recognizable was found at all (e.g. the whole response is
    // conversational prose).
    // Example: `1|A|\n2|B|\n3|\n4|C|` → [A, \n, B, \n, \n, C, \n]
    static func parseCompactResponse(_ compact: String) throws -> LLMCorrectionResponse {
        let rawLines = compact.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.isEmpty == false }

        var numberedContent: [Int: String] = [:]
        var positionalContent: [String] = []
        var sawNumberedLine = false

        for line in rawLines {
            let digitPrefixCount = line.prefix(while: { $0.isNumber }).count
            if digitPrefixCount > 0 {
                let afterDigits = line.index(line.startIndex, offsetBy: digitPrefixCount)
                guard afterDigits < line.endIndex, line[afterDigits] == "|",
                      let lineNumber = Int(line.prefix(digitPrefixCount)), lineNumber > 0
                else {
                    continue   // digits not followed by "|" (e.g. a stray number in prose) — noise, discard
                }
                sawNumberedLine = true
                let rest = "|" + String(line[line.index(after: afterDigits)...])
                if rest.hasPrefix("|") && rest.hasSuffix("|") && rest.count >= 2 {
                    numberedContent[lineNumber] = String(rest.dropFirst().dropLast())
                } else {
                    // Claims line N but the content after the number is malformed — reserve
                    // the slot as empty rather than dropping it (see comment above).
                    numberedContent[lineNumber] = ""
                }
                continue
            }
            // No line-number prefix: legacy positional format only if the WHOLE line is
            // pipe-bounded (old stub-file convention); anything else is unstructured noise.
            if line.hasPrefix("|") && line.hasSuffix("|") && line.count >= 2 {
                positionalContent.append(String(line.dropFirst().dropLast()))
            }
        }

        var entries: [LLMSegmentEntry] = []
        if sawNumberedLine {
            // maxLine is always >= 1 here (sawNumberedLine only sets when lineNumber > 0), so
            // `1...maxLine` is a valid range — but max(maxLine, 1) is kept anyway as cheap
            // insurance: a bare `1...maxLine` traps at runtime if that invariant ever breaks,
            // where this silently produces an empty (still-safe) range instead.
            let maxLine = numberedContent.keys.max() ?? 0
            for lineNumber in 1...max(maxLine, 1) where lineNumber <= maxLine {
                appendLineEntries(numberedContent[lineNumber] ?? "", to: &entries)
            }
        } else {
            for inner in positionalContent {
                appendLineEntries(inner, to: &entries)
            }
        }

        guard entries.isEmpty == false else {
            throw LLMCorrectionError.decodingError(
                "No recognizable \"N|...|\" lines found in the response. Raw: \(compact.prefix(300))"
            )
        }

        return LLMCorrectionResponse(segments: entries)
    }

    // Parses one line's inner content (the text between its outer `|` bounds, already
    // stripped) into segment entries, appending the implicit trailing "\n" every content
    // line encodes. Empty inner content (a bare `N|`, or a malformed line's reserved slot)
    // appends only the "\n" — matching how a genuinely blank source line is represented.
    private static func appendLineEntries(_ inner: String, to entries: inout [LLMSegmentEntry]) {
        if inner.isEmpty == false {
            for raw in inner.components(separatedBy: "|") {
                // Trim spaces the model may pad around segment delimiters — but not when the
                // whole token IS a space. A lone " " token is the model's own segment for an
                // actual space character in the source text (song lyrics routinely have one
                // before a parenthetical aside), and trimming it down to "" would silently drop
                // it here, breaking the surface-concat match against the source line and
                // sending that whole line to baseline fallback instead of the model's correction.
                let trimmed = raw.trimmingCharacters(in: .init(charactersIn: " "))
                let token = (trimmed.isEmpty && raw.isEmpty == false) ? raw : trimmed
                guard token.isEmpty == false else { continue }
                let (surface, reading) = parseSegmentToken(token)
                entries.append(LLMSegmentEntry(surface: surface, reading: reading))
            }
        }
        entries.append(LLMSegmentEntry(surface: "\n", reading: ""))
    }

    // Parses one segment token like `(巡)[めぐ]り(会)[あ]う` into (surface, reading).
    // Surface: kanji + kana exactly as they appear in the source text.
    // Reading: full phonetic reading including kana between kanji runs, so that
    //   projectRunReadings can re-split per run using the okurigana as delimiters.
    // Example: `(巡)[めぐ]り(会)[あ]う` → surface="巡り会う", reading="めぐりあう"
    // Pure-kana tokens (no `()` annotations) produce an empty reading.
    private static func parseSegmentToken(_ token: String) -> (surface: String, reading: String) {
        var surface = ""
        var reading = ""
        var hasAnnotation = false
        var i = token.startIndex

        while i < token.endIndex {
            let ch = token[i]
            if ch == "(" {
                // Kanji run: collect surface inside `(...)`.
                let afterOpen = token.index(after: i)
                if let closeIdx = token[afterOpen...].firstIndex(of: ")") {
                    let kanjiText = String(token[afterOpen..<closeIdx])
                    surface += kanjiText
                    i = token.index(after: closeIdx)
                    // Expect `[reading]` immediately after `)`.
                    if i < token.endIndex, token[i] == "[" {
                        let afterBracket = token.index(after: i)
                        if let closeBracket = token[afterBracket...].firstIndex(of: "]") {
                            let bracketReading = String(token[afterBracket..<closeBracket])
                            reading += Self.readingAligningToKanjiText(kanjiText, bracketReading: bracketReading)
                            i = token.index(after: closeBracket)
                            hasAnnotation = true
                        }
                    }
                } else {
                    // Malformed — treat `(` as literal.
                    surface.append(ch)
                    i = token.index(after: i)
                }
            } else if ch == "[" {
                // Stray `[reading]` not preceded by `()` — skip bracket content.
                let afterBracket = token.index(after: i)
                if let closeBracket = token[afterBracket...].firstIndex(of: "]") {
                    i = token.index(after: closeBracket)
                } else {
                    i = token.index(after: i)
                }
            } else {
                // Literal kana (okurigana between or after kanji runs).
                // Include in reading only when the token has annotations, so that
                // projectRunReadings can use the kana as a split delimiter.
                surface.append(ch)
                if hasAnnotation {
                    reading.append(ch)
                }
                i = token.index(after: i)
            }
        }

        // Pure-kana tokens have no annotation; their reading is left empty.
        return (surface, hasAnnotation ? reading : "")
    }

    // The model is expected to wrap only the kanji run itself in `(kanji)[reading]`, with any
    // trailing okurigana left outside the parens as plain characters — e.g. `(大切)[たいせつ]に
    // してた`. It occasionally sweeps trailing kana inside the parens instead —
    // `(大切にしてた)[たいせつ]` — which would otherwise make `reading` just "たいせつ", missing
    // the "にしてた" suffix that per-run furigana projection needs downstream. When kanjiText is
    // pure kanji (the common case), the bracket reading is used as-is. Otherwise, kanjiText's own
    // kanji runs are re-split against bracketReading and the surrounding kana characters are
    // spliced back in at their original positions, so `reading` still lines up with kanjiText
    // character-for-character. Falls back to the raw bracket reading if the re-split fails.
    private static func readingAligningToKanjiText(_ kanjiText: String, bracketReading: String) -> String {
        let innerRuns = FuriganaAttributedString.kanjiRuns(in: kanjiText)
        let chars = Array(kanjiText)
        guard innerRuns.count != 1 || innerRuns[0].start != 0 || innerRuns[0].end != chars.count else {
            return bracketReading
        }
        guard let runReadings = FuriganaAttributedString.normalizedRunReadings(surface: kanjiText, reading: bracketReading, runs: innerRuns),
              runReadings.count == innerRuns.count else {
            return bracketReading
        }

        var aligned = ""
        var idx = 0
        for (run, runReading) in zip(innerRuns, runReadings) {
            if idx < run.start {
                aligned += String(chars[idx..<run.start])
            }
            aligned += runReading
            idx = run.end
        }
        if idx < chars.count {
            aligned += String(chars[idx...])
        }
        return aligned
    }
}
