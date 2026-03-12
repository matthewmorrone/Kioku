import PhotosUI
import SwiftUI
import UIKit
import Vision

// Hosts OCR import controls and text-recognition helpers for the read screen.
extension ReadView {
    // Binds OCR error presentation to whether the read screen currently has an OCR failure message.
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

    // Renders the top-left OCR button that lets the user pick an image to recognize into a new note.
    var ocrImportButton: some View {
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
                        .font(.system(size: 14, weight: .semibold))
                }
            }
            .foregroundStyle(isPerformingOCRImport ? Color.secondary : Color.accentColor)
            .frame(width: 30, height: 30)
            .background(
                Capsule()
                    .fill(Color(.tertiarySystemFill))
            )
        }
        .buttonStyle(.plain)
        .disabled(isPerformingOCRImport)
        .accessibilityLabel("Import Text with OCR")
    }

    // Loads the selected image, runs OCR, and routes the recognized text into a fresh note.
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

    // Runs OCR recognition for raw image data supplied by either the camera or the photo library.
    func importTextFromOCRImageData(_ imageData: Data) async {
        guard isPerformingOCRImport == false else {
            return
        }

        isPerformingOCRImport = true
        defer {
            isPerformingOCRImport = false
            selectedOCRImageItem = nil
        }

        do {
            let recognizedText = try await Task.detached(priority: .userInitiated) {
                try Self.recognizeText(in: imageData)
            }.value
            let trimmedText = recognizedText.trimmingCharacters(in: .whitespacesAndNewlines)

            guard trimmedText.isEmpty == false else {
                ocrImportErrorMessage = "No text was recognized in the selected image."
                return
            }

            createOCRNote(with: trimmedText)
        } catch {
            ocrImportErrorMessage = error.localizedDescription
        }
    }

    // Presents the camera capture flow when the current device supports it.
    func presentCameraOCRIfAvailable() {
        guard UIImagePickerController.isSourceTypeAvailable(.camera) else {
            ocrImportErrorMessage = "Camera capture is not available on this device."
            return
        }

        isShowingCameraPicker = true
    }

    // Creates and selects a new note populated from OCR so the current note remains untouched.
    func createOCRNote(with recognizedText: String) {
        flushPendingNotePersistenceIfNeeded()

        let recognizedNote = Note(content: recognizedText)
        notesStore.addNote(recognizedNote)
        shouldActivateEditModeOnLoad = true
        selectedNote = recognizedNote
    }

    // Runs Vision text recognition against image data and returns joined line output.
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