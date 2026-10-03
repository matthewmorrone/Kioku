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

> Play a Japanese song or reading and follow along word by word. Kioku times the
> text to the audio on your phone, with furigana and tap-to-look-up on every line.

## What's New in This Version (1.1)

> • Lyrics view starts aligning by itself: open it on a note with audio and the
>   timing is worked out on your phone while you read along
> • Two sample notes to try right away: a short story read aloud and さくら さくら
> • Every kanji now gets furigana
> • Smarter word splitting and readings, including old spellings and katakana names
> • Tapping a word with no dictionary entry opens the full lookup sheet

## Description

> Kioku turns Japanese audio and text into something you can read along with.
>
> FOLLOW ALONG
> • Add a song or recording to a note and Kioku times every line and word to
>   the audio, on your phone, with no account and no upload
> • Karaoke-style lyrics view: the current word lights up as it's sung or spoken
> • Tap any word mid-song to look it up; tap a line to jump to it
> • Switch between the full mix, the isolated voice, or the instrumental
> • Fine-tune any word's timing by hand
>
> READ
> • Paste or import text and get instant furigana
> • Tap any word for its dictionary entry, conjugation breakdown, and pitch accent
> • Smart segmentation understands conjugated forms — tap できない, see できる
> • Adjustable typography: text size, line spacing, furigana size and gap
>
> LOOK UP
> • Complete offline Japanese–English dictionary
> • Search by kanji, kana, romaji, English, or wildcards
> • Handwriting input for kanji you can't type
> • Radical search and kanji details with stroke order
>
> STUDY
> • Save words while you read and organize them into lists
> • Flashcards and multiple-choice review with progress tracking
> • Word of the Day notifications
>
> PRIVATE BY DESIGN
> • No accounts, no analytics, no tracking
> • Alignment, transcription, and the dictionary all run on your phone
> • Optional AI features use Apple Intelligence or your own API key
>
> Dictionary data from JMdict (EDRDG), used under Creative Commons
> Attribution-ShareAlike. Full attributions in Settings → About.

## Keywords (100 chars max)

> japanese,dictionary,furigana,kanji,jlpt,flashcards,karaoke,offline,handwriting,lyrics,vocabulary

(96 characters. "study" made room for "karaoke". "Reader" is dropped — it's already in the
title "Kioku Reader" and Apple indexes the title. Don't repeat "kioku" either, same reason.)

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

> Kioku is a Japanese reading and study app. Reading with furigana, tap-to-look-up in an offline dictionary, saving words, and flashcard review need no account and no sign-in.
>
> Network use: the dictionary downloads once on first launch. The first time a note's audio is aligned, the on-device alignment and voice-separation models download once. After that, everything except the optional features below works offline.
>
> To try alignment: the app starts with two sample notes that have audio. Open one and tap the music-note button above the text; the lyrics view opens and timing starts on the device.
>
> Optional features, off until configured:
>
> 1. AI FEATURES (correction, song breakdowns): run on Apple Intelligence, or on OpenAI / Anthropic with an API key the user supplies. The app sends only the text the user asks about.
>
> 2. SUBTITLE SEARCH (needs the user's own jimaku.cc API key): searches a community subtitle index so users can study song lyrics and dialogue alongside audio they already have. The app does not bundle, host, or distribute any copyrighted media.
>
> No demo account is needed.

## ⚠️ Steps only you can do

1. **Register the app**: App Store Connect → My Apps → "+" → New App, with
   bundle ID `matthewmorrone.Kioku` (register the ID at
   developer.apple.com/account → Identifiers first if it isn't listed).
2. **Screenshots** (iPhone-only, one 6.9" set at 1320 × 2868): 1.1 keeps the existing set. A new
   set would lead with the lyrics view, then the Read view with furigana, the lookup sheet,
   dictionary search, and flashcard review, using the sample notes only. A first simulator build
   saturates the Mac, so run it while nobody is using it.
3. **Archive & upload**: `scripts/distribute.sh` (see RELEASE.md §5), or
   Xcode → Product → Archive → Distribute App → App Store Connect.
4. **TestFlight smoke test** on an iOS 18.x device if you can borrow one —
   all automated testing ran on the iOS 26.5 simulator and 18.0 is the new
   deployment floor (the lyric-translation feature sits exactly at it).
5. Paste the sections above into App Store Connect and submit.
