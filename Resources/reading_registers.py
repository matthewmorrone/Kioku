#!/usr/bin/env python3
"""Reading counts by register, and the classifier that tells a note's register, for the dictionary.

Furigana chooses among a word's readings with Tatoeba's usage counts (ReadingContextTable), which are
everyday sentences. Web and business writing (その後 → ご, 方 → かた, 等 → とう) and literature read some
kanji differently, so the dictionary also carries:

  reading_register_counts (register, kanji, reading, count)
      web: KWDLC (Kyoto University Web Document Leads Corpus), its training documents (id/train.id; its
          id/test.id documents are the benchmark's); every morpheme written as its dictionary form whose one
          kanji run the dictionary lists with several readings, with its annotated reading.
      literature: Aozora Bunko ruby (漢字《かんじ》) in public-domain works by authors the benchmark doesn't
          sample, every tenth work (by work id) held out for fitting; a ruby whose base is one kanji run the
          dictionary lists with several readings.
  register_grams (gram, everyday, web, literature), register_totals (register, grams, vocabulary)
      Character unigram and bigram counts of each register's text (everyday: Tatoeba's sentences with even
      ids, the training half; web and literature: the texts above), pruned to grams seen MIN_GRAM_COUNT
      times; the totals are before pruning. RegisterClassifier picks a note's register by naive Bayes.

Only counts are stored, never text. Run by generate_db.py (import_reading_registers), or on its own to add
the tables to an existing dictionary:  reading_registers.py DICTIONARY.sqlite
"""
import collections, concurrent.futures, csv, io, re, sqlite3, sys, tempfile, urllib.request, zipfile
from pathlib import Path

KANJI_RUN = re.compile(r'[㐀-䶿一-鿿豈-﫿々〆ヶ]+')
RUBY = re.compile(r'(?:｜([^《｜]+)|([㐀-䶿一-鿿豈-﫿々〆ヶ]+))《([^》]+)》')
# Benchmark authors (scripts/benchmark/fetch_aozora.py): their works are its gold, so never counted.
BENCHMARK_AUTHORS = {('夏目', '漱石'), ('芥川', '竜之介'), ('宮沢', '賢治'), ('太宰', '治'), ('中島', '敦'),
                     ('梶井', '基次郎'), ('坂口', '安吾'), ('新美', '南吉'), ('小川', '未明'), ('岡本', '綺堂'),
                     ('寺田', '寅彦'), ('林', '芙美子')}
WORKS_PER_AUTHOR = 10
MIN_GRAM_COUNT = 5
KWDLC_URL = 'https://github.com/ku-nlp/KWDLC/archive/c6ae49d29eca4e1134c6676d682adf5ed6a25f5a.zip'
AOZORA_CATALOGUE = 'https://www.aozora.gr.jp/index_pages/list_person_all_extended_utf8.zip'
REGISTERS = ('everyday', 'web', 'literature')


def hiragana(text):
    """Folds katakana to hiragana, the script the app compares readings in."""
    return ''.join(chr(ord(c) - 0x60) if 'ァ' <= c <= 'ヶ' else c for c in text)


def grams(text):
    """The character unigrams and bigrams RegisterClassifier scores, with ^ and $ marking the ends."""
    marked = f'^{text}$'
    return [marked[i:i + 2] for i in range(len(marked) - 1)] + list(marked)


def several_readings(conn):
    """Kanji runs the dictionary lists with more than one reading: the only ones furigana chooses for."""
    readings = collections.defaultdict(set)
    for surface, reading in conn.execute('SELECT surface, reading FROM surface_readings'):
        readings[surface].add(hiragana(reading))
    return {surface for surface, values in readings.items() if len(values) > 1}


def kwdlc(archive):
    """KWDLC's training sentences, each a list of (surface, reading, dictionary form) morphemes."""
    with zipfile.ZipFile(archive) as z:
        root = z.namelist()[0].split('/')[0]
        for document in z.read(f'{root}/id/train.id').decode().split():
            morphemes = []
            for line in z.read(f'{root}/knp/{document[:13]}/{document}.knp').decode().splitlines():
                if line.startswith('EOS'):
                    if morphemes:
                        yield morphemes
                    morphemes = []
                elif line and line[0] not in '#*+':
                    fields = line.split(' ')
                    if len(fields) > 3 and fields[0] != '\\':
                        morphemes.append((fields[0], fields[1], fields[2]))


def run_reading(word, reading):
    """The reading of `word`'s single kanji run: `reading` less the kana before and after it."""
    runs = list(KANJI_RUN.finditer(word))
    if len(runs) != 1:
        return None, None
    before, after = hiragana(word[:runs[0].start()]), hiragana(word[runs[0].end():])
    reading = hiragana(reading)
    if not reading.startswith(before) or not reading.endswith(after):
        return None, None
    return runs[0].group(), reading[len(before):len(reading) - len(after)] or None


def aozora_works(catalogue, folder):
    """Downloads the counted Aozora works into `folder` (four at a time, gentle on a volunteer-run
    server) and returns their texts. A work that fails three times is skipped and logged."""
    with zipfile.ZipFile(catalogue) as z:
        rows = list(csv.DictReader(io.StringIO(z.read(z.namelist()[0]).decode('utf-8-sig'))))
    picked, per_author, seen = [], collections.Counter(), set()
    for row in rows:
        author = (row['姓'], row['名'])
        if (author not in BENCHMARK_AUTHORS and row['役割フラグ'] == '著者' and row['文字遣い種別'] == '新字新仮名'
                and row['作品著作権フラグ'] == 'なし' and 'ruby' in row['テキストファイルURL']
                and row['作品ID'] not in seen and per_author[author] < WORKS_PER_AUTHOR):
            seen.add(row['作品ID'])
            per_author[author] += 1
            if int(row['作品ID']) % 10:
                picked.append(row['テキストファイルURL'])

    def download(url):
        """One work's text from its ruby zip, or None after three failed tries."""
        for attempt in range(3):
            try:
                data = urllib.request.urlopen(url, timeout=60).read()
                (folder / url.rsplit('/', 1)[1]).write_bytes(data)
                with zipfile.ZipFile(io.BytesIO(data)) as z:
                    return ''.join(z.read(n).decode('shift_jis', errors='replace') for n in z.namelist() if n.endswith('.txt'))
            except (OSError, zipfile.BadZipFile) as error:
                if attempt == 2:
                    print(f'  skipped {url}: {error}', file=sys.stderr)
        return None

    folder.mkdir(parents=True, exist_ok=True)
    with concurrent.futures.ThreadPoolExecutor(4) as pool:
        texts = [text for text in pool.map(download, picked) if text]
    print(f'  {len(texts)} of {len(picked)} Aozora works from {len(per_author)} authors')
    return texts


def aozora_paragraphs(text):
    """A work's body paragraphs as (plain text, [(ruby base, reading)]), markup removed."""
    lines = text.replace('\r', '').split('\n')
    separators = [i for i, line in enumerate(lines) if line.startswith('-------')]
    body = lines[separators[1] + 1:] if len(separators) >= 2 else lines[1:]
    end = next((i for i, line in enumerate(body) if line.startswith('底本：')), len(body))
    for raw in body[:end]:
        raw = re.sub(r'［＃[^］]*］', '', raw).replace('　', '').strip()
        if raw:
            ruby = [(m.group(1) or m.group(2), m.group(3)) for m in RUBY.finditer(raw)]
            plain = RUBY.sub(lambda m: m.group(1) or m.group(2), raw).replace('《', '').replace('》', '').replace('｜', '')
            yield plain, ruby


def build(conn, kwdlc_archive, catalogue, work_folder):
    """Creates and fills the three tables in `conn` (which must already hold surface_readings and
    sentence_pairs), and returns how many Aozora works were counted."""
    choosable = several_readings(conn)
    readings = collections.Counter()
    gram_counts = {register: collections.Counter() for register in REGISTERS}

    for japanese, in conn.execute('SELECT DISTINCT japanese FROM sentence_pairs WHERE ja_id % 2 = 0'):
        gram_counts['everyday'].update(grams(japanese))

    for morphemes in kwdlc(kwdlc_archive):
        gram_counts['web'].update(grams(''.join(surface for surface, _, _ in morphemes)))
        for surface, reading, headword in morphemes:
            if surface == headword:
                run, run_reading_ = run_reading(surface, reading)
                if run in choosable and run_reading_:
                    readings[('web', run, run_reading_)] += 1

    texts = aozora_works(catalogue, work_folder / 'aozora')
    for text in texts:
        for plain, ruby in aozora_paragraphs(text):
            gram_counts['literature'].update(grams(plain))
            for base, reading in ruby:
                reading = hiragana(reading)
                if KANJI_RUN.fullmatch(base) and base in choosable and re.fullmatch(r'[ぁ-ゖー]+', reading):
                    readings[('literature', base, reading)] += 1

    conn.execute('DROP TABLE IF EXISTS reading_register_counts')
    conn.execute('DROP TABLE IF EXISTS register_grams')
    conn.execute('DROP TABLE IF EXISTS register_totals')
    conn.execute('''CREATE TABLE reading_register_counts (register TEXT NOT NULL, kanji TEXT NOT NULL,
                    reading TEXT NOT NULL, count INTEGER NOT NULL, PRIMARY KEY (register, kanji, reading))''')
    conn.executemany('INSERT INTO reading_register_counts VALUES (?, ?, ?, ?)',
                     [(r, k, reading, n) for (r, k, reading), n in sorted(readings.items())])
    vocabulary = set().union(*gram_counts.values())
    conn.execute('CREATE TABLE register_totals (register TEXT PRIMARY KEY, grams INTEGER NOT NULL, vocabulary INTEGER NOT NULL)')
    conn.executemany('INSERT INTO register_totals VALUES (?, ?, ?)',
                     [(r, sum(gram_counts[r].values()), len(vocabulary)) for r in REGISTERS])
    conn.execute('''CREATE TABLE register_grams (gram TEXT PRIMARY KEY, everyday INTEGER NOT NULL,
                    web INTEGER NOT NULL, literature INTEGER NOT NULL) WITHOUT ROWID''')
    kept = [(g, *(gram_counts[r][g] for r in REGISTERS)) for g in sorted(vocabulary)]
    kept = [row for row in kept if sum(row[1:]) >= MIN_GRAM_COUNT]
    conn.executemany('INSERT INTO register_grams VALUES (?, ?, ?, ?)', kept)
    counted = collections.Counter(r for r, _, _ in readings.elements())
    print(f'  reading counts: web {counted["web"]}, literature {counted["literature"]} '
          f'({len(readings)} rows); register grams: {len(kept)} of {len(vocabulary)} kept')
    return len(texts)


def main():
    """Adds the tables to an existing dictionary, fetching the sources into a throwaway folder."""
    conn = sqlite3.connect(sys.argv[1])
    with tempfile.TemporaryDirectory(prefix='kioku-reading-registers-') as folder:
        folder = Path(folder)
        for url, name in ((KWDLC_URL, 'kwdlc.zip'), (AOZORA_CATALOGUE, 'catalogue.zip')):
            (folder / name).write_bytes(urllib.request.urlopen(url, timeout=300).read())
        build(conn, folder / 'kwdlc.zip', folder / 'catalogue.zip', folder)
    conn.commit()
    conn.close()


if __name__ == '__main__':
    main()
