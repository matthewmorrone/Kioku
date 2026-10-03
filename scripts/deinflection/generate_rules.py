#!/usr/bin/env python3
"""Generates deinflection rules from UniDic's conjugation data, for comparison with the hand-written
Resources/deinflection.json.

Two inputs:
  - UniDic's lexicon (lex.csv): every inflected form of every verb, adjective and auxiliary, tagged
    with its conjugation type (cType) and form (cForm). The ending of each (cType, cForm) relative to
    the dictionary form comes from here — data, including the euphonic forms (書い, 行っ, 読ん) and the
    colloquial contractions (行きゃ, なきゃ).
  - ATTACHMENTS below: which form of a word each auxiliary or particle attaches to (た on the
    euphonic 連用形, ない on the 未然形, ば on the 仮定形 …). UniDic's connection matrix holds only
    smoothed costs, not grammaticality, so these few textbook facts are written out by hand.

Rules come out in deinflection.json's format: a rule rewrites a word ending in kanaIn to kanaOut when
the word's current grammar is in rulesIn, and leaves it with the grammar in rulesOut.

    python3 generate_rules.py <lex.csv> > generated.json
"""
import collections
import csv
import json
import re
import sys
import unicodedata

LEX_SURFACE, LEX_POS1, LEX_CTYPE, LEX_CFORM, LEX_KANA, LEX_KANA_BASE = 0, 4, 8, 9, 21, 22

# The grammar a word of each UniDic conjugation type ends on, named as deinflection.json names it.
def grammar_for(ctype):
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
    return {
        '助動詞-ナイ': 'adj-i', '助動詞-タイ': 'adj-i',
        '助動詞-レル': 'v1',
        '助動詞-マス': 'masu', '助動詞-タ': 'ta', '助動詞-ヌ': 'nu',
    }.get(ctype)

# Auxiliaries whose own forms get rules (ました → ます), keyed by dictionary form, with the grammar a
# word ending in them has. せる/させる conjugate as 下一段 verbs in UniDic.
AUXILIARIES = {'ない': 'adj-i', 'たい': 'adj-i', 'れる': 'v1', 'られる': 'v1', 'せる': 'v1', 'させる': 'v1',
               'ます': 'masu', 'た': 'ta', 'だ': 'ta', 'ぬ': 'nu'}

# Which form each auxiliary or particle attaches to, by word grammar. "euphonic" is the 連用形 that
# takes た/て: the 音便 form when the conjugation type has one, else 連用形-一般. Voiced allomorphs
# (だ, で, だり) follow ん and ガ行 イ音便.
ATTACHMENTS = [
    # (attaching word as written, grammar it gives the whole, word grammars it follows, cForm)
    ('ない', 'adj-i', {'v5', 'v1', 'vk', 'masu-no'}, '未然形-一般'),
    ('ぬ', 'nu', {'v5', 'v1', 'vk'}, '未然形-一般'),
    ('ず', 'nu', {'v5', 'v1', 'vk'}, '未然形-一般'),
    ('れる', 'v1', {'v5'}, '未然形-一般'),
    ('られる', 'v1', {'v1', 'vk'}, '未然形-一般'),
    ('せる', 'v1', {'v5'}, '未然形-一般'),
    ('させる', 'v1', {'v1', 'vk'}, '未然形-一般'),
    ('ない', 'adj-i', {'vs'}, '未然形-一般'),
    ('れる', 'v1', {'vs'}, '未然形-サ'),
    ('せる', 'v1', {'vs'}, '未然形-サ'),
    ('ず', 'nu', {'vs'}, '未然形-セ'),
    ('ぬ', 'nu', {'vs'}, '未然形-セ'),
    ('ます', 'masu', {'v5', 'v1', 'vk', 'vs'}, '連用形-一般'),
    ('たい', 'adj-i', {'v5', 'v1', 'vk', 'vs'}, '連用形-一般'),
    ('ながら', None, {'v5', 'v1', 'vk', 'vs'}, '連用形-一般'),
    ('た', 'ta', {'v5', 'v1', 'vk', 'vs', 'masu'}, 'euphonic'),
    ('て', 'te', {'v5', 'v1', 'vk', 'vs', 'masu'}, 'euphonic'),
    ('ぬ', 'nu', {'masu'}, '未然形-一般'),
    # Godan potential: the え-stem + る, itself an ichidan verb (書ける, 話せる). UniDic lists these as
    # verbs of their own rather than as a form of 書く, so the attachment is written here.
    ('る', 'v1', {'v5'}, '仮定形-一般'),
    ('なさい', None, {'v5', 'v1', 'vk', 'vs'}, '連用形-一般'),
    ('たり', None, {'v5', 'v1', 'vk', 'vs'}, 'euphonic'),
    # Adjectives: た/たり on the 促音便 (高かった), て and ない on the plain 連用形 (高くて, 高くない).
    ('た', 'ta', {'adj-i'}, '連用形-促音便'),
    ('たり', None, {'adj-i'}, '連用形-促音便'),
    ('て', 'te', {'adj-i'}, '連用形-一般'),
    ('ない', 'adj-i', {'adj-i'}, '連用形-一般'),
    ('ば', None, {'v5', 'v1', 'vk', 'vs', 'adj-i'}, '仮定形-一般'),
]
VOICED = {'た': 'だ', 'て': 'で', 'たり': 'だり'}

# Helper verbs folded onto a verb's て-form (持っている, 食べてしまう), and the contractions that fuse
# て with one (持ってる, 食べちゃう): (after て, grammar of the whole, helper's dictionary form). The
# voiced form (で, じゃう…) follows the same voicing as て.
TE_HELPERS = [
    ('いる', 'v1', 'いる'), ('しまう', 'v5', 'しまう'), ('おく', 'v5', 'おく'), ('くる', 'vk', 'くる'),
    ('いく', 'v5', 'いく'), ('ゆく', 'v5', 'ゆく'), ('ある', 'v5', 'ある'), ('みる', 'v1', 'みる'),
    ('あげる', 'v1', 'あげる'), ('くれる', 'v1', 'くれる'), ('もらう', 'v5', 'もらう'),
    ('ほしい', 'adj-i', 'ほしい'),
]
TE_CONTRACTIONS = [
    # (contraction after a plain て-form, after a voiced one, grammar, helper)
    ('てる', 'でる', 'v1', 'いる'), ('ちゃう', 'じゃう', 'v5', 'しまう'), ('とく', 'どく', 'v5', 'おく'),
    ('てく', 'でく', 'v5', 'いく'),
]

# Forms used on their own, with nothing attached: the word ends there.
STANDALONE = {'仮定形-融合', '命令形', '意志推量形', '終止形-撥音便', '連用形-融合', '連用形-一般'}

KANA = re.compile(r'^[ぁ-ゖ]+$')
# Elongated or stylised spellings UniDic also lists (ね〜, でぇぇす, たぁ): not conjugation.
STYLISED = re.compile(r'[ー〜ぁぃぅぇぉ]$|ぁ|ぃ|ぅ|ぇ|ぉ')


def hiragana(text):
    """Folds UniDic's katakana readings to hiragana, the script rules match."""
    return ''.join(chr(ord(c) - 0x60) if 'ァ' <= c <= 'ヶ' else c for c in text)


# The vowel each kana ends in, for spotting a drawn-out spelling (しい for し, けえ for け, りゃあ).
VOWEL_ROWS = {
    'あ': 'あかさたなはまやらわがざだばぱゃ', 'い': 'いきしちにひみりぎじぢびぴ',
    'う': 'うくすつぬふむゆるぐずづぶぷゅ', 'え': 'えけせてねへめれげぜでべぺ',
    'お': 'おこそとのほもよろをごぞどぼぽょ',
}
VOWEL_OF = {kana: vowel for vowel, row in VOWEL_ROWS.items() for kana in row}


def is_drawn_out(text):
    """Whether a kana is followed by its own vowel (しい, けえ, ゃあ): a drawn-out, dialect or emphatic
    spelling, not a conjugation ending. おう and えい are excluded: they spell real long vowels (こう, せい)."""
    for a, b in zip(text, text[1:]):
        if b in 'あいえ' and VOWEL_OF.get(a) == b:
            return True
    return False


def unvoiced(kana):
    """The kana without its voicing mark (づ → つ, ば → は), for telling rendaku from a real change."""
    return unicodedata.normalize('NFC', unicodedata.normalize('NFD', kana).replace('\u3099', '').replace('\u309a', ''))


def common_prefix(a, b):
    n = 0
    while n < min(len(a), len(b)) and a[n] == b[n]:
        n += 1
    return n


def main():
    lex = sys.argv[1]
    # (cType, cForm) → Counter of (ending, base ending), from rows of conjugating words.
    endings = collections.defaultdict(collections.Counter)
    aux_forms = collections.defaultdict(set)  # aux dictionary form → {(surface, cForm)}
    stem_last_kana = collections.defaultdict(collections.Counter)  # empty-ending forms → last stem kana
    examples = collections.defaultdict(list)  # (cType, cForm, ending, base) → words, for --explain
    for row in csv.reader(open(lex, encoding='utf-8')):
        if len(row) <= LEX_KANA_BASE:
            continue
        pos1, ctype, cform = row[LEX_POS1], row[LEX_CTYPE], row[LEX_CFORM]
        # Readings, not spellings: a row written 分る under the base 分かる would otherwise yield a
        # nonsense ending. Rules match kana, so kana endings are what they need.
        surface, base = hiragana(row[LEX_KANA]), hiragana(row[LEX_KANA_BASE])
        if ctype == '*' or ctype.startswith('文語'):
            continue
        if pos1 == '助動詞':
            if base in AUXILIARIES and KANA.match(surface) and not STYLISED.search(surface):
                aux_forms[base].add((surface, cform))
            continue
        if pos1 not in ('動詞', '形容詞'):
            continue
        # A compound's base reading is its last element's own (つくる) while the form carries the
        # rendaku (形作った → ...づくった); such rows say nothing about endings. Only a voicing
        # difference is rendaku: する → さ/し and くる → こ change their first kana and are real forms.
        if not surface or not base:
            continue
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
        examples[(ctype, cform, ending, base_ending)].append(row[LEX_SURFACE])

    # A (cType, cForm) ending must be attested by enough words to be conjugation, not one word's quirk.
    MIN_WORDS = 10
    forms = collections.defaultdict(list)  # cType → [(cForm, ending, base ending)]
    for (ctype, cform), counter in endings.items():
        for (ending, base_ending), count in counter.items():
            # する and 来る are their conjugation types' only real members (UniDic writes 勉強する as
            # 勉強 + する), so their forms count however few words show them.
            if count >= MIN_WORDS or ctype.startswith(('サ行変格', 'カ行変格')):
                forms[ctype].append((cform, ending, base_ending))

    # ます takes further auxiliaries the way a verb does (まし + た, ませ + ぬ): its forms join the
    # conjugating words, written out whole since ます is a word of its own.
    forms['助動詞-マス'] = [(cform, surface, 'ます') for surface, cform in aux_forms['ます']]

    rules = collections.defaultdict(set)  # group → {(kanaIn, kanaOut, rulesIn, rulesOut, helper)}
    for ctype, ctype_forms in forms.items():
        grammar = grammar_for(ctype)
        if grammar is None:
            continue
        cforms = {cf for cf, _, _ in ctype_forms}
        # A godan ウ音便 (買うた, もうた) is Kansai speech; standard godan verbs take た on the other 音便.
        euphonic = [cf for cf in cforms if cf.startswith('連用形-') and cf.endswith('音便')
                    and not (grammar == 'v5' and cf == '連用形-ウ音便')] or ['連用形-一般']
        for cform, ending, base_ending in ctype_forms:
            if cform in STANDALONE and ending and grammar != 'masu':
                rules['standalone'].add((ending, base_ending, (grammar,), (grammar,), None))
            if grammar in ('v5', 'v1', 'vk', 'vs') and cform in euphonic:
                voiced = ending.endswith('ん') or (ctype == '五段-ガ行' and cform == '連用形-イ音便')
                te = 'で' if voiced else 'て'
                for after, gives, helper in TE_HELPERS:
                    rules['te+' + helper].add((ending + te + after, base_ending, (gives,), (grammar,), helper))
                for plain, voiced_form, gives, helper in TE_CONTRACTIONS:
                    rules['contraction:' + plain].add((ending + (voiced_form if voiced else plain), base_ending, (gives,), (grammar,), helper))
            for word, gives, follows, wants in ATTACHMENTS:
                if grammar not in follows:
                    continue
                if wants == 'euphonic':
                    if cform not in euphonic:
                        continue
                elif cform != wants:
                    continue
                voiced = word in VOICED and (ending.endswith('ん') or (ctype == '五段-ガ行' and cform == '連用形-イ音便'))
                attached = VOICED[word] if voiced else word
                kana_in = ending + attached
                rules_in = (gives,) if gives else (grammar,)
                rules['attach:' + word].add((kana_in, base_ending, rules_in, (grammar,), None))

    # Ichidan stems (食べ, 続け) end in the stem itself, an empty ending a rule can't match on: such a
    # stem is matched by its last kana instead (べ → べる), one rule per kana ichidan stems end in.
    v1_stem_kana = collections.Counter()
    for (ctype, cform), counter in endings.items():
        if grammar_for(ctype) == 'v1' and cform == '連用形-一般':
            for (ending, base_ending), count in counter.items():
                if ending == '' and base_ending == 'る':
                    v1_stem_kana.update(stem_last_kana[(ctype, cform)])
    for kana, count in v1_stem_kana.items():
        if count >= MIN_WORDS:
            rules['standalone'].add((kana, kana + 'る', ('v1',), ('v1',), None))

    # Fixed sequences of auxiliaries the attachments above don't compose: ない + で (しないで), and the
    # polite negative past ません + でした (食べませんでした).
    rules['aux:ない'].add(('ないで', 'ない', ('te',), ('adj-i',), None))
    rules['aux:ます'].add(('ませんでした', 'ます', ('masu',), ('masu',), None))

    # The auxiliaries' own forms: ました → ます (masu), なかった → ない (adj-i, through the adj-i rules).
    for aux, grammar in AUXILIARIES.items():
        for surface, cform in aux_forms[aux]:
            if surface != aux:
                rules['aux:' + aux].add((surface, aux, (grammar,), (grammar,), None))

    out = {}
    for group in sorted(rules):
        out[group] = [
            dict({'kanaIn': i, 'kanaOut': o, 'rulesIn': list(ri), 'rulesOut': list(ro)}, **({'helper': h} if h else {}))
            for i, o, ri, ro, h in sorted(rules[group], key=lambda r: r[:4])
        ]
    out['intermediateForms'] = ['te', 'masu', 'ta', 'nu']
    if '--explain' in sys.argv:
        for (ctype, cform, ending, base_ending), words in sorted(examples.items()):
            if len(words) >= MIN_WORDS:
                print(f'{ctype}\t{cform}\t{ending}→{base_ending}\t{len(words)}\t{" ".join(sorted(set(words))[:6])}', file=sys.stderr)
    json.dump(out, sys.stdout, ensure_ascii=False, indent=2)


if __name__ == '__main__':
    main()
