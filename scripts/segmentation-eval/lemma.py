# Lemma accuracy on exact-span matches: our lemma counts as correct when it shares a dictionary
# entry with the gold headword (so する matches 為る, その matches 其の).
import sys, json, sqlite3, collections
import os
db=sqlite3.connect(os.path.join(os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__)))),"Resources","dictionary.sqlite"))
ent=collections.defaultdict(set)
for t,e in db.execute("select text, entry_id from kana_forms union all select text, entry_id from kanji"): ent[t].add(e)
for label,path in (("today",sys.argv[2]),("clean",sys.argv[3])):
    ok=bad=nolemma=0; wrong=collections.Counter()
    for g,o in zip(open(sys.argv[1],encoding="utf-8"),open(path,encoding="utf-8")):
        rec=json.loads(g); pos=0; segs={}
        for part in o.rstrip("\n").split("\x1e"):
            f=part.split("\x1f"); s=f[0]; segs[(pos,pos+len(s))]=(f[1] if len(f)>1 else ""); pos+=len(s)
        for a,b,head,_r,_v in rec["g"]:
            if (a,b) not in segs: continue
            lem=segs[(a,b)]
            if not lem: nolemma+=1; continue
            if lem==head or (ent.get(lem,set()) & ent.get(head,set())): ok+=1
            else: bad+=1; wrong[(rec["s"][a:b],lem,head)]+=1
    n=ok+bad+nolemma
    print(f"{label}: exact spans {n}  lemma correct {ok} ({100*ok/n:.2f}%)  wrong {bad} ({100*bad/n:.2f}%)  none {nolemma}")
    print("   top wrong (surface, ours, gold):", wrong.most_common(14))
