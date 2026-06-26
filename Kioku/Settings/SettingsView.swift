import SwiftUI
import UniformTypeIdentifiers
import UserNotifications

// Single-screen settings, organized top-to-bottom: appearance (preview, typography, colors),
// reading behavior (audio, word of the day, clipboard), segmentation tuning, AI correction,
// developer tools, and data transfer. Footer prose is intentionally omitted — rows stand alone.
struct SettingsView: View {
    let dictionaryStore: DictionaryStore?
    // Hosts the on-demand local-network MCP listener whose UI lives in BridgeSettingsSection.
    @ObservedObject var bridgeServer: KiokuBridgeServer

    @EnvironmentObject private var notesStore: NotesStore
    @EnvironmentObject private var wordsStore: WordsStore
    @EnvironmentObject private var wordListsStore: WordListsStore
    @EnvironmentObject private var historyStore: HistoryStore
    @EnvironmentObject private var reviewStore: ReviewStore
    @EnvironmentObject private var songBreakdownStore: SongBreakdownStore

    // Opt-in Japanese visual theme (washi paper, vermilion accent, Mincho type, styled flashcards).
    @AppStorage(Theme.storageKey) private var japaneseTheme = false

    @AppStorage(TypographySettings.textSizeKey) private var textSize = TypographySettings.defaultTextSize
    @AppStorage(TypographySettings.lineSpacingKey) private var lineSpacing = TypographySettings.defaultLineSpacing
    @AppStorage(TypographySettings.kerningKey) private var kerning = TypographySettings.defaultKerning
    @AppStorage(TypographySettings.furiganaGapKey) private var furiganaGap = TypographySettings.defaultFuriganaGap
    @AppStorage(TypographySettings.customFuriganaSizeEnabledKey) private var customFuriganaSizeEnabled = false
    @AppStorage(TypographySettings.furiganaSizeKey) private var furiganaSize = TypographySettings.defaultFuriganaSize
    @AppStorage(LyricsHighlightGranularity.storageKey) private var lyricsHighlightGranularityRaw = LyricsHighlightGranularity.defaultValue.rawValue
    @AppStorage(AudioSettings.backgroundPlaybackKey) private var backgroundPlayback: Bool = AudioSettings.defaultBackgroundPlayback
    @AppStorage(ClipboardSettings.autoDetectKey) private var clipboardAutoDetect: Bool = ClipboardSettings.defaultAutoDetect
    @AppStorage(ParticleSettings.storageKey) private var particlesRaw: String = ParticleSettings.defaultRawValue
    @AppStorage(SegmentationDemotions.storageKey) private var demotionsRaw: String = SegmentationDemotions.defaultRawValue

    @AppStorage(LLMSettings.providerKey) private var llmProviderRaw: String = LLMSettings.defaultProvider
    // API keys live in the Keychain, not UserDefaults; @State holds the editing copy
    // and onChange writes through. keysRevision is a non-secret change counter other
    // views observe to re-check key presence without touching the secret itself.
    @State private var openAIKey: String = LLMSettings.apiKey(for: .openAI) ?? ""
    @State private var claudeKey: String = LLMSettings.apiKey(for: .claude) ?? ""
    @AppStorage(LLMSettings.keysRevisionKey) private var llmKeysRevision: Int = 0
    @AppStorage(LLMSettings.useLLMKey) private var useLLM: Bool = false
    @AppStorage(LLMSettings.temperatureKey) private var temperature: Double = LLMSettings.defaultTemperature

    @AppStorage(TokenColorSettings.enabledKey) private var customTokenColorsEnabled: Bool = false
    @AppStorage(TokenColorSettings.colorAKey) private var tokenColorAHex: String = TokenColorSettings.defaultColorAHex
    @AppStorage(TokenColorSettings.colorBKey) private var tokenColorBHex: String = TokenColorSettings.defaultColorBHex
    @AppStorage(TokenColorSettings.highlightColorKey) private var highlightHex: String = TokenColorSettings.defaultHighlightHex

    @AppStorage(WordOfTheDayScheduler.enabledKey) private var wotdEnabled: Bool = false
    @AppStorage(WordOfTheDayScheduler.hourKey) private var wotdHour: Int = 9
    @AppStorage(WordOfTheDayScheduler.minuteKey) private var wotdMinute: Int = 0

    // Auto-mark-as-learned: a word clears the bar in flashcard reviews → it's flagged learned.
    @AppStorage(LearnedSettings.enabledKey) private var autoLearnEnabled: Bool = false
    @AppStorage(LearnedSettings.ruleKey) private var autoLearnRuleRaw: String = AutoLearnRule.accuracyAndMinReviews.rawValue
    @AppStorage(LearnedSettings.thresholdKey) private var autoLearnThreshold: Double = LearnedSettings.defaultThreshold
    @AppStorage(LearnedSettings.minReviewsKey) private var autoLearnMinReviews: Int = LearnedSettings.defaultMinReviews
    @AppStorage(LearnedSettings.streakKey) private var autoLearnStreak: Int = LearnedSettings.defaultStreak

    @AppStorage(SegmenterSettings.backendKey) private var segmenterBackend: String = SegmenterSettings.defaultBackend
    @AppStorage(SegmenterSettings.mecabDictionaryKey) private var mecabDictionary: String = SegmenterSettings.defaultMeCabDictionary
    @AppStorage(SegmenterSettings.strategyKey) private var segmentationStrategy: SegmentationStrategy = SegmenterSettings.defaultStrategy

    @AppStorage(TranscriptionEngine.storageKey) private var transcriptionEngine: String = TranscriptionEngine.appleSpeech.rawValue

    @AppStorage(DebugSettings.pixelRulerKey) private var debugPixelRuler: Bool = false
    @AppStorage(DebugSettings.furiganaRectsKey) private var debugFuriganaRects: Bool = false
    @AppStorage(DebugSettings.headwordRectsKey) private var debugHeadwordRects: Bool = false
    @AppStorage(DebugSettings.headwordLineBandsKey) private var debugHeadwordLineBands: Bool = false
    @AppStorage(DebugSettings.furiganaLineBandsKey) private var debugFuriganaLineBands: Bool = false
    @AppStorage(DebugSettings.headwordLineNumbersKey) private var debugHeadwordLineNumbers: Bool = false
    @AppStorage(DebugSettings.rubyLineNumbersKey) private var debugRubyLineNumbers: Bool = false
    @AppStorage(DebugSettings.bisectorHeadwordKey) private var debugBisectorHeadword: Bool = false
    @AppStorage(DebugSettings.bisectorFuriganaKey) private var debugBisectorFurigana: Bool = false
    @AppStorage(DebugSettings.envelopeRectsKey) private var debugEnvelopeRects: Bool = false
    @AppStorage(DebugSettings.leftInsetGuideKey) private var debugLeftInsetGuide: Bool = false
    @AppStorage(DebugSettings.karaokeDebugHUDKey) private var debugKaraokeHUD: Bool = false
    // CoreText renderer is now the only path; toggle hidden, key kept for migration.
    // @AppStorage(DebugSettings.useCoreTextRendererKey) private var useCoreTextRenderer: Bool = true

    @State private var wotdPermissionStatus: UNAuthorizationStatus = .notDetermined
    @State private var wotdPendingCount: Int = 0
    // Transient confirmation for the "Send Test" button: shows which word was scheduled and
    // auto-clears. wotdTestTapCount drives the success haptic and guards the auto-clear so a
    // rapid re-tap doesn't get its status wiped by the previous tap's timer.
    @State private var wotdTestStatus: String?
    @State private var wotdTestTapCount = 0

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
    @State private var isShowingResetConfirmation = false
    @State private var isShowingImportConfirmation = false
    @State private var pendingImportDocument: AppBackupDocument?
    // Snapshot of Library/Caches total size, refreshed when Settings appears and after a clear.
    // Drives the byte readout on the Clear Caches button so the user sees what's about to free.
    @State private var cachesBytes: Int = 0
    @State private var isClearingCaches = false
    @State private var isShowingClearCachesConfirmation = false

    var body: some View {
        NavigationStack {
            Form {
                // MARK: Theme — opt-in Japanese visual style.
                Section {
                    Toggle(isOn: $japaneseTheme) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Japanese Theme")
                            Text("Washi paper, vermilion accent, Mincho type, and styled flashcards.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    // SwiftUI surfaces react to the @AppStorage flag on their own, but the UIKit
                    // nav/tab bar chrome is installed via appearance proxies only at launch. Re-run
                    // the global appearance pass when the toggle flips so newly-pushed screens match
                    // immediately (bars already on screen refresh on the next push or relaunch).
                    .onChange(of: japaneseTheme) { _, _ in Theme.refreshGlobalAppearance() }
                } header: {
                    Text("Theme")
                }

                // MARK: Appearance — live preview + typography sliders.
                Section {
                    SettingsPreviewRenderer(
                        textSize: $textSize,
                        lineSpacing: lineSpacing,
                        kerning: kerning,
                        furiganaGap: furiganaGap,
                        debugFuriganaRects: debugFuriganaRects,
                        debugHeadwordRects: debugHeadwordRects,
                        debugHeadwordLineBands: debugHeadwordLineBands,
                        debugFuriganaLineBands: debugFuriganaLineBands,
                        debugBisectorHeadword: debugBisectorHeadword,
                        debugBisectorFurigana: debugBisectorFurigana,
                        debugEnvelopeRects: debugEnvelopeRects,
                        debugLeftInsetGuide: debugLeftInsetGuide,
                        debugPixelRuler: debugPixelRuler,
                        debugHeadwordLineNumbers: debugHeadwordLineNumbers,
                        debugRubyLineNumbers: debugRubyLineNumbers
                    )
                    .frame(maxWidth: .infinity, alignment: .leading)
                    // Vertical padding for breathing room; negative horizontal padding cancels
                    // the renderer's hardcoded textContainerInset.left = 4 so the first glyph
                    // sits flush with the chrome's left edge inside the Form's already-inset row.
                    .padding(.vertical, 8)
                    .padding(.horizontal, -4)
                    .background(
                        RoundedRectangle(cornerRadius: 12)
                            .fill(Color(.secondarySystemBackground))
                    )

                    // Label switches to "Headword Size" when furigana size is decoupled.
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text(customFuriganaSizeEnabled ? "Headword Size" : "Text Size")
                            Spacer()
                            Text(String(format: "%.0f", textSize))
                                .foregroundStyle(.secondary)
                        }
                        Slider(value: $textSize, in: TypographySettings.textSizeRange, step: 1)
                    }

                    if customFuriganaSizeEnabled {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text("Furigana Size")
                                Spacer()
                                Text(String(format: "%.0f", furiganaSize))
                                    .foregroundStyle(.secondary)
                            }
                            Slider(value: $furiganaSize, in: TypographySettings.furiganaSizeRange, step: 1)
                        }
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Line Spacing")
                            Spacer()
                            Text(String(format: "%.0f", lineSpacing))
                                .foregroundStyle(.secondary)
                        }
                        Slider(value: $lineSpacing, in: TypographySettings.lineSpacingRange, step: 1)
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Furigana Spacing")
                            Spacer()
                            Text(String(format: "%.1f", furiganaGap))
                                .foregroundStyle(.secondary)
                        }
                        Slider(value: $furiganaGap, in: TypographySettings.furiganaGapRange, step: 0.5)
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Kerning")
                            Spacer()
                            Text(String(format: "%.1f", kerning))
                                .foregroundStyle(.secondary)
                        }
                        Slider(value: $kerning, in: TypographySettings.kerningRange, step: 1)
                    }

                    Toggle("Custom Furigana Size", isOn: $customFuriganaSizeEnabled)
                } header: {
                    Text("Typography")
                }

                // MARK: Colors
                Section {
                    Toggle("Custom Token Colors", isOn: $customTokenColorsEnabled)
                    if customTokenColorsEnabled {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 14) {
                                ForEach(TokenColorSettings.presets) { preset in
                                    tokenPresetSwatch(preset)
                                }
                            }
                            .padding(.vertical, 4)
                        }
                        ColorPicker("Primary Color", selection: tokenColorABinding, supportsOpacity: false)
                        ColorPicker("Secondary Color", selection: tokenColorBBinding, supportsOpacity: false)
                    }
                    ColorPicker("Highlight Color", selection: tokenHighlightBinding, supportsOpacity: false)
                } header: {
                    Text("Colors")
                }

                // MARK: Audio
                Section {
                    Picker("Highlight Granularity", selection: $lyricsHighlightGranularityRaw) {
                        ForEach(LyricsHighlightGranularity.allCases, id: \.rawValue) { granularity in
                            Text(granularity.displayName).tag(granularity.rawValue)
                        }
                    }
                    .pickerStyle(.segmented)
                    Toggle("Background Audio", isOn: $backgroundPlayback)
                } header: {
                    Text("Audio")
                }

                // MARK: Word of the Day
                Section {
                    Toggle("Word of the Day", isOn: $wotdEnabled)
                        .onChange(of: wotdEnabled) { _, _ in rescheduleWordOfTheDay() }

                    if wotdEnabled {
                        // Time picker binds to a synthetic Date so the system wheel renders correctly.
                        DatePicker("Time", selection: wotdTimeDateBinding, displayedComponents: .hourAndMinute)
                            .onChange(of: wotdHour)   { _, _ in rescheduleWordOfTheDay() }
                            .onChange(of: wotdMinute) { _, _ in rescheduleWordOfTheDay() }

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
                            wotdTestTapCount += 1
                            let tap = wotdTestTapCount
                            let word = wordsStore.words.randomElement()
                            let store = dictionaryStore
                            wotdTestStatus = "Scheduling…"
                            Task {
                                await WordOfTheDayScheduler.sendTestNotification(word: word, dictionaryStore: store)
                                wotdTestStatus = word.map { "Sent “\($0.surface)” — quit the app now; it arrives in ~10s, then tap it" } ?? "No saved word available"
                                try? await Task.sleep(nanoseconds: 4_000_000_000)
                                if wotdTestTapCount == tap { wotdTestStatus = nil }
                            }
                        }
                        .disabled(wordsStore.words.isEmpty)
                        .sensoryFeedback(.success, trigger: wotdTestTapCount)

                        if let wotdTestStatus {
                            Text(wotdTestStatus)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .transition(.opacity)
                        }
                    }
                } header: {
                    Text("Notifications")
                }
                .task {
                    await refreshWotdStatus()
                }

                // MARK: Clipboard
                Section {
                    Toggle("Auto-detect Japanese in Clipboard", isOn: $clipboardAutoDetect)
                } header: {
                    Text("Clipboard")
                }

                // MARK: Transcription — engine for importing audio → note.
                Section {
                    Picker("Engine", selection: $transcriptionEngine) {
                        ForEach(TranscriptionEngine.allCases, id: \.rawValue) { engine in
                            Text(engine.displayName).tag(engine.rawValue)
                        }
                    }
                } header: {
                    Text("Transcription")
                } footer: {
                    if transcriptionEngine == TranscriptionEngine.whisper.rawValue {
                        Text("On-device Whisper (Small) downloads ~466 MB on first use and is slower than Apple Speech, but holds up better on noisy or sung audio. Forced alignment is unaffected and stays on the Base model.")
                    } else {
                        Text("Apple Speech is fast and near real-time, and strong on clean spoken Japanese.")
                    }
                }

                // MARK: Learning — auto-mark words as learned past a chosen bar.
                Section {
                    Toggle("Auto-mark as learned", isOn: $autoLearnEnabled)
                    if autoLearnEnabled {
                        Picker("Rule", selection: $autoLearnRuleRaw) {
                            ForEach(AutoLearnRule.allCases) { rule in
                                Text(rule.title).tag(rule.rawValue)
                            }
                        }
                        let rule = AutoLearnRule(rawValue: autoLearnRuleRaw) ?? .accuracyAndMinReviews
                        if rule == .accuracyAndMinReviews || rule == .accuracyOnly {
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Text("Accuracy threshold")
                                    Spacer()
                                    Text("\(Int((autoLearnThreshold * 100).rounded()))%")
                                        .foregroundStyle(.secondary)
                                        .monospacedDigit()
                                }
                                Slider(value: $autoLearnThreshold, in: 0.5...1.0, step: 0.05)
                            }
                        }
                        if rule == .accuracyAndMinReviews {
                            Stepper("Minimum reviews: \(autoLearnMinReviews)", value: $autoLearnMinReviews, in: 1...20)
                        }
                        if rule == .consecutiveCorrect {
                            Stepper("Correct in a row: \(autoLearnStreak)", value: $autoLearnStreak, in: 1...20)
                        }
                    }
                } header: {
                    Text("Learning")
                } footer: {
                    Text("When on, a word is automatically marked learned (checkbox) once it clears this bar in flashcard reviews. You can always mark words by hand by long-pressing any star.")
                }

                // MARK: Segmentation — engine, then the two tuning chip-editors.
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

                    if segmenterBackend == SegmenterBackend.trie.rawValue {
                        Toggle("Global longest-match (experimental)", isOn: Binding(
                            get: { segmentationStrategy == .globalLongestMatch },
                            set: { segmentationStrategy = $0 ? .globalLongestMatch : .localLongestMatch }
                        ))
                    }
                } header: {
                    Text("Segmentation")
                }

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
                } header: {
                    Text("Allowed Particles")
                }

                Section {
                    ParticleTagEditor(tags: demotionsBinding)
                    HStack {
                        Spacer()
                        Button("Reset to Defaults") {
                            SegmentationDemotions.reset()
                            demotionsRaw = SegmentationDemotions.defaultRawValue
                        }
                        .buttonStyle(.bordered)
                        .font(.footnote)
                    }
                } header: {
                    Text("Segmentation Demotions")
                }

                // MARK: AI Correction
                Section {
                    Toggle("Use LLM API", isOn: $useLLM)

                    if useLLM {
                        Picker("Provider", selection: $llmProviderRaw) {
                            ForEach(LLMProvider.allCases, id: \.rawValue) { provider in
                                Text(provider.displayName).tag(provider.rawValue)
                            }
                        }

                        // Key entry rows are always visible so both keys can be saved independently.
                        // Edits write through to the Keychain; nothing secret touches UserDefaults.
                        SecureField("OpenAI API Key", text: $openAIKey)
                            .textContentType(.password)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                            .onChange(of: openAIKey) {
                                LLMSettings.setAPIKey(openAIKey, for: .openAI)
                                llmKeysRevision += 1
                            }
                        SecureField("Claude API Key", text: $claudeKey)
                            .textContentType(.password)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                            .onChange(of: claudeKey) {
                                LLMSettings.setAPIKey(claudeKey, for: .claude)
                                llmKeysRevision += 1
                            }
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
                }

                #if DEBUG
                // MARK: Debug overlays — hidden in release builds.
                Section {
                    Toggle("Pixel Ruler", isOn: $debugPixelRuler)
                    Toggle("Furigana Rects", isOn: $debugFuriganaRects)
                    Toggle("Headword Rects", isOn: $debugHeadwordRects)
                    Toggle("Envelope Rects", isOn: $debugEnvelopeRects)
                    Toggle("Headword Line Bands", isOn: $debugHeadwordLineBands)
                    Toggle("Furigana Line Bands", isOn: $debugFuriganaLineBands)
                    Toggle("Headword Line Numbers (L#)", isOn: $debugHeadwordLineNumbers)
                    Toggle("Ruby Line Numbers (R#)", isOn: $debugRubyLineNumbers)
                    Toggle("Headword Bisectors", isOn: $debugBisectorHeadword)
                    Toggle("Furigana Bisectors", isOn: $debugBisectorFurigana)
                    Toggle("Left Inset Guide", isOn: $debugLeftInsetGuide)
                    Toggle("Karaoke HUD", isOn: $debugKaraokeHUD)
                    // Toggle hidden — CoreText is now the only renderer.
                    // Toggle("Use CoreText Renderer (experimental)", isOn: $useCoreTextRenderer)
                } header: {
                    Text("Debug Overlays")
                }
                #endif

                BridgeSettingsSection(bridgeServer: bridgeServer)

                Section {
                    NavigationLink {
                        CrashLogsView()
                    } label: {
                        Label("Crash Logs", systemImage: "exclamationmark.triangle")
                    }
                    NavigationLink {
                        AboutView()
                    } label: {
                        Label("About", systemImage: "info.circle")
                    }
                }

                // MARK: Data transfer
                Section {
                    Button {
                        beginAppExport()
                    } label: {
                        Label("Export", systemImage: "square.and.arrow.up")
                    }
                    Button {
                        isShowingImporter = true
                    } label: {
                        Label("Import", systemImage: "square.and.arrow.down")
                    }
                    Button {
                        isShowingClearCachesConfirmation = true
                    } label: {
                        Label(
                            cachesBytes > 0 ? "Clear Caches (\(formattedBytes(cachesBytes)))" : "Clear Caches",
                            systemImage: "internaldrive"
                        )
                    }
                    .disabled(isClearingCaches || cachesBytes == 0)
                    Button(role: .destructive) {
                        isShowingResetConfirmation = true
                    } label: {
                        Label("Reset", systemImage: "trash")
                    }
                } header: {
                    Text("Data")
                }
            }
            .scrollDismissesKeyboard(.interactively)
            .washiBackground()
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
        .alert("Reset All Data?", isPresented: $isShowingResetConfirmation) {
            Button("Reset", role: .destructive) { resetAllData() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will permanently erase all notes, saved words, word lists, history, review progress, audio attachments, song breakdowns, and crash logs. App settings are kept. This cannot be undone.")
        }
        .alert("Clear Caches?", isPresented: $isShowingClearCachesConfirmation) {
            Button("Clear", role: .destructive) { performCachesClear() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Frees \(formattedBytes(cachesBytes)) of on-disk caches (isolated vocal stems, transcript checkpoints). Saved words, audio, and downloaded alignment models are NOT affected. Aligning a song the first time after this will redo the source-separation step.")
        }
        .task { await refreshCachesBytes() }
        .alert("Replace All Data?", isPresented: $isShowingImportConfirmation) {
            Button("Import", role: .destructive) {
                if let pendingImportDocument {
                    importAppBackup(pendingImportDocument)
                }
                pendingImportDocument = nil
            }
            Button("Cancel", role: .cancel) {
                pendingImportDocument = nil
            }
        } message: {
            if let payload = pendingImportDocument?.payload {
                Text("This will replace all current data with \(payload.notes.count) notes, \(payload.words.count) words, \(payload.wordLists.count) lists, and \(payload.reviewStats.count) review records. This cannot be undone.")
            }
        }
    }

    // Captures the latest full app state before presenting the system export flow.
    private func beginAppExport() {
        let reviewStats = reviewStore.stats
            .map { AppBackupReviewStats(canonicalEntryID: $0.key, stats: $0.value) }
            .sorted { $0.canonicalEntryID < $1.canonicalEntryID }

        let notes = notesStore.exportNotes()
        let audioStore = NotesAudioStore.shared
        let audioAttachments: [AudioAttachmentBackup] = notes
            .compactMap { $0.audioAttachmentID }
            .compactMap { audioStore.exportAttachment(for: $0) }

        exportDocument = AppBackupDocument(
            payload: AppBackupPayload(
                notes: notes,
                words: wordsStore.words,
                wordLists: wordListsStore.lists,
                history: historyStore.entries,
                reviewStats: reviewStats,
                markedWrong: Array(reviewStore.markedWrong).sorted(),
                learned: Array(reviewStore.learned).sorted(),
                notLearned: Array(reviewStore.notLearned).sorted(),
                lifetimeCorrect: reviewStore.lifetimeCorrect,
                lifetimeAgain: reviewStore.lifetimeAgain,
                audioAttachments: audioAttachments
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
                // Reject structurally invalid backups before the destructive
                // replace-all confirmation is ever offered.
                try AppBackupValidator.validate(document.payload)
                pendingImportDocument = document
                isShowingImportConfirmation = true
            } catch {
                showTransferAlert(title: "Import Failed", message: error.localizedDescription)
            }
        case .failure(let error):
            showTransferAlert(title: "Import Failed", message: error.localizedDescription)
        }
    }

    // Applies one validated app-backup snapshot to every persisted store in a single replace-all pass.
    //
    // Restore ordering makes the operation effectively atomic for the user:
    // 1. The payload was already validated before the confirmation dialog.
    // 2. Audio files are staged to disk first; any write failure rolls back the
    //    staged files (skipping IDs a live note still references) and aborts
    //    before a single store has been mutated.
    // 3. Store replacement itself is non-throwing, so once staging succeeds the
    //    swap cannot leave mixed old/new state.
    private func importAppBackup(_ document: AppBackupDocument) {
        let payload = document.payload
        // Validation already rejected duplicate review IDs; uniquingKeysWith is a
        // defense-in-depth guard so a missed case degrades instead of trapping.
        let stats = Dictionary(
            payload.reviewStats.map { ($0.canonicalEntryID, $0.reviewWordStats()) },
            uniquingKeysWith: { current, _ in current }
        )

        let audioStore = NotesAudioStore.shared
        let liveAttachmentIDs = Set(notesStore.notes.compactMap(\.audioAttachmentID))
        var stagedAttachmentIDs: [UUID] = []
        for attachment in payload.audioAttachments {
            do {
                try audioStore.importAttachment(attachment)
                stagedAttachmentIDs.append(attachment.attachmentID)
            } catch {
                // Roll back files staged by this import; an ID also referenced by a
                // live note predates the import and must survive the abort.
                for stagedID in stagedAttachmentIDs where liveAttachmentIDs.contains(stagedID) == false {
                    audioStore.deleteAttachment(stagedID)
                }
                showTransferAlert(
                    title: "Import Failed",
                    message: "An audio attachment could not be restored, so no data was changed. \(error.localizedDescription)"
                )
                return
            }
        }

        wordListsStore.replaceAll(with: payload.wordLists)
        wordsStore.replaceAll(with: payload.words)
        historyStore.replaceAll(with: payload.history)
        reviewStore.replaceAll(
            stats: stats,
            markedWrong: Set(payload.markedWrong),
            lifetimeCorrect: payload.lifetimeCorrect,
            lifetimeAgain: payload.lifetimeAgain,
            learned: Set(payload.learned),
            notLearned: Set(payload.notLearned)
        )
        notesStore.replaceAll(with: payload.notes)

        var message = "Imported \(payload.notes.count) notes, \(payload.words.count) words, \(payload.wordLists.count) lists, \(payload.history.count) history entries, and \(payload.reviewStats.count) review records."
        if payload.audioAttachments.isEmpty == false {
            message += " Restored \(payload.audioAttachments.count) audio attachment(s)."
        }

        showTransferAlert(title: "Import Complete", message: message)
    }

    // Clears all persisted user data: every store, attachment files (including
    // orphans no note references), derived song breakdowns, cached lyric
    // translations, and recorded crash logs. Settings, credentials, and
    // downloaded models are intentionally kept — the confirmation text says so.
    private func resetAllData() {
        wordListsStore.replaceAll(with: [])
        wordsStore.replaceAll(with: [])
        historyStore.replaceAll(with: [])
        reviewStore.replaceAll(stats: [:], markedWrong: [], lifetimeCorrect: 0, lifetimeAgain: 0)
        notesStore.replaceAll(with: [])
        songBreakdownStore.clearAll()
        NotesAudioStore.shared.deleteAllStoredFiles()
        CrashLogger.shared.clearCrashFiles()
        showTransferAlert(title: "Reset Complete", message: "All user data has been erased.")
    }

    // Presents a single alert for import and export status messages.
    private func showTransferAlert(title: String, message: String) {
        transferAlertTitle = title
        transferAlertMessage = message
        isShowingTransferAlert = true
    }

    // Refreshes the byte readout shown on the Clear Caches button. Scans off the main thread
    // so a deep cache (thousands of files) doesn't stall the Settings sheet.
    private func refreshCachesBytes() async {
        let bytes = await Task.detached(priority: .utility) { CachesCleaner.measure() }.value
        cachesBytes = bytes
    }

    // Wipes Library/Caches and reports the freed size via the shared transfer alert.
    private func performCachesClear() {
        guard isClearingCaches == false else { return }
        isClearingCaches = true
        Task {
            let freed = await Task.detached(priority: .utility) { CachesCleaner.clearAll() }.value
            cachesBytes = 0
            isClearingCaches = false
            showTransferAlert(title: "Caches Cleared", message: "Freed \(formattedBytes(freed)).")
        }
    }

    // Renders a byte count as a human-readable string (e.g. "747 MB", "1.2 GB") — matches what
    // iPhone Storage shows so the in-app number reads the same as the system view.
    private func formattedBytes(_ bytes: Int) -> String {
        let f = ByteCountFormatter()
        f.allowedUnits = [.useKB, .useMB, .useGB]
        f.countStyle = .file
        return f.string(fromByteCount: Int64(bytes))
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

    // A tappable three-tone swatch for a token-color preset: token A, token B, and the
    // coordinating highlight/glow color. Applies all three and turns custom colors on;
    // outlined in the accent color when it's the currently-active pair.
    private func tokenPresetSwatch(_ preset: TokenColorSettings.Preset) -> some View {
        let isSelected = customTokenColorsEnabled
            && tokenColorAHex.caseInsensitiveCompare(preset.aHex) == .orderedSame
            && tokenColorBHex.caseInsensitiveCompare(preset.bHex) == .orderedSame
        return Button {
            tokenColorAHex = preset.aHex
            tokenColorBHex = preset.bHex
            highlightHex = preset.highlightHex
            customTokenColorsEnabled = true
        } label: {
            VStack(spacing: 4) {
                HStack(spacing: 0) {
                    Color(UIColor(hexString: preset.aHex) ?? .gray)
                    Color(UIColor(hexString: preset.bHex) ?? .gray)
                    Color(UIColor(hexString: preset.highlightHex) ?? .gray)
                }
                .frame(width: 60, height: 24)
                .clipShape(RoundedRectangle(cornerRadius: 7))
                .overlay(
                    RoundedRectangle(cornerRadius: 7)
                        .stroke(isSelected ? Color.accentColor : Color.secondary.opacity(0.3),
                                lineWidth: isSelected ? 2 : 1)
                )
                Text(preset.name)
                    .font(.caption2)
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
            }
        }
        .buttonStyle(.plain)
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

    // Highlight color — shared by the favorited glow and the selection box (hex AppStorage) <-> Color.
    private var tokenHighlightBinding: Binding<Color> {
        Binding(
            get: { Color(UIColor(hexString: highlightHex) ?? UIColor(hexString: TokenColorSettings.defaultHighlightHex)!) },
            set: { color in
                if let hex = UIColor(color).hexString { highlightHex = hex }
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

    // Bridges AppStorage raw string to the demotion list expected by ParticleTagEditor.
    private var demotionsBinding: Binding<[String]> {
        Binding(
            get: { SegmentationDemotions.decodeList(from: demotionsRaw) },
            set: { demotionsRaw = SegmentationDemotions.encodeList($0) }
        )
    }
}

// Chip grid for adding and removing individual kana from the particle allowlist.
struct ParticleTagEditor: View {
    @Binding var tags: [String]
    @State private var draft: String = ""
    @FocusState private var draftFocused: Bool

    var body: some View {
        // FlowLayout (not LazyVGrid) so each chip takes its natural width and wraps — no fixed
        // columns. Multi-character demotions (その物, か弱い) size to their content.
        FlowLayout(spacing: 8) {
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
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
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

// FlowLayout lives in Kioku/FlowLayout.swift (shared with SubtitleImportView's vocab tag picker).

#Preview {
    ContentView(selectedTab: .settings)
}
