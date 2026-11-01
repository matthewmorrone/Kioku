import PhotosUI
import SwiftUI

// Attaches the multi-photo OCR picker and its result alert to the Notes tab as one modifier, so
// NotesView's long modifier chain stays within what the type-checker can resolve.
struct BulkPhotoPickerModifier: ViewModifier {
    @Binding var isPickerPresented: Bool
    @Binding var selection: [PhotosPickerItem]
    @Binding var summary: String
    // Runs OCR over the picked photos.
    let onPicked: ([PhotosPickerItem]) -> Void

    static let maxPhotos = 20

    // Wraps the content with the picker, the selection observer, and the summary alert.
    func body(content: Content) -> some View {
        content
            .photosPicker(
                isPresented: $isPickerPresented,
                selection: $selection,
                maxSelectionCount: Self.maxPhotos,
                matching: .images
            )
            .onChange(of: selection) { _, items in
                guard items.isEmpty == false else { return }
                onPicked(items)
            }
            .alert("Photo Import", isPresented: Binding(
                get: { summary.isEmpty == false },
                set: { if $0 == false { summary = "" } }
            )) {
                Button("OK", role: .cancel) { summary = "" }
            } message: {
                Text(summary)
            }
    }
}
