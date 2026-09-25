import SwiftUI
import UniformTypeIdentifiers
import UserNotifications

// Single-screen settings, organized top-to-bottom: typography preview (tap for the slider
// sheet), theme and highlight colors, lookup, AI, learning, word of the day, data transfer,
// dictionary, developer tools and storage. Footer prose is intentionally omitted — rows stand alone.
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

    // Typography sliders live in TypographySettingsSheet, opened by tapping the preview.
    @State private var isShowingTypographySheet = false
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

    // Auto-mark-as-learned: one right answer in every kind of question → learned (see AutoLearnPolicy).
    @AppStorage(LearnedSettings.enabledKey) private var autoLearnEnabled: Bool = false
    // Whether the Learn tab's study modes skip Learned/Mastered words. Read by each mode through
    // StudyWordPool; this is the single place it's set.
    @AppStorage(LearnedSettings.excludeLearnedKey) private var excludeLearnedInStudy: Bool = LearnedSettings.defaultExcludeLearned

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

    // engineSettings (the dictionary, diagnostics and debug sections) lives in
    // SettingsView+EngineSections.swift to keep this file under the line-count guardrail.

    var body: some View {
        NavigationStack {
            Form {
                // MARK: Typography — the live preview; tapping it opens the slider sheet. The
                // clear overlay takes the tap ahead of the renderer's own UIKit gestures.
                Section {
                    TypographyPreview()
                        .overlay {
                            Color.clear
                                .contentShape(Rectangle())
                                .onTapGesture { isShowingTypographySheet = true }
                        }
                        .accessibilityAddTraits(.isButton)
                } header: {
                    Text("Typography")
                }

                // MARK: Theme — the theme picker, its optional overrides, and the per-state
                // Saved Highlight colors (switched on from the Read toolbar), all one section.
                // Built from @ViewBuilder helpers in SettingsView+ThemeSection.swift to keep the
                // Swift type-checker within its expression budget.
                Section {
                    themePickerMenu
                    customThemeRows
                    customTokenColorRows
                    savedHighlightColorRows
                } header: {
                    Text("Theme")
                }

                // MARK: Lookup — how the word popover behaves, and clipboard pickup.
                Section {
                    Toggle("Show Japanese in Popover", isOn: $showJapaneseInPopover)
                    Toggle("Open Full Lookup on Tap", isOn: $prefersSheetDirectSegmentActions)
                    Toggle("Auto-detect Japanese in Clipboard", isOn: $clipboardAutoDetect)
                } header: {
                    Text("Lookup")
                }

                // MARK: AI — body lives in SettingsView+AICorrectionSection.swift
                aiCorrectionSection

                // MARK: Learning — auto-mark words as learned once every kind of question about
                // them has been answered right, and whether the Learn tab keeps drilling them.
                Section {
                    Toggle("Skip Learned Words", isOn: $excludeLearnedInStudy)
                    Toggle("Auto-mark as Learned", isOn: $autoLearnEnabled)
                } header: {
                    Text("Learning")
                }

                // MARK: Word of the Day — daily notification time and permission.
                Section {
                    Toggle("Daily Notification", isOn: $wotdEnabled)
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
                } header: {
                    Text("Word of the Day")
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

                // MARK: Dictionary, diagnostics and debug sections. See engineSettings.
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
        .sheet(isPresented: $isShowingTypographySheet) {
            TypographySettingsSheet()
        }
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
