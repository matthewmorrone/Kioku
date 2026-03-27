import UserNotifications

// Human-readable label for notification authorization status shown in Settings.
extension UNAuthorizationStatus {
    var displayLabel: String {
        switch self {
        case .authorized: return "Allowed"
        case .provisional: return "Provisional"
        case .denied: return "Denied"
        case .notDetermined: return "Not Requested"
        case .ephemeral: return "Ephemeral"
        @unknown default: return "Unknown"
        }
    }
}
