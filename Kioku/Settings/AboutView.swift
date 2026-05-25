import SwiftUI

// The About / Credits screen. Pushed from a row in SettingsView. Renders the
// canonical attribution data from Attributions (kept separate so the data is
// unit-testable independent of view layout). Sections: app version, dataset
// attributions (licenses we owe by CC BY-SA, BSD, MIT, etc.), third-party
// libraries.
struct AboutView: View {
    var body: some View {
        Form {
            Section("Kioku") {
                LabeledContent("Version", value: Attributions.versionString())
                Text("A Japanese reading and vocabulary companion. Built with the open datasets and libraries listed below — without them this app wouldn't exist.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("Dictionary Data") {
                ForEach(Attributions.datasets, id: \.name) { dataset in
                    AttributionRow(
                        title: dataset.name,
                        subtitle: dataset.description,
                        license: dataset.license,
                        urlString: dataset.sourceURL
                    )
                }
            }

            Section("Libraries") {
                ForEach(Attributions.libraries, id: \.name) { library in
                    AttributionRow(
                        title: library.name,
                        subtitle: library.purpose,
                        license: nil,
                        urlString: library.sourceURL
                    )
                }
            }
        }
        .navigationTitle("About")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// One attribution row: bold title, subtitle, optional license line, tappable
// source link. Used uniformly for datasets and libraries so the rendered list
// stays consistent.
private struct AttributionRow: View {
    let title: String
    let subtitle: String
    let license: String?
    let urlString: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.body.weight(.semibold))
            Text(subtitle)
                .font(.footnote)
                .foregroundStyle(.secondary)
            if let license {
                Text(license)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            if let url = URL(string: urlString) {
                Link(destination: url) {
                    Text(urlString)
                        .font(.caption.monospaced())
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
        }
        .padding(.vertical, 2)
    }
}
