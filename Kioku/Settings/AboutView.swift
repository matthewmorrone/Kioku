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
                LabeledContent("Dictionary", value: dictionaryVersionString)
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

    // Reports the dictionary release actually on disk, distinguishing "never downloaded" from
    // "downloaded but a newer release is pinned" from the normal up-to-date case, so a stuck or
    // pending download is visible here instead of only inferable from app behavior.
    private var dictionaryVersionString: String {
        guard let installedTag = DictionaryDownloadManager.installedReleaseTag else {
            return "Not downloaded"
        }
        if installedTag == DictionaryDownloadManager.releaseTag {
            return installedTag
        }
        return "\(installedTag) (update pending)"
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
