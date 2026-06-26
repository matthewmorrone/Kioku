import WidgetKit
import SwiftUI
import UIKit

// The app's visual language, redeclared locally because Theme lives in the main app target and
// isn't shared with the extension: warm sumi/kinari canvas, vermilion 朱色 accent, Hiragino Mincho
// for Japanese, system serif for English. Colors adapt to light/dark like the app's palette.
private enum WidgetTheme {
    // Builds a light/dark-adaptive color from two RGB triples (0–255), matching Theme.swift.
    static func adaptive(light: (CGFloat, CGFloat, CGFloat), dark: (CGFloat, CGFloat, CGFloat)) -> Color {
        Color(uiColor: UIColor { traits in
            let c = traits.userInterfaceStyle == .dark ? dark : light
            return UIColor(red: c.0 / 255, green: c.1 / 255, blue: c.2 / 255, alpha: 1)
        })
    }

    static let surface = adaptive(light: (255, 253, 248), dark: (33, 30, 24))
    static let ink = adaptive(light: (33, 28, 22), dark: (236, 228, 214))
    static let inkSecondary = adaptive(light: (110, 101, 90), dark: (168, 155, 137))
    static let vermilion = adaptive(light: (199, 54, 59), dark: (219, 90, 78))

    // Bold Hiragino Mincho for headwords; light for readings/labels. Both ship with iOS.
    static func mincho(_ size: CGFloat, bold: Bool = false) -> Font {
        .custom(bold ? "HiraMinProN-W6" : "HiraMinProN-W3", size: size)
    }

    // System serif for English glosses, keeping tonal kinship with the Mincho display face.
    static func serif(_ size: CGFloat) -> Font {
        .system(size: size, design: .serif)
    }
}

// One piece of a furigana-aligned word: `text` is a run of the surface; `ruby` is its reading when
// the run is kanji that takes furigana, nil for kana that stands on its own.
private struct FuriganaSegment {
    let text: String
    let ruby: String?
}

private extension Character {
    // True for hiragana / katakana (incl. the prolonged sound mark).
    var isKanaCharacter: Bool {
        unicodeScalars.allSatisfy { (0x3040...0x30FF).contains($0.value) }
    }
}

// Aligns a surface against its full kana reading so furigana lands over each kanji run individually
// — handling kanji·kana·kanji words like 繰り返す (く over 繰, かえ over 返, り and す plain). The kana
// runs in the surface are anchors that must appear in order within the reading; the reading between
// anchors is the furigana for the intervening kanji run. Falls back to a single ruby over the whole
// surface if the anchors don't line up.
private enum FuriganaAligner {
    static func segments(surface: String, reading: String?) -> [FuriganaSegment] {
        guard let reading, reading.isEmpty == false, reading != surface else {
            return [FuriganaSegment(text: surface, ruby: nil)]
        }

        // Group the surface into consecutive kana / non-kana runs.
        var runs: [(text: String, isKana: Bool)] = []
        for ch in surface {
            let kana = ch.isKanaCharacter
            if var last = runs.last, last.isKana == kana {
                last.text.append(ch)
                runs[runs.count - 1] = last
            } else {
                runs.append((String(ch), kana))
            }
        }

        let r = Array(reading)
        var ri = 0
        var result: [FuriganaSegment] = []
        for (index, run) in runs.enumerated() {
            if run.isKana {
                let runChars = Array(run.text)
                guard ri + runChars.count <= r.count, Array(r[ri..<ri + runChars.count]) == runChars else {
                    return [FuriganaSegment(text: surface, ruby: reading)]
                }
                result.append(FuriganaSegment(text: run.text, ruby: nil))
                ri += runChars.count
            } else {
                let end: Int
                if index + 1 < runs.count {
                    let nextChars = Array(runs[index + 1].text)
                    guard let found = firstIndex(of: nextChars, in: r, from: ri) else {
                        return [FuriganaSegment(text: surface, ruby: reading)]
                    }
                    end = found
                } else {
                    end = r.count
                }
                guard end >= ri else { return [FuriganaSegment(text: surface, ruby: reading)] }
                let ruby = String(r[ri..<end])
                result.append(FuriganaSegment(text: run.text, ruby: ruby.isEmpty ? nil : ruby))
                ri = end
            }
        }
        guard ri == r.count else { return [FuriganaSegment(text: surface, ruby: reading)] }
        return result
    }

    // Earliest index ≥ `start` where `needle` occurs contiguously in `haystack`.
    private static func firstIndex(of needle: [Character], in haystack: [Character], from start: Int) -> Int? {
        guard needle.isEmpty == false else { return start }
        var i = start
        while i + needle.count <= haystack.count {
            if Array(haystack[i..<i + needle.count]) == needle { return i }
            i += 1
        }
        return nil
    }
}

// Renders a word with per-run furigana. Each kanji run rides its reading in a VStack whose last text
// baseline aligns with the neighbouring kana, so okurigana stays on the baseline.
private struct FuriganaText: View {
    let surface: String
    let reading: String?
    let baseFont: Font
    let rubyFont: Font
    // Colors default to the paper-surface ink used by the home families. The Lock Screen accessory
    // slots pass .primary/.secondary instead so the system's vibrant monochrome rendering keeps the
    // text legible against any wallpaper (the fixed ink colors would wash out on a dark background).
    var baseColor: AnyShapeStyle = AnyShapeStyle(WidgetTheme.ink)
    var rubyColor: AnyShapeStyle = AnyShapeStyle(WidgetTheme.inkSecondary)

    var body: some View {
        let segments = FuriganaAligner.segments(surface: surface, reading: reading)
        HStack(alignment: .lastTextBaseline, spacing: 0) {
            ForEach(Array(segments.enumerated()), id: \.offset) { _, segment in
                if let ruby = segment.ruby {
                    VStack(spacing: 1) {
                        Text(ruby).font(rubyFont).foregroundStyle(rubyColor)
                        Text(segment.text).font(baseFont).foregroundStyle(baseColor)
                    }
                    .fixedSize()
                } else {
                    Text(segment.text).font(baseFont).foregroundStyle(baseColor)
                }
            }
        }
    }
}

// Renders one Word of the Day entry, scaling content to the widget family.
struct WordOfTheDayWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: WordOfTheDayWidgetEntry

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: contentAlignment)
            .containerBackground(for: .widget) { background }
            .widgetURL(deepLink)
    }

    // Accessory rectangular reads as a left-aligned line; everything else centers.
    private var contentAlignment: Alignment {
        family == .accessoryRectangular ? .leading : .center
    }

    // MARK: - Family routing

    @ViewBuilder
    private var content: some View {
        switch family {
        case .accessoryInline:
            inlineContent
        case .accessoryCircular:
            circularContent
        case .accessoryRectangular:
            rectangularContent
        case .systemLarge:
            largeContent
        case .systemSmall:
            smallContent
        default:
            mediumContent
        }
    }

    // Home families sit on the paper/sumi surface; Lock Screen families use the system's vibrant
    // backdrop.
    @ViewBuilder
    private var background: some View {
        switch family {
        case .accessoryRectangular, .accessoryCircular, .accessoryInline:
            AccessoryWidgetBackground()
        default:
            WidgetTheme.surface
        }
    }

    // The centered vermilion label that tops the home layouts.
    private var brandLabel: some View {
        Text("今日の言葉")
            .font(WidgetTheme.mincho(11))
            .tracking(2)
            .foregroundStyle(WidgetTheme.vermilion)
    }

    // The centered furigana headword.
    private func headword(_ word: WordOfTheDayMirrorEntry, base: CGFloat, ruby: CGFloat) -> some View {
        FuriganaText(surface: word.surface, reading: word.kana,
                     baseFont: WidgetTheme.mincho(base, bold: true), rubyFont: WidgetTheme.mincho(ruby))
            .minimumScaleFactor(0.5)
            .lineLimit(1)
            .frame(maxWidth: .infinity)
    }

    // A JLPT badge + the primary part of speech, for the medium and large sizes.
    private func metaLine(_ word: WordOfTheDayMirrorEntry, size: CGFloat) -> some View {
        HStack(spacing: 8) {
            if let jlpt = word.jlpt {
                Text("N\(jlpt)")
                    .font(.system(size: size - 1, weight: .medium))
                    .foregroundStyle(WidgetTheme.vermilion)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(WidgetTheme.vermilion, lineWidth: 1))
            }
            if let pos = word.primaryPartOfSpeech, pos.isEmpty == false {
                Text(pos)
                    .font(WidgetTheme.serif(size))
                    .italic()
                    .foregroundStyle(WidgetTheme.inkSecondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
        }
    }

    // MARK: - Small (2×2 — word + primary meaning)

    @ViewBuilder
    private var smallContent: some View {
        if let word = entry.word {
            VStack(spacing: 0) {
                brandLabel
                Spacer(minLength: 6)
                VStack(spacing: 6) {
                    headword(word, base: 26, ruby: 11)
                    Text(word.displayGlosses.first ?? word.meaning)
                        .font(WidgetTheme.serif(13))
                        .foregroundStyle(WidgetTheme.inkSecondary)
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                }
                .frame(maxWidth: .infinity)
                Spacer(minLength: 0)
            }
        } else {
            emptyState
        }
    }

    // MARK: - Medium (word + JLPT/POS + glosses)

    @ViewBuilder
    private var mediumContent: some View {
        if let word = entry.word {
            VStack(spacing: 6) {
                brandLabel
                Spacer(minLength: 0)
                headword(word, base: 32, ruby: 13)
                metaLine(word, size: 12)
                Text(word.displayGlosses.prefix(3).joined(separator: "; "))
                    .font(WidgetTheme.serif(14))
                    .foregroundStyle(WidgetTheme.inkSecondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                Spacer(minLength: 0)
            }
        } else {
            emptyState
        }
    }

    // MARK: - Large (word + JLPT/POS + numbered senses + example + recent-days list)

    @ViewBuilder
    private var largeContent: some View {
        if let word = entry.word {
            VStack(alignment: .leading, spacing: 0) {
                brandLabel.frame(maxWidth: .infinity, alignment: .center)
                Spacer(minLength: 8)
                headword(word, base: 38, ruby: 15)
                metaLine(word, size: 13).frame(maxWidth: .infinity, alignment: .center).padding(.top, 5)
                numberedSenses(word, limit: 2).padding(.top, 12)
                if let example = word.example {
                    exampleBlock(example, highlight: word.surface).padding(.top, 10)
                }
                Spacer(minLength: 8)
                if entry.recent.isEmpty == false {
                    recentList
                }
            }
        } else {
            emptyState
        }
    }

    // Numbered senses (left-aligned) for the large size; falls back to the display glosses as a
    // single entry for legacy mirror data without structured senses.
    private func numberedSenses(_ word: WordOfTheDayMirrorEntry, limit: Int) -> some View {
        let senses = word.senses.isEmpty
            ? [WordOfTheDaySense(partOfSpeech: nil, glosses: word.displayGlosses)]
            : Array(word.senses.prefix(limit))
        return VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(senses.enumerated()), id: \.offset) { index, sense in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("\(index + 1)")
                        .font(WidgetTheme.serif(13))
                        .foregroundStyle(WidgetTheme.vermilion)
                    Text(sense.glosses.joined(separator: "; "))
                        .font(WidgetTheme.serif(15))
                        .foregroundStyle(WidgetTheme.ink)
                        .lineLimit(2)
                    Spacer(minLength: 0)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // An example sentence with the headword tinted vermilion, plus its translation.
    private func exampleBlock(_ example: WordOfTheDayExample, highlight surface: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            exampleText(example.japanese, highlight: surface)
                .font(WidgetTheme.mincho(15))
                .lineLimit(2)
            Text(example.english)
                .font(WidgetTheme.serif(13))
                .italic()
                .foregroundStyle(WidgetTheme.inkSecondary)
                .lineLimit(2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // Builds the example's Japanese as a Text with the headword substring tinted, when it appears.
    private func exampleText(_ japanese: String, highlight surface: String) -> Text {
        guard surface.isEmpty == false, let range = japanese.range(of: surface) else {
            return Text(japanese).foregroundColor(WidgetTheme.ink)
        }
        return Text(String(japanese[..<range.lowerBound])).foregroundColor(WidgetTheme.ink)
            + Text(String(japanese[range])).foregroundColor(WidgetTheme.vermilion)
            + Text(String(japanese[range.upperBound...])).foregroundColor(WidgetTheme.ink)
    }

    // The prior-days list beneath the detail on the large family (capped to keep the tile from
    // overflowing alongside the senses and example).
    private var recentList: some View {
        VStack(spacing: 9) {
            Rectangle().fill(WidgetTheme.inkSecondary.opacity(0.25)).frame(height: 0.5)
            // TODO: tapping a history row should open that row's word, not today's. The widget has a
            // single `.widgetURL(deepLink)` for today's entry, so taps anywhere (including these rows)
            // deep-link to today. Wrap each row in `Link(destination: WordOfTheDayMirror.deepLinkURL(
            // entryID: item.entryID, surface: item.surface))` so each row carries its own URL.
            ForEach(entry.recent.prefix(3), id: \.fireDate) { item in
                HStack(alignment: .firstTextBaseline) {
                    Text(item.surface)
                        .font(WidgetTheme.mincho(16))
                        .foregroundStyle(WidgetTheme.ink)
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    Text(item.meaning)
                        .font(WidgetTheme.serif(13))
                        .foregroundStyle(WidgetTheme.inkSecondary)
                        .lineLimit(1)
                }
            }
        }
    }

    // A furigana headword tinted for the Lock Screen: .primary/.secondary let the system's vibrant
    // monochrome rendering keep it legible on any wallpaper. Mincho keeps it on-brand by typography
    // (color is stripped by the system on the Lock Screen, so the font is the only brand signal left).
    private func accessoryHeadword(_ word: WordOfTheDayMirrorEntry, base: CGFloat, ruby: CGFloat) -> some View {
        FuriganaText(
            surface: word.surface,
            reading: word.kana,
            baseFont: WidgetTheme.mincho(base, bold: true),
            rubyFont: WidgetTheme.mincho(ruby),
            baseColor: AnyShapeStyle(.primary),
            rubyColor: AnyShapeStyle(.secondary)
        )
    }

    // MARK: - Lock Screen circular

    @ViewBuilder
    private var circularContent: some View {
        if let word = entry.word {
            // Furigana can't fill a circle legibly, so the circular slot is a clean word badge: the
            // surface centered and scaled to fill the round area, on the accessory backdrop.
            Text(word.surface)
                .font(WidgetTheme.mincho(22, bold: true))
                .foregroundStyle(.primary)
                .minimumScaleFactor(0.35)
                .lineLimit(1)
                .padding(4)
        } else {
            Image(systemName: "book.closed")
        }
    }

    // MARK: - Lock Screen rectangular

    @ViewBuilder
    private var rectangularContent: some View {
        if let word = entry.word {
            VStack(alignment: .leading, spacing: 2) {
                accessoryHeadword(word, base: 16, ruby: 8)
                    .minimumScaleFactor(0.7)
                    .lineLimit(1)
                Text(word.meaning).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
            }
        } else {
            VStack(alignment: .leading, spacing: 1) {
                Text("Word of the Day").font(.headline)
                Text("Enable in Settings").font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Lock Screen inline

    private var inlineContent: some View {
        Text(inlineText)
    }

    private var inlineText: String {
        guard let word = entry.word else { return "Word of the Day" }
        return "\(word.surface) · \(word.meaning)"
    }

    // MARK: - Empty state (home families)

    private var emptyState: some View {
        VStack(spacing: 8) {
            brandLabel
            Text("Enable Word of the Day in Settings to see your latest word here.")
                .font(WidgetTheme.serif(14))
                .foregroundStyle(WidgetTheme.inkSecondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Helpers

    private var deepLink: URL? {
        guard let word = entry.word else { return nil }
        return WordOfTheDayMirror.deepLinkURL(entryID: word.entryID, surface: word.surface)
    }
}
