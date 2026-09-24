import SwiftUI
import UniformTypeIdentifiers
import UserNotifications

// Single-screen settings, organized top-to-bottom: appearance (typography, theme),
// reading behavior (audio, word of the day, clipboard), segmentation tuning, AI provider,
// developer tools, and data transfer. Footer prose is intentionally omitted — rows stand alone.
struct SettingsView: View {
    let dictionaryStore: DictionaryStore?
    // Hosts the on-demand local-network MCP listener whose UI lives in BridgeSettingsSection.
    @ObservedObject var bridgeServer: KiokuBridgeServer

    // Not private: SettingsView+BackupSection.swift's export/import functions read these directly.
    @EnvironmentObject var notesStore: NotesStore
    @EnvironmentObject var wordsStore: WordsStore
    @EnvironmentObject var wordListsStore: WordListsStore
    @EnvironmentObject var historyStore: HistoryStore
    @EnvironmentObject private var songBreakdownStore: SongBreakdownStore

    // Selected theme id — drives chrome (background/accent/typography) and the default token
    // colors when "Custom Token Colors" is off. See ThemeID for available themes.
    @AppStorage(Theme.themeIDKey) var themeIDRaw: String = ThemeID.system.rawValue

    @AppStorage(TypographySettings.textSizeKey) private var textSize = TypographySettings.defaultTextSize
    @AppStorage(TypographySettings.lineSpacingKey) private var lineSpacing = TypographySettings.defaultLineSpacing
    @AppStorage(TypographySettings.kerningKey) private var kerning = TypographySettings.defaultKerning
    @AppStorage(TypographySettings.furiganaGapKey) private var furiganaGap = TypographySettings.defaultFuriganaGap
    @AppStorage(TypographySettings.customFuriganaSizeEnabledKey) private var customFuriganaSizeEnabled = false
    @AppStorage(TypographySettings.furiganaSizeKey) private var furiganaSize = TypographySettings.defaultFuriganaSize
    @AppStorage(LyricsHighlightGranularity.storageKey)
    private var lyricsHighlightGranularityRaw = LyricsHighlightGranularity.defaultValue.rawValue
    @AppStorage(AudioSettings.backgroundPlaybackKey) private var backgroundPlayback: Bool = AudioSettings.defaultBackgroundPlayback
    @AppStorage(AudioSettings.autoAdvanceToNextNoteKey) private var autoAdvanceToNextNote: Bool = AudioSettings.defaultAutoAdvanceToNextNote
    @AppStorage(ClipboardSettings.autoDetectKey) private var clipboardAutoDetect: Bool = ClipboardSettings.defaultAutoDetect
    @AppStorage(DictionarySettings.includeArchaicReadingsKey)
    var includeArchaicReadings: Bool = DictionarySettings.defaultIncludeArchaicReadings
    @AppStorage(DictionarySettings.showJapaneseInPopoverKey)
    private var showJapaneseInPopover: Bool = DictionarySettings.defaultShowJapaneseInPopover
    @AppStorage(DictionarySettings.prefersSheetDirectSegmentActionsKey)
    private var prefersSheetDirectSegmentActions: Bool = DictionarySettings.defaultPrefersSheetDirectSegmentActions

    // No `private` modifiers below: the AI section's UI lives in
    // SettingsView+AICorrectionSection.swift and needs to read these as
    // bindings. Extensions in other source files can't reach `private`
    // members, so these stay at module-internal access.
    // The remote provider song breakdowns use.
    @AppStorage(LLMSettings.providerKey) var llmProviderRaw: String = LLMSettings.defaultProvider
    // API keys live in the Keychain, not UserDefaults; @State holds the editing copy
    // and onChange writes through. keysRevision is a non-secret change counter other
    // views observe to re-check key presence without touching the secret itself.
    @State var openAIKey: String = LLMSettings.apiKey(for: .openAI) ?? ""
    @State var claudeKey: String = LLMSettings.apiKey(for: .claude) ?? ""
    @AppStorage(LLMSettings.keysRevisionKey) var llmKeysRevision: Int = 0
    @AppStorage(LLMSettings.useLLMKey) var useLLM: Bool = true

    @AppStorage(TokenColorSettings.enabledKey) var customTokenColorsEnabled: Bool = false
    @AppStorage(TokenColorSettings.colorAKey) var tokenColorAHex: String = TokenColorSettings.defaultColorAHex
    @AppStorage(TokenColorSettings.colorBKey) var tokenColorBHex: String = TokenColorSettings.defaultColorBHex
    @AppStorage(TokenColorSettings.highlightColorKey) var highlightHex: String = TokenColorSettings.defaultHighlightHex
    @AppStorage(TokenColorSettings.savedColorKey) var savedHex: String = TokenColorSettings.defaultSavedHex
    @AppStorage(TokenColorSettings.savedLearnedColorKey) var savedLearnedHex: String = TokenColorSettings.defaultSavedLearnedHex
    @AppStorage(TokenColorSettings.savedNotLearnedColorKey) var savedNotLearnedHex: String = TokenColorSettings.defaultSavedNotLearnedHex
    @AppStorage(TokenColorSettings.savedElsewhereColorKey) var savedElsewhereHex: String = TokenColorSettings.defaultSavedElsewhereHex
    // Custom Theme: when on, the four hexes below override the active theme's chrome colors
    // (background / surface / ink / accent). Other palette slots keep the theme's values so a
    // half-customized palette stays coherent. The Read view's toolbar still owns the on/off
    // for segment coloring (`kioku.settings.colorAlternation`) — it's no longer surfaced here.
    @AppStorage(Theme.customThemeEnabledKey) var customThemeEnabled: Bool = false
    @AppStorage(Theme.customBackgroundHexKey) var customBackgroundHex: String = ""
    @AppStorage(Theme.customSurfaceHexKey) var customSurfaceHex: String = ""
    @AppStorage(Theme.customInkHexKey) var customInkHex: String = ""
    @AppStorage(Theme.customAccentHexKey) var customAccentHex: String = ""

    @AppStorage(WordOfTheDayScheduler.enabledKey) private var wotdEnabled: Bool = false
    @AppStorage(WordOfTheDayScheduler.hourKey) private var wotdHour: Int = 9
    @AppStorage(WordOfTheDayScheduler.minuteKey) private var wotdMinute: Int = 0

    // Auto-mark-as-learned: a word clears the bar in flashcard reviews → it's flagged learned.
    @AppStorage(LearnedSettings.enabledKey) private var autoLearnEnabled: Bool = false
    @AppStorage(LearnedSettings.ruleKey) private var autoLearnRuleRaw: String = AutoLearnRule.accuracyAndMinReviews.rawValue
    @AppStorage(LearnedSettings.thresholdKey) private var autoLearnThreshold: Double = LearnedSettings.defaultThreshold
    @AppStorage(LearnedSettings.minReviewsKey) private var autoLearnMinReviews: Int = LearnedSettings.defaultMinReviews
    @AppStorage(LearnedSettings.streakKey) private var autoLearnStreak: Int = LearnedSettings.defaultStreak
    // Whether the Learn tab's study modes skip Learned/Mastered words. Read by each mode through
    // StudyWordPool; this is the single place it's set.
    @AppStorage(LearnedSettings.excludeLearnedKey) private var excludeLearnedInStudy: Bool = LearnedSettings.defaultExcludeLearned
    @AppStorage(QuizAssistSettings.smarterOptionsKey) private var smarterQuizOptions: Bool = QuizAssistSettings.defaultSmarterOptions
    @AppStorage(SegmenterSettings.backendKey) var segmenterBackend: String = SegmenterSettings.defaultBackend
    @AppStorage(SegmenterSettings.mecabDictionaryKey) var mecabDictionary: String = SegmenterSettings.defaultMeCabDictionary
    @AppStorage(SegmenterSettings.splitsParticleClustersKey) var splitsParticleClusters = SegmenterSettings.defaultSplitsParticleClusters

    @AppStorage(DebugSettings.pixelRulerKey) var debugPixelRuler: Bool = false
    @AppStorage(DebugSettings.furiganaRectsKey) var debugFuriganaRects: Bool = false
    @AppStorage(DebugSettings.headwordRectsKey) var debugHeadwordRects: Bool = false
    @AppStorage(DebugSettings.headwordLineBandsKey) var debugHeadwordLineBands: Bool = false
    @AppStorage(DebugSettings.furiganaLineBandsKey) var debugFuriganaLineBands: Bool = false
    @AppStorage(DebugSettings.headwordLineNumbersKey) var debugHeadwordLineNumbers: Bool = false
    @AppStorage(DebugSettings.rubyLineNumbersKey) var debugRubyLineNumbers: Bool = false
    @AppStorage(DebugSettings.bisectorHeadwordKey) var debugBisectorHeadword: Bool = false
    @AppStorage(DebugSettings.bisectorFuriganaKey) var debugBisectorFurigana: Bool = false
    @AppStorage(DebugSettings.envelopeRectsKey) var debugEnvelopeRects: Bool = false
    @AppStorage(DebugSettings.leftInsetGuideKey) var debugLeftInsetGuide: Bool = false

    @State private var wotdPermissionStatus: UNAuthorizationStatus = .notDetermined
    @State private var wotdPendingCount: Int = 0
    // Transient confirmation for the "Send Test" button: shows which word was scheduled and
    // auto-clears. wotdTestTapCount drives the success haptic and guards the auto-clear so a
    // rapid re-tap doesn't get its status wiped by the previous tap's timer.
    @State var wotdTestStatus: String?
    @State var wotdTestTapCount = 0

    // Not private: SettingsView+BackupSection.swift's export/import functions read and write
    // these directly.
    @State var exportDocument = AppBackupDocument(
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
    @State var isShowingExporter = false
    @State private var isShowingImporter = false
    @State var isShowingTransferAlert = false
    @State var transferAlertTitle = ""
    @State var transferAlertMessage = ""
    @State private var isShowingResetConfirmation = false
    @State var isShowingImportConfirmation = false
    @State var pendingImportDocument: AppBackupDocument?
    // Snapshot of Library/Caches total size, refreshed when Settings appears and after a clear.
    // Drives the byte readout on the Clear Caches button so the user sees what's about to free.
    @State private var cachesBytes: Int = 0
    @State private var isClearingCaches = false
    // Bumped after Clear Caches so the Downloaded Models section re-measures; the section
    // reports its own deletions back so the Clear Caches readout re-measures too.
    @State private var storageRefreshToken = 0

    // engineSettings (the segmentation, dictionary, diagnostics and debug sections) lives in
    // SettingsView+EngineSections.swift to keep this file under the line-count guardrail.

    var body: some View {
        NavigationStack {
            Form {
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

                // Per-state colors for the Read tab's "Saved Highlight" display option
                // (Save/unmarked reuses the Highlight Color above). Its own section since
                // it's independent of Custom Token Colors — Saved Highlight has its own
                // on/off toggle in the Read toolbar.
                Section {
                    savedHighlightColorRows
                } header: {
                    Text("Saved Highlight")
                }

                // MARK: Theme — selects the visual identity (chrome + default token colors) and
                // exposes optional customization on top. Theme picker, then optional overrides,
                // all in one section because the user reads them as one concept. Section body
                // is built out of three @ViewBuilder helpers below to keep the Swift type-checker
                // out of trouble (the inline version blew past its expression budget).
                Section {
                    themePickerMenu
                    customThemeRows
                    customTokenColorRows
                } header: {
                    Text("Theme")
                }

                // MARK: Lookup — how the word popover behaves.
                Section {
                    Toggle("Show Japanese in Popover", isOn: $showJapaneseInPopover)
                    Toggle("Open Full Lookup on Tap", isOn: $prefersSheetDirectSegmentActions)
                } header: {
                    Text("Lookup")
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
                    Toggle("Continue to Next Note", isOn: $autoAdvanceToNextNote)
                } header: {
                    Text("Audio")
                }

                // MARK: AI — body lives in SettingsView+AICorrectionSection.swift
                aiCorrectionSection

                // MARK: Learning — auto-mark words as learned past a chosen bar, and whether the
                // Learn tab keeps drilling words that have got there.
                Section {
                    // On-device only, and only where the device can actually do it — hidden rather
                    // than shown disabled, since there's nothing the user could do to enable it.
                    if AppleIntelligenceAvailability.isAvailable {
                        Toggle("Smarter Quiz Options", isOn: $smarterQuizOptions)
                    }

                    Toggle("Skip Learned Words", isOn: $excludeLearnedInStudy)

                    Toggle("Auto-mark as Learned", isOn: $autoLearnEnabled)
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
                                    Text("Accuracy Threshold")
                                    Spacer()
                                    Text("\(Int((autoLearnThreshold * 100).rounded()))%")
                                        .foregroundStyle(.secondary)
                                        .monospacedDigit()
                                }
                                Slider(value: $autoLearnThreshold, in: 0.5...1.0, step: 0.05)
                            }
                        }
                        if rule == .accuracyAndMinReviews {
                            Stepper("Minimum Reviews: \(autoLearnMinReviews)", value: $autoLearnMinReviews, in: 1...20)
                        }
                        if rule == .consecutiveCorrect {
                            Stepper("Correct in a Row: \(autoLearnStreak)", value: $autoLearnStreak, in: 1...20)
                        }
                    }
                } header: {
                    Text("Learning")
                }

                // MARK: System — Word of the Day notifications and clipboard detection.
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
                    }
                    Toggle("Auto-detect Japanese in Clipboard", isOn: $clipboardAutoDetect)
                } header: {
                    Text("System")
                }
                .task {
                    await refreshWotdStatus()
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
                    Button(role: .destructive) {
                        isShowingResetConfirmation = true
                    } label: {
                        Label("Reset", systemImage: "trash")
                    }
                } header: {
                    Text("Data")
                }

                // MARK: Segmentation, dictionary, diagnostics and debug sections. See engineSettings.
                engineSettings
                // MARK: Storage — models, isolated vocals and caches (own file: self-contained
                // @State + alerts). Its Clear Caches state stays on this view.
                DownloadedModelsSection(
                    refreshToken: storageRefreshToken,
                    cachesBytes: cachesBytes,
                    isClearingCaches: isClearingCaches,
                    onClearCaches: { performCachesClear() },
                    onStorageChanged: { Task { await refreshCachesBytes() } }
                )

                Section {
                    NavigationLink {
                        AboutView()
                    } label: {
                        Label("About", systemImage: "info.circle")
                    }
                }

            }
            .scrollDismissesKeyboard(.interactively)
            .washiBackground()
            .navigationTitle("Settings")
        }
        // Tint applied INSIDE the SettingsView's own NavigationStack — on iOS 26 the parent
        // TabView's .themedTint() reliably reaches Toggle on-tracks but not Picker selection
        // labels through a nested NavigationStack, so the picker would render its label in
        // the stale parent tint (Washi vermilion) even after the theme switched. Re-applying
        // the modifier here forces the picker label, toggle, and any other tinted control to
        // share the active theme's accent.
        .themedTint()
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

    // Export/import logic (beginAppExport, handleExportResult, handleImportResult,
    // importAppBackup) lives in SettingsView+BackupSection.swift.

    // Clears all persisted user data: every store, attachment files (including
    // orphans no note references), derived song breakdowns, cached lyric
    // translations, and recorded crash logs. Settings, credentials, and
    // downloaded models are intentionally kept — the confirmation text says so.
    private func resetAllData() {
        wordListsStore.replaceAll(with: [])
        wordsStore.replaceAll(with: [])
        wordsStore.resetLifetimeCounts()
        historyStore.replaceAll(with: [])
        notesStore.replaceAll(with: [])
        songBreakdownStore.clearAll()
        NotesAudioStore.shared.deleteAllStoredFiles()
        CrashLogger.shared.clearCrashFiles()
        showTransferAlert(title: "Reset Complete", message: "All user data has been erased.")
    }

    // Presents a single alert for import and export status messages. Not private:
    // SettingsView+BackupSection.swift's export/import functions call this too.
    func showTransferAlert(title: String, message: String) {
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

    // Wipes Library/Caches and tmp/ and reports the freed size via the shared transfer alert.
    private func performCachesClear() {
        guard isClearingCaches == false else { return }
        isClearingCaches = true
        Task {
            let freed = await Task.detached(priority: .utility) { CachesCleaner.clearAll() }.value
            cachesBytes = 0
            isClearingCaches = false
            storageRefreshToken += 1
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
        // Already-learned words have nothing left to teach, so they'd only be a wasted notification.
        let learnedEntryIDs = wordsStore.learned
        let words = wordsStore.words.filter { learnedEntryIDs.contains($0.canonicalEntryID) == false }
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

    // Bridges the raw AppStorage string to a Picker-friendly ThemeID binding. Falls back to
    // System if the stored string ever desyncs from the enum (shouldn't happen, but the
    // picker can't render a nil tag).
    private var themeIDBinding: Binding<ThemeID> {
        Binding(
            get: { ThemeID(rawValue: themeIDRaw) ?? .system },
            set: { themeIDRaw = $0.rawValue }
        )
    }

    // Custom-theme color bindings live in SettingsView+ThemeSection.swift to keep this file
    // under the 1000-line build invariant.

    // Converts the hex string AppStorage value to/from a SwiftUI Color for use with ColorPicker.
    var tokenColorABinding: Binding<Color> {
        Binding(
            get: { Color(UIColor(hexString: tokenColorAHex) ?? UIColor(hexString: TokenColorSettings.defaultColorAHex)!) },
            set: { color in
                if let hex = UIColor(color).hexString { tokenColorAHex = hex }
            }
        )
    }

    // Converts the hex string AppStorage value to/from a SwiftUI Color for use with ColorPicker.
    var tokenColorBBinding: Binding<Color> {
        Binding(
            get: { Color(UIColor(hexString: tokenColorBHex) ?? UIColor(hexString: TokenColorSettings.defaultColorBHex)!) },
            set: { color in
                if let hex = UIColor(color).hexString { tokenColorBHex = hex }
            }
        )
    }

    // Highlight color — shared by the saved glow and the selection box (hex AppStorage) <-> Color.
    var tokenHighlightBinding: Binding<Color> {
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
}

#Preview {
    ContentView(selectedTab: .settings)
}
