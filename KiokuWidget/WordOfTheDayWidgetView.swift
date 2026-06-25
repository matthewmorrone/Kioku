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

    var body: some View {
        let segments = FuriganaAligner.segments(surface: surface, reading: reading)
        HStack(alignment: .lastTextBaseline, spacing: 0) {
            ForEach(Array(segments.enumerated()), id: \.offset) { _, segment in
                if let ruby = segment.ruby {
                    VStack(spacing: 1) {
                        Text(ruby).font(rubyFont).foregroundStyle(WidgetTheme.inkSecondary)
                        Text(segment.text).font(baseFont).foregroundStyle(WidgetTheme.ink)
                    }
                    .fixedSize()
                } else {
                    Text(segment.text).font(baseFont).foregroundStyle(WidgetTheme.ink)
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

    // The centered headword block: furigana + (optionally) part of speech + N glosses. Larger sizes
    // pass more glosses and turn on the POS line so each tile shows progressively more definition.
    private func definitionBlock(_ word: WordOfTheDayMirrorEntry, base: CGFloat, ruby: CGFloat,
                                 glossSize: CGFloat, glossLimit: Int, glossLines: Int, showPOS: Bool) -> some View {
        VStack(spacing: 6) {
            FuriganaText(surface: word.surface, reading: word.kana,
                         baseFont: WidgetTheme.mincho(base, bold: true), rubyFont: WidgetTheme.mincho(ruby))
                .minimumScaleFactor(0.5)
                .lineLimit(1)
            if showPOS, let pos = word.partOfSpeech, pos.isEmpty == false {
                Text(pos)
                    .font(WidgetTheme.serif(glossSize - 2))
                    .italic()
                    .foregroundStyle(WidgetTheme.inkSecondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(1)
            }
            Text(word.displayGlosses.prefix(glossLimit).joined(separator: "; "))
                .font(WidgetTheme.serif(glossSize))
                .foregroundStyle(WidgetTheme.inkSecondary)
                .multilineTextAlignment(.center)
                .lineLimit(glossLines)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Small (2×2 — word + primary meaning)

    @ViewBuilder
    private var smallContent: some View {
        if let word = entry.word {
            VStack(spacing: 0) {
                brandLabel
                Spacer(minLength: 6)
                definitionBlock(word, base: 26, ruby: 11, glossSize: 13, glossLimit: 1, glossLines: 2, showPOS: false)
                Spacer(minLength: 0)
            }
        } else {
            emptyState
        }
    }

    // MARK: - Medium (word + POS + several glosses)

    @ViewBuilder
    private var mediumContent: some View {
        if let word = entry.word {
            VStack(spacing: 0) {
                brandLabel
                Spacer(minLength: 0)
                definitionBlock(word, base: 34, ruby: 13, glossSize: 15, glossLimit: 3, glossLines: 3, showPOS: true)
                Spacer(minLength: 0)
            }
        } else {
            emptyState
        }
    }

    // MARK: - Large (word + POS + glosses + recent-days list)

    @ViewBuilder
    private var largeContent: some View {
        if let word = entry.word {
            VStack(spacing: 0) {
                brandLabel
                Spacer(minLength: 0)
                definitionBlock(word, base: 46, ruby: 17, glossSize: 17, glossLimit: 5, glossLines: 4, showPOS: true)
                Spacer(minLength: 0)
                if entry.recent.isEmpty == false {
                    recentList
                }
            }
        } else {
            emptyState
        }
    }

    // The prior-days list beneath the headline word on the large family.
    private var recentList: some View {
        VStack(spacing: 10) {
            Rectangle().fill(WidgetTheme.inkSecondary.opacity(0.25)).frame(height: 0.5)
            ForEach(entry.recent, id: \.fireDate) { item in
                HStack(alignment: .firstTextBaseline) {
                    Text(item.surface)
                        .font(WidgetTheme.mincho(17))
                        .foregroundStyle(WidgetTheme.ink)
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    Text(item.meaning)
                        .font(WidgetTheme.serif(14))
                        .foregroundStyle(WidgetTheme.inkSecondary)
                        .lineLimit(1)
                }
            }
        }
    }

    // MARK: - Lock Screen circular

    @ViewBuilder
    private var circularContent: some View {
        if let word = entry.word {
            Text(String(word.surface.prefix(2)))
                .font(.system(size: 22, weight: .semibold))
                .minimumScaleFactor(0.4)
                .lineLimit(1)
        } else {
            Image(systemName: "book.closed")
        }
    }

    // MARK: - Lock Screen rectangular

    @ViewBuilder
    private var rectangularContent: some View {
        if let word = entry.word {
            VStack(alignment: .leading, spacing: 1) {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(word.surface).font(.headline).lineLimit(1).minimumScaleFactor(0.7)
                    if let kana = displayKana(for: word) {
                        Text(kana).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
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

    // Kana worth showing on the accessory layouts: present, non-empty, not identical to the surface.
    private func displayKana(for word: WordOfTheDayMirrorEntry) -> String? {
        guard let kana = word.kana, kana.isEmpty == false, kana != word.surface else { return nil }
        return kana
    }

    private var deepLink: URL? {
        guard let word = entry.word else { return nil }
        return WordOfTheDayMirror.deepLinkURL(entryID: word.entryID, surface: word.surface)
    }
}
