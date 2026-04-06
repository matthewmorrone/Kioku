import SwiftUI
import UIKit

// Renders one subtitle cue row inside the lyrics popup.
// Active row: replaced by the persistent FuriganaTextRenderer overlay in LyricsView; this view
// renders a transparent placeholder that reserves the same height so the scroll list stays stable.
// Inactive rows: plain text scaled and faded by distance from the active cue.
struct LyricsCueRow: View {
    let cue: SubtitleCue
    let cueIndex: Int
    let isActive: Bool
    let distanceFromActive: Int
    let displayStyle: LyricsDisplayStyle
    @ObservedObject var translationCache: LyricsTranslationCache
    let onCueTapped: () -> Void

    @AppStorage(TypographySettings.textSizeKey) private var textSize = TypographySettings.defaultTextSize
    @AppStorage(TypographySettings.furiganaGapKey) private var furiganaGap = TypographySettings.defaultFuriganaGap

    private var activePlaceholderHeight: CGFloat {
        let bodyFont = UIFont.systemFont(ofSize: CGFloat(textSize))
        let furiganaFont = UIFont.systemFont(ofSize: max(CGFloat(textSize) * 0.5, 8))
        return furiganaFont.lineHeight + CGFloat(furiganaGap) + 4 + bodyFont.lineHeight + 8
    }

    private var rowOpacity: Double {
        switch distanceFromActive {
        case 0: return 1.0
        case 1: return 0.50
        case 2: return 0.30
        default: return 0.18
        }
    }

    private var inactiveFontSize: CGFloat {
        switch distanceFromActive {
            case 1:  return 17
            case 2:  return 15
            default: return 13
        }
    }

    private var verticalPadding: CGFloat {
        switch distanceFromActive {
            case 1:  return 10
            case 2:  return 6
            default: return 4
        }
    }

    var body: some View {
        if isActive { activePlaceholder } else { inactiveCueRow }
    }

    // Transparent placeholder — reserves exactly the same height as the overlay so the scroll
    // list doesn't shift. Height is calculated from font metrics and furigana gap.
    private var activePlaceholder: some View {
        Color.clear
            .frame(height: activePlaceholderHeight)
            .frame(maxWidth: .infinity)
    }

    // Inactive row: plain text, faded and scaled by distance.
    private var inactiveCueRow: some View {
        Text(cue.text)
            .font(.system(size: inactiveFontSize, weight: distanceFromActive == 1 ? .medium : .regular))
            .multilineTextAlignment(.center)
            .foregroundStyle(Color.primary.opacity(rowOpacity))
            .frame(maxWidth: .infinity)
            .padding(.vertical, verticalPadding)
            .contentShape(Rectangle())
            .onTapGesture { onCueTapped() }
    }
}
