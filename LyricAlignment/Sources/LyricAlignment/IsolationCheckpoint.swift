// IsolationCheckpoint.swift
//
// Partial vocal-isolation progress saved to disk while the app is in the background, so a run iOS
// kills in the background resumes from where it was instead of from zero. Holds the separator's
// overlap-add accumulators and the next chunk's start, keyed by the audio's content identity
// (VocalStemCache.identityKey). Caches, so the system may purge it; a missing file just means a
// fresh start.

import Foundation
import os

private let logger = Logger(subsystem: "matthewmorrone.LyricAlignment", category: "IsolationCheckpoint")

enum IsolationCheckpoint {
    // Caches/IsolationProgress/<key>.bin, creating the folder on demand.
    private static func url(for key: String) -> URL? {
        guard let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else { return nil }
        let dir = caches.appendingPathComponent("IsolationProgress", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent(key + ".bin")
    }

    // Writes the accumulators and the next chunk's start sample. Failure only costs the resume.
    static func save(key: String, nextStart: Int, acc: [Float], wacc: [Float]) {
        guard let url = url(for: key), acc.count == wacc.count else { return }
        var data = Data()
        var header: [Int64] = [Int64(acc.count), Int64(nextStart)]
        data.append(Data(bytes: &header, count: header.count * MemoryLayout<Int64>.size))
        acc.withUnsafeBytes { data.append(contentsOf: $0) }
        wacc.withUnsafeBytes { data.append(contentsOf: $0) }
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            logger.error("isolation checkpoint write failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    // The saved progress for `key` when it was taken over audio of exactly `length` samples.
    static func load(key: String, length: Int) -> (nextStart: Int, acc: [Float], wacc: [Float])? {
        guard let url = url(for: key), let data = try? Data(contentsOf: url) else { return nil }
        let headerSize = 2 * MemoryLayout<Int64>.size
        let bodySize = 2 * length * MemoryLayout<Float>.size
        guard data.count == headerSize + bodySize else { return nil }
        let header = data.prefix(headerSize).withUnsafeBytes { Array($0.bindMemory(to: Int64.self)) }
        guard header[0] == Int64(length), header[1] > 0, header[1] < Int64(length) else { return nil }
        let floats = data.dropFirst(headerSize).withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        return (Int(header[1]), Array(floats[0..<length]), Array(floats[length...]))
    }

    // Removes the saved progress once the isolation finishes or is cancelled.
    static func delete(key: String) {
        guard let url = url(for: key) else { return }
        try? FileManager.default.removeItem(at: url)
    }
}
