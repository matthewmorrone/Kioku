import SwiftUI
import UniformTypeIdentifiers

// Presents typography controls and a live preview for reading settings.
struct SettingsView: View {
    @EnvironmentObject private var notesStore: NotesStore

    @AppStorage(TypographySettings.textSizeKey)
    private var textSize = TypographySettings.defaultTextSize
    @AppStorage(TypographySettings.lineSpacingKey)
    private var lineSpacing = TypographySettings.defaultLineSpacing
    @AppStorage(TypographySettings.kerningKey)
    private var kerning = TypographySettings.defaultKerning
    @AppStorage(ParticleSettings.storageKey)
    private var particlesRaw: String = ParticleSettings.defaultRawValue

    @State private var exportDocument = NotesTransferDocument(notes: [])
    @State private var isShowingExporter = false
    @State private var isShowingImporter = false
    @State private var isShowingImportModeMenu = false
    @State private var pendingImportFileURL: URL?
    @State private var selectedImportMode: NotesImportMode = .replaceAll
    @State private var isShowingTransferAlert = false
    @State private var transferAlertTitle = ""
    @State private var transferAlertMessage = ""

    private let previewText = "情報処理技術者試験対策資料を精読し、概念理解を深める。"

    var body: some View {
        NavigationStack {
            Form {
                // Hosts typography sliders that update read and preview rendering.
                Section {
                        // Shows live typography preview content.
                    RichTextPreview(
                        text: previewText,
                        textSize: textSize,
                        lineSpacing: lineSpacing,
                        kerning: kerning
                    )
                    .frame(minHeight: 96)
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
                } header: {
                    Text("Typography")
                }

                // Inline chip editor for the single-kana allowlist used during lattice path filtering.
                Section {
                    ParticleTagEditor(tags: particlesBinding)
                } header: {
                    Text("Particles")
                } footer: {
                    Text("Single-kana segments not listed here are treated as bound morphemes and excluded from segmentation paths.")
                }

                Section {
                    // Exports the current notes collection and saved segments to a JSON file.
                    Button {
                        beginNotesExport()
                    } label: {
                        Label("Export", systemImage: "square.and.arrow.up")
                    }
                    // Imports a JSON export and replaces the current notes collection.
                    Button {
                        isShowingImporter = true
                    } label: {
                        Label("Import", systemImage: "square.and.arrow.down")
                    }
                }
            }
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
        .sheet(
            isPresented: $isShowingImportModeMenu,
            onDismiss: {
                pendingImportFileURL = nil
            }
        ) {
            NavigationStack {
                List {
                    ForEach(NotesImportMode.allCases, id: \.self) { mode in
                        Button {
                            selectedImportMode = mode
                            importNotes(from: mode)
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(mode.title)
                                Text(mode.detail)
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .navigationTitle("Import Notes")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Cancel") {
                            pendingImportFileURL = nil
                            isShowingImportModeMenu = false
                        }
                    }
                }
            }
        }
        .alert(transferAlertTitle, isPresented: $isShowingTransferAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(transferAlertMessage)
        }
    }

    // Captures the latest notes state before presenting the system export flow.
    private func beginNotesExport() {
        exportDocument = notesStore.makeTransferDocument()
        isShowingExporter = true
    }

    // Reports whether the export operation finished or failed.
    private func handleExportResult(_ result: Result<URL, Error>) {
        switch result {
        case .success:
            showTransferAlert(title: "Export Complete", message: "Your notes export was saved successfully.")
        case .failure(let error):
            showTransferAlert(title: "Export Failed", message: error.localizedDescription)
        }
    }

    // Validates the importer selection and loads the selected notes export file.
    private func handleImportResult(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let fileURL = urls.first else {
                showTransferAlert(title: "Import Failed", message: "No file was selected.")
                return
            }

            pendingImportFileURL = fileURL
            isShowingImportModeMenu = true
        case .failure(let error):
            showTransferAlert(title: "Import Failed", message: error.localizedDescription)
        }
    }

    // Imports a previously selected file using one explicit merge mode from the import-mode menu.
    private func importNotes(from mode: NotesImportMode) {
        guard let fileURL = pendingImportFileURL else {
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
            let document = try NotesTransferDocument(contentsOf: fileURL)
            notesStore.importTransferDocument(document, mode: mode)
            pendingImportFileURL = nil
            isShowingImportModeMenu = false
            showTransferAlert(
                title: "Import Complete",
                message: "\(mode.completionVerb) \(document.payload.notes.count) notes."
            )
        } catch {
            pendingImportFileURL = nil
            isShowingImportModeMenu = false
            showTransferAlert(title: "Import Failed", message: error.localizedDescription)
        }
    }

    // Presents a single alert for import and export status messages.
    private func showTransferAlert(title: String, message: String) {
        transferAlertTitle = title
        transferAlertMessage = message
        isShowingTransferAlert = true
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

    private let columns: [GridItem] = [GridItem(.adaptive(minimum: 56), spacing: 8)]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if tags.isEmpty {
                Text("No particles configured. Add kana to allow them as standalone segments.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                LazyVGrid(columns: columns, alignment: .leading, spacing: 8) {
                    ForEach(tags, id: \.self) { tag in
                        tagChip(for: tag)
                    }
                }
            }

            HStack(spacing: 8) {
                TextField("Add kana", text: $draft)
                    .textInputAutocapitalization(.never)
                    .disableAutocorrection(true)
                    .onSubmit { commitDraft() }

                Button("Add") { commitDraft() }
                    .buttonStyle(.borderedProminent)
                    .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            Button("Reset to Defaults") {
                ParticleSettings.reset()
                tags = ParticleSettings.decodeList(from: ParticleSettings.defaultRawValue)
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
    }

    private func tagChip(for tag: String) -> some View {
        HStack(spacing: 4) {
            Text(tag)
                .font(.subheadline)
            Button(role: .destructive) {
                tags.removeAll { $0 == tag }
            } label: {
                Image(systemName: "xmark")
                    .font(.caption2)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Capsule().fill(Color(.secondarySystemBackground)))
        .overlay(Capsule().stroke(Color.secondary.opacity(0.3), lineWidth: 1))
    }

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
