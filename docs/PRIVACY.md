# Kioku Privacy Policy

**Effective date:** September 28, 2026

Kioku is a Japanese reading and study app that runs entirely on your device.

## Data collection: none

Kioku does not collect, transmit, sell, or share any personal data. There are no
analytics, no advertising identifiers, no tracking, and no accounts. The app's
privacy manifest declares no collected data types.

Everything you create in Kioku — notes, saved words, word lists, study history,
review progress, audio attachments, and handwriting input — is stored only on
your device. It leaves your device only when you explicitly export a backup
file, and that file goes wherever you choose to save it.

## Network access

Kioku makes network requests only when you initiate them:

- **Dictionary download**: on first launch the dictionary is downloaded once
  from the project's GitHub releases. After that, dictionary and reading
  features work fully offline.
- **Model downloads** (for lyric alignment and vocal isolation) fetch model
  files from the project's GitHub releases and from Hugging Face the first time
  you align a song. These requests
  carry no personal data. Audio transcription uses Apple's on-device speech
  recognition.
- **Optional AI features** (correction, song breakdowns, word explanations)
  run on Apple Intelligence, or send the text you ask about to OpenAI or
  Anthropic using an API key *you* provide. They are off by default, and no
  request is made unless you configure one. Your key is stored in the device
  Keychain, Apple's encrypted credential store.
- **URL import** fetches the web page whose address you enter.
- **Optional subtitle search** (Jimaku) sends your search query to jimaku.cc
  using an API key you provide. Off by default.

## Crash logs

If the app crashes, a diagnostic record is written to the app's own private
storage on your device. It is never transmitted anywhere. Only the 20 most
recent records are kept, and "Reset All Data" erases them.

## Permissions

- **Camera** — only if you use OCR capture to create a note from a photo.
- **Speech recognition** — only if you transcribe imported audio.

## Children

Kioku does not collect data from anyone, including children.

## Changes

Any future change to this policy will be published at this URL with an updated
effective date. Because the app collects nothing, changes are expected to be
rare.

## Contact

Questions: open an issue at https://github.com/matthewmorrone/Kioku/issues
or email matthewmorrone1@gmail.com.
