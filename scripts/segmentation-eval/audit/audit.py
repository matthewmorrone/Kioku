"""Deinflection audit: does every gold surface resolve to its gold headword?
Inputs (made by collect.py and `segcli lemmas`): work/audit/pairs.json (surface, headword, reading,
count), work/audit/lemmas.txt (the real deinflector's lemma set per surface), the dictionary (forms → entries, entry → POS tags)."""
import json,sqlite3,collections,re,sys,os
WORK=os.path.join(os.path.dirname(os.path.abspath(__file__)),'..','work','audit')
import os
db=sqlite3.connect(os.path.join(os.path.dirname(os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))),"Resources","dictionary.sqlite"))
entries=collections.defaultdict(set); forms=collections.defaultdict(set)
for t in ('kanji','kana_forms'):
    for text,e in db.execute(f'select text,entry_id from {t}'): entries[text].add(e); forms[e].add(text)
pos=collections.defaultdict(set)
for e,p in db.execute('select entry_id,pos from senses where pos is not null'):
    pos[e]|={x.strip() for x in p.split(',')}
lemmas={}
for line in open(os.path.join(WORK,'lemmas.txt'),encoding='utf-8'):
    f=line.rstrip('\n').split(' ')
    lemmas[f[0]]={x.rsplit('=',1)[0] for x in f[3:] if x}
def conj_class(es):
    ts=set().union(*[pos[e] for e in es]) if es else set()
    for t in sorted(ts):
        if t.startswith('v1'): return 'v1'
    for t in sorted(ts):
        if t.startswith('v5'): return t
    for t in ('vs-i','vs-s','vk','vz','adj-i','adj-ix','aux-v','aux-adj','cop','aux'):
        if t in ts: return t
    if 'vs' in ts: return 'n+vs'
    return None
pairs=json.load(open(os.path.join(WORK,'pairs.json')))
total=sum(n for *_,n in pairs)
stat=collections.Counter(); rules=collections.defaultdict(lambda:[0,collections.Counter()]); other=collections.Counter()
for s,h,rd,n in pairs:
    head_entries=entries.get(h,set())
    if rd and not rd.startswith('#'): head_entries=head_entries & entries.get(rd,head_entries) or head_entries
    ls=lemmas.get(s,set())
    if any(entries.get(l,set())&head_entries for l in ls): stat['ok']+=n; continue
    kind='no edge at all' if not ls else 'resolves, but not to the gold headword'
    stat[kind]+=n
    cls=conj_class(head_entries)
    # ending pair: longest common prefix between the surface and any written form of the headword
    best=('',s,'?')
    for e in head_entries:
        for f in forms[e]:
            k=0
            while k<min(len(s),len(f)) and s[k]==f[k]: k+=1
            if k>len(best[0]) : best=(s[:k],s[k:],f[k:])
    if cls and best[0] and len(best[1])<=8:
        key=(cls,best[1],best[2],kind)
        rules[key][0]+=n; rules[key][1][s+'←'+h]+=n
    else:
        other[(s,h,kind)]+=n
print(f'gold tokens {total}')
for k,n in stat.most_common(): print(f'  {k:42s} {n:7d}  {100*n/total:5.2f}%')
print('\n== conjugated forms that fail, grouped by the missing ending (class, surface ending → lemma ending) ==')
for (cls,se,le,kind),(n,ex) in sorted(rules.items(),key=lambda kv:-kv[1][0])[:int(sys.argv[1]) if len(sys.argv)>1 else 60]:
    print(f'{n:6d}  {cls:8s} 〜{se or "∅"} → 〜{le or "∅"}   [{kind}]   e.g. '+', '.join(f'{w}×{c}' for w,c in ex.most_common(3)))
print('\n== failures that are not a conjugation of the headword (top) ==')
for (s,h,kind),n in other.most_common(40): print(f'{n:6d}  {s} ← {h}   [{kind}]')
json.dump([[list(k),v[0],v[1].most_common(5)] for k,v in rules.items()],open(os.path.join(WORK,'missing-rules.json'),'w'),ensure_ascii=False)
