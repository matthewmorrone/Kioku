import Foundation

// Jimaku REST API conformer for SubtitleProvider (Feature B). Jimaku is anime-focused and
// Japanese-native, with a one-credential auth model (an `Authorization: <key>` header — no login,
// no token exchange, no daily quota). Implemented as an `actor` for Sendable conformance and to
// match the provider seam; it holds no mutable state of its own.
//
// Jimaku's data model is two-step: search finds *entries* (shows), and each entry has *files*
// (episodes). We collapse that into the protocol's single search() by searching entries, then
// fetching each entry's files (optionally filtered to one episode) and flattening to one result per
// file. Download is trivial because each file carries a direct `url`.
actor JimakuProvider: SubtitleProvider {
    nonisolated let id = "jimaku"

    // Bound the work: searching a broad title can match many shows, and fetching files for all of
    // them would be a request storm. Cap matched entries and total surfaced files.
    private let maxEntries = 6
    private let maxFiles = 100
    // Subtitle files are tens of KB; a ceiling keeps a hostile or broken file URL from
    // exhausting memory before the parser ever sees it.
    private let maxSubtitleBytes = 5 << 20

    // Searches Jimaku for matching shows, then surfaces their subtitle files (one result per file),
    // optionally filtered to a single episode. `season` is ignored — Jimaku models seasons as
    // separate entries, not a parameter.
    func search(title: String, season: Int?, episode: Int?) async throws -> [SubtitleSearchResult] {
        guard let apiKey = JimakuSettings.apiKey() else { throw SubtitleProviderError.notConfigured }

        // Step 1: find matching entries (shows).
        var searchComponents = URLComponents(string: "\(JimakuSettings.apiBaseURL)/entries/search")!
        searchComponents.queryItems = [
            URLQueryItem(name: "query", value: title),
            URLQueryItem(name: "anime", value: "true"),
        ]
        let entries = try await get([JimakuProviderEntry].self, url: searchComponents.url!, apiKey: apiKey)

        // Step 2: for each entry (capped), fetch its files filtered to the requested episode, and
        // flatten into one result per file labelled with its source show.
        var results: [SubtitleSearchResult] = []
        for entry in entries.prefix(maxEntries) {
            var fileComponents = URLComponents(string: "\(JimakuSettings.apiBaseURL)/entries/\(entry.id)/files")!
            if let episode {
                fileComponents.queryItems = [URLQueryItem(name: "episode", value: String(episode))]
            }
            let files: [JimakuProviderFileEntry]
            do {
                files = try await get([JimakuProviderFileEntry].self, url: fileComponents.url!, apiKey: apiKey)
            } catch {
                // One show's file list failing shouldn't sink the others' results.
                AppLog.error(.audioAlignment, "Jimaku files for entry \(entry.id) failed: \(error)")
                continue
            }
            for file in files {
                results.append(SubtitleSearchResult(
                    id: "\(entry.id)/\(file.name)",
                    releaseName: file.name,
                    detail: "\(entry.displayName) · \(Self.formatSize(file.size))",
                    downloadToken: file.url
                ))
                if results.count >= maxFiles { return results }
            }
        }
        return results
    }

    // Downloads one file from its direct Jimaku URL to a local temp file whose extension matches the
    // remote name so ASSParser/SubtitleParser classify it correctly. Rejects archive/binary formats
    // we can't parse (Jimaku also hosts .zip/.sub) with a readable error instead of a parse failure.
    func download(_ result: SubtitleSearchResult) async throws -> SubtitleDownload {
        // The URL comes from Jimaku's file listing; insist on HTTPS so a listing entry can't
        // point the app at plaintext or non-web schemes.
        guard let fileURL = URL(string: result.downloadToken),
              fileURL.scheme?.lowercased() == "https",
              fileURL.host?.isEmpty == false else { throw SubtitleProviderError.noDownloadLink }

        let ext = (result.releaseName as NSString).pathExtension.lowercased()
        guard SubtitleFormat.supportedExtensions.contains(ext) else {
            throw SubtitleProviderError.unsupportedFormat(ext.isEmpty ? "?" : ext)
        }

        // The file URL is a direct/CDN link; fetch it WITHOUT the Authorization header so the API key
        // is never sent to a host other than jimaku.cc.
        let (data, response) = try await BoundedDownload.data(from: fileURL, maxBytes: maxSubtitleBytes)
        try Self.validate(response)

        // Write into a unique per-download directory but keep the file's REAL name, so downstream
        // (SubtitleImportView) derives a meaningful list name and note title from the release name
        // — e.g. "[SubsPlease] Sousou no Frieren - 01" — instead of an opaque UUID. The UUID lives in
        // the directory, guaranteeing uniqueness without colliding on identical release names.
        let safeName = result.releaseName.replacingOccurrences(of: "/", with: "-")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let localURL = directory.appendingPathComponent(safeName)
        try data.write(to: localURL)

        // Jimaku has no daily download cap, only request rate limiting — nothing to surface here.
        return SubtitleDownload(fileURL: localURL, remainingDownloads: nil)
    }

    // Performs an authenticated GET and decodes the JSON body into `type`. Jimaku auth is a bare
    // `Authorization: <key>` header (no "Bearer" prefix).
    private func get<T: Decodable>(_ type: T.Type, url: URL, apiKey: String) async throws -> T {
        var request = URLRequest(url: url)
        request.setValue(apiKey, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        try Self.validate(response)
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw SubtitleProviderError.badResponse
        }
    }

    // Throws badResponse for any non-2xx HTTP status so callers surface a readable error.
    private nonisolated static func validate(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw SubtitleProviderError.badResponse
        }
    }

    // Formats a byte count as a short human-readable size for the result detail line.
    private nonisolated static func formatSize(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }

}
