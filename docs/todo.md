# Todo

## Bugs

- [ ] Ruby persistent overhang spacing on the left edge
- [ ] Distribute spacing better for multikanji ruby headwords
- [x] Combining or splitting words: save button state not refreshed after merge/split
- [ ] Clicking the star button doesn't always trigger bookmarking (bookmark button works)
- [ ] Typing freely in English in the paste area is super laggy

## Segmentation & Lookup

- [x] Halfwidth katakana normalization in lookup (ｱｲｳｴｵ → アイウエオ)
- [ ] Use frequency data to influence segmentation path selection
- [ ] Provide meaning of verbs in the form they surface in
- [ ] Lexicon lemma ranking should respect saved-word surfaces when scoring inflection candidates (Lexicon.swift:184, 241)

## Read View

- [ ] Note-level TTS: play/pause, rate and voice controls, spoken-range highlighting
- [ ] Quiz on next and previous words/lines

## Words & Dictionary

- [x] Add personal note to saved words
- [ ] CSV import: flexible parsing
- [ ] Add manual/custom word creation and editing
- [ ] Deduplicate example sentences
- [ ] Custom reading popup should be prefilled and set to Japanese keyboard
- [ ] Make saving to the words list more responsive
- [ ] Add advanced dictionary filters/sorting (JLPT, POS, frequency, commonness toggles)
- [ ] Romaji display option
- [ ] List conjugations in dictionary view
- [ ] Variants section in WordDetail: list all kanji and kana forms of the entry, labeled, separate from the saved surface
- [ ] alternateSpellings(): include kanji variants (currently kana-only, and only when the saved surface contains kanji)
- [ ] CSV import: explicit option to fill kanji from the dictionary when the surface column is missing (today the importer silently substitutes kanji even when only kana was provided)

## Study & Review

- [ ] Spaced repetition scheduling (due dates, intervals, ease, FSRS-like logic)
- [ ] Auto clipboard paste/search

## Kanji

- [ ] Dedicated kanji discovery tab/screen
- [ ] Full kanji metadata support (radicals, readings, components)
- [ ] Handwriting input and stroke order
- [ ] Kanji of the day feature

## Audio & Alignment

- [ ] Expand karaoke alignment benchmark dataset and add CI evaluation job
- [ ] Native human audio pronunciation dataset support (beyond TTS)
- [ ] Vocal-vs-instrumental detection via Apple's Sound Analysis framework
      (`SNClassifySoundRequest` with the built-in speech/music classifier). Tap audio via
      `AVAudioEngine`, feed frames to the classifier, surface an `isVocalActive` published
      property on `AudioPlaybackController`. Lyrics popup gates "in vocal cue" on this so
      cues with bad SRT/TextGrid timing show the pulsing ♪ until the vocal actually arrives.
      Self-correcting per-song, no manual data fixes required.
- [ ] Audio-level silence detection (lightweight complement to vocal detection above).
      Use the existing `AVAudioPlayer.averagePower` meter with a hysteresis-gated threshold
      (e.g., level < 0.15 for > 300ms) to detect true silence between/before tracks. Cheaper
      than Sound Analysis but only catches actual quiet, not "instrumental without vocal".
- [ ] Unified ResolvedCue data model: replace the parallel `cues: [SubtitleCue]` +
      `cueTimings: [Int: [CueCharTiming]]` pair with a single value type that owns SRT cue
      boundaries AND optional TextGrid character checkpoints, with consistency validation at
      load time (drop or shift stale checkpoints whose timestamps fall outside the SRT
      cue's [startMs, endMs]). Consumers (AudioCueHighlightObserver, LyricsView) query a
      single source instead of cross-referencing two. Solves the class of bugs where
      hand-editing the SRT leaves stale TextGrid timings driving the per-word band.

## Settings

- [ ] Adjust ruby typography settings (spacing, padding)
- [ ] Default to Japanese IME where appropriate
- [ ] Clipboard behavior settings

## Ship Readiness

- [x] Hide/gate debug section and diagnostic toggles from release builds
- [x] Add explicit pre-import confirmation for backup restore
- [ ] Add UI smoke tests for core user loop (notes, lookup/save, study, backup)
- [ ] Split Settings into Basic vs Advanced (move advanced controls behind secondary screen)
- [ ] Progressive disclosure in dictionary detail UI
- [ ] Accessibility pass (VoiceOver labels, Dynamic Type scaling, contrast)
- [ ] App Store packaging artifacts and release QA checklist
- [ ] Credits/About screen with dataset attributions (JMdict, Tatoeba, IPADic, fastText)
