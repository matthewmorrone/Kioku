# In-Place Word Popover — Design

Date: 2026-07-11
Status: Approved design, ready for implementation planning

## Summary

Replace the Read tab's current behavior — tapping a word always opens the full lookup
sheet — with a lightweight popover as the first stop. The popover shows the word's meaning
with a favorite star, a speak-it-aloud tap target on the word itself, and an arrow that
escalates to the existing full lookup sheet. This is the "In-place context menu on the Read
tab" item from `docs/todo.md`.

## Background

Today, `ReadView.prefersSheetDirectSegmentActions` (`ReadView.swift:264`) is hardcoded `true`,
so every word tap in the Read tab opens the full `SegmentLookupSheet`/`SurfaceSheetViewController`
bottom sheet directly (headword, readings, definitions, merge/split controls). There is no
lighter-weight step first.

Investigation turned up that a **complete, working anchored popover already exists** —
`SegmentLookupSheet.presentPopover(definition:surface:leftNeighborSurface:rightNeighborSurface:onMergeLeft:onMergeRight:onSplitApply:onDismiss:sourceView:sourceRect:)`
(`SegmentLookupSheet.swift:109-213`) — a real `UIPopoverPresentationController`-anchored card
showing a gloss label and a chevron "escalate" button. It is currently **dead code**: unreachable
because `prefersSheetDirectSegmentActions` never lets execution reach it. This design revives
and extends that implementation rather than building a new popover mechanism.

## Goals

- Tapping a word shows a fast, lightweight glance at its meaning without leaving Read.
- One more tap gets you everything the current full sheet already provides — nothing is lost,
  just gated one tap later.
- Reuse existing, working infrastructure (popover shell, favorite toggle, TTS) rather than
  duplicating it.

## Non-goals

- No changes to the full lookup sheet's own contents or behavior.
- No changes to merge/split editing — still reached via the full sheet, just one tap further away.
- No new gesture claimed for this feature (long-press stays free/unclaimed).
- Not addressing the Words-tab `WordDetailView` / tab-switch escalation path at all — this
  feature only touches the Read-tab-local lookup sheet.

## Interaction model

1. **Tap a word** → the popover appears, anchored to the tapped word (arrow-tipped card,
   pointing at the word, `UIPopoverPresentationController`-based like the existing dead-code
   implementation). Single-row layout: **★ · word · meaning · ›**. The popover hugs its content
   width — no fixed-width dead space around short words/meanings.
   - If the word has no dictionary match (proper noun, unrecognized token), tap is a no-op —
     same as today's behavior for such tokens.
2. **Tap the star** → toggles favorite/save via the existing
   `wordsStore.toggle(canonicalEntryID:storedSurface:encounteredSurface:sourceNoteID:defaultSenseIDs:)`
   path (the same call `sheetSaveToggle` already makes). The popover stays open so the star's
   fill state updates visibly.
3. **Tap the word itself** (inside the popover) → speaks it aloud: `AVSpeechSynthesizer` +
   `AVSpeechUtterance(string:)` with `AVSpeechSynthesisVoice(language: "ja-JP")`, the same
   pattern already used in `SurfaceSheetViewController+Build.swift`, `WordDetailView.swift`, and
   `WordsView+ListContent.swift`. The popover stays open.
4. **Tap the arrow** → dismisses the popover and opens the full Read-tab lookup sheet — the
   same `SegmentLookupSheet.shared.presentSheet(...)` call that tap makes today. This is a pure
   "one tap later" version of current behavior, not a new destination.
5. **Tap elsewhere in the text** → dismisses the current popover; if the new tap lands on
   another word with a dictionary match, the popover reopens anchored to that word (a fresh
   present, not a live retarget — matches how `UIPopoverPresentationController` naturally
   behaves on dismiss-then-present).
6. **Long-press** is unaffected — it remains unclaimed on the main Read page (only
   `LyricsView`'s separate karaoke view uses long-press today, for a different purpose).

## What changes vs. what's reused

| Piece | Status |
|---|---|
| Popover shell (anchoring, sizing, arrow-tip presentation) | **Reused** — revive `SegmentLookupSheet.presentPopover`, currently dead code |
| Meaning/gloss resolution | **Reused** — `definitionPayloadForSelectedSegment(at:)` + `mostLikelyDefinition(from:)` (`ReadView+Segmentation.swift:648-681, 771`), already the exact resolver the dead-code popover path uses |
| Favorite toggle + star state | **Reused** — `wordsStore.toggle(...)`, `sheetIsSavedProvider`/`sheetIsSavedElsewhereProvider` pattern for the star's fill state |
| Speak-on-tap | **Reused pattern, new call site** — `AVSpeechSynthesizer`/`AVSpeechUtterance`, same as three existing call sites elsewhere in the app; the popover needs its own synthesizer instance (or associated-object retain, mirroring `SegmentLookupSheet.speechSynthesizerKey`) |
| Escalate arrow → full sheet | **Reused** — same `SegmentLookupSheet.shared.presentSheet(...)` call tap makes today |
| `prefersSheetDirectSegmentActions` | **Changed** — flips from an unconditional `true` to routing tap through the popover first |
| Popover contents (star + speak) | **New** — today's dead-code popover only has meaning + escalate arrow; star and speak-on-tap are additions to that existing view |

## Layout

Single-row card: star (left) — word, underlined/dotted to signal it's tappable-to-speak —
meaning text — chevron arrow (right). Confirmed via mockup: content-hugging width (no fixed
max-width causing dead space around short content), white/high-contrast text, anchored with a
small pointer arrow under the tapped word, consistent with the existing app's card styling.

## Testing

- Tapping a dictionary-matched word opens the popover anchored correctly; tapping a token with
  no dictionary entry is a no-op (existing behavior preserved).
- Star toggle inside the popover updates `WordsStore` and the star's visual state without
  dismissing the popover; verify against the existing `sheetIsSavedProvider`/
  `sheetIsSavedElsewhereProvider` predicates so saved-elsewhere (hollow star) still renders
  correctly.
- Speaking a word inside the popover produces audio without dismissing the popover, and doesn't
  leak/crash if the popover is dismissed mid-utterance (mirror the existing associated-object
  retain pattern's lifecycle handling).
- Arrow tap dismisses the popover and opens the exact same full sheet content tap used to open
  directly before this change (no content regression).
- Tapping a second word while a popover is showing correctly dismisses the first and presents
  a new one anchored to the second word.

## Open questions

None blocking. `prefersSheetDirectSegmentActions`'s naming will read oddly once it no longer
means "always" — worth a rename or at least a comment update during implementation, but that's
a mechanical detail for the implementation plan, not a design fork.

## Key files

- `Kioku/Read/ReadView.swift:264` — `prefersSheetDirectSegmentActions` (routing flag to change).
- `Kioku/Read/Lookup/SegmentLookupSheet.swift:109-213` — `presentPopover(...)` (revive + extend
  with star + speak).
- `Kioku/Read/Segmentation/ReadView+Segmentation.swift` — `handleReadModeSegmentTap`,
  `definitionPayloadForSelectedSegment(at:)`, `mostLikelyDefinition(from:)`,
  `resolvedDictionaryEntryForCurrentSelectedSegment()`, `sheetSaveToggle`, existing `presentPopover`
  call site (line ~625).
- `Kioku/Read/Lookup/SurfaceSheetViewController+Build.swift:279-297,360-368` — reference speak
  button + save button implementations to mirror inside the popover.
