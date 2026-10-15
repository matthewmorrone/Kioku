import UIKit

extension UIColor {
    // This color mixed toward white by `amount` (0…1): purple → lavender. Gives the second of two
    // neighbouring segments drawn in one color a shade of its own (KiokuCoreTextAttributedStringBuilder).
    // Resolved per trait collection, so a dynamic color lightens its light and dark variants alike.
    func lightened(by amount: CGFloat) -> UIColor {
        UIColor { traits in
            var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
            guard self.resolvedColor(with: traits).getRed(&red, green: &green, blue: &blue, alpha: &alpha) else {
                return self.resolvedColor(with: traits)
            }
            return UIColor(
                red: red + (1 - red) * amount,
                green: green + (1 - green) * amount,
                blue: blue + (1 - blue) * amount,
                alpha: alpha
            )
        }
    }
}
