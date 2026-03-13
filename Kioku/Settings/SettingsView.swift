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
    @State private var exportDocument = NotesTransferDocument(notes: [])
    @State private var isShowingExporter = false
    @State private var isShowingImporter = false
    @State private var isShowingImportModeMenu = false
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

                Section {
                    // Exports the current notes collection and saved segments to a JSON file.
                    Button {
                        beginNotesExport()
                    } label: {
                        Label("Export", systemImage: "square.and.arrow.up")
                    }
                    // Imports a JSON export and replaces the current notes collection.
                    Button {
                        isShowingImportModeMenu = true
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
        .confirmationDialog(
            "Import Notes",
            isPresented: $isShowingImportModeMenu,
            titleVisibility: .visible
        ) {
            Button(NotesImportMode.replaceAll.title) {
                selectedImportMode = .replaceAll
                isShowingImporter = true
            }
            Button(NotesImportMode.overwriteByID.title) {
                selectedImportMode = .overwriteByID
                isShowingImporter = true
            }
            Button(NotesImportMode.overwriteByTitle.title) {
                selectedImportMode = .overwriteByTitle
                isShowingImporter = true
            }
            Button(NotesImportMode.append.title) {
                selectedImportMode = .append
                isShowingImporter = true
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Choose how imported notes should be merged with your existing notes.")
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

            importNotes(from: fileURL)
        case .failure(let error):
            showTransferAlert(title: "Import Failed", message: error.localizedDescription)
        }
    }

    // Reads an exported notes document and replaces the current notes store contents.
    private func importNotes(from fileURL: URL) {
        let hasSecurityScope = fileURL.startAccessingSecurityScopedResource()
        defer {
            if hasSecurityScope {
                fileURL.stopAccessingSecurityScopedResource()
            }
        }

        do {
            let document = try NotesTransferDocument(contentsOf: fileURL)
            notesStore.importTransferDocument(document, mode: selectedImportMode)
            showTransferAlert(
                title: "Import Complete",
                message: "\(selectedImportMode.completionVerb) \(document.payload.notes.count) notes."
            )
        } catch {
            showTransferAlert(title: "Import Failed", message: error.localizedDescription)
        }
    }

    // Presents a single alert for import and export status messages.
    private func showTransferAlert(title: String, message: String) {
        transferAlertTitle = title
        transferAlertMessage = message
        isShowingTransferAlert = true
    }
}

#Preview {
    ContentView(selectedTab: .settings)
}
