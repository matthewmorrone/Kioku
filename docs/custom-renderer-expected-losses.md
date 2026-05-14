# Custom Renderer — Expected Losses

What we explicitly give up by replacing `UITextView` (TextKit 2) with `KiokuCoreTextView` in the Read view, plus a concrete way to check each one. "Lost" doesn't always mean "gone" — some are reimplemented, some are intentionally accepted, some are "verify it really is gone before merging."

**Verdict so far:** none of the items in §1–§4 are deal-breakers for this app's Read view —
selection menus, cursors, dictation, and link autodetection aren't load-bearing UX here.
The accessibility wiring in §3 is the only mandatory reimplementation. Everything else is
either a free win (§8) or a verify-and-move-on.

For each item:
- **Lost:** what disappears.
- **Used today?** whether the Read view actually depends on it currently.
- **Check:** one specific user action that surfaces the loss.
- **Plan:** reimplement / accept / N/A.

---

## 1. Selection & system text actions

| # | Lost | Used today? | Check | Plan |
|---|---|---|---|---|
| 1.1 | Native drag-to-select with selection handles + magnifier loupe | No (Read view uses tap-to-segment, not range selection) | Long-press text in Read view today: handles + loupe appear. Same gesture in CT view: nothing. | Accept |
| 1.2 | "Copy / Look Up / Translate / Share" context menu on selected text | Partially — long-press appears to surface a system menu | Select a word and long-press; menu appears. After: no selection, no menu. | If we want copy: add `UIContextMenuInteraction` (10 min). Look Up / Translate / Share: lost unless we wire them per-action. |
| 1.3 | Double-tap = select word, triple-tap = select paragraph | No (segment tap is the model) | Double-tap a word in TK2 — word highlights. Same in CT — only the tap-to-segment fires. | Accept |
| 1.4 | Drag selected text out of the view (UIDragInteraction) | No | Long-press → start drag → drop into Notes app. Currently works(?). After: no drag source. | Accept |
| 1.5 | Auto-scroll while extending selection past viewport | No | Drag selection to bottom of screen — TK2 auto-scrolls. After: no selection at all, so N/A. | Accept |

## 2. Cursor / editing affordances (already not used in Read view)

| # | Lost | Used today? | Check | Plan |
|---|---|---|---|---|
| 2.1 | Insertion caret rendering | No | Tap text in TK2 — caret appears at tap point. After: nothing. | Accept |
| 2.2 | Dictation, predictive text bar, autocorrect | No | Read view is read-only. Edit mode (Notes view) keeps UITextView. | N/A |
| 2.3 | UITextInput protocol conformance | No | Hardware keyboard arrow keys move caret in TK2. CT: nothing happens. | Accept |
| 2.4 | Find-in-text (`UITextView.isFindInteractionEnabled`) | Verify | If you ⌘F in the running app, does Find appear? | If no: accept. If yes: needs custom find UI (~30 min). |

## 3. Accessibility

| # | Lost | Used today? | Check | Plan |
|---|---|---|---|---|
| 3.1 | VoiceOver reads each line as an element automatically | Implicitly yes — UITextView is a known accessible element | Enable VoiceOver, swipe right through Read view. Each line voices. After: the CT view is silent unless we expose `accessibilityElements`. | **Reimplement.** Per-line `UIAccessibilityElement` with frame + label = line text. ~30 min, must do before merge. |
| 3.2 | Speak Selection / Speak Screen | Depends on selection — see 1.x | Settings → Accessibility → Spoken Content → Speak Screen, swipe down with two fingers. Currently reads from top. After: depends on a11y exposure. | Falls out of 3.1 if elements are exposed. |
| 3.3 | Rotor: jump by line / paragraph / heading | Implicitly | VO rotor → "Lines" → swipe up/down. Moves through TK2 text. After: rotor only sees the elements we expose. | Falls out of 3.1. |
| 3.4 | Switch Control / external keyboard tab traversal | Implicit | Connect external keyboard, tab through UI. CT view should still be a focus stop. | Falls out of 3.1 (UIAccessibilityElement gives focus). |
| 3.5 | Bold Text / Increase Contrast auto-applied to text | Partially — depends on whether we currently use system fonts | Settings → Accessibility → Display & Text Size → Bold Text. TK2 immediately bolds. After: depends on font config; we use `UIFont.systemFont(ofSize:)` so this should still work for the base font, but verify. | Verify, no work expected |
| 3.6 | Dynamic Type live-update | We use our own `textSize` slider, not OS Dynamic Type | Settings → Display & Text Size → Larger Text → adjust. App doesn't currently respond. After: same. | Accept (already not used) |

## 4. Data detectors / smart features

| # | Lost | Used today? | Check | Plan |
|---|---|---|---|---|
| 4.1 | Auto-detect URLs / phone numbers / dates as tappable links | Verify | Type a URL into a note, switch to Read view. TK2 may render it as a tappable link. After: plain text. | Verify with a note containing `https://example.com`. If links are tappable today, accept the loss or reimplement. |
| 4.2 | Live Text on text in images | Not in Read view directly | N/A | N/A |
| 4.3 | Smart Quotes / Smart Dashes | Input-only, never applies in Read view | N/A | N/A |

## 5. Layout-engine specific behaviors

| # | Lost | Used today? | Check | Plan |
|---|---|---|---|---|
| 5.1 | Lazy viewport-only layout | Yes (TK2 default) | Open a 10,000-line note. TK2 only lays out viewport; CT lays out all lines up front. Cold-open of a giant note may take longer with CT. | Verify with a synthetic huge note. Acceptable if open time stays under ~500ms; otherwise need lazy CT layout (only build CTLines for visible Y range). |
| 5.2 | TextKit 2's `firstRect(for:)` semantics | Yes | We replicate via `KiokuTextLayoutEngine.firstRect(forCharacterRange:)` — must return same rects. | Diff `firstRect` outputs across the regression notes. |
| 5.3 | Exclusion paths (currently used for wide-ruby line-start inset) | Yes | Open a note where the first segment of any line has wide ruby (e.g., 為替 at line start). TK2 inserts an exclusion path; CT path must shift line origin instead. | Verify the line origin shift is wired before merging — this is a known feature, not a regression. |
| 5.4 | Native paragraph styles: paragraphSpacingBefore, headIndent, tailIndent, etc. | Some via `NSParagraphStyle` | If `lineSpacing` / `paragraphStyle` is set in the attributed string, CTTypesetter honors it. Other paragraph attributes need testing. | Verify by setting lineSpacing in Settings → Read view reflows correctly. |

## 6. Scroll / focus integration

The current TK2 scroll-integration is broken in places (auto-scroll-to-cue lands in the wrong
spot, occasional jumps). Accepted policy: **reimplement on the new path, don't try to mirror
TK2's quirks.**

| # | Lost | Used today? | Check | Plan |
|---|---|---|---|---|
| 6.1 | UITextView's auto-content-size | Yes | CT view exposes its own `contentSize`; wrapping UIScrollView consumes it. | Verify last line not cut off. |
| 6.2 | scrollRangeToVisible(_:) for playback cue auto-scroll | Yes — but currently buggy | Active line should auto-scroll into a comfortable band (~32% from top) on cue change. | Reimplement clean using `layoutEngine.firstRect(forCharacterRange:)` + `UIScrollView.setContentOffset`. Should be more reliable than the TK2 version. |
| 6.3 | "Smooth" momentum on flick scroll | Yes | CT view inside `UIScrollView` should feel identical. | Verify on device. |

## 7. UITextInput-shaped APIs the rest of the codebase may call

| # | Lost | Used today? | Check | Plan |
|---|---|---|---|---|
| 7.1 | `textView.firstRect(for: textRange)` calls in our code | Yes (FuriganaTextRenderer + Coordinator) | grep `firstRect(for:` | Replaced via `layoutEngine.firstRect(forCharacterRange:)`. Verify every call site is migrated before merge. |
| 7.2 | `textView.position(from:offset:)` for tap → location | Yes (FuriganaTextRendererCoordinator.handleTap) | grep `textView.position\|beginningOfDocument` | Replaced via `layoutEngine.characterIndex(at:)`. Verify all call sites. |
| 7.3 | `textView.attributedText = …` reassignment as the "redraw" trigger | Yes (renderer's didRenderText branch) | grep `textView.attributedText` | Replaced by `KiokuCoreTextView.setAttributedString(_:)` which only invalidates layout when the value differs. |
| 7.4 | `textView.textContainer.exclusionPaths` | Yes (LineStartInset.swift) | grep `exclusionPaths` | CT path uses line-origin shift; the exclusion-path mechanism is gone. |
| 7.5 | `NSTextLayoutManager` / `NSTextLayoutFragment` direct use | Yes (Geometry.swift's bounds-inflation hack) | grep `textLayoutManager` | The whole hack disappears. CT lays out all lines on demand; no viewport cap. |

## 8. Things we're explicitly happy to lose

| # | Item | Why |
|---|---|---|
| 8.1 | TextKit 2's `bounds.height = 1_000_000` workaround | The cause of the bug is gone. CT has no viewport cap. |
| 8.2 | The `applyLeftInsetExclusionsForWideRuby` exclusion-path apply pass | Replaced by direct line-origin shift. No exclusion-path → relayout cascade. |
| 8.3 | `.kern` saturation / pixel-snap fights for inter-segment spacing | CT engine adjusts glyph origins directly. No more "negative kern is not honored past threshold." |
| 8.4 | `attributedText` reassignment invalidating all caches on every toggle | CT cache is keyed by `(string, width)`; toggles that don't change either are pure redraws. |
| 8.5 | Multiple `ensureLayout(exhaustive:)` calls per render | CT does one typesetting pass per `setAttributedString` / `setWidthConstraint`. |

---

## How to verify the losses are actually losses (and not silent regressions of features we want)

1. **`grep` audit (5 min):** for each item in §7, run the grep. Ensure every call site has a CT-path equivalent or an explicit `// TODO: not migrated, accepted` comment. No silent breakage.
2. **VoiceOver pass (10 min):** items 3.1–3.4 — must do before any merge. Walk through the regression notes with VO on.
3. **Long-press surface (5 min):** items 1.1, 1.2, 4.1 — long-press in TK2 mode, note what menus appear. Long-press in CT mode, confirm what's missing matches the table above. Decide per-item: reimplement or accept.
4. **Find-in-text probe (1 min):** ⌘F or settings search affordance — confirm whether Read view exposes it today (item 2.4).
5. **Synthetic huge note (item 5.1):** generate a 10k-line note in code, time cold-open in both renderers. Decision: lazy-CT-layout or accept.

If after these five passes nothing in §1–§7 surprises you, the loss table is the loss table — merge with confidence.
