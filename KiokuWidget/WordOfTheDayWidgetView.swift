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

// Splits a surface + reading so furigana sits only over the kanji: strips the kana shared at both
// ends (掬いあげる / すくいあげる → base 掬, reading すく, suffix いあげる). Falls back to the whole
// surface with no reading for kana-only or unsplittable words.
private struct FuriganaSplit {
    let prefix: String
    let base: String
    let readingCore: String
    let suffix: String

    init(surface: String, reading raw: String?) {
        guard let reading = raw, reading.isEmpty == false, reading != surface else {
            prefix = ""; base = surface; readingCore = ""; suffix = ""
            return
        }
        let s = Array(surface)
        let r = Array(reading)
        var p = 0
        while p < s.count, p < r.count, s[p] == r[p], s[p].isKanaCharacter { p += 1 }
        var q = 0
        while q < s.count - p, q < r.count - p, s[s.count - 1 - q] == r[r.count - 1 - q], s[s.count - 1 - q].isKanaCharacter { q += 1 }
        prefix = String(s[0..<p])
        base = String(s[p..<(s.count - q)])
        readingCore = String(r[p..<(r.count - q)])
        suffix = String(s[(s.count - q)..<s.count])
    }
}

private extension Character {
    // True for hiragana / katakana (incl. the prolonged sound mark), used to find the kanji core.
    var isKanaCharacter: Bool {
        unicodeScalars.allSatisfy { (0x3040...0x30FF).contains($0.value) }
    }
}

// Renders a word with furigana over its kanji core. The reading rides above the base in a VStack
// whose last text baseline aligns with the surrounding kana, so okurigana stays on the baseline.
private struct FuriganaText: View {
    let surface: String
    let reading: String?
    let baseFont: Font
    let rubyFont: Font

    var body: some View {
        let split = FuriganaSplit(surface: surface, reading: reading)
        HStack(alignment: .lastTextBaseline, spacing: 0) {
            if split.prefix.isEmpty == false {
                Text(split.prefix).font(baseFont).foregroundStyle(WidgetTheme.ink)
            }
            if split.base.isEmpty == false {
                if split.readingCore.isEmpty {
                    Text(split.base).font(baseFont).foregroundStyle(WidgetTheme.ink)
                } else {
                    VStack(spacing: 1) {
                        Text(split.readingCore).font(rubyFont).foregroundStyle(WidgetTheme.inkSecondary)
                        Text(split.base).font(baseFont).foregroundStyle(WidgetTheme.ink)
                    }
                    .fixedSize()
                }
            }
            if split.suffix.isEmpty == false {
                Text(split.suffix).font(baseFont).foregroundStyle(WidgetTheme.ink)
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

    // The centered headword + meaning block shared by every home size.
    private func wordBlock(_ word: WordOfTheDayMirrorEntry, base: CGFloat, ruby: CGFloat, meaning: CGFloat, meaningLines: Int) -> some View {
        VStack(spacing: 8) {
            FuriganaText(surface: word.surface, reading: word.kana,
                         baseFont: WidgetTheme.mincho(base, bold: true), rubyFont: WidgetTheme.mincho(ruby))
                .minimumScaleFactor(0.5)
                .lineLimit(1)
            Text(word.meaning)
                .font(WidgetTheme.serif(meaning))
                .foregroundStyle(WidgetTheme.inkSecondary)
                .multilineTextAlignment(.center)
                .lineLimit(meaningLines)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Small (2×2 — centered word + meaning)

    @ViewBuilder
    private var smallContent: some View {
        if let word = entry.word {
            VStack(spacing: 0) {
                brandLabel
                Spacer(minLength: 6)
                wordBlock(word, base: 26, ruby: 11, meaning: 13, meaningLines: 2)
                Spacer(minLength: 0)
            }
        } else {
            emptyState
        }
    }

    // MARK: - Medium (centered word + meaning)

    @ViewBuilder
    private var mediumContent: some View {
        if let word = entry.word {
            VStack(spacing: 0) {
                brandLabel
                Spacer(minLength: 0)
                wordBlock(word, base: 34, ruby: 13, meaning: 16, meaningLines: 2)
                Spacer(minLength: 0)
            }
        } else {
            emptyState
        }
    }

    // MARK: - Large (centered word, recent-days list pinned below)

    @ViewBuilder
    private var largeContent: some View {
        if let word = entry.word {
            VStack(spacing: 0) {
                brandLabel
                Spacer(minLength: 0)
                wordBlock(word, base: 46, ruby: 17, meaning: 18, meaningLines: 2)
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
