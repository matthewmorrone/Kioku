import SwiftUI

// Renders the full interactive kana chart.
// Major sections: representation picker, gojūon grid, dakuten section, handakuten section.
struct KanaChartView: View {
    @State private var representation: KanaRepresentation = .hiragana

    // Six-column grid: consonant label + five vowel columns.
    private let columns = Array(
        repeating: GridItem(.flexible(), spacing: 4),
        count: 6
    )

    var body: some View {
        VStack(spacing: 0) {
            representationPicker
                .padding(.horizontal)
                .padding(.top, 4)
                .padding(.bottom, 2)

            VStack(alignment: .leading, spacing: 8) {
                chartSection(title: nil, rows: KanaData.gojuuon)
                chartSection(title: "Voiced", rows: KanaData.dakuten)
                chartSection(title: "Semi-voiced", rows: KanaData.handakuten)
            }
            .padding(.horizontal)
            .padding(.bottom, 8)
        }
        // Swipe up advances to the next representation; swipe down goes back.
        .gesture(
            DragGesture(minimumDistance: 30)
                .onEnded { value in
                    let vertical = value.translation.height
                    guard abs(vertical) > abs(value.translation.width) else { return }
                    withAnimation(.easeInOut(duration: 0.2)) {
                        if vertical < 0 {
                            representation = representation.next
                        } else {
                            representation = representation.previous
                        }
                    }
                }
        )
    }

    // Segmented control showing current mode and letting the user tap directly.
    @ViewBuilder
    private var representationPicker: some View {
        Picker("Representation", selection: $representation) {
            ForEach(KanaRepresentation.allCases, id: \.self) { mode in
                Text(mode.label).tag(mode)
            }
        }
        .pickerStyle(.segmented)
    }

    // Builds a labelled section containing all kana rows; the ∅ row acts as the column header.
    @ViewBuilder
    private func chartSection(title: String?, rows: [KanaRow]) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            if let title {
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.top, 2)
            }

            // One grid row per kana row.
            ForEach(rows, id: \.consonant) { row in
                LazyVGrid(columns: columns, spacing: 2) {
                    // Consonant label on the left.
                    Text(row.consonant)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)

                    // Five vowel cells.
                    ForEach(0..<5, id: \.self) { i in
                        KanaCellView(
                            entry: row.entries[i],
                            representation: representation
                        )
                    }
                }
            }
        }
    }
}

#Preview {
    KanaChartView()
}
