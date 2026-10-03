#!/usr/bin/env python3
"""Decomposes the composite rules of a deinflection.json into atomic ones.

Atoms come from a generated rules file (generate_rules.py): each is one grammatical step — one
ending plus one auxiliary — taken from UniDic, so a chain of atoms is a real derivation, never an
accident of spelling. For each rule of the input:
  - a chain of two or more atoms reproduces it (same ending, grammar and helper) → it is composite:
    it is replaced by its atoms, and each atom the input lacks is added;
  - it equals a single atom → it is atomic and stays;
  - no chain reproduces it → it stays as written, and is listed.
Chaining follows Deinflector.deinflectionPaths: a rule applies when the word ends in kanaIn and the
word's grammar (none at the start) is in rulesIn; the result takes each grammar in rulesOut.

    python3 decompose.py <deinflection.json> <generated.json> > decomposed.json   (log on stderr)
"""
import collections
import json
import sys

sys.path.insert(0, __file__.rsplit('/', 1)[0])
from generate_rules import one_rule_per_line  # noqa: E402

STEM = 'Ｘ'
MAX_STEPS = 5


def rule_groups(data):
    return [(group, rule) for group, value in data.items()
            if isinstance(value, list) and value and isinstance(value[0], dict) for rule in value]


def key(rule):
    return (rule['kanaIn'], rule['kanaOut'], tuple(sorted(rule['rulesIn'])), tuple(sorted(rule['rulesOut'])), rule.get('helper'))


def chain_for(atoms, rule):
    """The shortest chain of atoms taking STEM+kanaIn to STEM+kanaOut with a grammar in rulesOut,
    folding the rule's helper (or none), as (group, atom) pairs; None when there is none."""
    target, wanted = STEM + rule['kanaOut'], set(rule['rulesOut'])
    helper = (rule['helper'],) if rule.get('helper') else ()
    queue = collections.deque([(STEM + rule['kanaIn'], None, (), ())])
    seen = set()
    while queue:
        word, grammar, helpers, chain = queue.popleft()
        if (word, grammar, helpers) in seen:
            continue
        seen.add((word, grammar, helpers))
        if chain and word == target and grammar in wanted and helpers == helper:
            return chain
        if len(chain) >= MAX_STEPS:
            continue
        for group, atom in atoms:
            if not word.endswith(atom['kanaIn']) or (grammar is not None and grammar not in atom['rulesIn']):
                continue
            stem = word[:len(word) - len(atom['kanaIn'])]
            if not stem.startswith(STEM):
                continue
            folded = helpers + ((atom['helper'],) if atom.get('helper') else ())
            for next_grammar in atom['rulesOut']:
                queue.append((stem + atom['kanaOut'], next_grammar, folded, chain + ((group, atom),)))
    return None


def shape(rule):
    """A rule's identity apart from the steps it accepts: what it rewrites, into what, and folding what."""
    return (rule['kanaIn'], rule['kanaOut'], tuple(sorted(rule['rulesOut'])), rule.get('helper'))


def show(rule):
    return f"{rule['kanaIn']}→{rule['kanaOut']} [{','.join(rule['rulesOut'])}]"


def main():
    hand = json.load(open(sys.argv[1]))
    atoms = rule_groups(json.load(open(sys.argv[2])))
    atom_keys = {key(a) for _, a in atoms}
    out = collections.OrderedDict((g, []) for g, v in hand.items() if isinstance(v, list) and v and isinstance(v[0], dict))
    present = set()
    composite, atomic, kept = [], [], []
    added = collections.OrderedDict()
    for group, rule in rule_groups(hand):
        chain = chain_for(atoms, rule)
        if chain and len(chain) >= 2:
            composite.append((group, rule, chain))
            for atom_group, atom in chain:
                added.setdefault(key(atom), (atom_group, atom))
        else:
            (atomic if chain else kept).append((group, rule))
            if key(rule) not in present:
                out[group].append(rule)
                present.add(key(rule))
    # An atom that differs from a kept rule only in the steps it accepts (きます→く after `masu` vs
    # the hand rule after v5) widens that rule's rulesIn instead of becoming a second rule.
    by_shape = {}
    for rules in out.values():
        for rule in rules:
            by_shape.setdefault(shape(rule), rule)
    new_atoms, widened = [], []
    for k, (atom_group, atom) in added.items():
        if k in present:
            continue
        existing = by_shape.get(shape(atom))
        if existing is not None:
            extra = [g for g in atom['rulesIn'] if g not in existing['rulesIn']]
            if extra:
                existing['rulesIn'] = existing['rulesIn'] + extra
                widened.append((existing, extra))
            present.add(k)
            continue
        atom = {f: v for f, v in atom.items() if f != 'source'} | ({'source': atom['source']} if 'source' in atom else {})
        out.setdefault(atom_group, []).append(atom)
        by_shape[shape(atom)] = atom
        present.add(k)
        new_atoms.append((atom_group, atom))
    result = collections.OrderedDict((g, v) for g, v in out.items() if v)
    for g, v in hand.items():
        if not (isinstance(v, list) and v and isinstance(v[0], dict)):
            result[g] = v
    sys.stdout.write(one_rule_per_line(result))

    log = sys.stderr
    total = len(rule_groups(hand))
    print(f'{total} rules: {len(composite)} composite (decomposed), {len(atomic)} atomic, {len(kept)} not reproducible (kept as written); {len(new_atoms)} atoms added, {len(widened)} rules widened → {sum(len(v) for v in out.values())} rules', file=log)
    print('\n## Decomposed (rule = atoms; + marks an added atom)', file=log)
    by = collections.defaultdict(list)
    for group, rule, chain in composite:
        new_shapes = {shape(n) for _, n in new_atoms}
        parts = ' · '.join(('+' if shape(a) in new_shapes else '') + f"{a['kanaIn']}→{a['kanaOut']}" for _, a in chain)
        by[group].append(f'{show(rule)} = {parts}')
    for group in sorted(by, key=lambda g: -len(by[g])):
        print(f'### {group} ({len(by[group])})', file=log)
        print('\n'.join(by[group]), file=log)
    print('\n## Widened (now also accept)', file=log)
    for rule, extra in widened:
        print(f"{show(rule)} +{extra}", file=log)
    print('\n## Added atoms', file=log)
    for group, atom in new_atoms:
        print(f"{group}\t{show(atom)} in {atom['rulesIn']}\t{atom.get('source', '')}", file=log)
    print('\n## Not reproducible by atoms (kept as written)', file=log)
    for group, rule in kept:
        print(f'{group}\t{show(rule)} in {rule["rulesIn"]}' + (f" helper {rule['helper']}" if rule.get('helper') else ''), file=log)


if __name__ == '__main__':
    main()
