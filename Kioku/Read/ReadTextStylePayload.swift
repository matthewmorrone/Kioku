import Foundation
import UIKit

// Carries the styled read-mode text plus per-segment foreground colors used by furigana labels.
struct ReadTextStylePayload {
    let attributedText: NSAttributedString
    let segmentForegroundByLocation: [Int: UIColor]
}