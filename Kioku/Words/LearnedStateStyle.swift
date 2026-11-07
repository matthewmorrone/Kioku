import SwiftUI
import UIKit

// The one place that says how a word's mark looks: the Saved / Not Learned / Learned order every
// menu follows, and the icon + color each mark uses. The colors are the same Saved Highlight
// colors the reading text is tinted with (ReadingColors), so an icon always matches the highlight
// of the words it describes — theme default, or the user's custom hex when Custom Text Colors is on.
enum LearnedStateStyle {
    // Standard menu order, shared by every long-press menu, bulk menu and filter.
    static let menuOrder: [LearnedState] = [.unmarked, .notLearned, .learned]

    // Resolves the current highlight colors from stored settings so every caller agrees with the text.
    // Read at call time: menus and icons are rebuilt whenever a mark changes.
    static var colors: ReadingColors {
        let d = UserDefaults.standard
        // Reads a stored hex, falling back to the shipped default when unset.
        func hex(_ key: String, _ fallback: String) -> String { d.string(forKey: key) ?? fallback }
        return ReadingColors.resolve(
            customEnabled: d.bool(forKey: TokenColorSettings.enabledKey),
            colorAHex: hex(TokenColorSettings.colorAKey, TokenColorSettings.defaultColorAHex),
            colorBHex: hex(TokenColorSettings.colorBKey, TokenColorSettings.defaultColorBHex),
            highlightHex: hex(TokenColorSettings.highlightColorKey, TokenColorSettings.defaultHighlightHex),
            savedHex: hex(TokenColorSettings.savedColorKey, TokenColorSettings.defaultSavedHex),
            savedLearnedHex: hex(TokenColorSettings.savedLearnedColorKey, TokenColorSettings.defaultSavedLearnedHex),
            savedNotLearnedHex: hex(TokenColorSettings.savedNotLearnedColorKey, TokenColorSettings.defaultSavedNotLearnedHex)
        )
    }

    // Highlight color for a mark (.unmarked = plain Saved).
    static func uiColor(for state: LearnedState) -> UIColor {
        switch state {
        case .unmarked:   return colors.saved
        case .learned:    return colors.savedLearned
        case .notLearned: return colors.savedNotLearned
        }
    }

    // SwiftUI form of uiColor(for:).
    static func color(for state: LearnedState) -> Color { Color(uiColor(for: state)) }

    // SF Symbol for a mark in menus and filters (the unfilled star for Save).
    static func menuIcon(for state: LearnedState) -> String {
        switch state {
        case .unmarked:   return "star"
        case .learned:    return "checkmark"
        case .notLearned: return "questionmark"
        }
    }

    // Menu title for a mark.
    static func title(for state: LearnedState) -> String {
        switch state {
        case .unmarked:   return "Saved"
        case .learned:    return "Learned"
        case .notLearned: return "Not Learned"
        }
    }

    // Menu icon pre-colored with the mark's highlight color; .alwaysOriginal keeps UIKit/SwiftUI
    // menus from re-tinting it to the label color.
    static func coloredMenuImage(for state: LearnedState) -> UIImage? {
        UIImage(systemName: menuIcon(for: state))?
            .withTintColor(uiColor(for: state), renderingMode: .alwaysOriginal)
    }

    // Label for SwiftUI menus carrying the colored icon.
    static func menuLabel(for state: LearnedState, title override: String? = nil) -> some View {
        Label {
            Text(override ?? title(for: state))
        } icon: {
            Image(uiImage: coloredMenuImage(for: state) ?? UIImage())
        }
    }

    // Tint for a star/mark button given the word's saved flag: its mark's color when saved, else gray.
    static func buttonColor(state: LearnedState, isSaved: Bool) -> Color {
        isSaved || state != .unmarked ? color(for: state) : .secondary
    }

    // UIKit form of buttonColor, for the lookup popover/sheet buttons.
    static func buttonUIColor(state: LearnedState, isSaved: Bool) -> UIColor {
        isSaved || state != .unmarked ? uiColor(for: state) : .secondaryLabel
    }
}
