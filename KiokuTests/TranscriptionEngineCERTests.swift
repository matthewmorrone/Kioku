import XCTest
@testable import Kioku

// Diagnostic (not gating) comparison of the three TranscriptionEngine cases against the
// alignment fixtures' known-good lyric text (KiokuTests/Fixtures/alignment/<name>.note.txt,
// which is real kanji/kana Japanese, not romanized — directly comparable to engine output).
// Runs each engine on each fixture's audio, flattens the resulting cues to one string, and
// scores character error rate (Levenshtein distance / reference length) against the note text.
// Answers "does Qwen3-ASR actually beat Whisper-Small / Apple Speech" with a real number instead
// of the asserted-but-unmeasured claim in TranscriptionSettings.swift.
//
// One (engine, fixture) pair per test method, each run as its OWN xcodebuild invocation (see
// below) — vocal-stem isolation is cached on disk (VocalStemCache) so it survives across the
// separate process launches, but the on-device model itself does not: reloading Qwen3-ASR's MLX
// checkpoint 3x in one process (once per fixture, no caching across calls) accumulated memory
// until the app got jetsam-killed mid-run on a physical iPhone, before printing any result, even
// with only one engine in play. One (engine, fixture) pair per process keeps peak memory to a
// single model load. Whisper needs the Small GGML model already downloaded (or this downloads
// it, ~466MB, once). Apple Speech needs prior speech-recognition authorization on the device —
// grant it once via the app's own Transcribe flow if this hangs on a system prompt.
//
// To run (repeat -only-testing for each method separately, NOT together):
//     xcodebuild test -project Kioku.xcodeproj -scheme Kioku \
//         -destination 'platform=iOS,id=<device-udid>' \
//         -only-testing:KiokuTests/TranscriptionEngineCERTests/testQwen3_SutekiDane \
//         -parallel-testing-enabled NO
@MainActor
final class TranscriptionEngineCERTests: XCTestCase {

    // Fixtures compared: three songs already checked in for alignment quality testing, chosen
    // for no reason beyond already existing with real kanji/kana note.txt ground truth.
    private static let fixtureNames = ["suteki-dane", "tsukiiro-chainon", "muunpuraido"]

    // One test method per (engine, fixture) pair — see the file-level comment on why these
    // aren't merged. Each prints a single CER line; combine the nine logs by hand.
    func testQwen3_SutekiDane() async throws { try await run(.qwen3, "suteki-dane") }
    func testQwen3_TsukiiroChainon() async throws { try await run(.qwen3, "tsukiiro-chainon") }
    func testQwen3_Muunpuraido() async throws { try await run(.qwen3, "muunpuraido") }
    func testWhisper_SutekiDane() async throws { try await run(.whisper, "suteki-dane") }
    func testWhisper_TsukiiroChainon() async throws { try await run(.whisper, "tsukiiro-chainon") }
    func testWhisper_Muunpuraido() async throws { try await run(.whisper, "muunpuraido") }
    func testAppleSpeech_SutekiDane() async throws { try await run(.appleSpeech, "suteki-dane") }
    func testAppleSpeech_TsukiiroChainon() async throws { try await run(.appleSpeech, "tsukiiro-chainon") }
    func testAppleSpeech_Muunpuraido() async throws { try await run(.appleSpeech, "muunpuraido") }

    // Runs one engine against one fixture and prints a single CER result line. No XCTAssert
    // thresholds — this is a measurement, not a regression gate.
    private func run(_ engine: TranscriptionEngine, _ fixtureName: String) async throws {
        let bundle = Bundle(for: type(of: self))
        guard let noteURL = bundle.url(forResource: "\(fixtureName).note", withExtension: "txt"),
              let audioURL = requireAudioResource(bundle: bundle, fixtureName: fixtureName) else {
            throw XCTSkip("Fixture \(fixtureName) not in test bundle")
        }
        let referenceText = try flattenedReferenceText(noteURL: noteURL)
        let hypothesis = try await transcribeFlattened(audioURL: audioURL, engine: engine)
        let score = characterErrorRate(hypothesis: hypothesis, reference: referenceText)
        print("""

        [CERTest] \(fixtureName) / \(engine.displayName): \(String(format: "%.1f%%", score * 100)) CER
        [CERTest] REFERENCE (\(referenceText.count) chars): \(referenceText)
        [CERTest] HYPOTHESIS (\(hypothesis.count) chars): \(hypothesis)

        """)
    }

    // MARK: - Harness

    // Locates the fixture's audio file under any of the extensions AlignmentQualityTests accepts.
    private func requireAudioResource(bundle: Bundle, fixtureName: String) -> URL? {
        for ext in ["mp3", "m4a", "wav"] {
            if let url = bundle.url(forResource: "\(fixtureName).audio", withExtension: ext) { return url }
        }
        return nil
    }

    // Reference text for CER: every non-blank note.txt line, whitespace stripped, concatenated in
    // song order. Matches the flattening applied to engine output so the comparison is apples-to-apples.
    private func flattenedReferenceText(noteURL: URL) throws -> String {
        let text = try String(contentsOf: noteURL, encoding: .utf8)
        return text
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.isEmpty == false }
            .joined()
    }

    // Runs one engine over the fixture audio and flattens its cues to a single whitespace-free
    // string, same shape as the reference text. Whisper resolves (downloading if absent) the
    // Small model per TranscriptionSettings.swift's own choice of variant.
    private func transcribeFlattened(audioURL: URL, engine: TranscriptionEngine) async throws -> String {
        let whisperModelURL = engine == .whisper ? try await resolvedSmallWhisperModelURL() : nil
        let cues = try await AudioTranscriptionService.transcribe(
            url: audioURL, engine: engine, isolateVocals: true, whisperModelURL: whisperModelURL
        )
        return cues.map(\.text).joined()
            .components(separatedBy: .whitespacesAndNewlines)
            .joined()
    }

    // Whisper Small's on-disk URL, downloading it first if this device has never used Whisper
    // transcription before.
    private func resolvedSmallWhisperModelURL() async throws -> URL {
        let manager = WhisperModelManager()
        let small = WhisperDownloadableModel.all.first { $0.id == "small" }!
        if let url = manager.resolvedURL(for: .downloaded(small.filename)) { return url }
        await manager.download(small)
        guard let url = manager.resolvedURL(for: .downloaded(small.filename)) else {
            throw XCTSkip("Could not download Whisper Small model for comparison")
        }
        return url
    }

    // Character error rate: Levenshtein distance between hypothesis and reference, divided by
    // reference length. Standard CER definition, matching the one cited in TranscriptionSettings.swift.
    private func characterErrorRate(hypothesis: String, reference: String) -> Double {
        let ref = Array(reference), hyp = Array(hypothesis)
        guard ref.isEmpty == false else { return hyp.isEmpty ? 0 : 1 }
        return Double(editDistance(ref, hyp)) / Double(ref.count)
    }

    // Classic O(n·m) Levenshtein edit distance over two Character arrays.
    private func editDistance(_ a: [Character], _ b: [Character]) -> Int {
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var prev = Array(0...b.count)
        for i in 1...a.count {
            var curr = [Int](repeating: 0, count: b.count + 1)
            curr[0] = i
            for j in 1...b.count {
                curr[j] = a[i - 1] == b[j - 1] ? prev[j - 1] : 1 + Swift.min(prev[j - 1], prev[j], curr[j - 1])
            }
            prev = curr
        }
        return prev[b.count]
    }
}
