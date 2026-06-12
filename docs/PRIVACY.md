# Kioku Privacy Policy

**Effective date:** June 12, 2026

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

- **Dictionary and reading features** work fully offline. The dictionary is
  bundled with the app.
- **Speech-model downloads** (for audio transcription and lyric alignment)
  fetch model files from Hugging Face when you choose to download a model.
  These requests carry no personal data.
- **Optional AI correction** sends the text you ask to correct to OpenAI or
  Anthropic, using an API key *you* provide. This is off by default, and no
  request is made unless you enable it. Your key is stored in the device
  Keychain, Apple's encrypted credential store.
- **Optional subtitle search** (Jimaku) sends your search query to jimaku.cc
  using an API key you provide. Off by default.
- **Optional local-network bridge** hosts a connection on your own Wi-Fi
  network so tools you run can read and edit your notes. It is off by default,
  protected by a token generated on your device, and never reachable from the
  internet.

## Crash logs

If the app crashes, a diagnostic record is written to the app's own Documents
folder on your device. It is never transmitted anywhere. You can view and
delete these records in Settings → Diagnostics, and "Reset All Data" erases
them.

## Permissions

- **Camera** — only if you use OCR capture to create a note from a photo.
- **Speech recognition** — only if you transcribe imported audio.
- **Local network** — only if you enable the bridge.

## Children

Kioku does not collect data from anyone, including children.

## Changes

Any future change to this policy will be published at this URL with an updated
effective date. Because the app collects nothing, changes are expected to be
rare.

## Contact

Questions: open an issue at https://github.com/matthewmorrone/Kioku/issues
or email matthewmorrone1@gmail.com.
