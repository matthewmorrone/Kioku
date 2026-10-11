#!/usr/bin/env python3
"""Scores every tool on every gold set with the same rules, and prints the tables docs/ACCURACY.md quotes.

    score.py WORK DICTIONARY.sqlite set1,set2,... tool1,tool2,...

Expects WORK/<set>.jsonl (build_gold.py) and WORK/<set>.<tool>.fur / .seg (Kioku's segcli or
run_analyzer.py).

Readings. A gold span counts when its surface has one kanji run and its reading crops cleanly to that
run (the headword's reading less its kana). It is scored only where EVERY tool put ruby over exactly that
run, so each tool is judged on the same words; a tool's ruby over a longer word (基本的 against the gold's
基本) can't be compared with the shorter word's reading and drops the span for all. 私 and 来 are left out
for everyone: UniDic, Sudachi and Apple read 私 as the formal わたくし by convention, and gold marks a
conjugated 来る (来て) with its dictionary reading く. "Several readings" = spans whose kanji run Kioku's
dictionary lists with more than one reading — the words where choosing matters.

Segmentation. Cut precision: of the cuts a tool makes, the share that fall on a gold word boundary.
Cut-throughs: tool segments that partly overlap a gold word (cutting into it while also crossing its edge).
For KWDLC, whose word units attach な/に/だ to adjectives and fuse のだ/ので, cut-throughs whose gold word is
such a unit are counted apart as convention differences."""
import json, re, sqlite3, sys

KANJI = re.compile(r'[㐀-䶿一-鿿豈-﫿々〆ヶ]+')
EXCLUDED = {'私', '来'}


def hira(text):
    """Folds katakana to hiragana so readings compare in one script."""
    return ''.join(chr(ord(c) - 0x60) if 'ァ' <= c <= 'ヶ' else c for c in text)


def utf16(text, index):
    """The UTF-16 offset of a string index, the unit Kioku and run_analyzer.py report."""
    return len(text[:index].encode('utf-16-le')) // 2


def readings(work, name, tools, listed):
    """Reading accuracy per tool on the spans all of them cover, overall and on ambiguous words."""
    gold = [json.loads(line) for line in open(f'{work}/{name}.jsonl')]
    ruby = {t: [{l: (n, r) for l, n, r in json.loads(x)} for x in open(f'{work}/{name}.{t}.fur')] for t in tools}
    rows = []
    for i, record in enumerate(gold):
        text = record['s']
        for start, end, headword, reading, *_ in record['g']:
            surface = text[start:end]
            runs = list(KANJI.finditer(surface))
            if len(runs) != 1 or runs[0].group() in EXCLUDED or not re.fullmatch(r'[ぁ-ゖー]+', reading or ''):
                continue
            before, after = hira(surface[:runs[0].start()]), hira(surface[runs[0].end():])
            if not (reading.startswith(before) and reading.endswith(after)):
                continue
            want = reading[len(before):len(reading) - len(after)] if after else reading[len(before):]
            if not want:
                continue
            location = utf16(text, start + runs[0].start())
            length = utf16(text, start + runs[0].end()) - location
            got = {t: ruby[t][i].get(location) for t in tools}
            if any(g is None or g[0] != length for g in got.values()):
                continue
            ambiguous = len(listed.get(runs[0].group(), ())) > 1
            rows.append((ambiguous, {t: hira(g[1]) == want for t, g in got.items()}))
    for label, subset in (('all words', rows), ('several readings', [r for r in rows if r[0]])):
        cells = '  '.join(f'{t} {100 * sum(r[1][t] for r in subset) / max(len(subset), 1):.2f}%' for t in tools)
        print(f'  readings, {label} ({len(subset)}): {cells}')


def segmentation(work, name, tools):
    """Cut precision and cut-throughs per tool against the gold word boundaries."""
    gold = [json.loads(line) for line in open(f'{work}/{name}.jsonl')]
    for tool in tools:
        cuts = good = throughs = convention = 0
        for record, line in zip(gold, open(f'{work}/{name}.{tool}.seg')):
            words = [(a, b) for a, b, *_ in record['g']]
            boundaries = {b for _, b in words} | {a for a, _ in words}
            position = 0
            for piece in line.rstrip('\n').split('\x1e'):
                a, b = position, position + len(piece)
                position = b
                if b < len(record['s']):
                    cuts += 1
                    good += b in boundaries
                for ga, gb in words:
                    if ga < b and gb > a and not (a <= ga and gb <= b) and not (ga <= a and b <= gb):
                        throughs += 1
                        word = record['s'][ga:gb]
                        if name == 'kwdlc' and (re.search(r'(な|に|だ|です|でした)$', word) and len(word) > 1
                                                or re.match(r'の(でしょう|だろう|で|だ|です)|ので', word)):
                            convention += 1
                        break
        extra = f', of them KWDLC convention {convention}, other {throughs - convention}' if name == 'kwdlc' else ''
        print(f'  segmentation {tool}: cut precision {100 * good / max(cuts, 1):.2f}% ({cuts - good} of {cuts} cuts inside a word), cut-throughs {throughs}{extra}')


def main():
    work, dictionary, sets, tools = sys.argv[1], sys.argv[2], sys.argv[3].split(','), sys.argv[4].split(',')
    db = sqlite3.connect(f'file:{dictionary}?mode=ro', uri=True)
    listed = {}
    for surface, reading in db.execute('SELECT surface, reading FROM surface_readings'):
        listed.setdefault(surface, set()).add(hira(reading))
    for name in sets:
        print(f'== {name}')
        readings(work, name, tools, listed)
        segmentation(work, name, tools)


if __name__ == '__main__':
    main()
