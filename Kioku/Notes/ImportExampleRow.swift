import SwiftUI

// One worked example on the Importing Files help page: the picked file names in monospace,
// then what the import makes of them.
struct ImportExampleRow: View {
    let files: [String]
    let result: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(files, id: \.self) { file in
                Label(file, systemImage: "doc")
                    .font(.callout.monospaced())
            }
            Text(result)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 2)
    }
}
