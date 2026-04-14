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
