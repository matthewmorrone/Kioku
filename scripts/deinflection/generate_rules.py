#!/usr/bin/env python3
"""Generates Resources/deinflection.json from the grammar table and UniDic's conjugation data.

Two inputs:
  - Resources/deinflection-grammar.json: which form of a word each auxiliary, particle or helper
    attaches to, the stem compounds, fixed sequences, and the recorded decisions (omitted rules,
    exception lists). Hand-reviewed.
  - UniDic's lexicon (lex.csv): every inflected form of every verb, adjective and auxiliary, tagged
    with its conjugation type (cType) and form (cForm). The ending of each (cType, cForm) relative to
    the dictionary form comes from here, including the euphonic forms (書い, 行っ, 読ん) and the
    colloquial contractions (行きゃ, なきゃ).

Rules come out in deinflection.json's format: a rule rewrites a word ending in kanaIn to kanaOut when
the word's current grammar is in rulesIn, and leaves it with the grammar in rulesOut. Each rule carries
`source`, naming the grammar-table row and UniDic form it came from.

Then the rules of Resources/deinflection-extras.json (exceptions, not grammar: 行く's irregular forms,
the honorific い-stems …) are added as written, rules that differ only in the steps they accept or in
the helper they name are merged, and a "build" record notes the checksums of everything used.

    python3 generate_rules.py <lex.csv> [--grammar G] [--extras E] [--unidic-sha SHA] > deinflection.json
"""
import collections
import csv
import hashlib
import json
import os
import re
import sys
import unicodedata

LEX_SURFACE, LEX_POS1, LEX_CTYPE, LEX_CFORM, LEX_KANA, LEX_KANA_BASE = 0, 4, 8, 9, 21, 22
RESOURCES = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', '..', 'Resources')
GRAMMAR_DEFAULT = os.path.join(RESOURCES, 'deinflection-grammar.json')
EXTRAS_DEFAULT = os.path.join(RESOURCES, 'deinflection-extras.json')

# A (cType, cForm) ending must be attested by this many words to count as conjugation rather than one
# word's quirk or a data error. する and 来る are exempt: they are their types' only real members.
MIN_WORDS = 10
# Ichidan stems match by their last kana (べ → べる); a few single-kana stems (似る, 煮る) are rare.
MIN_STEM_KANA_WORDS = 3

KANA = re.compile(r'^[ぁ-ゖ]+$')
# Elongated or stylised spellings UniDic also lists (ね〜, でぇぇす, たぁ): not conjugation.
STYLISED = re.compile(r'[ー〜ぁぃぅぇぉ]$|ぁ|ぃ|ぅ|ぇ|ぉ')
VOWEL_ROWS = {
    'あ': 'あかさたなはまやらわがざだばぱゃ', 'い': 'いきしちにひみりぎじぢびぴ',
    'う': 'うくすつぬふむゆるぐずづぶぷゅ', 'え': 'えけせてねへめれげぜでべぺ',
    'お': 'おこそとのほもよろをごぞどぼぽょ',
}
VOWEL_OF = {kana: vowel for vowel, row in VOWEL_ROWS.items() for kana in row}


def grammar_for(ctype):
    """The grammar a word of a UniDic conjugation type ends on, named as deinflection.json names it."""
    family = ctype.split('-')[0]
    if family == '五段':
        return 'v5'
    if family in ('上一段', '下一段'):
        return 'v1'
    if family == 'カ行変格':
        return 'vk'
    if family == 'サ行変格':
        return 'vs'
    if family == '形容詞':
        return 'adj-i'
    if ctype == '助動詞-マス':
        return 'masu'
    return None


def hiragana(text):
    """Folds UniDic's katakana readings to hiragana, the script rules match."""
    return ''.join(chr(ord(c) - 0x60) if 'ァ' <= c <= 'ヶ' else c for c in text)


def unvoiced(kana):
    """The kana without its voicing mark (づ → つ, ば → は), for telling rendaku from a real change."""
    return unicodedata.normalize('NFC', unicodedata.normalize('NFD', kana).replace('゙', '').replace('゚', ''))


def is_drawn_out(text):
    """Whether a kana is followed by its own vowel (しい, けえ, ゃあ): a drawn-out, dialect or emphatic
    spelling, not a conjugation ending. おう and えい are left alone: they spell real long vowels."""
    return any(b in 'あいえ' and VOWEL_OF.get(a) == b for a, b in zip(text, text[1:]))


def common_prefix(a, b):
    """Length of the shared beginning of two readings: the stem, before the endings differ."""
    n = 0
    while n < min(len(a), len(b)) and a[n] == b[n]:
        n += 1
    return n


def read_unidic(lex, aux_words):
    """Endings per (cType, cForm), the last stem kana of empty-ending forms, and auxiliaries' forms."""
    endings = collections.defaultdict(collections.Counter)
    stem_last_kana = collections.defaultdict(collections.Counter)
    aux_forms = collections.defaultdict(set)
    for row in csv.reader(open(lex, encoding='utf-8')):
        if len(row) <= LEX_KANA_BASE:
            continue
        pos1, ctype, cform = row[LEX_POS1], row[LEX_CTYPE], row[LEX_CFORM]
        if ctype == '*' or ctype.startswith('文語'):
            continue
        if pos1 == '助動詞':
            surface = row[LEX_SURFACE]
            base = row[LEX_SURFACE] if cform == '終止形-一般' else None
            lemma = hiragana(row[LEX_KANA_BASE])
            if lemma in aux_words and KANA.match(surface) and not STYLISED.search(surface) and not is_drawn_out(surface):
                aux_forms[lemma].add((surface, cform))
            continue
        if pos1 not in ('動詞', '形容詞'):
            continue
        # Readings, not spellings: a row written 分る under the base 分かる would otherwise yield a
        # nonsense ending. Rules match kana, so kana endings are what they need.
        surface, base = hiragana(row[LEX_KANA]), hiragana(row[LEX_KANA_BASE])
        if not surface or not base:
            continue
        # A compound's base reading is its last element's own (つくる) while the form carries the
        # rendaku (形作った → ...づくった); only a voicing difference is rendaku. する → さ/し and
        # くる → こ change their first kana and are real forms.
        if surface[0] != base[0] and unvoiced(surface[0]) == base[0]:
            continue
        p = common_prefix(surface, base)
        ending, base_ending = surface[p:], base[p:]
        if not base_ending or not KANA.match(base_ending) or (ending and not KANA.match(ending)):
            continue
        if STYLISED.search(ending) or is_drawn_out(ending):
            continue
        endings[(ctype, cform)][(ending, base_ending)] += 1
        if not ending and p:
            stem_last_kana[(ctype, cform)][surface[p - 1]] += 1
    return endings, stem_last_kana, aux_forms


def one_rule_per_line(data):
    """deinflection.json with each rule on a line of its own: readable, and a diff shows one line per
    changed rule."""
    lines = ['{']
    keys = list(data)
    for index, key in enumerate(keys):
        comma = ',' if index < len(keys) - 1 else ''
        value = data[key]
        if isinstance(value, list) and value and isinstance(value[0], dict):
            lines.append(f'  {json.dumps(key, ensure_ascii=False)}: [')
            lines += [f'    {json.dumps(rule, ensure_ascii=False)}' + (',' if i < len(value) - 1 else '') for i, rule in enumerate(value)]
            lines.append(f'  ]{comma}')
        else:
            lines.append(f'  {json.dumps(key, ensure_ascii=False)}: {json.dumps(value, ensure_ascii=False)}{comma}')
    lines.append('}')
    return '\n'.join(lines) + '\n'


def option(name, default=None):
    """The value after --name on the command line, else the default."""
    return sys.argv[sys.argv.index(name) + 1] if name in sys.argv else default


def sha256(path):
    """Hex SHA-256 of a file, for the build record."""
    with open(path, 'rb') as f:
        return hashlib.sha256(f.read()).hexdigest()


def is_omitted(rule, patterns):
    """Whether a generated rule matches one of the grammar's omittedPatterns."""
    for pattern in patterns:
        if 'kanaIn' in pattern and not re.search(pattern['kanaIn'], rule['kanaIn']):
            continue
        if 'kanaOut' in pattern and not re.search(pattern['kanaOut'], rule['kanaOut']):
            continue
        if 'rulesOut' in pattern and rule['rulesOut'] != pattern['rulesOut']:
            continue
        return True
    return False


def merged(groups):
    """Merges, within a group, rules that differ only in the steps they accept (rulesIn is unioned)
    or in naming a helper (the one naming it is kept): the deinflector treats them as one rule."""
    out = {}
    for group, rules in groups.items():
        by_shape = {}
        for rule in rules:
            shape = (rule['kanaIn'], rule['kanaOut'], tuple(rule['rulesOut']))
            kept = by_shape.get(shape)
            if kept is None or (kept.get('helper') and rule.get('helper') and kept['helper'] != rule['helper']):
                by_shape[shape if kept is None else shape + (rule['helper'],)] = rule
                continue
            kept['rulesIn'] = kept['rulesIn'] + [g for g in rule['rulesIn'] if g not in kept['rulesIn']]
            if rule.get('helper') and not kept.get('helper'):
                kept['helper'] = rule['helper']
        out[group] = list(by_shape.values())
    return out


def main():
    lex = sys.argv[1]
    grammar_path = option('--grammar', GRAMMAR_DEFAULT)
    extras_path = option('--extras', EXTRAS_DEFAULT)
    grammar = json.load(open(grammar_path, encoding='utf-8'))
    aux_words = grammar['auxiliaryConjugations']['words']
    aux_grammar = {aux: row['grammar'] for aux, row in aux_words.items()}
    voiced = grammar['voicing']['voiced']
    standalone_group = grammar['standaloneForms']['forms']
    standalone = set(standalone_group)

    endings, stem_last_kana, aux_forms = read_unidic(lex, set(aux_grammar))

    forms = collections.defaultdict(list)  # cType → [(cForm, ending, base ending)]
    for (ctype, cform), counter in endings.items():
        for (ending, base_ending), count in counter.items():
            if count >= MIN_WORDS or ctype.startswith(('サ行変格', 'カ行変格')):
                forms[ctype].append((cform, ending, base_ending))
    # ます takes further auxiliaries the way a verb does (まし + た, ませ + ぬ): its forms join the
    # conjugating words, written out whole since ます is a word of its own.
    forms['助動詞-マス'] = [(cform, surface, 'ます') for surface, cform in aux_forms['ます']]

    rules = {}  # (group, kanaIn, kanaOut, rulesIn, rulesOut) → (helper, source)

    def add(group, kana_in, kana_out, rules_in, rules_out, source, helper=None):
        key = (group, kana_in, kana_out, tuple(rules_in), tuple(rules_out))
        rules.setdefault(key, (helper, source))

    for ctype, ctype_forms in sorted(forms.items()):
        word_grammar = grammar_for(ctype)
        if word_grammar is None:
            continue
        cforms = {cf for cf, _, _ in ctype_forms}
        # The 連用形 that takes た/て: the 音便 form when the type has one, else 連用形-一般. A godan
        # ウ音便 (買うた) is Kansai speech; standard godan verbs take た on the other 音便.
        euphonic = [cf for cf in cforms if cf.startswith('連用形-') and cf.endswith('音便')
                    and not (word_grammar == 'v5' and cf == '連用形-ウ音便')] or ['連用形-一般']
        for cform, ending, base_ending in ctype_forms:
            unidic = f'UniDic {ctype} {cform}'
            is_voiced = ending.endswith('ん') or (ctype == '五段-ガ行' and cform == '連用形-イ音便')
            if cform in standalone and ending and word_grammar != 'masu':
                add(standalone_group[cform], ending, base_ending, [word_grammar], [word_grammar], unidic)
            for row in grammar['attachments']:
                if word_grammar not in row['after']:
                    continue
                if (cform not in euphonic) if row['form'] == 'euphonic' else (cform != row['form']):
                    continue
                attached = voiced.get(row['attach'], row['attach']) if is_voiced and row['attach'] in voiced else row['attach']
                rules_in = [row['gives']] if row['gives'] else [word_grammar]
                add(row['group'], ending + attached, base_ending, rules_in, [word_grammar],
                    f"{unidic} + {row['attach']} (attachments)", row.get('helper'))
            if word_grammar in grammar['stemCompounds']['after'] and cform == '連用形-一般':
                for word in grammar['stemCompounds']['words']:
                    for spelling in word['spellings']:
                        rules_in = [word['gives']] if word['gives'] else [word_grammar]
                        add(word['group'], ending + spelling, base_ending, rules_in,
                            [word_grammar], f'{unidic} + {spelling} (stemCompounds)', spelling)
            if word_grammar in ('v5', 'v1', 'vk', 'vs') and cform in euphonic:
                te = voiced['て'] if is_voiced else 'て'
                for helper in grammar['teHelpers']['words']:
                    add(helper['group'], ending + te + helper['word'], base_ending, [helper['gives']],
                        [word_grammar], f"{unidic} + {te}{helper['word']} (teHelpers)", helper['word'])
                for contraction in grammar['teHelpers']['contractions']:
                    form = contraction['voiced'] if is_voiced else contraction['plain']
                    add(contraction['group'], ending + form, base_ending, [contraction['gives'] or word_grammar],
                        [word_grammar], f'{unidic} + {form} (teHelpers.contractions)', contraction.get('helper'))

    # Ichidan stems (食べ, 続け) end in the stem itself, an empty ending a rule can't match on: such a
    # stem is matched by its last kana instead (べ → べる), one rule per kana ichidan stems end in.
    v1_stem_kana = collections.Counter()
    for (ctype, cform), counter in stem_last_kana.items():
        if grammar_for(ctype) == 'v1' and cform == '連用形-一般':
            v1_stem_kana.update(counter)
    for kana, count in v1_stem_kana.items():
        if count >= MIN_STEM_KANA_WORDS:
            add(grammar['standaloneForms']['ichidanStemGroup'], kana, kana + 'る', ['v1'], ['v1'],
                'UniDic 一段 連用形-一般 (bare stem, by its last kana)')

    # The auxiliaries' own forms: ました → ます (masu), なかった → ない (adj-i, through the adj-i rules).
    for aux, aux_word_grammar in aux_grammar.items():
        for surface, cform in sorted(aux_forms[aux]):
            if surface != aux and cform in standalone:
                add(aux_words[aux]['group'], surface, aux, [aux_word_grammar], [aux_word_grammar], f'UniDic 助動詞 {aux} {cform}')

    for row in grammar['fixedSequences']:
        add(row['group'], row['kanaIn'], row['kanaOut'], row['rulesIn'], row['rulesOut'], f"fixedSequences: {row['note']}")

    omitted = {(o['kanaIn'], o['kanaOut'], tuple(o['rulesOut'])) for o in grammar['omitted']}
    patterns = grammar['omittedPatterns']['patterns']
    groups = collections.defaultdict(list)
    for (group, kana_in, kana_out, rules_in, rules_out), (helper, source) in sorted(rules.items()):
        rule = {'kanaIn': kana_in, 'kanaOut': kana_out, 'rulesIn': list(rules_in), 'rulesOut': list(rules_out)}
        if (kana_in, kana_out, rules_out) in omitted or is_omitted(rule, patterns):
            continue
        if helper:
            rule['helper'] = helper
        rule['source'] = source
        groups[group].append(rule)
    extras = json.load(open(extras_path, encoding='utf-8'))
    for section in extras['sections']:
        for row in section['rules']:
            rule = {k: v for k, v in row.items() if k != 'group'}
            rule['source'] = 'deinflection-extras.json: ' + section['about'].split(':')[0]
            groups[row['group']].append(rule)
    out = merged(groups)
    out['nonIchidanRuVerbs'] = grammar['nonIchidanRuVerbs']
    out['intermediateForms'] = grammar['intermediateForms']
    out['build'] = {
        'generator': 'scripts/deinflection/generate_rules.py',
        'unidic': {'member': 'unidic-mecab_kana-accent-2.1.2_src/lex.csv', 'sha256': option('--unidic-sha', sha256(lex))},
        'grammar': {'file': 'Resources/deinflection-grammar.json', 'sha256': sha256(grammar_path)},
        'extras': {'file': 'Resources/deinflection-extras.json', 'sha256': sha256(extras_path)},
    }
    sys.stdout.write(one_rule_per_line(out))


if __name__ == '__main__':
    main()
