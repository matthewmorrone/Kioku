import Foundation

// Describes one structural backup defect in terms suitable for the import alert.
nonisolated enum AppBackupValidationError: LocalizedError {
    case invalid(String)

    // Explains why the selected backup cannot be restored.
    var errorDescription: String? {
        switch self {
        case .invalid(let reason):
            return "Invalid app backup: \(reason)"
        }
    }
}
