# Libraries

What the app links, what was evaluated and left out, and why.

---

## Installed Libraries

What we actually link.

### LyricAlignment (local) ✅
- **Location:** `LyricAlignment/` (sibling SPM package)
- **Why installed:** Lyric alignment (HTDemucs vocal isolation + HuBERT phoneme CTC alignment, both CoreML); produces the timed cues the read screen consumes. No package dependencies of its own.

### MeCab — dictionary build only, not in the app
- **Where:** `Resources/generate_db.py`, at dictionary build time. `mecab-python3` + `ipadic` (requirements.txt) back wordfreq's Japanese tokenizer, which supplies `wordfreq_zipf`; the Homebrew `mecab` CLI with `mecab-ipadic` splits expression headwords for `entry_decomposition` (the word screen's おとな + に + なる breakdown).
- **Not in the app or the eval CLI:** the app segments with its own trie + Viterbi segmenter.

### zinnia-swift (shinjukunian) ✅
- **Repo:** https://github.com/shinjukunian/zinnia-swift
- **SPM:** remote, pinned to revision `567ac62` (upstream's last commit; the 0.1.0 tag predates the public API the app uses)
- **Why installed:** Swift bindings for the Zinnia handwriting recognition engine. Powers kanji handwriting input.

### dagre-swift (lukilabs) ✅
- **Repo:** https://github.com/lukilabs/dagre-swift
- **SPM:** remote, `SwiftDagre` product. **Debug builds only:** the Paths diagram (`WordDetailView+SublatticeDiagram.swift`) and its section are `#if DEBUG`, so Release never references SwiftDagre and the linker drops it.
- **Why installed:** Lays out the segmentation sublattice diagram on the word detail screen.

---

## Candidates (not installed)

Short list — anything not below was evaluated and rejected.

### CodableCSV (dehesa)
- **Repo:** https://github.com/dehesa/CodableCSV
- **Why interesting:** Codable-compatible CSV encode/decode. Enables Anki / generic-CSV vocab import/export for users migrating in or out.
- **Revisit when:** Anki interop or bulk vocabulary import/export becomes a feature.

### Shuffle (Kicksort)
- **Repo:** https://github.com/Kicksort/Shuffle
- **Why interesting:** Tinder-style swipe-card UI for flashcard review, SPM-installable (unlike Koloda).
- **Revisit when:** Card-based review UX is on the roadmap. Current review flow doesn't need it.

---

## Python pipeline (server-side, not Swift)

### stable-ts (jianfch)
- **Repo:** https://github.com/jianfch/stable-ts
- **Status:** Offline tooling in `~/Projects/alignment` (`align.py`), not a Swift dependency and not in LyricAlignment. Its Whisper large-v3 runs are one of the three voters (with Japanese wav2vec2 and MMS) in the alignment test oracle (`consensus.py`); it was also the server-side aligner before on-device alignment replaced it (2026-04-10).

---

## Rejected (do not revisit without new evidence)

- **USearch** — semantic similarity over embeddings; no embedding pipeline planned.
- **mlx-swift / soniqo speech-swift** — removed 2026-09-27: only the iOS 18–25 Qwen3-ASR fallback used them, and they (plus ~20 transitive packages: swift-transformers, swift-huggingface, swift-crypto, swift-collections, Jinja, swift-argument-parser for MLX's CudaBuild plugin) were most of every package build. Transcription is SpeechTranscriber, iOS 26+ only.
- **SwiftLCS** — LLM correction reconciliation already works with custom diff.
- **swift-subtitle-kit / SwiftSubtitles** — we're SRT-only, server-generated; custom parsing suffices.
- **swift-audio-marker** — LyricAlignment already covers per-word timing markers.
- **TextFormation** — notes are Japanese plain text; indentation/bracket helpers don't apply.
- **FluidAudio** — diarization not needed for single-speaker content.
- **SwiftFFmpeg** — AVFoundation covers our conversion needs; +20 MB binary.
- **ElevenLabs** — cloud TTS, out of scope.
- **String-Japanese** — KanaNormalizer + ScriptClassifier cover kana/romaji classification.
