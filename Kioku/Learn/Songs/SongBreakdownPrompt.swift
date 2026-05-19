import Foundation

// Holds the verbatim song-breakdown prompt template as a Swift static string so the binary
// always ships it (no resource-bundling complexity for plain .txt files in Xcode 16
// synchronized groups). `instantiated(withLyrics:)` substitutes the lyrics marker.
//
// The template is the user-authored prompt as supplied — do not paraphrase or trim it.
// If you need to revise the prompt, change the literal here; consumers depend on the
// output shape this prompt produces (Line N header, romaji italic line, dash bullets,
// **Gist:** marker, --- section separator, "= line N" / "Parallel to line N" references).
enum SongBreakdownPrompt {
    static let lyricsMarker: String = "[paste lyrics here]"

    static let template: String = """
        You are helping me learn and memorize a Japanese song line by line. Provide a complete line-by-line breakdown following these rules:

        ## Format per line

        **Line N: [original line in Japanese, unchanged]**
        *[romaji matching what is actually sung, not what is written]*

        - **[word in kanji/kana]** ([romaji]) — [definition + nuance, register, etymology, or distinction from near-synonyms when relevant]
        - [repeat for each meaningful word/morpheme]
        - [skip pure case particles like を/が/に unless they do something interesting]

        **Gist:** [natural English rendering of the whole line — interpreted IN CONTEXT of the entire song]

        [Optional: one short pattern-to-bank note if the line introduces a grammar pattern worth memorizing — literary negatives (〜ず), te-form chains, stem-form continuatives, mimetic + と, furigana mismatches, 〜ゆく vs 〜いく, classical attributive なる, etc. Skip if nothing new.]

        ---

        ## Rules

        0. **Read the entire song before writing any gist.** Each gist must reflect the song's voice, addressee, established imagery, tense/aspect, and the meaning the line carries at *its specific position* in the narrative. Concretely:
           - Resolve dropped subjects/objects against the participants the song has established by that point — not as a generic "someone/something."
           - A bare noun-phrase line ("夕凪の時間", "化石ムーンフラグメント") is part of a longer thought continued by adjacent lines; render it as a clause that fits the surrounding sentence, not as an orphan fragment.
           - Use proper nouns and loanword referents (e.g. Chénon, Aurore, Lumière) consistently across lines once introduced. Do not retranslate them differently in different gists.
           - When a chorus line recurs with different surrounding imagery, the gist may shade differently the second time even if the Japanese is identical — note this in the optional pattern-bank line for that occurrence.
           - Maintain tense/aspect and register across the song; a song that is consistently past-reflective should not flip to abstract present in one line.

        1. **Line splits**: Use the exact line breaks from the source. Do not split or merge lines.

        2. **Romaji**:
           - Match what is actually sung, not just the kanji's standard reading. Flag furigana mismatches explicitly (e.g. 愛人 written, *hito* sung; 破片 written, *kakera* sung).
           - Use double vowels (ou, ee, aa), never macrons. Show two vowels whenever two morae are written (映画 = eiga, 東京 = toukyou).
           - Use *wo* for を, *zu* for ず, *ji* for じ (not *o*, *du*, *zi*).

        3. **Loanwords**: Identify the source language (usually French or English in J-pop) and original meaning. Do not over-defend their thematic importance — if a loanword is purely aesthetic and doesn't grammatically integrate, say so plainly.

        4. **Repeated lines**: After the first full breakdown of a chorus line, on later occurrences just note "= line N" or "Parallel to line N with substitution: X → Y" and explain only what changed. Do not repeat full breakdowns of identical material.

        5. **Depth**: Assume basic grammar and kana fluency. Focus on the *interesting* stuff — etymology, register (literary vs colloquial vs classical), distinctions from near-synonyms (触れる vs 触る, 寒い vs 冷たい, 命 vs 人生 vs 生活, 羽 vs 翅, 雷 vs 稲妻, etc.), cultural/aesthetic context (mono no aware, specific seasonal/time imagery like 夕凪, 黄昏 = 誰そ彼). Do not pad with N5-level basics.

        6. **No extra commentary**: No intros, no outros, no "here's the song!" or "enjoy!" — just the breakdown. End when the song ends.

        7. **Skip nothing**: Cover every line in order, including short interjections or vocalizations (mark them as such, e.g. "Vocal exclamation").

        8. **Tone**: Direct, concise, occasionally dry. No filler praise. Correctness over politeness — call out wrong common interpretations.

        ## Lyrics

        \(lyricsMarker)

        """

    // Returns the prompt with the lyrics block substituted. Falls back to appending the lyrics
    // if the marker is missing (defensive — shouldn't happen with the literal above, but the
    // template lives in one place and prevents silently shipping a prompt without lyrics).
    static func instantiated(withLyrics lyrics: String) -> String {
        if template.contains(lyricsMarker) {
            return template.replacingOccurrences(of: lyricsMarker, with: lyrics)
        }
        return template + "\n\n" + lyrics
    }
}
