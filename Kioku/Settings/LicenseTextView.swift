import SwiftUI

// Renders the full text of one bundled license file (Kioku/Settings/Licenses/<name>.txt), pushed
// from a Settings → About attribution row. Layout: a single scrolling, selectable monospaced text
// block; a short message stands in if the file is missing from the bundle.
struct LicenseTextView: View {
    let resourceName: String

    var body: some View {
        ScrollView {
            Text(licenseText)
                .font(.caption.monospaced())
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
        }
    }

    // Loads the bundled text once per render; the files are a few KB.
    private var licenseText: String {
        guard let url = Bundle.main.url(forResource: resourceName, withExtension: "txt"),
              let text = try? String(contentsOf: url, encoding: .utf8) else {
            return "License text unavailable."
        }
        return text
    }
}
