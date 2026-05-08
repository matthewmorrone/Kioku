# Custom Renderer Plan (Replacing TextKit 2 in Read View)

## Why

TextKit 2 is causing perceptible lag on furigana / ruby-spacing toggles. Each toggle currently triggers:

1. Rebuild of the entire `NSAttributedString` via `ReadTextStyleResolver.makePayload()`.
2. Reassignment of `textView.attributedText` (invalidates all TK2 caches).
3. `ensureTextLayout(exhaustive: true)` over the full document.
4. `applyLeftInsetExclusionsForWideRuby` — O(segments × fragments) walk.
5. A second exhaustive layout.
6. The single-pass spacing-correction pass — O(N) `firstRect` per segment, plus `invalidateLayout(docRange)` and a third exhaustive layout, plus a fourth if any pair needed reverting.

That's one attributed-string rebuild + up to four full-document layouts + an O(segments²-ish) line-fragment enumeration on every toggle. The Read view is read-only, so most of TextKit's complexity (selection, cursor, editing) is unused.

## What TextKit 2 currently provides — and the replacement cost

| Capability | Replacement effort |
|---|---|
| Japanese line breaking (kinsoku, hanging punctuation, no-break-before) | Free — `CTFramesetter` handles it; both TK2 and CT use the same CoreText typesetter underneath. |
| Glyph metrics (advance, bounds, baseline) | `CTRunGetAdvances`, `CTRunGetTypographicBounds` — direct calls. |
| `firstRect(for:)` for overlay positioning | `CTLineGetOffsetForStringIndex`, O(1) per query. Faster than current path. |
| Attribute-driven styling (colors, kerning, font) | Free — CoreText reads `NSAttributedString` attributes directly. |
| Exclusion paths for ruby inset | Deleted entirely — shift line origins by precomputed overhang at draw time. |
| Tap hit-testing | Per line: `CTLineGetStringIndexForPosition` → segment lookup. Cleaner than current TK→firstRect dance. |
| Selection drag, copy | Real work if used in Read view. Verify whether long-press copy is in any user flow before assuming we can drop it. |
| Accessibility (VoiceOver) | Real work — line-by-line `UIAccessibilityElement` exposure. |

## Architecture

- `KiokuReadTextView : UIView` (or `CALayer`-backed) that owns:
  - The attributed string.
  - A `CTFramesetter` cache keyed by `(text, width, font, kerning)`.
  - The laid-out `[CTLine]` for the current width.
- `draw(_:)` enumerates lines, calls `CTLineDraw`, then existing overlay code draws ruby / envelopes / bisectors at coordinates from CTLine offsets (no `firstRect` walks).
- Toggle of furigana / ruby spacing → no relayout. The framesetter is unchanged because base text didn't change. Just `setNeedsDisplay()`.

Notes (editor) view stays on `UITextView`. Only the Read view is replaced.

## Estimated effort

- **Core CoreText renderer** (framesetter cache, draw lines, expose per-segment rects via CTLine offsets): ~30–45 min.
- **Swap into ReadView**, route scroll/contentSize, port overlay coordinate sources from `firstRect` to CTLine offsets: ~45 min.
- **Tap hit-testing** for segment selection: ~20 min — `CTLineGetStringIndexForPosition` + binary search over line Ys.
- **Adapt existing furigana / envelope / bisector code** to consume rects from the new path: ~30 min — that math is already coordinate-system independent.

**Total: ~2 hours for a working drop-in covering the happy path.**

## Risks / unknowns that may extend timeline

1. **Long-press copy from Read view.** Verify whether this is a current user flow. If yes, reimplement via `UIMenuController` + selection model.
2. **Mixed-script line breaks** where `CTFramesetter` and TK2 disagree. Unlikely to be material — both wrap on the same CoreText primitives.
3. **VoiceOver / accessibility.** Has to be done deliberately; not free.
4. **Justification, RTL, vertical text** if planned. CoreText supports them; adds work.

## Cheaper alternative to try first

The perceived toggle lag is mostly because `isVisualEnhancementsEnabled` and `isRubySpacingEnabled` are hashed into `makeBaseTextRenderSignature` — they don't change the base attributed string content (only gate overlay drawing and post-layout passes). Pulling them out of that signature is a few-line change that would push toggles down the cheap "scroll-only" branch and skip the attributed-text rebuild + 4× exhaustive layout chain.

If that change brings toggle latency into acceptable range, the custom renderer becomes a "later, when we want full control" project rather than a now-priority.

## Sequence to follow

1. Pull the two flags out of `makeBaseTextRenderSignature`. Measure toggle latency.
2. If still slow, build the custom renderer per the architecture above.
3. Migrate Read view; keep Notes editor on UITextView.
4. Verify selection / copy / VoiceOver coverage matches current Read-view UX.
