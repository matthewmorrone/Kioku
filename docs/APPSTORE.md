# App Store Submission Kit

Everything App Store Connect asks for, pre-filled. Copy each section into the
matching field. Items marked ⚠️ are the only steps that require your account
or your phone.

---

## App record

| Field | Value |
|---|---|
| Name | **Kioku Reader** |
| Subtitle | Read, look up, and study Japanese |
| Bundle ID | `matthewmorrone.Kioku` |
| SKU | `kioku-ios` |
| Primary language | English (U.S.) |
| Category | Education (primary), Reference (secondary) |
| Price | Free |

Name resolved 2026-06-12: bare "Kioku" is unavailable in App Store Connect
(it blocks reserved-but-unpublished names, which the public iTunes Search API
doesn't reveal), so the store title is "Kioku Reader" — matches the bundle
product name. The on-device display name under the icon is independent of this.

## Promotional text (170 chars max)

> Paste any Japanese text and read it with furigana, tap-to-look-up, and
> one-tap word saving. Fully offline dictionary. Your data never leaves your
> phone.

## Description

> Kioku turns any Japanese text into a readable, studyable document.
>
> READ
> • Paste or import text and get instant furigana annotations
> • Tap any word for its dictionary entry, conjugation breakdown, and pitch info
> • Smart segmentation understands conjugated forms — tap できない, see できる
> • Adjustable typography: text size, line spacing, furigana size and gap
>
> LOOK UP
> • Complete offline Japanese–English dictionary — no connection needed
> • Search by kanji, kana, romaji, English, or wildcards
> • Handwriting input: draw kanji you can't type, including multi-character words
> • Radical search and kanji detail views with stroke information
> • Paste a whole sentence and get a word-by-word breakdown
>
> STUDY
> • Save words while you read; organize them into lists
> • Flashcards and multiple-choice review with progress tracking
> • Word of the Day notifications
> • Study history that remembers every word you've looked up
>
> LISTEN
> • Attach audio to notes and follow along karaoke-style, line by line
> • On-device transcription and lyric alignment (downloadable speech models)
> • Per-word timing you can edit by hand
>
> PRIVATE BY DESIGN
> • No accounts, no analytics, no tracking — the privacy label is empty
> • Everything stays on your phone; full backup export/import included
> • Optional AI features use your own API key, stored in the device Keychain
>
> Dictionary data from JMdict (EDRDG), used under Creative Commons
> Attribution-ShareAlike. Full attributions in Settings → About.

## Keywords (100 chars max)

> japanese,dictionary,furigana,kanji,jlpt,flashcards,study,offline,handwriting,lyrics,vocabulary

(94 characters. "Reader" is dropped — it's already in the title "Kioku
Reader" and Apple indexes the title. Don't repeat "kioku" either, same reason.)

## URLs

| Field | Value |
|---|---|
| Support URL | https://github.com/matthewmorrone/Kioku/issues |
| Marketing URL (optional) | https://github.com/matthewmorrone/Kioku |
| Privacy Policy URL | https://github.com/matthewmorrone/Kioku/blob/main/docs/PRIVACY.md |

## Privacy questionnaire (App Privacy section)

- "Do you or your third-party partners collect data from this app?" → **No**
- Resulting label: **Data Not Collected**

The optional BYOK AI calls and Jimaku search are user-initiated requests with
user-supplied credentials; Apple's definition of "collect" (transmitted off
device and retained by *you*, the developer) is not met. Nothing is sent to
any server you operate — you operate none.

## Age rating questionnaire

Answer **None/No** to every content question (violence, sexual content,
profanity, gambling, contests, unrestricted web access, user-generated content
with interaction). Kioku displays dictionary content and the user's own text.
Expected rating: **4+**.

## Export compliance

Already declared in the binary (`ITSAppUsesNonExemptEncryption = NO`); App
Store Connect will not ask.

## App Review notes (paste into "Notes" in the review information section)

> Kioku is a fully offline Japanese dictionary/reader. Three features that may
> need context:
>
> 1. LOCAL-NETWORK BRIDGE (Settings → MCP Bridge, OFF by default): hosts an
>    HTTP endpoint on the user's own Wi-Fi so automation tools the user runs
>    can read/edit their notes. Bearer-token protected; token is generated on
>    device. Never reachable from the internet. This is why the app declares
>    NSLocalNetworkUsageDescription and NSBonjourServices.
>
> 2. AI CORRECTION (Settings → AI Correction, OFF by default): user supplies
>    their own OpenAI or Anthropic API key; the app sends only the text the
>    user asks to correct. No account or sign-in is required to use the app
>    (Guideline 5.1.1 — the feature is optional and keys are user-provided).
>
> 3. SUBTITLE SEARCH (optional, requires the user's own jimaku.cc API key,
>    unconfigured by default): searches a community subtitle index so users
>    can study song lyrics and dialogue alongside audio they already possess.
>    The app does not bundle, host, or distribute any copyrighted media.
>
> No demo account is needed — all functionality is available immediately
> offline.

## ⚠️ Steps only you can do

1. **Register the app**: App Store Connect → My Apps → "+" → New App, with
   bundle ID `matthewmorrone.Kioku` (register the ID at
   developer.apple.com/account → Identifiers first if it isn't listed).
2. **Screenshots** (iPhone-only now, so one set): take 6.9" screenshots on
   your iPhone (1320 × 2868). Suggested five: Read view with furigana, a
   word-detail sheet, dictionary search with handwriting input, flashcard
   review, karaoke lyrics view. Settings → no personal notes visible.
3. **Archive & upload**: Xcode → Product → Archive → Distribute App →
   App Store Connect. Xcode mints the Distribution certificate automatically.
4. **TestFlight smoke test** on an iOS 18.x device if you can borrow one —
   all automated testing ran on the iOS 26.5 simulator and 18.0 is the new
   deployment floor (the lyric-translation feature sits exactly at it).
5. Paste the sections above into App Store Connect and submit.
