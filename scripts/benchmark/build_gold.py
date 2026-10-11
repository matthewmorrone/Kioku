#!/usr/bin/env python3
"""Builds the benchmark's gold sets, one pair of files per set in WORK:
<set>.txt (one text per line) and <set>.jsonl ({"s": text, "g": [[start, end, headword, reading, 0], ...]}),
offsets into the text — the format scripts/segmentation-eval reads.

  tatoeba-held2k, tatoeba-fresh5k: Kioku's own held-out Tatoeba sets (scripts/segmentation-eval/data),
      never used to fit anything; every word with its headword, and a reading where the word has several.
  aozora: public-domain fiction from Aozora Bunko; gold = the readings the texts' editors put in ruby
      (｜漢字《かんじ》), one kanji run each. Ruby marks the words a reader might stumble on, so it's hard.
  kwdlc: the Kyoto University Web Document Leads Corpus (web pages); gold = every morpheme with its
      annotated reading and boundaries.

    build_gold.py WORK      (after fetch.sh has filled WORK/aozora and WORK/KWDLC)"""
import glob, gzip, json, os, re, sys

KANJI_RUN = re.compile(r'^[㐀-䶿一-鿿豈-﫿々〆ヶ]+$')
HERE = os.path.dirname(os.path.abspath(__file__))


def hira(text):
    """Folds katakana to hiragana so readings compare in one script."""
    return ''.join(chr(ord(c) - 0x60) if 'ァ' <= c <= 'ヶ' else c for c in text)


def write(work, name, records):
    """Writes one gold set as <name>.txt and <name>.jsonl."""
    with open(f'{work}/{name}.txt', 'w') as txt, open(f'{work}/{name}.jsonl', 'w') as jsonl:
        for record in records:
            txt.write(record['s'] + '\n')
            jsonl.write(json.dumps(record, ensure_ascii=False) + '\n')
    print(f'{name}: {len(records)} texts, {sum(len(r["g"]) for r in records)} gold spans')


def tatoeba(work):
    """Kioku's held-out Tatoeba sets, as committed."""
    data = os.path.join(HERE, '..', 'segmentation-eval', 'data')
    for source, name in (('held2k', 'tatoeba-held2k'), ('fresh', 'tatoeba-fresh5k')):
        write(work, name, [json.loads(line) for line in gzip.open(f'{data}/{source}.jsonl.gz', 'rt')])


def aozora(work):
    """Paragraphs of the fetched Aozora works, ruby stripped from the text and kept as gold."""
    records = []
    for path in sorted(glob.glob(f'{work}/aozora/works/*.txt')):
        lines = open(path).read().split('\n')
        # The body sits between the second dashed separator line and the 底本 colophon.
        separators = [i for i, line in enumerate(lines) if line.startswith('-------')]
        body = lines[separators[1] + 1:] if len(separators) >= 2 else lines[1:]
        end = next((i for i, line in enumerate(body) if line.startswith('底本：')), len(body))
        for raw in body[:end]:
            raw = re.sub(r'［＃[^］]*］', '', raw).replace('　', '').strip()
            if not raw:
                continue
            text, gold, position = '', [], 0
            for match in re.finditer(r'(?:｜([^《｜]+)|([㐀-䶿一-鿿豈-﫿々〆ヶ]+))《([^》]+)》', raw):
                text += raw[position:match.start()]
                base = match.group(1) or match.group(2)
                start = len(text)
                text += base
                reading = hira(match.group(3))
                if KANJI_RUN.match(base) and re.fullmatch(r'[ぁ-ゖー]+', reading):
                    gold.append([start, start + len(base), base, reading, 0])
                position = match.end()
            text = (text + raw[position:]).replace('《', '').replace('》', '').replace('｜', '')
            if gold and len(text) < 400:
                records.append({'s': text, 'g': gold})
    write(work, 'aozora', records)


def kwdlc(work):
    """Every KWDLC sentence, each morpheme a gold span with its reading."""
    records = []
    for path in sorted(glob.glob(f'{work}/KWDLC/knp/**/*.knp', recursive=True)):
        morphemes = []
        for line in open(path):
            if line.startswith('EOS'):
                if morphemes:
                    text, gold = '', []
                    for surface, reading in morphemes:
                        gold.append([len(text), len(text) + len(surface), surface, hira(reading), 0])
                        text += surface
                    records.append({'s': text, 'g': gold})
                morphemes = []
            elif line[0] not in '#*+':
                fields = line.split(' ')
                if len(fields) > 2 and fields[0] != '\\':
                    morphemes.append((fields[0], fields[1]))
    write(work, 'kwdlc', records)


if __name__ == '__main__':
    work = sys.argv[1]
    tatoeba(work)
    aozora(work)
    kwdlc(work)
