import Foundation
import UIKit

// Carries the styled read-mode text plus per-token foreground colors used by furigana labels.
struct ReadTextStylePayload {
    let attributedText: NSAttributedString
    let tokenForegroundByLocation: [Int: UIColor]
}