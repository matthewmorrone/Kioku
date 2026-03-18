import Foundation
import Observation

// Represents the resolved URL for a Whisper model, regardless of its origin.
enum WhisperModelSource: Equatable {
    case bundled
    case downloaded(String) // filename in app support
    case userFile(URL)

    // Human-readable label shown in the UI.
    var displayName: String {
        switch self {
            case .bundled: return "Tiny (Built-in)"
            case .downloaded(let name): return name
            case .userFile(let url): return url.lastPathComponent
        }
    }
}

// A downloadable model entry — name, file, parameter count, and approximate file size for display.
struct WhisperDownloadableModel: Identifiable {
    let id: String
    let displayName: String
    let filename: String
    let parameters: String // e.g. "39M"
    let sizeMB: Int        // approximate download size

    // Pre-converted GGML binaries from huggingface.co/ggerganov/whisper.cpp.
    static let all: [WhisperDownloadableModel] = [
        WhisperDownloadableModel(id: "tiny",   displayName: "Tiny",   filename: "ggml-tiny.bin",   parameters: "39M",  sizeMB: 75),
        WhisperDownloadableModel(id: "base",   displayName: "Base",   filename: "ggml-base.bin",   parameters: "74M",  sizeMB: 142),
        WhisperDownloadableModel(id: "small",  displayName: "Small",  filename: "ggml-small.bin",  parameters: "244M", sizeMB: 466),
        WhisperDownloadableModel(id: "medium", displayName: "Medium", filename: "ggml-medium.bin", parameters: "769M", sizeMB: 1500),
    ]

    var remoteURL: URL {
        URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/\(filename)")!
    }
}

// Manages the set of available Whisper model sources: bundled tiny, downloaded models, user files.
// Owns downloading and deletion of models stored in the app support directory.
@Observable
final class WhisperModelManager {
    // Downloaded model filenames present in the app support models directory.
    private(set) var downloadedModels: [String] = []

    // Per-model download progress keyed by filename. Non-nil means download is active.
    private(set) var downloadProgress: [String: Double] = [:]

    // Per-model download error message keyed by filename.
    private(set) var downloadErrors: [String: String] = [:]

    // True when the tiny model is bundled in the app bundle.
    var hasBundledTiny: Bool {
        let url = Bundle.main.url(forResource: "ggml-tiny", withExtension: "bin")
        print("[Whisper] hasBundledTiny: \(url?.path ?? "NOT FOUND")")
        return url != nil
    }

    // Directory where downloaded models are stored.
    static var modelsDirectory: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return support.appendingPathComponent("WhisperModels", isDirectory: true)
    }

    init() {
        refreshDownloadedModels()
    }

    // Returns the resolved file URL for a given source, or nil if unavailable.
    func resolvedURL(for source: WhisperModelSource) -> URL? {
        switch source {
        case .bundled:
            return Bundle.main.url(forResource: "ggml-tiny", withExtension: "bin")
        case .downloaded(let filename):
            let url = Self.modelsDirectory.appendingPathComponent(filename)
            return FileManager.default.fileExists(atPath: url.path) ? url : nil
        case .userFile(let url):
            return url
        }
    }

    // Scans the models directory and updates the downloadedModels list.
    func refreshDownloadedModels() {
        let dir = Self.modelsDirectory
        guard let contents = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else {
            downloadedModels = []
            return
        }
        downloadedModels = contents.filter { $0.hasSuffix(".bin") }.sorted()
    }

    // Downloads the given model to the app support models directory with progress reporting.
    // Uses URLSession downloadTask (writes to disk directly) with a delegate for progress;
    // avoids the byte-by-byte bytes(from:) API which is far too slow for 75–1500 MB files.
    func download(_ model: WhisperDownloadableModel) async {
        let filename = model.filename
        guard downloadProgress[filename] == nil else {
            print("[Whisper] download(\(filename)): already in flight, skipping")
            return
        }

        await MainActor.run {
            downloadProgress[filename] = 0
            downloadErrors.removeValue(forKey: filename)
        }

        do {
            let dir = Self.modelsDirectory
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let destination = dir.appendingPathComponent(filename)

            print("[Whisper] download(\(filename)): starting from \(model.remoteURL)")

            let delegate = WhisperDownloadProgressDelegate { [weak self] progress in
                guard let self else { return }
                Task { @MainActor in self.downloadProgress[filename] = progress }
            }

            let (tempURL, response) = try await URLSession.shared.download(from: model.remoteURL, delegate: delegate)

            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            print("[Whisper] download(\(filename)): HTTP \(status), temp file at \(tempURL.path)")

            guard status == 200 else {
                throw WhisperDownloadError.httpError(status)
            }

            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.moveItem(at: tempURL, to: destination)
            print("[Whisper] download(\(filename)): moved to \(destination.path)")

            await MainActor.run {
                downloadProgress.removeValue(forKey: filename)
                refreshDownloadedModels()
            }
        } catch {
            print("[Whisper] download(\(filename)): failed — \(error)")
            await MainActor.run {
                downloadProgress.removeValue(forKey: filename)
                downloadErrors[filename] = error.localizedDescription
            }
        }
    }

    // Cancels an in-progress download — removes partial state. The caller must cancel the Task.
    func cancelDownload(filename: String) {
        print("[Whisper] cancelDownload(\(filename))")
        downloadProgress.removeValue(forKey: filename)
        downloadErrors.removeValue(forKey: filename)
    }

    // Deletes a downloaded model from disk.
    func deleteModel(filename: String) throws {
        let url = Self.modelsDirectory.appendingPathComponent(filename)
        try FileManager.default.removeItem(at: url)
        refreshDownloadedModels()
    }
}

// Relays URLSession download progress to a closure, following redirects transparently.
private final class WhisperDownloadProgressDelegate: NSObject, URLSessionDownloadDelegate {
    private let onProgress: (Double) -> Void

    init(onProgress: @escaping (Double) -> Void) {
        self.onProgress = onProgress
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard totalBytesExpectedToWrite > 0 else {
            print("[Whisper] progress: totalBytesExpectedToWrite unknown (redirect response?)")
            return
        }
        let progress = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
        print("[Whisper] progress: \(Int(progress * 100))% (\(totalBytesWritten)/\(totalBytesExpectedToWrite) bytes)")
        onProgress(progress)
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        // File move is handled by the async download(from:delegate:) continuation.
        print("[Whisper] delegate didFinishDownloadingTo: \(location.path)")
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            print("[Whisper] delegate didCompleteWithError: \(error)")
        }
    }
}

// Errors produced during model downloading.
private enum WhisperDownloadError: LocalizedError {
    case httpError(Int)

    var errorDescription: String? {
        switch self {
        case .httpError(let code): return "Server returned HTTP \(code)."
        }
    }
}
