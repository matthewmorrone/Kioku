# Lexicon Data Surfaces

This document defines the UI-facing lexical methods provided by `Lexicon`, with example input and output.

## reading(surface)
Description:
Return the kana reading of the surface form. If input is already kana, return it unchanged.

Examples:
- `reading("食べた") -> "たべた"`
- `reading("たべた") -> "たべた"`

## lemma(surface)
Description:
Return possible dictionary lemmas for an inflected surface form using deinflection rules.

Examples:
- `lemma("食べた") -> ["食べる"]`
- `lemma("行かなかった") -> ["行く"]`

## normalize(surface)
Description:
Return normalized lookup candidates combining lemma and reading.

Example:
- `normalize("食べた") -> [(lemma: "食べる", reading: "たべる")]`

## inflectionInfo(surface)
Description:
Return a structured explanation of how the surface form derives from the lemma. Covers all groups from `Resources/deinflection.json`.

Example:
- `inflectionInfo("食べさせられた") -> (lemma: "食べる", chain: ["causative", "passive", "past"])`

## lookupLexeme(lemma, reading)
Description:
Find lexeme entries matching lemma and optional reading.

Example:
- `lookupLexeme("食べる", "たべる") -> [DictionaryEntry(entryId: 1376300, ...)]`

## resolve(surface)
Description:
Resolve one surface into lemma/reading candidates and return ranked lexeme matches.

Example:
- `resolve("食べた") -> [(lexeme: "食べる", score: 0.98)]`

## lexeme(id)
Description:
Return the core lexeme record for a dictionary entry id (`"1376300"` or `"lex_1376300"`).

Example:
- `lexeme("lex_1376300") -> DictionaryEntry(entryId: 1376300, ...)`

## forms(lexemeId)
Description:
Return all orthographic forms of a lexeme.

Example:
- `forms("lex_1376300") -> [(spelling: "食べる", reading: "たべる"), (spelling: "喰べる", reading: "たべる"), (spelling: "たべる", reading: "たべる")]`

## senses(lexemeId)
Description:
Return meanings associated with a lexeme.

Example:
- `senses("lex_1376300") -> ["to eat", "to live on (food)"]`

## primaryReading(lexemeId)
Description:
Return primary reading used for a lexeme.

Example:
- `primaryReading("lex_1376300") -> "たべる"`

## displayForm(lexemeId)
Description:
Return preferred dictionary headword spelling.

Example:
- `displayForm("lex_1376300") -> (spelling: "食べる", reading: "たべる")`

## matchedForm(surface, lexemeId)
Description:
Return form that best matches tapped surface text.

Example:
- `matchedForm("食べた", "lex_1376300") -> (spelling: "食べる", reading: "たべる")`

## containsKanji(text)
Description:
Return true if text contains kanji.

Example:
- `containsKanji("食べた") -> true`

## isKana(text)
Description:
Return true if text is only hiragana or katakana.

Example:
- `isKana("たべた") -> true`

## kanjiCharacters(lexemeId)
Description:
Return unique kanji characters used across a lexeme's forms.

Example:
- `kanjiCharacters("lex_1376300") -> ["食"]`

## expandInflection(lemma)
Description:
Generate valid inflected forms from a lemma using the same rule set as deinflection.

Example:
- `expandInflection("食べる") -> ["食べる", "食べた", "食べない", "食べれば", "食べさせる", "食べられる"]`

## inflectionChain(surface)
Description:
Return the grouped rule chain that derives lemma from surface, including compound auxiliaries.

Example:
- `inflectionChain("食べさせられた") -> ["causative", "passive", "past"]`

## Removed APIs
The following lattice-oriented methods were removed from `Lexicon` and are no longer part of this data surface:
- `latticeNeighbors(nodeId, distance)`
- `nodeComponents(nodeId)`
