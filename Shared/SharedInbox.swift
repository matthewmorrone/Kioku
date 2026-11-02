import Foundation

// The hand-off between the share extension and the app: the extension drops one JSON file per
// shared item into a folder in the App Group container, and the app picks them up (and deletes
// them) when it opens. Compiled into BOTH the app and the share extension, so it is plain Foundation
// with no app dependencies. Nothing here touches notes; the app turns items into notes itself, so
// only one process ever writes the notes store.
nonisolated enum SharedInbox {
    static let groupIdentifier = "group.matthewmorrone.Kioku"
    private static let folderName = "ShareInbox"

    // The inbox folder inside the App Group container, created on demand. nil when the group isn't
    // available (an unsigned build), in which case sharing reports an error instead of losing data.
    static func defaultDirectory(fileManager: FileManager = .default) -> URL? {
        guard let container = fileManager.containerURL(forSecurityApplicationGroupIdentifier: groupIdentifier) else {
            return nil
        }
        return container.appendingPathComponent(folderName, isDirectory: true)
    }

    // Writes one item as its own file, so two shares can never overwrite each other.
    static func enqueue(_ item: SharedInboxItem, in directory: URL, fileManager: FileManager = .default) throws {
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(item)
        try data.write(to: fileURL(for: item, in: directory), options: .atomic)
    }

    // Everything read from the inbox, plus a description of each file that couldn't be read or
    // removed. `problems` is returned (not logged here) because the extension has no app logger.
    struct DrainResult: Equatable {
        var items: [SharedInboxItem] = []
        var problems: [String] = []
    }

    // Returns every waiting item, oldest first, and removes each file once it has been read. A file
    // that can't be decoded is reported and removed so it can't be retried on every launch.
    static func drain(from directory: URL, fileManager: FileManager = .default) -> DrainResult {
        var result = DrainResult()
        guard fileManager.fileExists(atPath: directory.path) else { return result }
        let urls: [URL]
        do {
            urls = try fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
                .filter { $0.pathExtension == "json" }
        } catch {
            result.problems.append("could not list inbox: \(error)")
            return result
        }
        for url in urls {
            do {
                result.items.append(try JSONDecoder().decode(SharedInboxItem.self, from: try Data(contentsOf: url)))
            } catch {
                result.problems.append("dropping unreadable item \(url.lastPathComponent): \(error)")
            }
            do {
                try fileManager.removeItem(at: url)
            } catch {
                result.problems.append("could not remove \(url.lastPathComponent): \(error)")
            }
        }
        result.items.sort { $0.createdAt < $1.createdAt }
        return result
    }

    private static func fileURL(for item: SharedInboxItem, in directory: URL) -> URL {
        directory.appendingPathComponent("\(item.id.uuidString).json", isDirectory: false)
    }
}
