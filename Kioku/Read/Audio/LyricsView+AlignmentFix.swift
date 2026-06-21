import SwiftUI
import UIKit

// Pill-button helper for the alignment-fix row's commit actions (Start here / + shift rest /
// End here). Split into its own file purely to keep LyricsView.swift under the 1000-line cap;
// it carries no view state, so it lives as a plain extension method.
extension LyricsView {
    // Pill button for a start/end-commit action in the alignment-fix row.
    func fixActionButton(title: String, system: String, tint: UIColor, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 3) {
                Image(systemName: system)
                    .font(.system(size: 11, weight: .semibold))
                Text(title)
                    .font(.system(size: 10, weight: .semibold))
            }
            .foregroundStyle(Color(tint))
            .padding(.horizontal, 10)
            .frame(height: 24)
            .background(Color(tint).opacity(0.16))
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
    }
}
