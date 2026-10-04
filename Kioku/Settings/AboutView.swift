import SwiftUI

// The About / Credits screen. Pushed from a row in SettingsView. Renders the
// canonical attribution data from Attributions (kept separate so the data is
// unit-testable independent of view layout). Sections: app version, dataset
// attributions (licenses we owe by CC BY-SA, BSD, MIT, etc.), downloaded speech
// models, third-party libraries.
struct AboutView: View {
    // The bundled license file whose text is being shown, pushed from a row's license line.
    @State private var shownLicenseFile: String?

    var body: some View {
        Form {
            Section {
                LabeledContent("Version", value: Attributions.versionString())
                LabeledContent("Dictionary", value: dictionaryVersionString)
            } header: {
                Text("Kioku")
            } footer: {
                Text("A Japanese reading and vocabulary companion. Built with the open datasets and libraries listed below — without them this app wouldn't exist.")
            }

            Section("Dictionary Data") {
                ForEach(Attributions.datasets, id: \.name) { dataset in
                    AttributionRow(
                        title: dataset.name,
                        subtitle: dataset.description,
                        license: dataset.license,
                        urlString: dataset.sourceURL,
                        onShowLicense: dataset.licenseTextFile.map { file in { shownLicenseFile = file } }
                    )
                }
            }

            Section("Speech Models") {
                ForEach(Attributions.models, id: \.name) { model in
                    AttributionRow(
                        title: model.name,
                        subtitle: model.description,
                        license: model.license,
                        urlString: model.sourceURL
                    )
                }
            }

            Section("Libraries") {
                ForEach(Attributions.libraries, id: \.name) { library in
                    AttributionRow(
                        title: library.name,
                        subtitle: library.purpose,
                        license: library.license,
                        urlString: library.sourceURL
                    )
                }
            }
        }
        .navigationDestination(item: $shownLicenseFile) { file in
            LicenseTextView(resourceName: file)
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

// One attribution row: bold title, subtitle, optional license line, tappable source link. When the
// license's full text ships in the app, the license line itself is tappable and opens that text,
// separately from the link. Used uniformly for datasets and libraries so the list stays consistent.
private struct AttributionRow: View {
    let title: String
    let subtitle: String
    let license: String?
    let urlString: String
    var onShowLicense: (() -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.body.weight(.semibold))
            Text(subtitle)
                .font(.footnote)
                .foregroundStyle(.secondary)
            if let license {
                if let onShowLicense {
                    Button(action: onShowLicense) {
                        Text(license)
                            .font(.caption)
                            .multilineTextAlignment(.leading)
                    }
                    .buttonStyle(.borderless)
                } else {
                    Text(license)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
            if let url = URL(string: urlString) {
                Link(destination: url) {
                    Text(urlString)
                        .font(.caption.monospaced())
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .buttonStyle(.borderless)
            }
        }
        .padding(.vertical, 2)
    }
}
