# Kioku

An iOS app for reading, looking up, and studying Japanese. It turns Japanese text and audio into something you can read along with, and everything runs on the device.

[Kioku Reader on the App Store](https://apps.apple.com/us/app/kioku-reader/id6761954675)

## What it does

**Follow along**
- Attach a song or recording to a note and Kioku times every line and word to the audio on your phone, with no account and no upload
- A karaoke-style lyrics view highlights the current word as it's sung or spoken
- Tap any word to look it up, or tap a line to jump to it
- Switch between the full mix, the isolated voice, or the instrumental, and adjust any word's timing by hand

**Read**
- Paste or import text and get furigana on every kanji
- Tap a word for its dictionary entry, conjugation breakdown and pitch accent
- Segmentation understands conjugated forms, so tapping できない shows できる
- Adjustable text size, line spacing, and furigana size and gap

**Look up**
- A complete offline Japanese to English dictionary
- Search by kanji, kana, romaji, English, or wildcards
- Handwriting input for kanji you can't type, plus radical search and kanji details with stroke order

**Study**
- Save words while you read and organize them into lists
- Flashcards and multiple-choice review with progress tracking
- Word of the Day notifications

## Engineering overview

Kioku combines an offline dictionary and language analysis with on-device audio processing. The app includes SQLite-backed dictionary storage and search, Japanese deinflection and conjugation handling, and a local Swift package for lyric alignment. That package uses Core ML and Accelerate for phoneme alignment and vocal isolation.

The repository includes unit and UI test targets, a manually triggered iOS test workflow with coverage summaries, and invariant checks. See `.github/workflows/tests.yml` for the test workflow. Audio alignment quality fixtures are excluded from that simulator workflow and are intended for device evaluation.

## Privacy

No accounts, analytics or tracking. Notes, saved words, study history and audio stay on the device and leave it only when you export a backup. The app downloads its dictionary once from this project's GitHub releases, and downloads models for lyric alignment and vocal isolation when you use those features. Optional AI features use Apple Intelligence or your own API key. See [docs/PRIVACY.md](docs/PRIVACY.md).

## Building from source

The App Store version is the easiest way to run Kioku. To build it yourself you need Xcode and an iOS 18 device or simulator.

```bash
git clone git@github.com:matthewmorrone/Kioku.git
cd Kioku
bash scripts/setup.sh
open Kioku.xcodeproj
```

`scripts/setup.sh` installs the repo's git hooks, which run invariant checks before commits and pushes, unpacks the bundled handwriting model, and sets up the Python environment used to build the dictionary. The dictionary itself is downloaded at runtime and doesn't need building to run the app.

## Built on

- [zinnia-swift](https://github.com/shinjukunian/zinnia-swift): handwriting recognition
- `LyricAlignment/`: an in-repo Swift package that does lyric alignment with CoreML models for vocal isolation and phoneme alignment
- JMdict (EDRDG) for dictionary data, used under CC BY-SA

More in [docs/libraries.md](docs/libraries.md), [docs/INVARIANTS.md](docs/INVARIANTS.md) and [docs/todo.md](docs/todo.md).
