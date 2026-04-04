# Karaoke Lyrics View — Design Spec

## Summary

A floating popup overlay on `ReadView` that shows the subtitle cue list in a scrollable, karaoke-style layout. Active cue is highlighted with furigana and a machine translation. Words in the active cue are tappable for dictionary lookup. Controls (play/pause, scrubber, repeat) are embedded at the bottom of the popup. Tapping outside the popup dismisses it.

---

## Trigger

- A ♪ button in the existing toolbar row (`toolbarButtons` in `ReadView`), positioned to the right of the play/pause button.
- Only visible when `audioController.duration > 0` **and** `audioAttachmentCues.isEmpty == false`.
- Tapping it sets `isShowingLyricsView = true` on `ReadView`. The existing audio bar (scrubber + play button) is hidden while the lyrics popup is open.

---

## Popup Appearance

- **Size:** 50% of screen height, ~90% of screen width.
- **Position:** Centered horizontally and vertically in the screen.
- **Background:** `UIColor.systemBackground` at ~97% opacity, blur material, `cornerRadius: 20`.
- **Backdrop:** A semi-transparent black dimming layer behind the popup, covering the full `ReadView`. Tapping the dim layer dismisses the popup.
- **Presentation:** SwiftUI `.overlay` on `ReadView`, not a sheet. No animation required beyond the default SwiftUI opacity transition.

---

## Cue List

- A `ScrollView` + `ScrollViewReader` containing one row per `SubtitleCue`.
- Auto-scrolls to keep the active cue visible as playback progresses (using `scrollTo` with `anchor: .center`).
- User can freely scroll at any time; auto-scroll resumes on the next cue change.
- Tapping any non-active cue seeks `AudioPlaybackController` to that cue's `startMs` and resumes playback.

### Active cue row

- Amber tint background (`systemOrange` at ~14% opacity), `cornerRadius: 10`.
- Furigana rendered using the existing `FuriganaView` (reuses `furiganaBySegmentLocation` / `furiganaLengthBySegmentLocation` from `ReadView` state — resolved by matching cue text offsets to note text offsets via `audioAttachmentHighlightRanges`).
- Each word (segment) in the active cue is individually tappable, opening the existing `SegmentLookupSheet` exactly as tapping in the read view does.
- A machine translation of the cue text is shown below the Japanese text in a smaller italic style using Apple's on-device `Translation` framework (`TranslationSession`, iOS 17.4+). Translation is requested lazily when a cue becomes active and cached in a `[Int: String]` dictionary keyed by cue index. Translation failures are silent (no translation shown).

### Inactive cue rows

- Center-aligned text, no furigana.
- Opacity scaled by distance from active cue: adjacent cues ~28%, further cues ~20%.
- Font size slightly smaller than active cue.

---

## Bottom Controls

No hard divider between cue list and controls. The cue list fades out at the bottom via a gradient mask. Controls sit flush below.

Single row: **play/pause button (22pt) · scrubber (fills remaining width, timestamps below) · repeat button (22pt)**

- **Play/pause:** Amber tint circle. Toggles `audioController.play()` / `audioController.pause()`.
- **Scrubber:** Reuses `AudioPlaybackScrubber` logic (current time, total duration, seek on drag).
- **Repeat:** Dim circle when off, amber circle when on. When on, `AudioPlaybackController` is monitored — when `currentTimeMs` exceeds the active cue's `endMs`, playback seeks back to `startMs` automatically.

---

## Display Style Setting

Three styles selectable in Settings under a new "Lyrics Display Style" option:

| Key | Name | Description |
|-----|------|-------------|
| `appleMusic` | Apple Music | Active line large + bold, center-aligned. Past/future lines fade above and below. |
| `accentBar` | Accent Bar | Left-aligned. Active line has a left amber accent bar. |
| `focusCard` | Focus Card | Active cue in a prominent card. Past/future compressed to single lines above/below. |

Stored in `AppStorage` as a `String` raw value. Defaults to `appleMusic`.

---

## New Files

| File | Purpose |
|------|---------|
| `Kioku/Read/Audio/LyricsView.swift` | The floating popup SwiftUI view. Owns the cue list, controls, and dismiss tap target. |
| `Kioku/Read/Audio/LyricsCueRow.swift` | A single cue row — active variant (furigana + translation + tappable words) and inactive variant. |
| `Kioku/Read/Audio/LyricsTranslationCache.swift` | `@MainActor` observable class. Manages `TranslationSession`, caches `[Int: String]` results, exposes `translation(for:cueIndex:)` async method. |
| `Kioku/Settings/LyricsDisplayStyle.swift` | `enum LyricsDisplayStyle: String, CaseIterable` with `appleMusic`, `accentBar`, `focusCard` cases and display names. |

---

## Modified Files

| File | Change |
|------|--------|
| `Kioku/Read/ReadView.swift` | Add `@State var isShowingLyricsView = false`. Add ♪ button to `toolbarButtons`. Hide audio scrubber + play button while `isShowingLyricsView`. Add `.overlay` with `LyricsView`. |
| `Kioku/Settings/SettingsView.swift` | Add "Lyrics Display Style" picker in the typography/display section. |

---

## Architecture Notes

- `LyricsView` receives `audioController` (as `ObservedObject`), `cues`, `highlightRanges`, `furiganaBySegmentLocation`, `furiganaLengthBySegmentLocation`, `segmentationRanges`, `text`, `onSegmentTapped`, `onDismiss`, and `displayStyle` as inputs. It owns no state beyond scroll position and repeat toggle.
- `LyricsTranslationCache` is instantiated once in `ReadView` and passed to `LyricsView`. It is cleared when the note changes.
- Repeat loop logic lives in `LyricsView` via an `onChange(of: audioController.currentTimeMs)` modifier — no changes to `AudioPlaybackController`.
- Word-tap in the active cue resolves the segment location from the note text using the existing `audioAttachmentHighlightRanges` offset, then calls the same `onSegmentTapped` closure used by `FuriganaTextRenderer`.

---

## Out of Scope

- Animated karaoke text fill (per-character progress highlight within a line).
- Landscape layout.
- Persistence of repeat state across sessions.
