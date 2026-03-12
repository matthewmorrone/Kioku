import Foundation
import UIKit

// Coordinates UIKit camera picker callbacks for the read screen OCR capture sheet.
final class CameraImagePickerCoordinator: NSObject, UINavigationControllerDelegate, UIImagePickerControllerDelegate {
    private let onImagePicked: (Data) -> Void
    private let onCancel: () -> Void

    // Stores the capture and dismissal callbacks used by the camera picker sheet.
    init(onImagePicked: @escaping (Data) -> Void, onCancel: @escaping () -> Void) {
        self.onImagePicked = onImagePicked
        self.onCancel = onCancel
    }

    // Finishes camera capture, extracts image data, and closes the picker.
    func imagePickerController(
        _ picker: UIImagePickerController,
        didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
    ) {
        defer {
            onCancel()
        }

        guard let image = info[.originalImage] as? UIImage else {
            return
        }

        guard let imageData = image.jpegData(compressionQuality: 0.95) else {
            return
        }

        onImagePicked(imageData)
    }

    // Dismisses the camera picker when the user cancels without capturing an image.
    func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
        onCancel()
    }
}