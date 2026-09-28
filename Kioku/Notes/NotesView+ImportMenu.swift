import SwiftUI

// The Notes tab's Import menu and its single-file audio path. Import Audio forwards the picked file
// to ContentView via `onAudioImported`, which switches to Read, where it's checked for speech vs
// singing and transcribed into a new note (ReadView+AudioTranscription.swift). OCR lives in
// NotesView+OCR.swift; bulk import in BulkImportSheet.
extension NotesView {
    // Toolbar Import menu: bulk file import, single audio file (iOS 26+, SpeechTranscriber), and
    // text from the camera, a photo or a URL. Shows a spinner while OCR runs.
    var importMenu: some View {
        Menu {
            Button {
                isShowingBulkImportSheet = true
            } label: {
                Label("Import Files…", systemImage: "tray.and.arrow.down")
            }
            if #available(iOS 26.0, *) {
                Button {
                    isShowingAudioImporter = true
                } label: {
                    Label("Import Audio…", systemImage: "waveform")
                }
            }
            Section {
                Button {
                    presentCameraOCRIfAvailable()
                } label: {
                    Label("Camera", systemImage: "camera")
                }
                Button {
                    isShowingPhotoLibraryPicker = true
                } label: {
                    Label("Photo Library", systemImage: "photo.on.rectangle")
                }
                Button {
                    isShowingURLImportSheet = true
                } label: {
                    Label("From URL", systemImage: "link")
                }
            }
        } label: {
            Group {
                if isPerformingOCRImport {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Image(systemName: "square.and.arrow.down")
                        .scaledFont(size: 16)
                }
            }
            .frame(width: 32, height: 32)
        }
        .disabled(isPerformingOCRImport)
        .accessibilityLabel("Import")
    }

    // Forwards the picked audio file; a picker failure other than cancellation is only logged,
    // since the picker itself is the visible surface.
    func handleAudioImporterResult(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            onAudioImported?(url)
        case .failure(let error):
            AppLog.error(.transcription, "audio import picker failed: \(error)")
        }
    }
}
