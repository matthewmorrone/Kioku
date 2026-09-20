import Foundation
// Harness-only stand-in: the CLI always opens the database by explicit URL.
enum DictionaryDownloadManager {
    static var isInstalled: Bool { false }
    static var installedDatabaseURL: URL { URL(fileURLWithPath: "/dev/null") }
}
