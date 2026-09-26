import Foundation

// Replays the app's post-model aligner (CTCAlignmentCore, compiled from this repo's
// SwiftWhisperAlign sources by ../build.sh) on what the phone dumped for one song: stem and mix
// emissions, the romaji, and the cached vocal stem decoded to 44.1 kHz f32 (see ../pull.sh).
//
// Usage: replay <dump dir> <stem key> <note.txt> [--phone <cues.json>] [--no-deaf] [--deaf=THR,MINRUN] [--tokens]
//   --phone     mark each line = / ≠ against the phone's saved cue start (within 10 ms)
//   --no-deaf   turn deaf fill off (it is on in the app); --deaf=… overrides its two thresholds
//   --tokens    also print the first four lines' checkpoint times
// Output: one line per lyric line, "start end [phone …] text", after the aligner's breadcrumbs.

let args = CommandLine.arguments
guard args.count >= 4 else {
    FileHandle.standardError.write("usage: replay <dump dir> <stem key> <note.txt> [--phone cues.json] [--no-deaf] [--deaf=THR,MINRUN] [--tokens]\n".data(using: .utf8)!)
    exit(2)
}
let dir = args[1], key = args[2]

// Reads a raw little-endian Float32 file.
func floats(_ path: String) -> [Float] {
    guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else {
        FileHandle.standardError.write("missing \(path)\n".data(using: .utf8)!); exit(1)
    }
    return data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
}

// Loads an emission dump as the aligner's matrix (29 classes, 32 s / 1599 frames per window).
func matrix(_ path: String) -> MMSEmissions.Matrix {
    let v = floats(path)
    return MMSEmissions.Matrix(frames: v.count / MMSEmissions.classes, frameSec: 32.0 / 1599.0, values: v)
}

let lines = (try? String(contentsOfFile: args[3], encoding: .utf8))?.components(separatedBy: "\n")
    .map { $0.trimmingCharacters(in: .whitespaces) }.filter { $0.isEmpty == false } ?? []
let romaji = (try? String(contentsOfFile: "\(dir)/\(key).romaji.txt", encoding: .utf8))?.components(separatedBy: "\n") ?? []
guard romaji.count == lines.count else {
    FileHandle.standardError.write("romaji has \(romaji.count) lines, note has \(lines.count) — use the note the phone aligned\n".data(using: .utf8)!)
    exit(1)
}
let spans = romaji.map { $0.split(separator: "|").map { RomanizedSpan(romaji: String($0), charOffsetUTF16: 0, charLengthUTF16: 1) } }

if args.contains("--no-deaf") { EmissionDropoutFill.isDeafFillEnabled = false }
if let arg = args.first(where: { $0.hasPrefix("--deaf=") }) {
    let v = arg.dropFirst(7).split(separator: ",").compactMap { Double($0) }
    if v.count == 2 { EmissionDropoutFill.deafThreshold = Float(v[0]); EmissionDropoutFill.deafMinRunSec = v[1] }
}

let out: (lines: [AlignedLine], lineTokens: [[AlignedToken]])
do {
    out = try CTCAlignmentCore.align(stem: matrix("\(dir)/\(key).emissions.f32"), mix: matrix("\(dir)/\(key).mix-emissions.f32"),
                                     vocalMono: floats("\(dir)/\(key).stem44.f32"), lines: lines, romanization: spans,
                                     log: { print("  [\($0)]") })
} catch {
    FileHandle.standardError.write("alignment failed: \(error.localizedDescription)\n".data(using: .utf8)!)
    exit(1)
}

var phone: [String: [Double]] = [:]
if let i = args.firstIndex(of: "--phone"), i + 1 < args.count,
   let data = try? Data(contentsOf: URL(fileURLWithPath: args[i + 1])),
   let cues = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
    for c in cues { if let t = c["text"] as? String, let s = c["startMs"] as? Int { phone[t, default: []].append(Double(s) / 1000) } }
}
var used: [String: Int] = [:]
for (li, l) in out.lines.enumerated() {
    let k = used[l.text, default: 0]; used[l.text] = k + 1
    let p = phone[l.text].flatMap { k < $0.count ? $0[k] : nil }
    if args.contains("--tokens"), li < 4 {
        print("        tokens:", out.lineTokens[li].map { String(format: "%.2f", $0.start) }.joined(separator: " "))
    }
    let mark = p.map { String(format: "phone %7.2f %@", $0, abs($0 - l.start) < 0.011 ? "=" : "≠") } ?? ""
    print(String(format: "%8.2f %8.2f  %@  %@", l.start, l.end, mark, l.text))
}
