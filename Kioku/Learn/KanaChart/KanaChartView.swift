import SwiftUI

// Renders the full interactive kana chart on a single non-scrolling screen.
// The representation (hiragana / katakana / rōmaji / IPA) is changed by swiping vertically;
// the current mode is shown in the navigation title.
// Major sections: gojūon grid, dakuten section, handakuten section.
struct KanaChartView: View {
    @State private var representation: KanaRepresentation = .hiragana

    // Six-column grid: consonant label + five vowel columns.
    private let columns = Array(
        repeating: GridItem(.flexible(), spacing: 4),
        count: 6
    )

    // The chart holds 16 data rows (gojūon 11 + dakuten 4 + handakuten 1); headers, spacing, and
    // padding consume a roughly fixed amount of the remaining height.
    private let dataRowCount = 16
    private let verticalOverhead: CGFloat = 120

    var body: some View {
        NavigationStack {
            GeometryReader { geo in
                let cellHeight = cellHeight(forAvailableHeight: geo.size.height)
                VStack(alignment: .leading, spacing: 8) {
                    chartSection(rows: KanaChartData.gojuuon, cellHeight: cellHeight)
                    chartSection(rows: KanaChartData.dakuten, cellHeight: cellHeight)
                    chartSection(rows: KanaChartData.handakuten, cellHeight: cellHeight)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .padding(.horizontal)
                .padding(.top, 2)
                // Swiping anywhere on the chart cycles modes, so the whole area must be hit-testable.
                .contentShape(Rectangle())
                .gesture(modeSwipe)
            }
            // Leave room at the bottom so the full-screen chart (it no longer scrolls, so it now
            // reaches the screen edge) sits clear above the Learn pager's page-dot overlay.
            .padding(.bottom, 52)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                LearnHomeTitle(title: representation.label, systemImage: "tablecells")
            }
        }
    }

    // Divides the leftover vertical space evenly across the data rows so the chart fills the screen
    // without scrolling; clamped to stay legible on small phones and reasonable on large screens.
    private func cellHeight(forAvailableHeight totalHeight: CGFloat) -> CGFloat {
        let usable = totalHeight - verticalOverhead
        return min(48, max(22, usable / CGFloat(dataRowCount)))
    }

    // Vertical swipe cycles the representation: up advances, down goes back.
    private var modeSwipe: some Gesture {
        DragGesture(minimumDistance: 20)
            .onEnded { value in
                // Require the same 2:1 dominance the Learn pager demands of a horizontal swipe, so
                // an ambiguous diagonal changes neither the page nor the representation instead of
                // whichever recogniser happens to accept it first.
                guard abs(value.translation.height) > abs(value.translation.width) * 2 else { return }
                withAnimation(.easeInOut(duration: 0.2)) {
                    representation = value.translation.height < 0
                        ? representation.next
                        : representation.previous
                }
            }
    }

    // Builds one section containing its vowel header row followed by one grid row per kana row.
    @ViewBuilder
    private func chartSection(rows: [KanaRow], cellHeight: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            // Vowel header row matching the six-column grid layout.
            LazyVGrid(columns: columns, spacing: 2) {
                Text("")
                    .frame(maxWidth: .infinity)
                ForEach(["a", "i", "u", "e", "o"], id: \.self) { vowel in
                    Text(vowel)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                }
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
                            representation: representation,
                            height: cellHeight
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
