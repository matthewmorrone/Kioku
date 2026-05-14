# Custom Renderer Regression Checklist

Tracks behaviors that may change when `KiokuCoreTextView` replaces TextKit 2 in the Read view.
Each row: what to check, the practical test, and severity.

**Severity:**
- 🔴 **Block merge** — a working app needs this.
- 🟡 **Verify, then triage** — unlikely to regress, but cheap to confirm.
- 🟢 **Accepted change** — different by design, document and move on.

---

## 1. Layout & typography

| # | Behavior | Test | Severity |
|---|---|---|---|
| 1.1 | Line breaking matches current (kinsoku, no-break-before for 、。) | Open 5 Japanese notes of varying length. Screenshot side-by-side: TK2 vs CT. Diff line-end positions visually. | 🔴 |
| 1.2 | Mixed-script wrap (Kanji + romaji + numbers) | Note containing "iPhone 15 Pro Maxを買った" — verify wrap doesn't split inside "iPhone". | 🟡 |
| 1.3 | Empty / blank paragraphs preserve height | Note: "あ\n\n\nい". Should show three blank lines between, not collapse. | 🟡 |
| 1.4 | Trailing whitespace on wrapped lines | Note ending in spaces — verify cursor/tap works at end of line, no visible wide gap. | 🟡 |
| 1.5 | Last-line furigana visible | Note ≥ 50 lines. Scroll to bottom. Last line's ruby must render. (TK2 had a viewport-cap bug here; CT doesn't have a viewport. Should be fixed by construction.) | 🔴 |
| 1.6 | Width-change reflow on rotation / Split View | Rotate iPad mid-note. Verify reflow without artifacts. | 🟡 |
| 1.7 | Bounds.width = 0 transient (initial layout) | Cold-launch into a long note. First frame must not show empty content or crash. | 🔴 |
| 1.8 | Font fallback for missing glyphs | Note containing emoji or unusual CJK ideographs. Verify they render (with system fallback). | 🟡 |
| 1.9 | Dynamic Type response | Cycle text size in Settings. Verify CT renderer reflows; the `textSize` binding is the source of truth, not OS-level Dynamic Type — but bold/contrast accessibility settings must still propagate via UIKit. | 🟡 |

## 2. Furigana / ruby

| # | Behavior | Test | Severity |
|---|---|---|---|
| 2.1 | Ruby centered over kanji run | Toggle furigana on. Inspect any kanji segment — ruby midpoint should align with kanji midpoint. | 🔴 |
| 2.2 | Per-run readings on multi-run compounds (抜け殻) | Open a note containing 抜け殻. Both ぬ and がら must render above their respective kanji. | 🔴 |
| 2.3 | Wide-ruby line-start inset | Note where the first segment of a line has wider ruby than its kanji (e.g., line starting with 為替). Ruby must not be clipped at left edge. (CT path shifts line origin instead of using exclusion paths.) | 🔴 |
| 2.4 | Mixed kanji + okurigana ruby placement (食べる) | Ruby "た" should sit over 食 only, not stretch over べる. | 🔴 |
| 2.5 | Reading override (user-edited furigana) | Long-press → edit reading → verify the new value renders without rebuild thrash. | 🟡 |

## 3. Inter-segment spacing

| # | Behavior | Test | Severity |
|---|---|---|---|
| 3.1 | Adjacent same-line segments don't overlap | Dump `[envelope-gap]` log on a note with wide-ruby pairs (瞬き → 数え was the worst case). All gaps should be ≥ 0pt. | 🔴 |
| 3.2 | Adjacent segments don't have phantom large gaps | Same log: gaps should also be close to user kerning (no 3pt outliers). | 🔴 |
| 3.3 | Kerning slider in Settings still works | Drag kerning. Verify gaps respond live, not in 0.3pt steps (CT renderer should be quantization-free vs TextKit's pixel snapping). | 🟡 |
| 3.4 | Toggling ruby-spacing setting | Toggle on/off — verify spacing applies/reverts cleanly without flicker or stale layout. | 🟡 |

## 4. Selection & interaction

| # | Behavior | Test | Severity |
|---|---|---|---|
| 4.1 | Tap-to-select-segment | Tap a segment. The correct segment range highlights. Tap on whitespace/punctuation: nothing selected. | 🔴 |
| 4.2 | Selection envelope rendering | Selected segment shows the surrounding rectangle (kanji extent ∪ ruby frame). Width matches TK2 reference. | 🔴 |
| 4.3 | Tap dismissal | Tap outside any segment — selection clears. | 🟡 |
| 4.4 | Long-press copy (if used) | Verify whether Read view exposes a copy gesture today. If yes, reimplement with `UIContextMenuInteraction`. If no, document as N/A. | 🟡 |
| 4.5 | Double-tap / triple-tap | Did TK2 expose word/line selection here? If used, port; otherwise drop. | 🟢 |

## 5. Scrolling & content size

| # | Behavior | Test | Severity |
|---|---|---|---|
| 5.1 | Scroll physics feel native | Flick-scroll a long note. Compare to TK2 — should be indistinguishable (CT view is just content inside `UIScrollView`). | 🟡 |
| 5.2 | contentSize matches actual document height | Scroll to bottom. Last line is fully visible, not cut off. | 🔴 |
| 5.3 | Auto-scroll to active playback cue | Play audio on a synced note. Active line should auto-scroll into view (currently 32% from top). | 🔴 |
| 5.4 | Scroll-to-top on note switch | Switch notes. New note starts at top. | 🟡 |
| 5.5 | External scroll sync (read ↔ edit mode) | Toggle edit mode mid-scroll. Position is preserved. | 🟡 |
| 5.6 | Pinch-to-zoom-text-size | Pinch in/out. Text size updates live without crash; layout reflows. | 🟡 |

## 6. Color, style, debug overlays

| # | Behavior | Test | Severity |
|---|---|---|---|
| 6.1 | Color alternation between segments | Toggle in Settings. Even/odd segments alternate between configured colors. | 🟡 |
| 6.2 | Unknown-segment highlighting | Note with ≥1 unknown word. Highlighted in `unknownSegmentForegroundColor`. | 🟡 |
| 6.3 | Playback highlight band | Active cue has its background tint. | 🔴 |
| 6.4 | Dark mode colors resolve correctly | Toggle dark mode. Foreground colors update without app restart. | 🟡 |
| 6.5 | Debug envelope/bisector rects | Each debug toggle in Settings. Rects render correctly over CT-laid-out segments. | 🟡 |
| 6.6 | Illegal merge boundary indicator (red bar) | Trigger an illegal merge. Red boundary bar renders at the right location. | 🟡 |

## 7. Performance

| # | Behavior | Test | Severity |
|---|---|---|---|
| 7.1 | Initial render time | Cold-launch into a large note (≥1000 chars). Time to first paint should be ≤ TK2 (CT's framesetter is single-shot, no incremental viewport realization). | 🟡 |
| 7.2 | Toggle latency (furigana on/off) | Toggle. Should feel instant (no `attributedText` reassign, just `setNeedsDisplay`). | 🟡 |
| 7.3 | Scroll FPS | Flick-scroll long note. Target 120fps on ProMotion devices. | 🟡 |
| 7.4 | Memory steady-state | Open 5 large notes in succession. CT should not leak framesetters. Profile with Instruments. | 🟡 |

## 8. Accessibility (the real risk)

| # | Behavior | Test | Severity |
|---|---|---|---|
| 8.1 | VoiceOver reads text | Enable VO. Swipe right repeatedly. Each segment or line is voiced. | 🔴 |
| 8.2 | VoiceOver follows playback / selection | Selection moves during playback — does VO follow? | 🟡 |
| 8.3 | Speak Screen / Speak Selection | If supported on TK2, must work on CT too. | 🟡 |
| 8.4 | Bold Text / Increase Contrast | Toggle in Settings. Renderer reflects. | 🟡 |
| 8.5 | Switch Control / external keyboard | Tab-traversal still moves selection through segments. | 🟡 |

## 9. Out of scope (intentional changes)

| # | Behavior | Rationale |
|---|---|---|
| 9.1 | Cursor caret rendering | Read view has no cursor today. CT path doesn't add one. |
| 9.2 | Native UITextView selection handles | Replaced by tap-to-segment model already in place. |
| 9.3 | Dictation / IME / predictive bar | Read-only view; not applicable. |
| 9.4 | Notes editor (edit mode) | Stays on UITextView. Only Read view migrates. |
| 9.5 | TextKit-2-specific bugs | Last-line furigana drop-out (`bounds.height = 1_000_000` workaround) and viewport-cap fragments — both go away by construction. |

---

## How to verify systematically

1. **Side-by-side flag.** Add `@AppStorage("kioku.debug.useCoreTextRenderer") var useCoreTextRenderer = false`. Toggle in Settings. Both renderers stay mounted in dev so you can A/B with one tap.
2. **Reference notes.** Create a "regression suite" of 5 notes covering: short kana, long mixed-script paragraph, multi-run kanji compound (抜け殻, 食べ物), wide-ruby-at-line-start (為替), heavy ruby-overlap candidate (lyrics with 瞬き 数え).
3. **Screenshot diff.** Take TK2 screenshot, switch flag, take CT screenshot. Diff visually for each note.
4. **Log-based.** Keep `[envelope-gap]` log enabled. Open the regression notes. Spacing residuals should be at-worst as good as TK2 baseline numbers (recorded earlier in this session: 0.3-3.3pt range).
5. **Instrument.** Time `applyOverlay` in both paths; log on each render. CT path should be ≥ as fast.
6. **VoiceOver smoke test.** Enable VO. Read through one note end-to-end. Verify nothing is silently skipped.
7. **Accessibility audit.** Run Xcode's Accessibility Inspector against both renderer modes.

Don't merge until items marked 🔴 are all verified.
