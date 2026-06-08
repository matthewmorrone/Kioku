import SwiftUI

// In-app subtitle search (Feature B). The user enters a show title (+ optional episode), the view
// queries the subtitle provider (Jimaku) for matching files, lists them, and on selection downloads
// the chosen file and hands it straight to SubtitleImportView — the same extract→vocab flow as a
// manually-picked file (Feature A). The provider is hidden behind the SubtitleProvider protocol, so
// swapping or adding backends later touches nothing in this view.
struct SubtitleSearchView: View {
    let dictionaryStore: DictionaryStore?
    let segmenter: (any TextSegmenting)?
    // Forwarded to SubtitleImportView so the downloaded file's note precomputes furigana too.
    var surfaceReadingData: SurfaceReadingDataMap = SurfaceReadingDataMap()
    var kanjiReadingFallback: KanjiReadingFallbackMap = KanjiReadingFallbackMap()

    @EnvironmentObject private var wordsStore: WordsStore
    @EnvironmentObject private var wordListsStore: WordListsStore
    @EnvironmentObject private var notesStore: NotesStore

    @Environment(\.dismiss) private var dismiss

    private let provider = JimakuProvider()

    @State private var title = ""
    @State private var episodeText = ""
    @State private var results: [SubtitleSearchResult] = []
    @State private var isSearching = false
    @State private var isDownloading = false
    @State private var hasSearched = false
    @State private var errorText: String? = nil
    @State private var handoff: DownloadedSubtitle? = nil
    @State private var isSettingsPresented = false

    // Wraps a downloaded file URL so it can drive a `.sheet(item:)` handoff into SubtitleImportView.
    private struct DownloadedSubtitle: Identifiable {
        let id = UUID()
        let url: URL
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                if JimakuSettings.isConfigured() == false {
                    notConfiguredPrompt
                } else {
                    searchControls
                    resultsList
                }
                if let errorText {
                    Text(errorText)
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding()
            .navigationTitle("Search Subtitles")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { isSettingsPresented = true } label: { Image(systemName: "gear") }
                }
            }
            .sheet(isPresented: $isSettingsPresented) {
                NavigationStack { JimakuSettingsView() }
            }
            .sheet(item: $handoff) { item in
                SubtitleImportView(
                    dictionaryStore: dictionaryStore,
                    segmenter: segmenter,
                    surfaceReadingData: surfaceReadingData,
                    kanjiReadingFallback: kanjiReadingFallback,
                    initialFileURL: item.url
                )
                .environmentObject(wordsStore)
                .environmentObject(wordListsStore)
                .environmentObject(notesStore)
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
            }
        }
    }

    private var notConfiguredPrompt: some View {
        VStack(spacing: 12) {
            Image(systemName: "key.slash")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text("Add your Jimaku API key to search for subtitles.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Button("Open Settings") { isSettingsPresented = true }
                .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var searchControls: some View {
        VStack(spacing: 8) {
            TextField("Show title", text: $title)
                .textFieldStyle(.roundedBorder)
                .submitLabel(.search)
                .onSubmit { runSearch() }
            TextField("Episode (optional)", text: $episodeText)
                .textFieldStyle(.roundedBorder)
                .keyboardType(.numberPad)
            Button {
                runSearch()
            } label: {
                if isSearching {
                    ProgressView().frame(maxWidth: .infinity)
                } else {
                    Text("Search").frame(maxWidth: .infinity)
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty || isSearching)
        }
    }

    @ViewBuilder
    private var resultsList: some View {
        if results.isEmpty {
            if hasSearched && isSearching == false {
                ContentUnavailableView("No subtitles found", systemImage: "magnifyingglass")
            } else {
                Spacer()
            }
        } else {
            List(results) { result in
                Button {
                    download(result)
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(result.releaseName).lineLimit(2)
                        Text(result.detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .disabled(isDownloading)
            }
            .listStyle(.plain)
        }
    }

    // Queries the provider for subtitle files matching the title (+ optional episode), populating the
    // results list. Runs on a Task so the network call never blocks the main actor.
    private func runSearch() {
        let query = title.trimmingCharacters(in: .whitespaces)
        guard query.isEmpty == false else { return }
        errorText = nil
        isSearching = true
        hasSearched = true
        let episode = Int(episodeText.trimmingCharacters(in: .whitespaces))

        Task {
            do {
                results = try await provider.search(title: query, season: nil, episode: episode)
            } catch {
                errorText = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                results = []
            }
            isSearching = false
        }
    }

    // Downloads the chosen result to a local temp file and hands it to SubtitleImportView for the
    // extract→vocab flow.
    private func download(_ result: SubtitleSearchResult) {
        errorText = nil
        isDownloading = true
        Task {
            do {
                let downloaded = try await provider.download(result)
                handoff = DownloadedSubtitle(url: downloaded.fileURL)
            } catch {
                errorText = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
            isDownloading = false
        }
    }
}
