# Karaoke Vocab-Probe Mode Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking. **Read the referenced existing files before writing UI/integration code** — this plan names the exact symbols to wire into but does not restate their full bodies.

**Goal:** A "Sing" mode in the lyric view that plays the instrumental, records the user singing, and (post-hoc) reports which *content words* they produced (known) vs. missed — surfacing missed words as study candidates.

**Architecture:** Reuse the existing HTDemucs vocal-isolation + Whisper transcription pipeline. Derive the instrumental by subtraction (mix − isolated vocals) and cache it beside the vocal stem. Record the mic to a transient buffer, transcribe it per lyric *section* (runs of lines between ♪/large-gap breaks) via `StemTranscriber.segments(regions:)`, normalize reference content-words and ASR output to kana, and match per-word with order-preserving alignment. Present per-section/per-word results; route missed words to a word list. No pitch, no timing scoring, no SRS auto-mutation.

**Tech Stack:** Swift 6, SwiftUI + UIKit (LyricsView is SwiftUI over CoreText), AVFoundation (`AVAudioEngine` mic capture, `AVAudioSession`), SwiftWhisperAlign (`HTDemucsCoreMLSeparator`, `StemTranscriber`, `VocalStemCache`), the app's segmenter/`Lexicon` (kana readings + POS), `WordsStore`/`WordListsStore`.

**Scope note:** This is one plan spanning four phases; each phase produces working, independently-testable software and should be committed/verified before the next. Phases 1 and 3 are pure logic (unit-testable without a device); Phases 2 and 4 are device/UI and verified on Monoceros.

**Cross-cutting invariants (per docs/INVARIANTS.md):** every function gets an intent comment immediately above it; keep files under the ~800-line warning band (create new files rather than growing `LyricsView.swift`/`AudioPlaybackController.swift`); Swift 6 concurrency (`nonisolated`/`@Sendable` on the pure helpers).

---

## File Structure

**Create:**
- `Kioku/Read/Audio/Karaoke/InstrumentalStem.swift` — derive instrumental = mix − vocals; cache/load beside the vocal stem. Pure, `nonisolated`.
- `Kioku/Read/Audio/Karaoke/KaraokeRecorder.swift` — `AVAudioEngine` mic capture to an in-memory mono Float buffer at 44.1 kHz; permission handling. `@MainActor` control surface.
- `Kioku/Read/Audio/Karaoke/LyricSectioner.swift` — group `[SubtitleCue]` into sections at ♪/large-gap boundaries. Pure, `nonisolated`.
- `Kioku/Read/Audio/Karaoke/VocabProbeScorer.swift` — the scoring core: reference content-words + ASR text → per-word known/missed, per section. Pure, `nonisolated`.
- `Kioku/Read/Audio/Karaoke/KaraokeSession.swift` — `@MainActor @Observable` orchestrator: prepare stem → play instrumental + record → transcribe per section → score → publish results.
- `Kioku/Read/Audio/Karaoke/KaraokeResultsView.swift` — results sheet (overall %, per-section, per-word known/missed, "Add missed to list").
- `KiokuTests/LyricSectionerTests.swift`, `KiokuTests/VocabProbeScorerTests.swift`, `KiokuTests/InstrumentalStemTests.swift`.

**Modify:**
- `SwiftWhisperAlign/Sources/SwiftWhisperAlign/VocalStemCache.swift` — add instrumental-stem load/store/has (parallel to the vocal API) so both stems share the content-keyed cache.
- `Kioku/Read/Audio/LyricsView.swift` — add the "Sing" entry button + present `KaraokeResultsView`; host the `KaraokeSession`.
- `Kioku/Read/Audio/AudioPlaybackController.swift` — allow playing from an explicit instrumental URL (read this file first; if it already plays an arbitrary attachment URL, pass the instrumental URL through instead of adding API).
- `Kioku/Info.plist` (or the target's generated Info settings) — add `NSMicrophoneUsageDescription`.

---

## Phase 1 — Instrumental stem (derive + cache)

**Rationale:** The HTDemucs CoreML model emits only the *vocals* stem (`isolateVocalsMono`). The instrumental is `mix − vocals` in the time domain. Cache it beside the vocal stem so "generate + store both" holds and karaoke playback is instant on repeat.

### Task 1: Instrumental cache API in VocalStemCache

**Files:**
- Modify: `SwiftWhisperAlign/Sources/SwiftWhisperAlign/VocalStemCache.swift`

- [ ] **Step 1: Read** `VocalStemCache.swift` end-to-end. Note the existing private `cacheURL(for:)`/`contentKey`/WAV read-write helpers and the public `hasStem`/`stemWAVURL`/`load`/`store` surface (whatever the exact store/load names are).

- [ ] **Step 2: Add a parallel instrumental surface** mirroring the vocal one, keyed by the same `contentKey` with an `instrumental-` filename prefix (so vocal and instrumental entries never collide and both fall under `maxBytes`/`enforceBudget`). Add:
  - `public static func hasInstrumental(for audioURL: URL) -> Bool`
  - `public static func instrumentalWAVURL(for audioURL: URL) -> URL?`
  - `public static func loadInstrumental(for audioURL: URL) -> [Float]?`
  - `public static func storeInstrumental(_ samples: [Float], for audioURL: URL)`
  Reuse the existing WAV encode/decode + filename helpers; only the prefix differs. Keep `formatVersion` shared so a bump invalidates both.

- [ ] **Step 3: Ensure `enforceBudget()` counts instrumental files too** (it globs the cache dir — confirm the prefix is included; adjust the glob/predicate if it filters by `vocal-` prefix).

- [ ] **Step 4: Build the package** — `swift build` in `SwiftWhisperAlign/` (or app build). Expected: compiles.

- [ ] **Step 5: Commit** — `chore(align): instrumental-stem cache API in VocalStemCache`.

### Task 2: Derive the instrumental (mix − vocals)

**Files:**
- Create: `Kioku/Read/Audio/Karaoke/InstrumentalStem.swift`
- Test: `KiokuTests/InstrumentalStemTests.swift`

- [ ] **Step 1: Write the failing test** — subtraction is exact and length-safe:

```swift
import XCTest
@testable import Kioku

final class InstrumentalStemTests: XCTestCase {
    // Instrumental = mix − vocals, sample-wise, clamped to the shorter length.
    func testSubtractionRemovesVocals() {
        let mix:    [Float] = [1.0, 0.5, -0.3, 0.2]
        let vocals: [Float] = [0.4, 0.5, -0.1, 0.2]
        XCTAssertEqual(InstrumentalStem.subtract(mix: mix, vocals: vocals),
                       [0.6, 0.0, -0.2, 0.0], accuracy: 1e-6)
    }
    // Mismatched lengths clamp to the shorter buffer rather than crashing.
    func testLengthMismatchClamps() {
        XCTAssertEqual(InstrumentalStem.subtract(mix: [1, 1, 1], vocals: [0.5]).count, 1)
    }
}
```
(Add `XCTAssertEqual(_:_:accuracy:)` array overload inline or compare element-wise if no array-accuracy assert exists.)

- [ ] **Step 2: Run test, verify it fails** — `InstrumentalStem` undefined.

- [ ] **Step 3: Implement** `Kioku/Read/Audio/Karaoke/InstrumentalStem.swift`:

```swift
import Foundation

// Derives a karaoke instrumental from a full mix and its isolated vocal stem. The HTDemucs
// CoreML model emits only vocals, so the instrumental is the time-domain difference
// (mix − vocals) at matched sample rate/length. Not a true multi-stem separation, but adequate
// to sing over. nonisolated so it runs on the detached preparation task.
nonisolated enum InstrumentalStem {
    // Sample-wise mix − vocals, clamped to the shorter buffer.
    static func subtract(mix: [Float], vocals: [Float]) -> [Float] {
        let n = min(mix.count, vocals.count)
        var out = [Float](repeating: 0, count: n)
        for i in 0..<n { out[i] = mix[i] - vocals[i] }
        return out
    }
}
```

- [ ] **Step 4: Run test, verify pass.**

- [ ] **Step 5: Commit** — `feat(karaoke): derive instrumental by mix−vocals subtraction`.

### Task 3: `ensureInstrumental(for:)` orchestration

**Files:**
- Modify: `Kioku/Read/Audio/Karaoke/InstrumentalStem.swift`

- [ ] **Step 1: Add** an async producer that returns the instrumental WAV URL, generating + caching on demand. It decodes the attachment to mono mix, gets the vocal stem (from `VocalStemCache` if present, else `HTDemucsCoreMLSeparator.isolateVocalsMono`), subtracts, and stores. Read `CTCForcedAligner.isolatedVocalStem`/existing callers for the exact decode-to-stereo helper and reuse it — do not reinvent audio decoding.

```swift
extension InstrumentalStem {
    // Returns a playable instrumental WAV URL for the attachment, generating + caching it (and
    // the vocal stem, if absent) on first use. `onStage` reports "Separating vocals…" etc.
    static func ensureInstrumentalURL(
        for audioURL: URL,
        onStage: (@Sendable (String) -> Void)? = nil
    ) async throws -> URL {
        if let cached = VocalStemCache.instrumentalWAVURL(for: audioURL) { return cached }
        // 1. decode attachment → stereo [[Float]] (reuse the existing decode helper used by
        //    CTCForcedAligner.isolatedVocalStem — locate and call it here).
        // 2. vocals mono: VocalStemCache.load(for:) ?? HTDemucsCoreMLSeparator.isolateVocalsMono(stereo:)
        //    (store the vocal stem back via the existing vocal store if it was freshly computed).
        // 3. mix mono = average of stereo channels, clamped to vocals length.
        // 4. instrumental = InstrumentalStem.subtract(mix:vocals:)
        // 5. VocalStemCache.storeInstrumental(instrumental, for: audioURL)
        // 6. return VocalStemCache.instrumentalWAVURL(for: audioURL)!
        fatalError("fill in per the numbered steps using the real decode/store symbols")
    }
}
```
Replace the `fatalError` body with the real calls once the decode/store symbols are confirmed by reading `CTCForcedAligner.swift` + the `VocalStemCache` store signature. Add an intent comment above the function (shown).

- [ ] **Step 2: Build.** Expected: compiles. (No unit test — it's I/O orchestration verified on-device in Phase 2.)

- [ ] **Step 3: Commit** — `feat(karaoke): ensureInstrumentalURL generates + caches instrumental on demand`.

---

## Phase 2 — Recording + instrumental playback in LyricsView

### Task 4: Mic permission string

**Files:**
- Modify: target Info settings / `Info.plist`

- [ ] **Step 1: Add** `NSMicrophoneUsageDescription` = "Kioku uses the microphone to score your singing against the lyrics. Audio is analyzed on-device and not saved." Verify the key lands in the built app's `Info.plist`.
- [ ] **Step 2: Commit** — `chore: add microphone usage description`.

### Task 5: KaraokeRecorder (transient mic capture)

**Files:**
- Create: `Kioku/Read/Audio/Karaoke/KaraokeRecorder.swift`

- [ ] **Step 1: Implement** an `@MainActor` recorder that: requests permission (`AVAudioApplication.requestRecordPermission` on iOS 17+); configures `AVAudioSession` category `.playAndRecord` with `.defaultToSpeaker` + `.allowBluetooth`; installs a tap on `engine.inputNode`; accumulates mono Float samples resampled to 44.1 kHz; exposes `start()`, `stop() -> [Float]`, and `elapsed`/`isRecording`. No file is written (transient). Intent comment above each method.
- [ ] **Step 2: Note the bleed contract** in a comment: the app plays the *instrumental* out loud, so the tap captures user voice + instrumental bleed; the instrumental has no lyrics so it doesn't inflate word matches. (Headphones still improve accuracy — surface a soft hint in Phase 4, not a hard gate.)
- [ ] **Step 3: Build.** Expected: compiles.
- [ ] **Step 4: Commit** — `feat(karaoke): transient mic recorder (AVAudioEngine tap)`.

### Task 6: Wire "Sing" entry + instrumental playback

**Files:**
- Modify: `Kioku/Read/Audio/LyricsView.swift`, `Kioku/Read/Audio/AudioPlaybackController.swift`

- [ ] **Step 1: Read** `LyricsView.swift` and `AudioPlaybackController.swift`. Determine how a song attachment URL is currently played. If the controller already plays an arbitrary URL, no API change is needed — Phase 3's session will hand it the instrumental URL. If it only plays the stored attachment, add a minimal `func play(url: URL)` (intent comment) that loads an `AVAudioPlayer`/engine from the given URL, reusing existing playback plumbing.
- [ ] **Step 2: Add** a mic/"Sing" button to the lyric view's control row (near the existing playback controls). It's enabled only when the note has an audio attachment and cues. Tapping it starts a `KaraokeSession` (Phase 3). For this task, stub the tap to call `session.start()` behind a compile guard or a no-op if Phase 3 isn't merged yet.
- [ ] **Step 3: Build + deploy to Monoceros** (deploy skill). Verify: button appears on a song note; tapping prompts mic permission the first time.
- [ ] **Step 4: Commit** — `feat(karaoke): Sing entry button + instrumental playback path in LyricsView`.

---

## Phase 3 — Sectioning + scoring (pure logic, fully unit-tested)

### Task 7: LyricSectioner

**Files:**
- Create: `Kioku/Read/Audio/Karaoke/LyricSectioner.swift`
- Test: `KiokuTests/LyricSectionerTests.swift`

- [ ] **Step 1: Write the failing test:**

```swift
import XCTest
@testable import Kioku

final class LyricSectionerTests: XCTestCase {
    private func cue(_ i: Int, _ s: Int, _ e: Int, _ t: String) -> SubtitleCue {
        SubtitleCue(index: i, startMs: s, endMs: e, text: t)
    }
    // A ♪ cue and a gap over the threshold each start a new section; lyric runs between them group.
    func testSplitsOnMarkerAndGap() {
        let cues = [
            cue(0, 0, 2000, "朽ちた翼"),
            cue(1, 2000, 4000, "並べて"),
            cue(2, 4000, 6000, "♪"),                 // instrumental marker → boundary
            cue(3, 20000, 22000, "夢の続き"),          // 14s gap before this → boundary
        ]
        let sections = LyricSectioner.sections(cues: cues, gapThresholdMs: 10_000)
        XCTAssertEqual(sections.count, 2)
        XCTAssertEqual(sections[0].startMs, 0)
        XCTAssertEqual(sections[0].endMs, 4000)
        XCTAssertEqual(sections[0].lineTexts, ["朽ちた翼", "並べて"])
        XCTAssertEqual(sections[1].lineTexts, ["夢の続き"])
    }
    // A song with no breaks falls back to fixed-size grouping (default 4 lines).
    func testFallbackFixedGrouping() {
        let cues = (0..<9).map { cue($0, $0*2000, $0*2000+1500, "行\($0)") }
        let sections = LyricSectioner.sections(cues: cues, gapThresholdMs: 10_000, fallbackLinesPerSection: 4)
        XCTAssertEqual(sections.count, 3)   // 4 + 4 + 1
    }
}
```

- [ ] **Step 2: Run, verify fail** (`LyricSectioner` undefined).

- [ ] **Step 3: Implement:**

```swift
import Foundation

// Groups subtitle cues into singable sections. Boundaries are ♪/♫ instrumental cues and
// inter-cue gaps exceeding gapThresholdMs (the same signals SubtitleParser/SubtitleEditorTimingTools
// use). When a song has no such breaks, falls back to fixed-size line grouping so scoring still
// has multiple sections. nonisolated: pure over value types, callable off-main.
nonisolated enum LyricSectioner {
    struct Section: Equatable {
        var startMs: Int
        var endMs: Int
        var lineTexts: [String]
    }

    private static func isInstrumentalMarker(_ text: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return t == "♪" || t == "♫" || t.isEmpty
    }

    // Sections from markers + gaps; fixed-size fallback when no boundary is ever hit.
    static func sections(cues: [SubtitleCue], gapThresholdMs: Int, fallbackLinesPerSection: Int = 4) -> [Section] {
        let lyric = cues.filter { isInstrumentalMarker($0.text) == false }
        guard lyric.isEmpty == false else { return [] }

        var sections: [Section] = []
        var current: [SubtitleCue] = []
        var brokeOnce = false

        func flush() {
            guard let first = current.first, let last = current.last else { return }
            sections.append(Section(startMs: first.startMs, endMs: last.endMs,
                                    lineTexts: current.map(\.text)))
            current = []
        }

        var prevEnd: Int? = nil
        var markerBoundaryPending = false
        for cue in cues {
            if isInstrumentalMarker(cue.text) { markerBoundaryPending = true; continue }
            let gap = prevEnd.map { cue.startMs - $0 } ?? 0
            if (markerBoundaryPending || gap >= gapThresholdMs), current.isEmpty == false {
                brokeOnce = true; flush()
            }
            markerBoundaryPending = false
            current.append(cue)
            prevEnd = cue.endMs
        }
        flush()

        if brokeOnce == false && lyric.count > fallbackLinesPerSection {
            return stride(from: 0, to: lyric.count, by: fallbackLinesPerSection).map { start in
                let slice = Array(lyric[start..<min(start + fallbackLinesPerSection, lyric.count)])
                return Section(startMs: slice.first!.startMs, endMs: slice.last!.endMs,
                               lineTexts: slice.map(\.text))
            }
        }
        return sections
    }
}
```

- [ ] **Step 4: Run, verify pass.**
- [ ] **Step 5: Commit** — `feat(karaoke): section lyrics at instrumental/gap boundaries`.

### Task 8: VocabProbeScorer — kana normalization + per-word match

**Files:**
- Create: `Kioku/Read/Audio/Karaoke/VocabProbeScorer.swift`
- Test: `KiokuTests/VocabProbeScorerTests.swift`

**Interface (define once, reused by Phase 4):**

```swift
struct ProbeWord: Equatable { let surface: String; let reading: String; let known: Bool }
struct ProbeSectionResult: Equatable { let index: Int; let words: [ProbeWord]; var knownCount: Int; var total: Int }
```

- [ ] **Step 1: Write the failing test.** The scorer takes (reference content-words with kana readings) + (ASR text kana) and marks each reference word known if its kana appears, in order, within the ASR kana (order-preserving greedy subsequence). Inject a stub kana-normalizer so the test is deterministic without the full segmenter:

```swift
import XCTest
@testable import Kioku

final class VocabProbeScorerTests: XCTestCase {
    // Reference words whose kana appear (in order) in the ASR kana are 'known'; the rest 'missed'.
    func testOrderPreservingWordMatch() {
        let ref = [("翼", "つばさ"), ("並べて", "ならべて"), ("夢", "ゆめ")]
        // Sang the first and third but not the middle:
        let asrKana = "つばさゆめ"
        let result = VocabProbeScorer.scoreSection(index: 0, referenceWords: ref, asrKana: asrKana)
        XCTAssertEqual(result.words.map(\.known), [true, false, true])
        XCTAssertEqual(result.knownCount, 2)
        XCTAssertEqual(result.total, 3)
    }
    // A word counts as known only if ALL its mora are covered contiguously in order.
    func testPartialReadingIsMissed() {
        let ref = [("並べて", "ならべて")]
        let result = VocabProbeScorer.scoreSection(index: 0, referenceWords: ref, asrKana: "ならXXて")
        XCTAssertEqual(result.words.map(\.known), [false])
    }
}
```

- [ ] **Step 2: Run, verify fail.**

- [ ] **Step 3: Implement the matcher** (pure kana logic; the segmenter integration lives in Task 9):

```swift
import Foundation

// Scores one lyric section for the vocab probe: which reference content-words the singer produced.
// Matching is on KANA readings (robust to ASR kanji/kana script drift): walk the ASR kana with a
// cursor; a reference word is 'known' when its full reading is found as a contiguous run at/after
// the cursor, and the cursor advances past it (order-preserving so a chorus repeat can't double-credit
// within a section). nonisolated: pure, callable off-main.
nonisolated enum VocabProbeScorer {
    static func scoreSection(index: Int, referenceWords: [(surface: String, reading: String)], asrKana: String) -> ProbeSectionResult {
        let hay = Array(asrKana)
        var cursor = 0
        var words: [ProbeWord] = []
        for (surface, reading) in referenceWords {
            let needle = Array(reading)
            let found = firstContiguousRange(of: needle, in: hay, from: cursor)
            if let end = found { cursor = end }
            words.append(ProbeWord(surface: surface, reading: reading, known: found != nil))
        }
        let knownCount = words.filter(\.known).count
        return ProbeSectionResult(index: index, words: words, knownCount: knownCount, total: words.count)
    }

    // Returns the end index (exclusive) of the first contiguous occurrence of needle in hay at/after `from`.
    private static func firstContiguousRange(of needle: [Character], in hay: [Character], from: Int) -> Int? {
        guard needle.isEmpty == false, hay.count - from >= needle.count else { return nil }
        var i = from
        while i <= hay.count - needle.count {
            if Array(hay[i..<i+needle.count]) == needle { return i + needle.count }
            i += 1
        }
        return nil
    }
}
```

- [ ] **Step 4: Run, verify pass.**
- [ ] **Step 5: Commit** — `feat(karaoke): kana-mora per-word vocab scorer`.

### Task 9: Reference extraction (content words + readings) & ASR→kana

**Files:**
- Modify: `Kioku/Read/Audio/Karaoke/VocabProbeScorer.swift`

- [ ] **Step 1: Add** two adapters that bridge to the app's segmenter (read `ReadView+Segmentation`/`Lexicon` for the exact segment + reading + POS APIs already used by tap-to-save so this REUSES that filtering, per the "content words only" decision — do not write a new POS filter):
  - `static func referenceContentWords(sectionLineTexts: [String], segmenter:) -> [(surface: String, reading: String)]` — segment each line, keep content POS (noun/verb/adj/adv), attach kana reading (prefer `Lexicon`/furigana reading; katakana→hiragana fold via `KanaNormalizer`).
  - `static func toKana(_ asrText: String, segmenter:) -> String` — segment ASR output, concatenate kana readings, fold to hiragana. (ASR emits mixed script; normalizing through the segmenter yields comparable kana.)
- [ ] **Step 2: Add a test** with a real (or lightweight injected) segmenter fixture confirming a known line yields the expected content-word readings and that particles are dropped. If a segmenter fixture isn't readily constructible in tests, gate this behind the existing segmenter-integration test pattern (see `SegmenterIntegrationTests`).
- [ ] **Step 3: Build + test.**
- [ ] **Step 4: Commit** — `feat(karaoke): content-word extraction + ASR kana normalization`.

---

## Phase 4 — Session orchestration + results UI

### Task 10: KaraokeSession orchestrator

**Files:**
- Create: `Kioku/Read/Audio/Karaoke/KaraokeSession.swift`

- [ ] **Step 1: Implement** an `@MainActor @Observable` (or `ObservableObject`) session with states `idle → preparing → countdown → singing → scoring → results(‌[ProbeSectionResult]) / failed(String)`. Flow:
  1. `preparing`: `InstrumentalStem.ensureInstrumentalURL(for: attachmentURL, onStage:)`.
  2. `countdown`: 3-2-1.
  3. `singing`: `AudioPlaybackController.play(url: instrumentalURL)` + `KaraokeRecorder.start()`; stop both at track end (or user stop).
  4. `scoring` (off-main): recording `[Float]` → `StemTranscriber.segments(stem: recording, regions: sectionWindows, cacheIdentity: nil)` where `sectionWindows` are `LyricSectioner` section `[start,end]` in seconds; bucket returned segments into their section by midpoint; for each section, `VocabProbeScorer.toKana` the bucketed ASR text and `scoreSection` against `referenceContentWords`.
  5. `results`: publish `[ProbeSectionResult]`; dedup a flattened **missed** list by `(surface, reading)` across sections.
- [ ] **Step 2:** Intent comment on each method; keep the file focused (extract the scoring pipeline into a `nonisolated` helper if it grows).
- [ ] **Step 3: Build.**
- [ ] **Step 4: Commit** — `feat(karaoke): session orchestrator (prepare → record → score)`.

### Task 11: Results UI + save missed to a list

**Files:**
- Create: `Kioku/Read/Audio/Karaoke/KaraokeResultsView.swift`
- Modify: `Kioku/Read/Audio/LyricsView.swift`

- [ ] **Step 1: Implement** `KaraokeResultsView`: overall % (known/total across sections), a per-section list (each with its known/total and a disclosure of its words colored known=green / missed=secondary), and a prominent **"Add N missed words to…"** action opening the existing list picker (reuse `WordListsStore` + the same add path CSV import/batch uses; do NOT touch `ReviewStore`). Include a one-line soft hint: "Headphones improve accuracy."
- [ ] **Step 2: Present** it from `LyricsView` on `session.state == .results`. Wire the "Sing" button (Task 6) to drive the real `KaraokeSession`.
- [ ] **Step 3: Build + deploy to Monoceros.** Manual verification (see below).
- [ ] **Step 4: Commit** — `feat(karaoke): results sheet + save missed words to list`.

---

## Manual verification (on Monoceros, after Phase 4)

- [ ] Open a song note with lyrics; tap **Sing**. First run: mic permission prompt; instrumental "Preparing…" then countdown.
- [ ] Instrumental plays with **no original vocals**; lyrics scroll as normal.
- [ ] Sing some lines, skip others; at the end a results sheet shows an overall %, per-section breakdown, and a missed-words list dominated by content words (no は/を/の).
- [ ] "Add missed to list" adds exactly the missed content words (deduped) to the chosen list; `ReviewStore` is untouched.
- [ ] Re-entering Sing on the same song skips "Preparing" (instrumental cached).
- [ ] A song never aligned before still works (generates the stem on demand).

## Self-review notes (coverage)

- Words-only / known-vs-unknown → Tasks 8–9, 11. Instrumental playback + both-stems cache → Tasks 1–3. Per-section → Task 7. Post-hoc → Task 10 step 4. Kana/mora → Task 8. Content-words-only → Task 9. LyricsView entry → Tasks 6, 11. Transient recording → Task 5. Generate-on-demand → Task 3/10. Missed→save, no SRS → Task 11.
- **Deferred / explicitly out of scope for v1:** pitch/timing scoring; live per-section feedback (post-hoc only); keep-for-playback recordings; SRS auto-mutation; a Learn-tab entry.
- **Known risks to watch:** HTDemucs OOM on first on-demand generation (reuse the existing autoreleasepool/jetsam mitigations from `HTDemucsCoreMLSeparator`); mic I/O latency (~150–200ms) is negligible at section granularity; ASR false-negatives make "missed" a soft signal (hence save-don't-penalize).
