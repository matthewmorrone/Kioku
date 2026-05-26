# Library Candidates for Future Integration

Libraries evaluated but not yet installed. Revisit when the relevant feature area is being built.

---

## Installed Libraries

What we actually link.

### SwiftWhisper (exPHAT) ✅
- **Repo:** https://github.com/exPHAT/SwiftWhisper
- **Vendored at:** `Packages/SwiftWhisper/`
- **Why installed:** On-device Whisper transcription. Bundles whisper.cpp with no transitive dependencies, avoiding the swift-transformers ↔ swift-tokenizers conflict that WhisperKit caused with AzooKeyKanaKanjiConverter.

### SwiftWhisperAlign (local) ✅
- **Location:** `SwiftWhisperAlign/` (sibling SPM package)
- **Why installed:** Per-word audio alignment, subtitle reconciliation, lyric alignment. Wraps SwiftWhisper output into timed markers consumed by the read screen.

### MeCab (matthewmorrone fork) ✅
- **Repo:** https://github.com/matthewmorrone/mecab.git
- **SPM:** remote, pinned in `Package.resolved`
- **Why installed:** Powers the `.mecab` segmentation backend. Also the planned source of empirical Viterbi bigram costs (see `matrix.def`) once we promote it from alt-backend to scoring oracle.

### zinnia-swift (local) ✅
- **Repo:** https://github.com/sasakure-uk/zinnia-swift
- **Vendored at:** `Packages/zinnia-swift/`
- **Why installed:** Swift bindings for the Zinnia handwriting recognition engine. Powers kanji handwriting input.

---

## Candidates (not installed)

Short list — anything not below was evaluated and rejected.

### CodableCSV (dehesa)
- **Repo:** https://github.com/dehesa/CodableCSV
- **Why interesting:** Codable-compatible CSV encode/decode. Enables Anki / generic-CSV vocab import/export for users migrating in or out.
- **Revisit when:** Anki interop or bulk vocabulary import/export becomes a feature.

### mlx-audio (Blaizzy)
- **Repo:** https://github.com/Blaizzy/mlx-audio
- **Why interesting:** MLX-based audio inference; on-device vocal stem separation for songs with overpowering instrumentation.
- **Blocker:** High integration cost, requires MLX runtime. Revisit when stem separation moves on-device.

### Shuffle (Kicksort)
- **Repo:** https://github.com/Kicksort/Shuffle
- **Why interesting:** Tinder-style swipe-card UI for flashcard review, SPM-installable (unlike Koloda).
- **Revisit when:** Card-based review UX is on the roadmap. Current review flow doesn't need it.

---

## Python pipeline (server-side, not Swift)

### stable-ts (jianfch)
- **Repo:** https://github.com/jianfch/stable-ts
- **Status:** Already in use — drives the offline audio-alignment pipeline producing word-level SRT/TextGrid/JSON for SailorMoon batch and other songs. Not a Swift dependency.

---

## Rejected (do not revisit without new evidence)

- **USearch** — semantic similarity over embeddings; no embedding pipeline planned.
- **SwiftLCS** — LLM correction reconciliation already works with custom diff.
- **swift-subtitle-kit / SwiftSubtitles** — we're SRT-only, server-generated; custom parsing suffices.
- **swift-audio-marker** — SwiftWhisperAlign already covers per-word timing markers.
- **TextFormation** — notes are Japanese plain text; indentation/bracket helpers don't apply.
- **FluidAudio** — diarization not needed for single-speaker content.
- **SwiftFFmpeg** — AVFoundation covers our conversion needs; +20 MB binary.
- **ElevenLabs** — cloud TTS, out of scope.
- **novi/mecab-swift** — we already link MeCab directly via the matthewmorrone fork.
- **String-Japanese** — KanaNormalizer + ScriptClassifier cover kana/romaji classification.
- **similarity-search-kit** — duplicate of USearch, same reasoning.
- **Koloda** — no SPM support; Shuffle is the SPM-compatible equivalent.
- **RichTextKit** — conflicts with overlay-rendered ruby on plain-text notes.
- **ESTMusicIndicator** — no SPM, trivial to reimplement as ~30 lines of SwiftUI.
- **subtweak** — offline preprocessing CLI, not a runtime dependency.
