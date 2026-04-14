# Pitch Accent Visualization Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the placeholder H/L text pitch accent view with a line-graph visualization where mora sit inside filled dots at high/low positions, connected by lines, with accent-type coloring and a pattern label.

**Architecture:** Single file rewrite of `PitchAccentView.swift`. Uses SwiftUI `Canvas` to draw the graph (circles, lines, text) with computed positions from the existing `PitchAccent` model. No data model or pipeline changes.

**Tech Stack:** SwiftUI, Canvas API

---

## File Map

| File | Action | Responsibility |
|------|--------|----------------|
| `Kioku/Read/Furigana/PitchAccentView.swift` | **Rewrite** | Line-graph pitch accent visualization |

The call site in `Kioku/Words/WordDetailView.swift:337-342` already passes `PitchAccent` to `PitchAccentView(accent:)` — the public interface stays identical, so no changes needed there.

---

### Task 1: Rewrite PitchAccentView with Canvas-based line graph

**Files:**
- Rewrite: `Kioku/Read/Furigana/PitchAccentView.swift`

- [ ] **Step 1: Replace the file contents with the new implementation**

Rewrite `Kioku/Read/Furigana/PitchAccentView.swift` with the following:

```swift
import SwiftUI

// Renders a pitch accent record as a line graph with mora inside filled dots.
// Each mora is a circle at a high or low vertical position connected by lines.
// The accent type determines the color. A pattern label sits to the trailing side.
// Displayed in the word detail screen's "Pitch Accent" section.
struct PitchAccentView: View {
    let accent: PitchAccent

    // Layout constants for the graph drawing.
    private let dotRadius: CGFloat = 16
    private let dotSpacing: CGFloat = 44
    private let highY: CGFloat = 18
    private let lowY: CGFloat = 50
    private let canvasHeight: CGFloat = 68

    // Splits kana into individual mora strings (handles digraphs like きゃ, っ, ー).
    private var morae: [String] {
        moraeSplit(accent.kana)
    }

    // Returns true/false for high/low at each mora position given the downstep.
    private var isHigh: [Bool] {
        let n = accent.accent
        let count = morae.count
        return (0..<count).map { i in
            if n == 0 {
                // Heiban: mora 0 is low, rest are high.
                return i != 0
            } else if n == 1 {
                // Atamadaka: mora 0 is high, rest are low.
                return i == 0
            } else {
                // Nakadaka/Odaka: mora 0 low, 1..<n high, n onward low.
                return i > 0 && i < n
            }
        }
    }

    // Determines the accent pattern type for color and label selection.
    private var patternType: PitchPatternType {
        if accent.accent == 0 { return .heiban }
        if accent.accent == 1 { return .atamadaka }
        if accent.accent == accent.morae { return .odaka }
        return .nakadaka
    }

    // Whether to show a trailing particle mora (all types except heiban).
    private var showsParticle: Bool {
        patternType != .heiban
    }

    // Total number of dot columns including the optional particle.
    private var columnCount: Int {
        morae.count + (showsParticle ? 1 : 0)
    }

    // Width needed for the dot columns plus heiban arrow space.
    private var graphWidth: CGFloat {
        let dotsWidth = CGFloat(columnCount) * dotSpacing
        // Heiban gets extra space for the dashed arrow.
        let arrowExtra: CGFloat = patternType == .heiban ? 36 : 0
        return dotsWidth + arrowExtra
    }

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            Canvas { context, size in
                drawGraph(context: &context, size: size)
            }
            .frame(width: graphWidth, height: canvasHeight)

            // Pattern label to the trailing side of the graph.
            Text(patternType.label)
                .font(.caption)
                .foregroundStyle(patternType.color)
        }
    }

    // Draws the complete pitch accent graph: lines, dots with mora text, particle, and arrow.
    private func drawGraph(context: inout GraphicsContext, size: Size) {
        let color = patternType.color
        let moraPositions = computeMoraPositions()

        // Draw solid connecting line through all real mora.
        drawContourLine(context: &context, positions: moraPositions, color: color)

        // Draw heiban arrow or particle with dashed connector.
        if patternType == .heiban {
            drawHeibanArrow(context: &context, lastPosition: moraPositions.last!, color: color)
        } else if showsParticle {
            let particleCenter = CGPoint(
                x: CGFloat(morae.count) * dotSpacing + dotSpacing / 2,
                y: lowY
            )
            drawParticleConnector(
                context: &context,
                from: moraPositions.last!,
                to: particleCenter,
                color: color
            )
            drawParticleDot(context: &context, center: particleCenter, color: color)
        }

        // Draw filled dots with mora text on top of lines.
        for (i, pos) in moraPositions.enumerated() {
            drawMoraDot(context: &context, center: pos, mora: morae[i], color: color)
        }
    }

    // Computes the center point for each real mora dot.
    private func computeMoraPositions() -> [CGPoint] {
        isHigh.enumerated().map { i, high in
            CGPoint(
                x: CGFloat(i) * dotSpacing + dotSpacing / 2,
                y: high ? highY : lowY
            )
        }
    }

    // Draws the solid polyline connecting real mora dots.
    private func drawContourLine(context: inout GraphicsContext, positions: [CGPoint], color: Color) {
        guard positions.count >= 2 else { return }
        var path = Path()
        path.move(to: positions[0])
        for i in 1..<positions.count {
            path.addLine(to: positions[i])
        }
        context.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
    }

    // Draws the dashed arrow for heiban (pitch stays high, no drop).
    private func drawHeibanArrow(context: inout GraphicsContext, lastPosition: CGPoint, color: Color) {
        let arrowStart = CGPoint(x: lastPosition.x + dotRadius, y: lastPosition.y)
        let arrowEnd = CGPoint(x: lastPosition.x + dotRadius + 30, y: lastPosition.y)

        // Dashed line.
        var linePath = Path()
        linePath.move(to: arrowStart)
        linePath.addLine(to: arrowEnd)
        context.stroke(linePath, with: .color(color), style: StrokeStyle(lineWidth: 1.5, lineCap: .round, dash: [5, 3]))

        // Arrowhead.
        var arrowPath = Path()
        arrowPath.move(to: arrowEnd)
        arrowPath.addLine(to: CGPoint(x: arrowEnd.x - 7, y: arrowEnd.y - 4))
        arrowPath.addLine(to: CGPoint(x: arrowEnd.x - 7, y: arrowEnd.y + 4))
        arrowPath.closeSubpath()
        context.fill(arrowPath, with: .color(color))
    }

    // Draws the dashed line from the last real mora edge to the particle circle edge.
    private func drawParticleConnector(context: inout GraphicsContext, from: CGPoint, to: CGPoint, color: Color) {
        let dx = to.x - from.x
        let dy = to.y - from.y
        let length = sqrt(dx * dx + dy * dy)
        guard length > 0 else { return }
        let ux = dx / length
        let uy = dy / length

        // Start at the edge of the source circle, end at the edge of the target circle.
        let start = CGPoint(x: from.x + ux * dotRadius, y: from.y + uy * dotRadius)
        let end = CGPoint(x: to.x - ux * dotRadius, y: to.y - uy * dotRadius)

        var path = Path()
        path.move(to: start)
        path.addLine(to: end)
        context.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: 2, lineCap: .round, dash: [5, 3]))
    }

    // Draws a filled circle with the mora character centered inside.
    private func drawMoraDot(context: inout GraphicsContext, center: CGPoint, mora: String, color: Color) {
        let rect = CGRect(
            x: center.x - dotRadius,
            y: center.y - dotRadius,
            width: dotRadius * 2,
            height: dotRadius * 2
        )
        context.fill(Circle().path(in: rect), with: .color(color))

        // Mora text centered in the circle, dark against colored fill.
        let text = context.resolve(Text(mora).font(.system(size: 13, weight: .semibold)).foregroundStyle(Color(uiColor: .systemBackground)))
        context.draw(text, at: center)
    }

    // Draws the particle dot: dashed stroke outline, no fill, colored text.
    private func drawParticleDot(context: inout GraphicsContext, center: CGPoint, color: Color) {
        let rect = CGRect(
            x: center.x - dotRadius,
            y: center.y - dotRadius,
            width: dotRadius * 2,
            height: dotRadius * 2
        )
        context.stroke(
            Circle().path(in: rect),
            with: .color(color),
            style: StrokeStyle(lineWidth: 2, dash: [4, 3])
        )

        // Particle kana — always は as a generic particle indicator.
        let text = context.resolve(Text("は").font(.system(size: 13)).foregroundStyle(color))
        context.draw(text, at: center)
    }

    // Splits a kana string into mora units. Digraphs (ゃゅょャュョ) attach to the
    // preceding mora, while っ, ッ, and ー are independent mora.
    private func moraeSplit(_ kana: String) -> [String] {
        let combining: Set<Character> = ["ゃ", "ゅ", "ょ", "ャ", "ュ", "ョ"]
        var result: [String] = []
        for ch in kana {
            if combining.contains(ch), result.isEmpty == false {
                result[result.count - 1].append(ch)
            } else {
                result.append(String(ch))
            }
        }
        return result
    }
}

// Categorizes the four pitch accent pattern types with associated colors and labels.
enum PitchPatternType {
    case heiban, atamadaka, nakadaka, odaka

    // Japanese pattern label shown to the side of the graph.
    var label: String {
        switch self {
        case .heiban: "平板"
        case .atamadaka: "頭高"
        case .nakadaka: "中高"
        case .odaka: "尾高"
        }
    }

    // Accent-type color. Uses SwiftUI built-in colors for light/dark mode adaptivity.
    var color: Color {
        switch self {
        case .heiban: .cyan
        case .atamadaka: .orange
        case .nakadaka: .yellow
        case .odaka: .green
        }
    }
}
```

- [ ] **Step 2: Build the project to verify compilation**

Run:
```bash
xcodebuild -scheme Kioku -destination 'platform=iOS Simulator,name=iPhone 16' build 2>&1 | tail -5
```
Expected: `** BUILD SUCCEEDED **`

The public interface is unchanged (`PitchAccentView(accent:)`) so `WordDetailView.swift` needs no modification.

- [ ] **Step 3: Visual verification on simulator**

1. Build and run on simulator
2. Open a saved word that has pitch accent data (e.g. a common word like 食べる or 学校)
3. Scroll to the "Pitch Accent" section in the word detail view
4. Verify: filled dots with kana inside, connected by lines, positioned at correct heights
5. Verify: pattern label (平板/頭高/中高/尾高) appears to the right of the graph
6. Verify: if the word has a non-heiban accent, the particle dot (は) appears with dashed outline and dashed connector stopping at circle edges
7. Verify: if the word is heiban, a dashed arrow extends from the last dot

- [ ] **Step 4: Test edge cases**

Check these scenarios by browsing different saved words:
- Single-mora word (e.g. 目 め) — should render one dot
- Long word with many mora — graph should extend horizontally without clipping
- Word with digraph mora (e.g. きゃ inside a dot) — should display correctly
- Multiple accent variants for the same word — each rendered as a separate graph row

- [ ] **Step 5: Commit**

```bash
git add Kioku/Read/Furigana/PitchAccentView.swift
git commit -m "feat: replace pitch accent H/L labels with line-graph visualization

Mora sit inside filled dots at high/low positions connected by lines.
Color varies by accent type. Particle mora shown for non-heiban patterns
with dashed outline and edge-to-edge connector. Pattern label to the side."
```
