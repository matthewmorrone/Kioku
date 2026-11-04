// Replays a recorded Sing session (Documents/sing-debug/<stamp>/, see SingSessionDump) through the
// shipped in-order grader and prints each word's verdict next to the one the phone reached.
// Usage: sing-replay <dir> [--against <other dir>] [--lookahead N] [--frames-per-token N]
//                    [--confirm N] [--pass F] [--mass N] [--stall N] [--gap N] [--decoy] [--decoy-tokens] [--quiet]
//   --decoy grades the session's audio against its lyrics in reverse order: whatever it hears is junk.
//   --against feeds this session's words the audio of ANOTHER session: every word it hears is a
//   false positive, so it measures how easily a rule is fooled.
import Foundation

struct Event: Codable { let kind: String; var songSec: Double?; var offset: Int?; var frames: Int?; var frameSec: Double?
    var windowStartSec: Double?; var windowSec: Double?; var audioStartSec: Double? }
struct Word: Codable { let id: Int; let tokens: [Int]; let startSec: Double }
struct Session: Codable { let passFraction: Double; let classes: Int; let noteText: String; let words: [Word]; let events: [Event]; let verdicts: [String: Bool] }

func load(_ path: String) -> (Session, [Float]) {
    let dir = URL(fileURLWithPath: path)
    let session = try! JSONDecoder().decode(Session.self, from: Data(contentsOf: dir.appendingPathComponent("session.json")))
    let data = try! Data(contentsOf: dir.appendingPathComponent("emissions.f32"))
    let floats = data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
    return (session, floats)
}

var args = Array(CommandLine.arguments.dropFirst())
guard let dir = args.first, dir.hasPrefix("--") == false else { print("usage: sing-replay <dir> [options]"); exit(2) }
args.removeFirst()
func option(_ name: String) -> String? { args.firstIndex(of: name).flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil } }

let (own, ownFloats) = load(dir)
let (audioSession, floats) = option("--against").map(load) ?? (own, ownFloats)
let targets = (args.contains("--decoy") ? Array(own.words.reversed()) : own.words).map {
    SingWordTarget(id: $0.id, tokens: args.contains("--decoy-tokens") ? $0.tokens.reversed() : $0.tokens, startSec: $0.startSec)
}
let timeline = SingEmissionTimeline()
let grader = SingInOrderGrader(targets: targets, passFraction: option("--pass").flatMap(Double.init) ?? own.passFraction, timeline: timeline)
if let v = option("--lookahead").flatMap(Int.init) { grader.maximumLookahead = v }
if let v = option("--frames-per-token").flatMap(Int.init) { grader.framesPerToken = v }
if let v = option("--confirm").flatMap(Int.init) { grader.heardToConfirmMiss = v }

if let v = option("--mass").flatMap(Int.init) { SingPhonemeScorer.massFrames = v }
if let v = option("--stall").flatMap(Int.init) { grader.stallSounds = v }
if let v = option("--gap").flatMap(Int.init) { SingPhonemeScorer.maxGapFrames = v }
var verdicts: [Int: SingVerdict] = [:]
for event in audioSession.events {
    if event.kind == "seek" {
        for id in grader.seek(toSongSec: event.songSec ?? 0) { verdicts[id] = nil }
    } else if let offset = event.offset, let frames = event.frames {
        timeline.merge(logProbs: Array(floats[offset..<(offset + frames * audioSession.classes)]), frames: frames,
                       frameSec: event.frameSec ?? 0.02, classes: audioSession.classes, windowStartSec: event.windowStartSec ?? 0,
                       windowSec: event.windowSec ?? 4, audioStartSec: event.audioStartSec ?? 0)
        let before = grader.cursor
        for v in grader.grade() { verdicts[v.id] = v }
        if let from = option("--trace").flatMap(Int.init), grader.cursor >= from, grader.cursor == before, grader.cursor < targets.count,
           let earliest = timeline.earliestSec,
           let slice = timeline.slice(fromSec: max(earliest, grader.anchorSec ?? earliest), toSec: timeline.coveredUntilSec) {
            let words = Array(targets[grader.cursor..<min(targets.count, grader.cursor + grader.maximumLookahead)])
            let scores = SingPhonemeScorer.wordScores(words: words.map(\.tokens), logProbs: slice.values, classes: audioSession.classes,
                                                      firstFrame: 0, lastFrame: slice.frames - 1)
            print("run@\(String(format: "%.1f", timeline.coveredUntilSec)) cursor \(grader.cursor) frames \(slice.frames) scores " +
                  scores.map { String(format: "%.2f", $0.score) }.joined(separator: " "))
        }
    }
}

let note = own.noteText as NSString
var heardCount = 0, missedCount = 0, agree = 0, compared = 0
for word in own.words {
    let phone = own.verdicts[String(word.id)]
    let mine = verdicts[word.id]
    if let mine { if mine.isHeard { heardCount += 1 } else { missedCount += 1 } }
    if let phone, let mine { compared += 1; if phone == mine.isHeard { agree += 1 } }
    if args.contains("--quiet") { continue }
    let surface = note.substring(with: NSRange(location: word.id, length: min(6, note.length - word.id))).replacingOccurrences(of: "\n", with: "⏎")
    let flag = phone == nil || mine == nil ? "?" : (phone == mine!.isHeard ? "=" : "≠")
    let tag = mine.map { $0.isHeard ? "heard " : "missed" } ?? "  -   "
    print("\(flag) \(tag) \(String(format: "%.2f", mine?.score ?? 0)) \(surface.padding(toLength: 8, withPad: " ", startingAt: 0)) heard「\(mine?.heard ?? "")」phone:\(phone.map { $0 ? "heard" : "missed" } ?? "-")")
}
print("replay: \(heardCount) heard, \(missedCount) missed, \(own.words.count - heardCount - missedCount) ungraded of \(own.words.count) words" +
      (compared > 0 ? "; agrees with the phone on \(agree)/\(compared)" : ""))
