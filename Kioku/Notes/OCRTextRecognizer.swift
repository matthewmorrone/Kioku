import Foundation
import Vision

// Vision OCR for Japanese and English text in an image. The single implementation behind the
// Notes photo import, bulk photo import and the image-lookup Shortcut.
nonisolated enum OCRTextRecognizer {
    // Accurate level, JA + EN, language correction on. Lines are joined by \n so a note made from
    // the result keeps the source line breaks.
    static func recognizeText(in imageData: Data) throws -> String {
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
