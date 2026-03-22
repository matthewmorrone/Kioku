import SwiftUI

// Renders one parsed CSV import row showing surface, kana, and meaning in a three-column layout.
// Part of the preview list in CSVImportView.
struct CSVImportRow: View {
    let item: CSVImportItem

    var body: some View {
        HStack(spacing: 12) {
            Text(item.finalSurface ?? "—")
                .font(.headline)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)

            Text(item.finalKana ?? "")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .center)

            Text(item.finalMeaning ?? "—")
                .font(.subheadline)
                .foregroundStyle(item.isImportable ? .secondary : .tertiary)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .contentShape(Rectangle())
    }
}
