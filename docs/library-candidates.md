# Library Candidates for Future Integration

Libraries evaluated but not yet installed. Revisit when the relevant feature area is being built.

---

## Audio & Speech

### FluidAudio
- **Repo:** https://github.com/FluidInference/FluidAudio
- **Why interesting:** Real-time streaming ASR, speaker diarization, VAD — all offloaded to Apple Neural Engine. Strong audio infrastructure.
- **Blocker:** Japanese model coverage unconfirmed. Revisit when FluidInference ships a Japanese Parakeet variant or when diarization is needed for multi-speaker audio.

### SwiftWhisper (exPHAT) ✅ installed
- **Repo:** https://github.com/exPHAT/SwiftWhisper
- **SPM:** `https://github.com/exPHAT/SwiftWhisper.git`
- **Why installed:** Bundles whisper.cpp directly with no transitive dependencies, avoiding the `swift-transformers` ↔ `swift-tokenizers` target name conflict that WhisperKit caused with AzooKeyKanaKanjiConverter.
- **Note:** WhisperKit is temporarily removed. Re-evaluate once the upstream conflict between argmaxinc/WhisperKit and azooKey/AzooKeyKanaKanjiConverter is resolved.

### mlx-audio (Blaizzy)
- **Repo:** https://github.com/Blaizzy/mlx-audio
- **SPM:** `https://github.com/Blaizzy/mlx-audio.git`
- **Why interesting:** MLX-based audio inference; could support vocal stem separation or custom model inference.
- **Blocker:** High integration cost, requires MLX runtime. Revisit when building vocal stem separation.

### SwiftFFmpeg
- **Repo:** https://github.com/sunlubo/SwiftFFmpeg
- **SPM:** `https://github.com/sunlubo/SwiftFFmpeg.git`
- **Why interesting:** Full FFmpeg wrapping for audio/video format conversion. Useful for converting audio to raw PCM/WAV for stem separation model input.
- **Blocker:** Requires bundling a prebuilt FFmpeg binary for iOS (~20MB+). AVFoundation's `AVAssetExportSession` covers most conversion needs. Revisit when a Core ML stem separation model requires a specific PCM format AVFoundation can't produce.

### ElevenLabs (atacan)
- **Repo:** https://github.com/atacan/ElevenLabs
- **SPM:** `https://github.com/atacan/ElevenLabs.git`
- **Why interesting:** TTS — could narrate vocabulary definitions or example sentences.
- **Blocker:** Not in current scope. Revisit if audio pronunciation preview becomes a feature.

---

## Japanese Language

### novi/mecab-swift
- **Repo:** https://github.com/novi/mecab-swift
- **SPM:** `https://github.com/novi/mecab-swift.git`
- **Why interesting:** MeCab morphological analyzer; a well-maintained alternative/complement to the existing lattice segmenter.
- **Blocker:** Adding a second segmentation path risks architectural complexity. The existing lattice segmenter + deinflection pipeline is purpose-built for this app. Revisit if MeCab coverage proves better for specific text types.

### String-Japanese (brevansio)
- **Repo:** https://github.com/brevansio/String-Japanese
- **SPM:** `https://github.com/brevansio/String-Japanese.git`
- **Why interesting:** Kana/romaji detection, character classification utilities.
- **Blocker:** `KanaNormalizer` and `ScriptClassifier` already cover this. Only useful if those need replacement or extension with edge cases.

### similarity-search-kit (ZachNagengast)
- **Repo:** https://github.com/ZachNagengast/similarity-search-kit
- **SPM:** `https://github.com/ZachNagengast/similarity-search-kit.git`
- **Why interesting:** Apple Neural Engine-accelerated embedding similarity search. Could power "find similar words" or smart review card ranking.
- **Blocker:** Overlaps with USearch (already installed). Only add if Apple Neural Engine acceleration proves measurably faster than USearch for the specific embedding dimensions used.

---

## UI

### Koloda (Yalantis)
- **Repo:** https://github.com/Yalantis/Koloda
- **Why interesting:** Tinder-style swipe card UI for flashcard review mode.
- **Blocker:** No SPM support (CocoaPods/Carthage only). Card review UI is coming from v1 of the app anyway.
- **Alternative:** [Shuffle](https://github.com/Kicksort/Shuffle) has identical mechanics with SPM support (`https://github.com/Kicksort/Shuffle.git`).

### RichTextKit (danielsaidi)
- **Repo:** https://github.com/danielsaidi/RichTextKit
- **SPM:** `https://github.com/danielsaidi/RichTextKit.git`
- **Why interesting:** Full rich text editing with formatting toolbar.
- **Blocker:** Notes are plain text with overlay-rendered ruby — rich text formatting would conflict with the segmentation/annotation pipeline. Only revisit if note format fundamentally changes.

### ESTMusicIndicator (Aufree)
- **Repo:** https://github.com/Aufree/ESTMusicIndicator
- **Why interesting:** Animated bar indicator for playback state on note rows.
- **Blocker:** No SPM support (CocoaPods only). Implement as a small custom SwiftUI view using animated bars — it's ~30 lines.

---

## Subtitle & Timing

### subtweak (juri)
- **Repo:** https://github.com/juri/subtweak
- **SPM:** `https://github.com/juri/subtweak.git`
- **Why interesting:** SRT timing adjustment and gap detection.
- **Blocker:** SubtitleKit (already installed) covers resync in-process. subtweak is better as an offline preprocessing CLI tool.

---

## Stable-ts (jianfch)
- **Repo:** https://github.com/jianfch/stable-ts
- **Why interesting:** Enhances Whisper timestamp stability — produces much more accurate word-level timing for karaoke alignment.
- **Blocker:** Python only. Would need to run server-side and consume results via API, or find a way to port the timestamp-stabilization logic to Swift/Core ML. High value if on-device Whisper timestamps prove too jittery for tight karaoke sync.
