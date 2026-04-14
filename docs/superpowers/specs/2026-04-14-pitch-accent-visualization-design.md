# Pitch Accent Visualization Design

## Summary

Replace the placeholder H/L text label pitch accent view with a line-graph visualization where each mora sits inside a filled dot positioned at high or low pitch, connected by lines. Displayed in the word detail screen's existing "Pitch Accent" section.

## Visual Specification

### Dot-and-Line Graph

Each mora is rendered as a **filled circle** at one of two vertical positions:
- **High** — top rail
- **Low** — bottom rail

Circles are connected by a **solid line** tracing the pitch contour. The mora character (kana) is rendered as text centered inside its circle, with dark fill against the colored background.

Position alone encodes pitch — all dots use the same filled style regardless of H/L.

### Pitch Pattern Rules

Standard Japanese pitch accent rules determine dot positions:

| Pattern | Accent Value | Dot Positions |
|---------|-------------|---------------|
| 平板 (heiban) | 0 | mora 0 = L, all others = H |
| 頭高 (atamadaka) | 1 | mora 0 = H, all others = L |
| 中高 (nakadaka) | 2..n-1 | mora 0 = L, mora 1..<accent = H, accent onward = L |
| 尾高 (odaka) | n (= mora count) | mora 0 = L, all others = H |

### Particle Mora

A particle mora (e.g. は, が) is **always shown** after the word's mora to disambiguate odaka from heiban:
- **Heiban**: no particle; a dashed arrow continues at the high rail to indicate pitch stays high
- **All others with a downstep**: a particle mora is shown at the low position

Particle rendering:
- Circle: **dashed stroke outline**, no fill
- Text: colored (matching the accent color), no bold
- Connecting line: **dashed**, runs from the **edge** of the last real mora dot to the **edge** of the particle circle — does not penetrate either circle

### Color by Accent Type

Each accent type uses a distinct color:

| Pattern | Color |
|---------|-------|
| 平板 (heiban) | Blue (`#4fc3f7`) |
| 頭高 (atamadaka) | Orange-red (`#ff7043`) |
| 中高 (nakadaka) | Yellow (`#f9a825`) |
| 尾高 (odaka) | Green (`#66bb6a`) |

These are reference colors for light-on-dark rendering. Actual SwiftUI colors should be chosen to work with both light and dark mode.

### Pattern Label

The pattern name (平板, 頭高, 中高, 尾高) is displayed **to the side** of the graph (trailing edge), not below it.

## Placement

- **Word detail screen** — in the existing "Pitch Accent" section (`WordDetailView.swift`)
- One graph rendered per `PitchAccent` record (a word can have multiple accent variants from the database)
- No changes to other screens (lookup sheet, reading view, word list)

## Data Model

No changes required. The existing pipeline provides everything needed:

- `PitchAccent` struct: `word`, `kana`, `kind`, `accent` (downstep position), `morae` (mora count)
- `WordDisplayData.pitchAccents: [PitchAccent]` — fetched via `DictionaryStore.fetchWordDisplayData`
- `moraeSplit(_:)` — existing function splits kana into mora units handling digraphs

## Implementation Approach

### File Changes

| File | Change |
|------|--------|
| `Kioku/Read/Furigana/PitchAccentView.swift` | **Rewrite** — replace H/L text layout with Canvas/Shape-based line graph |

### Drawing Strategy

Use SwiftUI `Canvas` for the graph drawing:

1. Split kana into mora array using existing `moraeSplit`
2. Compute x positions: evenly spaced columns, one per mora (plus optional particle)
3. Compute y positions: high rail or low rail per mora based on accent pattern rules
4. Draw the solid connecting polyline through real mora centers
5. Draw filled circles at each mora position, render kana text centered inside
6. For heiban: draw dashed arrow continuing from last dot at high rail
7. For non-heiban: draw particle circle (dashed outline) at low position, dashed line from last real mora edge to particle edge
8. Render pattern label to the trailing side

### Edge-to-Edge Line Calculation

The dashed line between the last real mora and the particle must stop at each circle's border. Given:
- Last mora center `(x1, y1)`, particle center `(x2, y2)`, radius `r`
- Unit vector from mora to particle: `(dx, dy) / length`
- Line start: `(x1 + dx*r, y1 + dy*r)`
- Line end: `(x2 - dx*r, y2 - dy*r)`

## Scope Boundaries

**In scope:**
- Replace `PitchAccentView` rendering
- Color-coded accent types
- Particle mora for odaka/nakadaka/atamadaka disambiguation
- Pattern label to the side

**Out of scope:**
- Data pipeline changes
- Pitch display in lookup sheet, reading view, or word list
- User preference for visualization style
- Accessibility: VoiceOver description of pitch pattern (future enhancement)
