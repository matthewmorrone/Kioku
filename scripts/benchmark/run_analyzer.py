#!/usr/bin/env python3
"""Runs one open-source Japanese analyzer over a set's texts and writes its output in the formats Kioku's
eval CLI produces, so every tool is scored by the same code:
  <out>.fur — per text, a JSON list of [utf16Location, utf16Length, reading]: one ruby per token whose
      surface has a single kanji run, over that run, read as the analyzer reads it in context;
  <out>.seg — per text, the analyzer's tokens joined by U+001E (gaps between tokens kept as pieces).

    run_analyzer.py mecab|unidic|sudachiA|sudachiC texts.txt out

mecab is the `mecab` command with its default IPADic; unidic is fugashi with the full `unidic` package;
sudachiA / sudachiC are SudachiPy with sudachidict_core in short (A) and long (C) split modes."""
import json, re, subprocess, sys

KANJI = re.compile(r'[㐀-䶿一-鿿豈-﫿々〆ヶ]+')


def hira(text):
    """Folds katakana to hiragana so readings compare in one script."""
    return ''.join(chr(ord(c) - 0x60) if 'ァ' <= c <= 'ヶ' else c for c in (text or ''))


def tokenizer(which, texts):
    """A function from a text to its (surface, reading) tokens."""
    if which == 'mecab':
        output = subprocess.run(['mecab'], input='\n'.join(texts) + '\n', capture_output=True, text=True, check=True).stdout
        parsed = {}
        for text, block in zip(texts, output.split('EOS\n')):
            tokens = []
            for line in block.splitlines():
                if '\t' in line:
                    surface, features = line.split('\t', 1)
                    fields = features.split(',')
                    tokens.append((surface, fields[7] if len(fields) > 7 and fields[7] != '*' else None))
            parsed[text] = tokens
        return lambda text: parsed[text]
    if which == 'unidic':
        import fugashi
        tagger = fugashi.Tagger()
        return lambda text: [(word.surface, word.feature.kana) for word in tagger(text)]
    from sudachipy import Dictionary, SplitMode
    sudachi = Dictionary(dict='core').create()
    mode = SplitMode.A if which == 'sudachiA' else SplitMode.C
    return lambda text: [(m.surface(), m.reading_form()) for m in sudachi.tokenize(text, mode)]


def main():
    which, source, out = sys.argv[1:4]
    texts = [line.rstrip('\n') for line in open(source)]
    tokens_of = tokenizer(which, texts)
    with open(f'{out}.fur', 'w') as furigana, open(f'{out}.seg', 'w') as segmentation:
        for text in texts:
            position, rows, pieces = 0, [], []
            for surface, reading in tokens_of(text):
                if not surface.strip():
                    continue
                start = text.find(surface, position)
                if start < 0:
                    continue
                if start > position:
                    pieces.append(text[position:start])
                pieces.append(surface)
                runs = list(KANJI.finditer(surface))
                if len(runs) == 1 and reading:
                    # The run's own reading: the token's reading less its kana before and after the run.
                    full, before, after = hira(reading), hira(surface[:runs[0].start()]), hira(surface[runs[0].end():])
                    if full.startswith(before) and full.endswith(after) and len(full) > len(before) + len(after):
                        core = full[len(before):len(full) - len(after)] if after else full[len(before):]
                        utf16 = len(text[:start + runs[0].start()].encode('utf-16-le')) // 2
                        rows.append([utf16, len(runs[0].group().encode('utf-16-le')) // 2, core])
                position = start + len(surface)
            if position < len(text):
                pieces.append(text[position:])
            furigana.write(json.dumps(rows, ensure_ascii=False) + '\n')
            segmentation.write('\x1e'.join(pieces) + '\n')


if __name__ == '__main__':
    main()
