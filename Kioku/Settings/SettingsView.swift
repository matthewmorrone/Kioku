import SwiftUI
import UniformTypeIdentifiers
import UserNotifications

// Presents typography controls, Word of the Day configuration, and a live preview for reading settings.
struct SettingsView: View {
    let dictionaryStore: DictionaryStore?

    @EnvironmentObject private var notesStore: NotesStore
    @EnvironmentObject private var wordsStore: WordsStore
    @EnvironmentObject private var wordListsStore: WordListsStore
    @EnvironmentObject private var historyStore: HistoryStore
    @EnvironmentObject private var reviewStore: ReviewStore

    @AppStorage(TypographySettings.textSizeKey) private var textSize = TypographySettings.defaultTextSize
    @AppStorage(TypographySettings.lineSpacingKey) private var lineSpacing = TypographySettings.defaultLineSpacing
    @AppStorage(TypographySettings.kerningKey) private var kerning = TypographySettings.defaultKerning
    @AppStorage(TypographySettings.furiganaGapKey) private var furiganaGap = TypographySettings.defaultFuriganaGap
    @AppStorage(LyricsDisplayStyle.storageKey) private var lyricsDisplayStyleRaw = LyricsDisplayStyle.defaultValue.rawValue
    @AppStorage(ParticleSettings.storageKey) private var particlesRaw: String = ParticleSettings.defaultRawValue

    @AppStorage(LLMSettings.providerKey) private var llmProviderRaw: String = LLMSettings.defaultProvider
    @AppStorage(LLMSettings.openAIKeyStorageKey) private var openAIKey: String = ""
    @AppStorage(LLMSettings.claudeKeyStorageKey) private var claudeKey: String = ""
    @AppStorage(LLMSettings.useLLMKey) private var useLLM: Bool = false
    @AppStorage(LLMSettings.stubResponseKey) private var stubResponse: String = ""
    @AppStorage(LLMSettings.temperatureKey) private var temperature: Double = LLMSettings.defaultTemperature

    @AppStorage(TokenColorSettings.enabledKey) private var customTokenColorsEnabled: Bool = false
    @AppStorage(TokenColorSettings.colorAKey) private var tokenColorAHex: String = TokenColorSettings.defaultColorAHex
    @AppStorage(TokenColorSettings.colorBKey) private var tokenColorBHex: String = TokenColorSettings.defaultColorBHex

    @AppStorage(WordOfTheDayScheduler.enabledKey) private var wotdEnabled: Bool = false
    @AppStorage(WordOfTheDayScheduler.hourKey) private var wotdHour: Int = 9
    @AppStorage(WordOfTheDayScheduler.minuteKey) private var wotdMinute: Int = 0

    @AppStorage(SegmenterSettings.backendKey) private var segmenterBackend: String = SegmenterSettings.defaultBackend
    @AppStorage(SegmenterSettings.mecabDictionaryKey) private var mecabDictionary: String = SegmenterSettings.defaultMeCabDictionary

    @AppStorage(DebugSettings.pixelRulerKey) private var debugPixelRuler: Bool = false
    @AppStorage(DebugSettings.furiganaRectsKey) private var debugFuriganaRects: Bool = false
    @AppStorage(DebugSettings.headwordRectsKey) private var debugHeadwordRects: Bool = false
    @AppStorage(DebugSettings.headwordLineBandsKey) private var debugHeadwordLineBands: Bool = false
    @AppStorage(DebugSettings.furiganaLineBandsKey) private var debugFuriganaLineBands: Bool = false
    @AppStorage(DebugSettings.bisectorsKey) private var debugBisectors: Bool = false
    @AppStorage(DebugSettings.startupSegmentationDiffsKey) private var debugStartupSegmentationDiffs: Bool = false

    @State private var wotdPermissionStatus: UNAuthorizationStatus = .notDetermined
    @State private var wotdPendingCount: Int = 0

    @State private var exportDocument = AppBackupDocument(
        payload: AppBackupPayload(
            notes: [],
            words: [],
            wordLists: [],
            history: [],
            reviewStats: [],
            markedWrong: [],
            lifetimeCorrect: 0,
            lifetimeAgain: 0
        )
    )
    @State private var isShowingExporter = false
    @State private var isShowingImporter = false
    @State private var isShowingTransferAlert = false
    @State private var transferAlertTitle = ""
    @State private var transferAlertMessage = ""

    var body: some View {
        NavigationStack {
            Form {
                // Lets the user override the default system-color segment alternation palette.
                Section {
                    Toggle("Custom Token Colors", isOn: $customTokenColorsEnabled)
                    if customTokenColorsEnabled {
                        ColorPicker("Primary Color", selection: tokenColorABinding, supportsOpacity: false)
                        ColorPicker("Secondary Color", selection: tokenColorBBinding, supportsOpacity: false)
                        Button("Reset to Defaults") {
                            tokenColorAHex = TokenColorSettings.defaultColorAHex
                            tokenColorBHex = TokenColorSettings.defaultColorBHex
                        }
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    }
                }

                // Hosts typography sliders that update read and preview rendering.
                Section {
                        // Shows live typography preview.
                    SettingsPreviewRenderer(
                        textSize: $textSize,
                        lineSpacing: lineSpacing,
                        kerning: kerning,
                        furiganaGap: furiganaGap,
                        debugFuriganaRects: debugFuriganaRects,
                        debugHeadwordRects: debugHeadwordRects,
                        debugHeadwordLineBands: debugHeadwordLineBands,
                        debugFuriganaLineBands: debugFuriganaLineBands,
                        debugBisectors: debugBisectors
                    )
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .background(
                        RoundedRectangle(cornerRadius: 12)
                            .fill(Color(.secondarySystemBackground))
                    )


                    // Controls base font size.
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Text Size")
                            Spacer()
                            Text(String(format: "%.0f", textSize))
                                .foregroundStyle(.secondary)
                        }
                        Slider(value: $textSize, in: TypographySettings.textSizeRange, step: 1)
                    }

                    // Controls additional line spacing.
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Line Spacing")
                            Spacer()
                            Text(String(format: "%.0f", lineSpacing))
                                .foregroundStyle(.secondary)
                        }
                        Slider(value: $lineSpacing, in: TypographySettings.lineSpacingRange, step: 1)
                    }

                    // Controls vertical gap between furigana text and the kanji below it.
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Furigana Spacing")
                            Spacer()
                            Text(String(format: "%.1f", furiganaGap))
                                .foregroundStyle(.secondary)
                        }
                        Slider(value: $furiganaGap, in: TypographySettings.furiganaGapRange, step: 0.5)
                    }
                    // Controls character spacing.
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Kerning")
                            Spacer()
                            Text(String(format: "%.1f", kerning))
                                .foregroundStyle(.secondary)
                        }
                        Slider(value: $kerning, in: TypographySettings.kerningRange, step: 1)
                    }
                }

                Section {
                    Picker("Lyrics Style", selection: $lyricsDisplayStyleRaw) {
                        ForEach(LyricsDisplayStyle.allCases, id: \.rawValue) { style in
                            Text(style.displayName).tag(style.rawValue)
                        }
                    }
                }

                // Inline chip editor for the single-kana allowlist used during lattice path filtering.
                Section {
                    ParticleTagEditor(tags: particlesBinding)
                    HStack {
                        Spacer()
                        Button("Reset to Defaults") {
                            ParticleSettings.reset()
                            particlesRaw = ParticleSettings.defaultRawValue
                        }
                        .buttonStyle(.bordered)
                        .font(.footnote)
                    }
                }

                // Selects which segmentation engine to use and which MeCab dictionary to load.
                Section {
                    Picker("Engine", selection: $segmenterBackend) {
                        ForEach(SegmenterBackend.allCases, id: \.rawValue) { backend in
                            Text(backend.displayName).tag(backend.rawValue)
                        }
                    }

                    if segmenterBackend == SegmenterBackend.mecab.rawValue {
                        Picker("Dictionary", selection: $mecabDictionary) {
                            ForEach(MeCabDictionary.allCases, id: \.rawValue) { dict in
                                Text(dict.displayName).tag(dict.rawValue)
                            }
                        }
                    }

                } header: {
                    Text("Segmentation")
                } footer: {
                    if segmenterBackend == SegmenterBackend.mecab.rawValue {
                        Text("MeCab uses statistical morphological analysis. IPAdic is smaller; UniDic provides finer-grained segmentation.")
                    } else if segmenterBackend == SegmenterBackend.nlTokenizer.rawValue {
                        Text("Apple's built-in ICU tokenizer. No external dictionary needed.")
                    } else {
                        Text("Dictionary trie uses the built-in word list with deinflection rules.")
                    }
                }

                // Configures the LLM provider and API keys used by the segmentation correction feature.
                Section {
                    Toggle("Use LLM API", isOn: $useLLM)

                    if useLLM {
                        // Picker selects which provider's key is active. Shown as a menu on iOS.
                        Picker("Provider", selection: $llmProviderRaw) {
                            ForEach(LLMProvider.allCases, id: \.rawValue) { provider in
                                Text(provider.displayName).tag(provider.rawValue)
                            }
                        }

                        // Key entry rows are always visible so both keys can be saved independently.
                        // SecureField hides the entry but does not prevent UserDefaults storage.
                        SecureField("OpenAI API Key", text: $openAIKey)
                            .textContentType(.password)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                        SecureField("Claude API Key", text: $claudeKey)
                            .textContentType(.password)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                    }

                    // Lower temperature = more deterministic output; higher = more varied corrections.
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("Temperature")
                            Spacer()
                            Text(String(format: "%.2f", temperature))
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                        Slider(value: $temperature, in: 0.0...1.0, step: 0.05)
                    }
                } header: {
                    Text("AI Correction")
                } footer: {
                    if useLLM {
                        Text("When enabled, the correction button calls the LLM API and costs tokens.")
                            .foregroundStyle(.orange)
                    } else {
                        Text("Using stub response. Enable \"Use LLM API\" to call the real API.")
                    }
                }

                // Controls daily Word of the Day push notifications from the saved word list.
                Section {
                    Toggle("Word of the Day", isOn: $wotdEnabled)
                        .onChange(of: wotdEnabled) { _, _ in rescheduleWordOfTheDay() }

                    if wotdEnabled {
                        // Time picker binds to a synthetic Date so the system wheel renders correctly.
                        DatePicker("Time", selection: wotdTimeDateBinding, displayedComponents: .hourAndMinute)
                            .onChange(of: wotdHour)   { _, _ in rescheduleWordOfTheDay() }
                            .onChange(of: wotdMinute) { _, _ in rescheduleWordOfTheDay() }

                        // Authorization status row
                        HStack {
                            Text("Permission")
                            Spacer()
                            Text(wotdPermissionStatus.displayLabel)
                                .foregroundStyle(.secondary)
                        }

                        if wotdPermissionStatus == .notDetermined || wotdPermissionStatus == .denied {
                            Button("Request Permission") {
                                Task {
                                    _ = await WordOfTheDayScheduler.requestAuthorization()
                                    await refreshWotdStatus()
                                }
                            }
                            .disabled(wotdPermissionStatus == .denied)
                        }

                        Button("Send Test") {
                            let word = wordsStore.words.randomElement()
                            let store = dictionaryStore
                            Task {
                                await WordOfTheDayScheduler.sendTestNotification(word: word, dictionaryStore: store)
                            }
                        }
                        .disabled(wordsStore.words.isEmpty)
                    }
                } footer: {
                    if wotdEnabled && wotdPermissionStatus == .denied {
                        Text("Notifications are denied. Enable them in Settings → Notifications → Kioku.")
                            .foregroundStyle(.orange)
                    }
                }
                .task {
                    await refreshWotdStatus()
                }

                // Read-mode visual debugging aids — not for production use.
                Section {
                    Toggle("Pixel Ruler", isOn: $debugPixelRuler)
                    Toggle("Furigana Rects", isOn: $debugFuriganaRects)
                    Toggle("Headword Rects", isOn: $debugHeadwordRects)
                    Toggle("Headword Line Bands", isOn: $debugHeadwordLineBands)
                    Toggle("Furigana Line Bands", isOn: $debugFuriganaLineBands)
                    Toggle("Bisectors", isOn: $debugBisectors)
                }

                Section {
                    // Exports the full app state to one JSON backup file.
                    Button {
                        beginAppExport()
                    } label: {
                        Label("Export", systemImage: "square.and.arrow.up")
                    }
                    // Imports a full-app backup and replaces the current persisted state.
                    Button {
                        isShowingImporter = true
                    } label: {
                        Label("Import", systemImage: "square.and.arrow.down")
                    }
                }
            }
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle("Settings")
        }
        .toolbar(.visible, for: .tabBar)
        .fileExporter(
            isPresented: $isShowingExporter,
            document: exportDocument,
            contentType: .json,
            defaultFilename: "kioku-export"
        ) { result in
            handleExportResult(result)
        }
        .fileImporter(
            isPresented: $isShowingImporter,
            allowedContentTypes: [.json],
            allowsMultipleSelection: false
        ) { result in
            handleImportResult(result)
        }
        .alert(transferAlertTitle, isPresented: $isShowingTransferAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(transferAlertMessage)
        }
    }

    // Captures the latest full app state before presenting the system export flow.
    private func beginAppExport() {
        let reviewStats = reviewStore.stats
            .map { AppBackupReviewStats(canonicalEntryID: $0.key, stats: $0.value) }
            .sorted { $0.canonicalEntryID < $1.canonicalEntryID }
        exportDocument = AppBackupDocument(
            payload: AppBackupPayload(
                notes: notesStore.exportNotes(),
                words: wordsStore.words,
                wordLists: wordListsStore.lists,
                history: historyStore.entries,
                reviewStats: reviewStats,
                markedWrong: Array(reviewStore.markedWrong).sorted(),
                lifetimeCorrect: reviewStore.lifetimeCorrect,
                lifetimeAgain: reviewStore.lifetimeAgain
            )
        )
        isShowingExporter = true
    }

    // Reports whether the export operation finished or failed.
    private func handleExportResult(_ result: Result<URL, Error>) {
        switch result {
        case .success:
            showTransferAlert(title: "Export Complete", message: "Your app backup was saved successfully.")
        case .failure(let error):
            showTransferAlert(title: "Export Failed", message: error.localizedDescription)
        }
    }

    // Validates the importer selection and loads the selected app-backup file.
    private func handleImportResult(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let fileURL = urls.first else {
                showTransferAlert(title: "Import Failed", message: "No file was selected.")
                return
            }

            let hasSecurityScope = fileURL.startAccessingSecurityScopedResource()
            defer {
                if hasSecurityScope {
                    fileURL.stopAccessingSecurityScopedResource()
                }
            }

            do {
                let document = try AppBackupDocument(contentsOf: fileURL)
                importAppBackup(document)
            } catch {
                showTransferAlert(title: "Import Failed", message: error.localizedDescription)
            }
        case .failure(let error):
            showTransferAlert(title: "Import Failed", message: error.localizedDescription)
        }
    }

    // Applies one validated app-backup snapshot to every persisted store in a single replace-all pass.
    private func importAppBackup(_ document: AppBackupDocument) {
        let payload = document.payload
        let stats = Dictionary(uniqueKeysWithValues: payload.reviewStats.map { ($0.canonicalEntryID, $0.reviewWordStats()) })

        wordListsStore.replaceAll(with: payload.wordLists)
        wordsStore.replaceAll(with: payload.words)
        historyStore.replaceAll(with: payload.history)
        reviewStore.replaceAll(
            stats: stats,
            markedWrong: Set(payload.markedWrong),
            lifetimeCorrect: payload.lifetimeCorrect,
            lifetimeAgain: payload.lifetimeAgain
        )
        notesStore.replaceAll(with: payload.notes)

        let message = """
        Imported \(payload.notes.count) notes, \(payload.words.count) words, \(payload.wordLists.count) lists, \(payload.history.count) history entries, and \(payload.reviewStats.count) review records.
        """

        showTransferAlert(title: "Import Complete", message: message)
    }

    // Presents a single alert for import and export status messages.
    private func showTransferAlert(title: String, message: String) {
        transferAlertTitle = title
        transferAlertMessage = message
        isShowingTransferAlert = true
    }

    // Fetches the current notification authorization status and pending count.
    private func refreshWotdStatus() async {
        wotdPermissionStatus = await WordOfTheDayScheduler.authorizationStatus()
        wotdPendingCount = await WordOfTheDayScheduler.pendingWordOfTheDayRequestCount()
    }

    // Triggers a background schedule refresh with the current words and settings.
    private func rescheduleWordOfTheDay() {
        let words = wordsStore.words
        let store = dictionaryStore
        let enabled = wotdEnabled
        let hour = wotdHour
        let minute = wotdMinute
        Task.detached(priority: .utility) {
            await WordOfTheDayScheduler.refreshScheduleIfEnabled(
                words: words,
                dictionaryStore: store,
                hour: hour,
                minute: minute,
                enabled: enabled,
                forceRefresh: true
            )
            let count = await WordOfTheDayScheduler.pendingWordOfTheDayRequestCount()
            await MainActor.run { wotdPendingCount = count }
        }
    }

    // Converts the hex string AppStorage value to/from a SwiftUI Color for use with ColorPicker.
    private var tokenColorABinding: Binding<Color> {
        Binding(
            get: { Color(UIColor(hexString: tokenColorAHex) ?? UIColor(hexString: TokenColorSettings.defaultColorAHex)!) },
            set: { color in
                if let hex = UIColor(color).hexString { tokenColorAHex = hex }
            }
        )
    }

    // Converts the hex string AppStorage value to/from a SwiftUI Color for use with ColorPicker.
    private var tokenColorBBinding: Binding<Color> {
        Binding(
            get: { Color(UIColor(hexString: tokenColorBHex) ?? UIColor(hexString: TokenColorSettings.defaultColorBHex)!) },
            set: { color in
                if let hex = UIColor(color).hexString { tokenColorBHex = hex }
            }
        )
    }

    // Converts hour/minute integer AppStorage values to/from a Date for use with DatePicker.
    private var wotdTimeDateBinding: Binding<Date> {
        Binding(
            get: {
                var comps = Calendar.current.dateComponents([.year, .month, .day], from: Date())
                comps.hour = wotdHour
                comps.minute = wotdMinute
                return Calendar.current.date(from: comps) ?? Date()
            },
            set: { date in
                let comps = Calendar.current.dateComponents([.hour, .minute], from: date)
                wotdHour = comps.hour ?? 9
                wotdMinute = comps.minute ?? 0
            }
        )
    }

    // Bridges AppStorage raw string to the sorted particle list expected by ParticleTagEditor.
    private var particlesBinding: Binding<[String]> {
        Binding(
            get: { ParticleSettings.decodeList(from: particlesRaw) },
            set: { particlesRaw = ParticleSettings.encodeList($0) }
        )
    }
}

// Chip grid for adding and removing individual kana from the particle allowlist.
private struct ParticleTagEditor: View {
    @Binding var tags: [String]
    @State private var draft: String = ""
    @FocusState private var draftFocused: Bool

    private let columns: [GridItem] = [GridItem(.adaptive(minimum: 56), spacing: 8)]

    var body: some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: 8) {
            ForEach(tags, id: \.self) { tag in
                tagChip(for: tag)
            }
            addChip
        }
        .padding(.vertical, 4)
        .padding(.leading, 8)
    }

    // Inline text-field chip for entering a new particle without a separate row.
    // A hidden reference HStack drives the size; the real TextField sits on top.
    private var addChip: some View {
        HStack(spacing: 0) {
            // Hidden reference matches a real chip's content structure for identical sizing.
            Text(draft.isEmpty ? "か" : draft)
                .font(.subheadline)
                .hidden()
            Image(systemName: "xmark")
                .font(.caption2)
                .hidden()
        }
        .padding(8)
        .background(Capsule().fill(Color(.secondarySystemBackground)))
        .overlay(Capsule().stroke(draftFocused ? Color.accentColor.opacity(0.6) : Color.secondary.opacity(0.3), lineWidth: 1))
        .overlay {
            TextField("＋", text: $draft)
                .textInputAutocapitalization(.never)
                .disableAutocorrection(true)
                .focused($draftFocused)
                .onSubmit { commitDraft() }
                .font(.subheadline)
                .padding(.horizontal, 8)
        }
        .contentShape(Capsule())
        .onTapGesture { draftFocused = true }
    }

    // Renders a single tag pill with a destructive remove button.
    private func tagChip(for tag: String) -> some View {
        HStack(spacing: 0) {
            Text(tag)
                .font(.subheadline)
            Button(role: .destructive) {
                tags.removeAll { $0 == tag }
            } label: {
                Image(systemName: "xmark")
                    .font(.caption2)
                    .foregroundColor(Color.gray)
            }
            .buttonStyle(.plain)
            .padding(.leading, 4)
        }
        .padding(8)
        .background(Capsule().fill(Color(.secondarySystemBackground)))
        .overlay(Capsule().stroke(Color.secondary.opacity(0.3), lineWidth: 1))
    }

    // Trims and appends the draft tag to the list, then clears the draft field.
    private func commitDraft() {
        let normalized = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalized.isEmpty == false else { return }
        if tags.contains(normalized) == false {
            tags.append(normalized)
            tags.sort()
        }
        draft = ""
    }
}


#Preview {
    ContentView(selectedTab: .settings)
}
