import Foundation

// One selected photo as it arrives at bulk OCR: its bytes, or why they couldn't be loaded.
// Pure data.
nonisolated enum BulkOCRInput: Equatable, Sendable {
    case image(Data)
    case unreadable(String)
}

// What OCR made of one photo. Pure data.
nonisolated enum BulkOCROutcome: Equatable, Sendable {
    case recognized(String)
    case noText
    case failed(String)
}
