import SwiftUI
import UIKit

// Renders the camera capture sheet used by the read screen OCR importer.
struct CameraImagePicker: UIViewControllerRepresentable {
    let onImagePicked: (Data) -> Void
    @Environment(\.dismiss) private var dismiss

    // Builds the UIKit camera picker that captures a still image for OCR import.
    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.cameraCaptureMode = .photo
        picker.allowsEditing = false
        picker.delegate = context.coordinator
        return picker
    }

    // Keeps the camera picker configuration stable while the sheet remains visible.
    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {
    }

    // Connects the camera picker delegate callbacks back into SwiftUI sheet control.
    func makeCoordinator() -> CameraImagePickerCoordinator {
        CameraImagePickerCoordinator(onImagePicked: onImagePicked, onCancel: {
            dismiss()
        })
    }
}