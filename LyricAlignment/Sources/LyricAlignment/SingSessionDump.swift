// SingSessionDump.swift
//
// Debug aid for Sing mode: writes what one session fed its grader — every model run's
// log-probabilities and the seeks — to Documents/sing-debug/<timestamp>/, so the Mac replay
// (scripts/sing-replay) can grade the same session again with a changed rule, without the singer.
// emissions.f32 holds the runs' [frames × classes] matrices back to back; session.json holds the
// words, the strictness and the ordered events that index into it.

import Foundation

public final class SingSessionDump {
    private struct Event: Codable {
        let kind: String
        var songSec: Double?
        var offset: Int?
        var frames: Int?
        var frameSec: Double?
        var windowStartSec: Double?
        var windowSec: Double?
        var audioStartSec: Double?
    }
    private struct Word: Codable {
        let id: Int
        let tokens: [Int]
        let startSec: Double
    }
    private struct Document: Codable {
        let passFraction: Double
        let classes: Int
        let noteText: String
        let words: [Word]
        let events: [Event]
        let verdicts: [String: Bool]
    }

    private let directory: URL
    private let emissions: FileHandle
    private let words: [Word]
    private let passFraction: Double
    private let classes: Int
    private let noteText: String
    private var events: [Event] = []
    private var floatsWritten = 0

    /// Opens a dump for a session over `targets`; nil when the folder can't be created.
    public init?(targets: [SingWordTarget], passFraction: Double, classes: Int, noteText: String) {
        let stamp = DateFormatter()
        stamp.dateFormat = "yyyyMMdd-HHmmss"
        guard let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return nil }
        let dir = docs.appendingPathComponent("sing-debug/\(stamp.string(from: Date()))", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let file = dir.appendingPathComponent("emissions.f32")
            guard FileManager.default.createFile(atPath: file.path, contents: nil) else { return nil }
            emissions = try FileHandle(forWritingTo: file)
        } catch {
            return nil
        }
        directory = dir
        words = targets.map { Word(id: $0.id, tokens: $0.tokens, startSec: $0.startSec) }
        self.passFraction = passFraction
        self.classes = classes
        self.noteText = noteText
    }

    /// Records the cursor being placed (the start, a seek, a loop) at `songSec`.
    public func addSeek(songSec: Double) {
        events.append(Event(kind: "seek", songSec: songSec))
    }

    /// Records one model run, exactly as it was merged into the timeline.
    public func addRun(logProbs: [Float], frames: Int, frameSec: Double, windowStartSec: Double, windowSec: Double, audioStartSec: Double) {
        logProbs.withUnsafeBufferPointer { emissions.write(Data(buffer: $0)) }
        events.append(Event(kind: "run", offset: floatsWritten, frames: frames, frameSec: frameSec,
                            windowStartSec: windowStartSec, windowSec: windowSec, audioStartSec: audioStartSec))
        floatsWritten += logProbs.count
    }

    /// Closes the dump and writes session.json with the verdicts the app reached.
    public func finish(verdicts: [Int: Bool]) {
        emissions.closeFile()
        let document = Document(passFraction: passFraction, classes: classes, noteText: noteText, words: words, events: events,
                                verdicts: Dictionary(uniqueKeysWithValues: verdicts.map { (String($0.key), $0.value) }))
        do {
            try JSONEncoder().encode(document).write(to: directory.appendingPathComponent("session.json"))
        } catch {
            NSLog("[Sing] dump write failed: \(error.localizedDescription)")
        }
    }
}
