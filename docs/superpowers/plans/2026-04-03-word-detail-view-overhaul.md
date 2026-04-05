# Word Detail View Overhaul — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Expand WordDetailView to surface all available per-word data — pitch accent, kanji breakdown, review stats, cross-references, antonyms, loanword origins, and sense restrictions — matching the information density of the lookup sheet where relevant.

**Architecture:** Each new data category is fetched alongside existing data in `loadDisplayData()` and stored in a dedicated `@State` property. Sections are added to the existing `List` in `WordDetailView.swift`. No new stores or persistence layers are needed — all data is already in the SQLite dictionary database or existing in-memory stores injected via `@EnvironmentObject`.

**Tech Stack:** SwiftUI, UIKit (via existing UIViewRepresentable helpers), SQLite via `DictionaryStore`, existing stores (`ReviewStore`, `WordListsStore`, `HistoryStore`).

---

## Data Catalog

### Currently Shown
| Data | Source | Notes |
|---|---|---|
| Surface + furigana + lemma | `SavedWord.surface`, `entry.kanaForms`, lookup reading | Header via `SegmentLookupSheetHeader` / `LookupHeaderView` |
| All matching definitions | `DictionaryEntry.senses` | Sorted by frequency; POS, gloss, tags |
| Frequency tier chip | `FrequencyData.frequencyLabel` | Per-entry: Very Common → Very Rare |
| Alternate spellings | `entry.kanaForms` (filtered) | Excludes archaic/search-only |
| Example sentences | `WordDisplayData.sentences` | Up to 20 from Tatoeba, expandable |
| Word components | `TextSegmenting.longestMatchEdges` | Surface + first gloss per component |

### Available but Not Shown
| Data | Source | What to Show |
|---|---|---|
| Pitch accent | `WordDisplayData.pitchAccents` → `[PitchAccent]` | Mora/downstep pattern per reading; accent type label |
| Kanji breakdown | `DictionaryStore.fetchKanjiInfo(for:)` | Per-kanji: grade, JLPT, stroke count, on/kun readings, meanings |
| Review statistics | `ReviewStore.stats[canonicalEntryID]` | Correct/again counts, accuracy %, last reviewed date |
| Sense restrictions | `DictionaryStore.fetchSenseRestrictions(entryID:)` | Which kanji/kana forms apply to which sense |
| Cross-references & antonyms | `DictionaryStore.fetchSenseReferences(entryID:)` | "See also" / "Antonym" per sense |
| Loanword origins | `DictionaryStore.fetchLoanwordSources(entryID:)` | Language, original word, wasei flag |
| Word list membership | `SavedWord.wordListIDs` + `WordListsStore` | Which lists contain this word |
| Save date | `SavedWord.savedAt` | "Saved on …" |
| History (last looked up) | `HistoryStore.entries` | Last lookup date |
| KanjiForm/KanaForm priority tags | `KanjiForm.priority`, `KanaForm.priority` | Common marker (ichi1/news1/spec1 = common) |
| KanjiForm/KanaForm info tags | `KanjiForm.info`, `KanaForm.info` | e.g. "irregular kanji", "ateji", "usually kana" |

### Reasonable to Add (Requires Minor Derivation)
| Data | How | Notes |
|---|---|---|
| Pitch accent diagram | Draw mora row + downstep marker from `PitchAccent.accent` + `.morae` | Standard H/L pattern; well-understood formula |
| "Common word" badge | `KanjiForm.priority` or `KanaForm.priority` contains `ichi1`/`news1`/`spec1` | Boolean: is this a common entry? |
| JLPT level (entry-level) | Max JLPT across kanji in surface via `KanjiInfo.jlptLevel` | Approximate; note as "approx." |

---

## File Map

| File | Change |
|---|---|
| `Kioku/Words/WordDetailView.swift` | Add `@EnvironmentObject ReviewStore`, new `@State` properties for pitch/kanji/enrichment data, new section renderers, expanded `loadDisplayData()` |
| `Kioku/Read/Furigana/PitchAccentView.swift` | **Create** — SwiftUI view rendering mora row + downstep from `PitchAccent` |

No other files need modification. All data sources are already accessible.

---

## Task 1 — Pitch Accent Section

**Files:**
- Create: `Kioku/Read/Furigana/PitchAccentView.swift`
- Modify: `Kioku/Words/WordDetailView.swift`

Pitch accent data is already fetched into `WordDisplayData.pitchAccents`. We just need to render it.

A `PitchAccent` has:
- `accent: Int` — downstep position (0 = flat/heiban; N = drop after mora N)
- `morae: Int` — total mora count
- `kana: String` — the kana reading this applies to
- `kind: String?` — UniDic POS kind tag (can be shown as a subscript label)

The standard rendering: draw a row of mora boxes, each labeled with its kana character. A line runs across the tops. After mora `accent` (1-indexed), the line drops. Mora 0 always starts low (unless heiban where the line stays high throughout after mora 1).

Simplified version for this plan: show a text-based pattern (H/L per mora) and the reading with a drop marker `꜀`. This avoids a complex custom drawing view while still being useful.

- [ ] **Step 1: Create `PitchAccentView.swift`**

```swift
import SwiftUI

// Renders a single pitch accent record as a kana string with H/L pattern labels.
// The accent value is the downstep position (0 = flat/heiban, N = drop after mora N).
struct PitchAccentView: View {
    let accent: PitchAccent

    // Splits kana into individual mora strings (handles digraphs like きゃ, っ, ー).
    private var morae: [String] {
        mораeSplit(accent.kana)
    }

    // Returns H or L for each mora position given the downstep.
    private var pattern: [String] {
        let n = accent.accent
        let count = morae.count
        return (0..<count).map { i in
            if n == 0 {
                // Heiban: mora 0 is L, rest are H
                return i == 0 ? "L" : "H"
            } else {
                // Atamadaka (n==1): mora 0 is H, rest L
                // Nakadaka/Odaka: mora 0 L, 1..<n H, n onward L
                if n == 1 { return i == 0 ? "H" : "L" }
                return i == 0 ? "L" : (i < n ? "H" : "L")
            }
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(morae.enumerated()), id: \.offset) { i, mora in
                VStack(spacing: 1) {
                    Text(pattern.indices.contains(i) ? pattern[i] : "")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.secondary)
                    Text(mora)
                        .font(.subheadline)
                }
                .frame(minWidth: 20)
                if i < morae.count - 1 {
                    Divider()
                        .frame(height: 28)
                        .opacity(accent.accent > 0 && i == accent.accent - 1 ? 1 : 0)
                }
            }
            if accent.accent == 0 {
                // Heiban: show a trailing marker to indicate no drop
                Text("→")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .padding(.leading, 2)
            }
        }
        .padding(.vertical, 2)
    }

    // Splits a kana string into mora units, keeping digraphs (ゃゅょャュョ) and
    // special characters (っッー) attached to their preceding mora.
    private func mораeSplit(_ kana: String) -> [String] {
        let combining: Set<Character> = ["ゃ","ゅ","ょ","ャ","ュ","ョ"]
        var result: [String] = []
        for ch in kana {
            if combining.contains(ch), result.isEmpty == false {
                result[result.count - 1].append(ch)
            } else {
                result.append(String(ch))
            }
        }
        return result
    }
}
```

- [ ] **Step 2: Add pitch accent section to `WordDetailView`**

In `WordDetailView.swift`, pitch accent data is already in `savedDisplayData?.pitchAccents`. Add the section inside the `List`, after the Definition section:

```swift
// Pitch Accent section — uses data already present in WordDisplayData.
if let pitchAccents = savedDisplayData?.pitchAccents, pitchAccents.isEmpty == false {
    Section("Pitch Accent") {
        ForEach(pitchAccents, id: \.kana) { pa in
            PitchAccentView(accent: pa)
        }
    }
}
```

- [ ] **Step 3: Commit**

```bash
git add Kioku/Read/Furigana/PitchAccentView.swift Kioku/Words/WordDetailView.swift
git commit -m "feat: add pitch accent section to WordDetailView"
```

---

## Task 2 — Kanji Breakdown Section

**Files:**
- Modify: `Kioku/Words/WordDetailView.swift`

`DictionaryStore.fetchKanjiInfo(for: String) throws -> KanjiInfo?` fetches one kanji character at a time. We iterate the unique kanji in `word.surface` (using `ScriptClassifier.containsKanji`) and fetch each.

`KanjiInfo` fields:
- `literal: String`
- `grade: Int?` — Jōyō grade 1–6, 8 = secondary school
- `strokeCount: Int?`
- `jlptLevel: Int?` — 1 (hardest) to 4 (easiest)
- `onReadings: [String]`
- `kunReadings: [String]`
- `meanings: [String]`

- [ ] **Step 1: Add state and fetch to `WordDetailView`**

Add at the top of the struct (alongside existing `@State` properties):

```swift
@State private var kanjiInfos: [KanjiInfo] = []
```

Add fetch logic at the end of `loadDisplayData()`:

```swift
// Fetch kanji breakdown for each unique kanji in the surface.
if let store = dictionaryStore {
    let uniqueKanji = word.surface.filter { ScriptClassifier.containsKanji(String($0)) }
        .map(String.init)
        .reduce(into: [String](), { if !$0.contains($1) { $0.append($1) } })
    let infos = await Task { @MainActor in
        uniqueKanji.compactMap { try? store.fetchKanjiInfo(for: $0) }
    }.value
    kanjiInfos = infos
}
```

- [ ] **Step 2: Add kanji breakdown section to the `List`**

Place after the Components section:

```swift
if kanjiInfos.isEmpty == false {
    Section("Kanji") {
        ForEach(kanjiInfos, id: \.literal) { info in
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(info.literal)
                        .font(.system(size: 28, weight: .medium))

                    VStack(alignment: .leading, spacing: 2) {
                        Text(info.meanings.prefix(3).joined(separator: ", "))
                            .font(.subheadline)

                        HStack(spacing: 8) {
                            if let grade = info.grade {
                                label(grade == 8 ? "Secondary" : "Grade \(grade)")
                            }
                            if let jlpt = info.jlptLevel {
                                label("JLPT N\(jlpt)")
                            }
                            if let strokes = info.strokeCount {
                                label("\(strokes) strokes")
                            }
                        }
                    }
                }

                if info.onReadings.isEmpty == false {
                    HStack(spacing: 4) {
                        Text("ON")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.tertiary)
                        Text(info.onReadings.joined(separator: "・"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                if info.kunReadings.isEmpty == false {
                    HStack(spacing: 4) {
                        Text("KUN")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.tertiary)
                        Text(info.kunReadings.joined(separator: "・"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.vertical, 4)
        }
    }
}
```

Add a private helper at the bottom of `WordDetailView`:

```swift
// Renders a small pill-shaped metadata label.
@ViewBuilder
private func label(_ text: String) -> some View {
    Text(text)
        .font(.caption2)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 5)
        .padding(.vertical, 2)
        .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 4))
}
```

- [ ] **Step 3: Commit**

```bash
git add Kioku/Words/WordDetailView.swift
git commit -m "feat: add kanji breakdown section to WordDetailView"
```

---

## Task 3 — Review Statistics Section

**Files:**
- Modify: `Kioku/Words/WordDetailView.swift`

`ReviewStore` is an `@EnvironmentObject` already injected at the call site in `WordsView`. Add it to `WordDetailView` and read `stats[word.canonicalEntryID]`.

`ReviewWordStats` fields:
- `correct: Int`
- `again: Int`
- `total: Int` (computed = correct + again)
- `accuracy: Double?` (computed = correct / total, nil if never reviewed)
- `lastReviewedAt: Date?`

- [ ] **Step 1: Add `ReviewStore` environment object**

At the top of the struct (alongside other `@EnvironmentObject` declarations — note: `wordsStore` was removed in a prior change, so add fresh):

```swift
@EnvironmentObject private var reviewStore: ReviewStore
```

- [ ] **Step 2: Inject `ReviewStore` at the call site in `WordsView`**

In `WordsView.swift`, the sheet that presents `WordDetailView` already injects `wordsStore` and `wordListsStore`. Add `reviewStore`:

```swift
.sheet(item: $selectedDetailWord, onDismiss: { selectedDetailReading = nil }) { word in
    WordDetailView(word: word, reading: selectedDetailReading, dictionaryStore: dictionaryStore)
        .environmentObject(wordsStore)
        .environmentObject(wordListsStore)
        .environmentObject(reviewStore)   // add this line
        .presentationDetents([.large])
}
```

`WordsView` already has `@EnvironmentObject private var reviewStore: ReviewStore` — verify this is present; if not add it alongside the other environment objects at the top of `WordsView`.

- [ ] **Step 3: Add review stats section to the `List`**

Place after the Examples section:

```swift
let stats = reviewStore.stats[word.canonicalEntryID]
if stats != nil || true {  // always show — "Not yet reviewed" is informative
    Section("Review") {
        if let stats {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Correct")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("\(stats.correct)")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(.green)
                }
                Spacer()
                VStack(alignment: .center, spacing: 2) {
                    Text("Again")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("\(stats.again)")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(.red)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text("Accuracy")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if let acc = stats.accuracy {
                        Text("\(Int(acc * 100))%")
                            .font(.title3.weight(.semibold))
                    } else {
                        Text("—")
                            .font(.title3.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.vertical, 4)

            if let lastReviewed = stats.lastReviewedAt {
                HStack {
                    Text("Last reviewed")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(lastReviewed, style: .relative)
                        .foregroundStyle(.secondary)
                }
                .font(.caption)
            }
        } else {
            Text("Not yet reviewed")
                .foregroundStyle(.secondary)
        }
    }
}
```

- [ ] **Step 4: Commit**

```bash
git add Kioku/Words/WordDetailView.swift
git commit -m "feat: add review statistics section to WordDetailView"
```

---

## Task 4 — Loanword Origins, Cross-References, and Antonyms

**Files:**
- Modify: `Kioku/Words/WordDetailView.swift`

These three use the same fetch pattern — called on `savedDisplayData?.entry.entryId` — and are small enough to handle in one task.

**`LoanwordSource`** fields:
- `senseOrderIndex: Int`
- `lang: String` — ISO 639 code ("eng", "fre", "ger", "por", "dut", etc.)
- `wasei: Bool` — wasei-eigo (Japanese-coined word using foreign components)
- `lsType: LoanwordSourceType` — `.full` or `.part`
- `content: String?` — the original word in source language

**`SenseReference`** fields:
- `senseOrderIndex: Int`
- `type: SenseReferenceKind` — `.xref` (see also) or `.ant` (antonym)
- `target: String` — the target word/expression

- [ ] **Step 1: Add state properties**

```swift
@State private var loanwordSources: [LoanwordSource] = []
@State private var senseReferences: [SenseReference] = []
```

- [ ] **Step 2: Fetch in `loadDisplayData()`**

Add after existing enrichment fetches, inside the `Task { @MainActor in }` block where `dictionaryStore` is available:

```swift
if let savedID = allDisplayData.first?.entry.entryId, let store = dictionaryStore {
    let sources = await Task { @MainActor in
        (try? store.fetchLoanwordSources(entryID: savedID)) ?? []
    }.value
    loanwordSources = sources

    let refs = await Task { @MainActor in
        (try? store.fetchSenseReferences(entryID: savedID)) ?? []
    }.value
    senseReferences = refs
}
```

Note: `loadDisplayData()` already has access to `dictionaryStore` and sets `allDisplayData` before this runs, so `allDisplayData.first?.entry.entryId` is safe to use after the existing fetch block.

- [ ] **Step 3: Add loanword section**

Place after the Kanji section:

```swift
if loanwordSources.isEmpty == false {
    Section("Origin") {
        ForEach(Array(loanwordSources.enumerated()), id: \.offset) { _, source in
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    if let word = source.content, word.isEmpty == false {
                        Text(word)
                            .font(.subheadline.weight(.medium))
                    }
                    Text(languageName(for: source.lang))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if source.wasei {
                    label("wasei")
                }
                if source.lsType == .part {
                    label("partial")
                }
            }
            .padding(.vertical, 2)
        }
    }
}
```

Add helper:

```swift
// Maps ISO 639-2/B language codes to display names for common loanword sources.
private func languageName(for code: String) -> String {
    let map: [String: String] = [
        "eng": "English", "fre": "French", "ger": "German",
        "por": "Portuguese", "dut": "Dutch", "ita": "Italian",
        "spa": "Spanish", "rus": "Russian", "chi": "Chinese",
        "kor": "Korean", "san": "Sanskrit", "ara": "Arabic",
    ]
    return map[code] ?? code.uppercased()
}
```

- [ ] **Step 4: Surface cross-references and antonyms inline in `senseRow`**

The existing `senseRow(number:sense:)` renders one sense. We need sense-level `xref`/`ant` data. Pass the references in.

Replace the `senseRow` call site in the `ForEach`:

```swift
ForEach(Array(data.entry.senses.enumerated()), id: \.offset) { idx, sense in
    let senseRefs = senseReferences.filter { $0.senseOrderIndex == idx }
    senseRow(number: idx + 1, sense: sense, refs: senseRefs)
}
```

Update `senseRow` signature and body — add after the tags `HStack`:

```swift
@ViewBuilder
private func senseRow(number: Int, sense: DictionaryEntrySense, refs: [SenseReference] = []) -> some View {
    // ... existing body unchanged up to the closing brace, then add:
    let xrefs = refs.filter { $0.type == .xref }.map(\.target)
    let ants  = refs.filter { $0.type == .ant  }.map(\.target)
    if xrefs.isEmpty == false {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text("See also:")
                .font(.caption2)
                .foregroundStyle(.tertiary)
            Text(xrefs.joined(separator: "、"))
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(.leading, 24)
    }
    if ants.isEmpty == false {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text("Antonym:")
                .font(.caption2)
                .foregroundStyle(.tertiary)
            Text(ants.joined(separator: "、"))
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(.leading, 24)
    }
}
```

- [ ] **Step 5: Commit**

```bash
git add Kioku/Words/WordDetailView.swift
git commit -m "feat: add loanword origins and cross-references to WordDetailView"
```

---

## Task 5 — Word List Membership and Save Date

**Files:**
- Modify: `Kioku/Words/WordDetailView.swift`

`WordListsStore` is already injected at the call site. `SavedWord.savedAt` and `SavedWord.wordListIDs` are directly on `word`. The "Lists" section was removed in a prior change — reinstate it in a cleaner form alongside save metadata.

- [ ] **Step 1: Add `wordListsStore` environment object back to `WordDetailView`**

```swift
@EnvironmentObject private var wordListsStore: WordListsStore
```

- [ ] **Step 2: Add the membership + save date section**

Place at the end of the `List`, after Loanword Origins:

```swift
Section("Saved") {
    let memberNames: [String] = {
        let liveIDs = wordListsStore.lists.filter { word.wordListIDs.contains($0.id) }.map(\.name).sorted()
        return liveIDs
    }()

    HStack {
        Text("Added")
            .foregroundStyle(.secondary)
        Spacer()
        Text(word.savedAt, style: .date)
            .foregroundStyle(.secondary)
    }
    .font(.subheadline)

    if memberNames.isEmpty == false {
        ForEach(memberNames, id: \.self) { name in
            Label(name, systemImage: "list.bullet")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }
}
```

- [ ] **Step 3: Ensure `wordListsStore` is injected at the call site in `WordsView`**

The sheet already injects it:

```swift
.environmentObject(wordListsStore)
```

Verify this line is present in the `.sheet(item: $selectedDetailWord …)` block. It was present before the Lists section was removed — it should still be there.

- [ ] **Step 4: Commit**

```bash
git add Kioku/Words/WordDetailView.swift
git commit -m "feat: add save date and list membership to WordDetailView"
```

---

## Task 6 — Common Word Badge

**Files:**
- Modify: `Kioku/Words/WordDetailView.swift`

A word is "common" if any of its kanji or kana forms has a priority tag containing `ichi1`, `news1`, or `spec1`. This is a standard JMdict convention used by dictionaries like Jisho.

- [ ] **Step 1: Add computed property**

Add to `WordDetailView`:

```swift
// Returns true when the saved entry is flagged as common in JMdict priority data.
// Checks the first kanji form (or kana form if no kanji) for ichi1/news1/spec1 tags.
private var isCommonWord: Bool {
    guard let entry = savedDisplayData?.entry else { return false }
    let priorityForms = entry.kanjiForms.map(\.priority) + entry.kanaForms.map(\.priority)
    return priorityForms.compactMap { $0 }.contains {
        $0.contains("ichi1") || $0.contains("news1") || $0.contains("spec1")
    }
}
```

- [ ] **Step 2: Surface the badge in the header area**

After `SegmentLookupSheetHeader(…)` in `body`, add:

```swift
if isCommonWord {
    Text("Common Word")
        .font(.caption2.weight(.semibold))
        .foregroundStyle(.white)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(Color.accentColor, in: Capsule())
        .padding(.bottom, 4)
}
```

- [ ] **Step 3: Commit**

```bash
git add Kioku/Words/WordDetailView.swift
git commit -m "feat: add common word badge to WordDetailView header"
```

---

## Section Order (Final)

After all tasks, the `List` sections appear in this order:

1. **Definition** — all matching entries, senses with POS/gloss/tags, xrefs/antonyms inline, frequency chip
2. **Pitch Accent** — mora pattern per reading
3. **Also Written As** — alternate spellings
4. **Examples** — Tatoeba sentences, expandable
5. **Components** — longestMatch segmentation components
6. **Kanji** — per-character grade/JLPT/strokes/readings/meanings
7. **Origin** — loanword sources (shown only when present)
8. **Review** — correct/again/accuracy/last reviewed
9. **Saved** — save date + word list membership

---

## Self-Review

**Spec coverage:**
- ✅ Pitch accent — Task 1
- ✅ Kanji breakdown — Task 2
- ✅ Review stats — Task 3
- ✅ Loanword origins — Task 4
- ✅ Cross-references/antonyms — Task 4
- ✅ Common word badge — Task 6
- ✅ Save date + list membership — Task 5
- ❌ Sense restrictions (stagk/stagr) — omitted; these are highly technical JMdict metadata that would confuse most users. The data exists (`fetchSenseRestrictions`) but the display value is marginal.
- ❌ History last-looked-up — omitted; not meaningfully different from `savedAt` for most words and adds `HistoryStore` as a dependency for little user value.
- ❌ KanjiForm/KanaForm info tags (ateji, io, iK, etc.) — omitted; already partially surfaced via the "Also Written As" filter logic. Full exposure would be low-value clutter.

**Placeholder scan:** No TBD/TODO/placeholder phrases present.

**Type consistency:**
- `PitchAccentView` receives `PitchAccent` — matches `WordDisplayData.pitchAccents: [PitchAccent]` ✅
- `KanjiInfo` accessed via `fetchKanjiInfo(for:)` — matches existing `DictionaryStore` API ✅
- `LoanwordSource.lsType == .part` — matches `LoanwordSourceType` enum ✅
- `SenseReference.type == .xref/.ant` — matches `SenseReferenceKind` enum ✅
- `senseRow(number:sense:refs:)` default parameter `refs: [SenseReference] = []` preserves existing call sites ✅
- `ReviewWordStats` accessed via `reviewStore.stats[word.canonicalEntryID]` — matches `ReviewStore.stats: [Int64: ReviewWordStats]` ✅
