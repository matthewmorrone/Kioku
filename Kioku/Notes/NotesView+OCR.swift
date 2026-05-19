import PhotosUI
import SwiftUI
import UIKit
import Vision

// OCR import flow for the Notes tab. Owns everything from menu button to Vision
// recognition; on success forwards the recognized Note up to ContentView via
// `onOCRImportedNote`, which installs the note, sets it as the active Read note,
// switches tabs, and arms edit mode (the previous Read-side end state).
extension NotesView {
    // Bool binding for `.alert(isPresented:)` reflecting OCR error message presence.
    var ocrImportErrorPresented: Binding<Bool> {
        Binding(
            get: { ocrImportErrorMessage.isEmpty == false },
            set: { isPresented in
                if isPresented == false {
                    ocrImportErrorMessage = ""
                }
            }
        )
    }

    // Toolbar menu offering Camera vs. Photo Library entry points. Shows a small spinner
    // while OCR is running so the user knows the request is in flight and the picker
    // shouldn't reopen.
    var ocrImportToolbarButton: some View {
        Menu {
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
        } label: {
            Group {
                if isPerformingOCRImport {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Image(systemName: "text.viewfinder")
                        .font(.system(size: 16))
                }
            }
            .frame(width: 32, height: 32)
        }
        .disabled(isPerformingOCRImport)
        .accessibilityLabel("Import Text with OCR")
    }

    // Loads the picker-selected image, runs OCR, forwards the recognized text into a new Note.
    func importTextFromSelectedOCRImage(_ item: PhotosPickerItem) async {
        do {
            guard let imageData = try await item.loadTransferable(type: Data.self) else {
                ocrImportErrorMessage = "The selected image could not be loaded."
                return
            }
            await importTextFromOCRImageData(imageData)
        } catch {
            ocrImportErrorMessage = error.localizedDescription
        }
    }

    // Runs Vision OCR on raw image data and, on success, calls the parent's import handler.
    // Guarded against concurrent calls so a rapid-fire double-tap doesn't double-fire.
    func importTextFromOCRImageData(_ imageData: Data) async {
        guard isPerformingOCRImport == false else { return }

        isPerformingOCRImport = true
        defer {
            isPerformingOCRImport = false
            selectedOCRImageItem = nil
        }

        do {
            let recognizedText = try await Task.detached(priority: .userInitiated) {
                try NotesView.recognizeText(in: imageData)
            }.value
            let trimmedText = recognizedText.trimmingCharacters(in: .whitespacesAndNewlines)

            guard trimmedText.isEmpty == false else {
                ocrImportErrorMessage = "No text was recognized in the selected image."
                return
            }

            let recognizedNote = Note(content: trimmedText)
            onOCRImportedNote?(recognizedNote)
        } catch {
            ocrImportErrorMessage = error.localizedDescription
        }
    }

    // Presents the camera-capture flow when the device supports it; surfaces a clear error
    // (rather than silently failing) on simulators / iPads without a back camera.
    func presentCameraOCRIfAvailable() {
        guard UIImagePickerController.isSourceTypeAvailable(.camera) else {
            ocrImportErrorMessage = "Camera capture is not available on this device."
            return
        }
        isShowingCameraPicker = true
    }

    // Vision request: accurate level, JA + EN, language correction on. Lines joined by \n
    // so the resulting note preserves the source line breaks.
    nonisolated static func recognizeText(in imageData: Data) throws -> String {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.recognitionLanguages = ["ja-JP", "en-US"]

        let handler = VNImageRequestHandler(data: imageData, options: [:])
        try handler.perform([request])

        let recognizedLines = (request.results ?? []).compactMap { observation in
            observation.topCandidates(1).first?.string.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        .filter { $0.isEmpty == false }

        return recognizedLines.joined(separator: "\n")
    }
}
