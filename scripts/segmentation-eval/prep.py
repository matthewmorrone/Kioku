# Joins Tatoeba indices to the dictionary's Japanese sentences (sentence_pairs in the pinned
# Resources/dictionary.sqlite, fetched if missing); writes held-out/train sentence files + gold spans (json lines).
import re, sys, json
import os, sqlite3, subprocess
S=sys.argv[1]
ROOT=os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
subprocess.run(["bash",os.path.join(ROOT,"scripts","ensure_dictionary.sh")],check=True)
db=sqlite3.connect(f"file:{os.path.join(ROOT,'Resources','dictionary.sqlite')}?mode=ro",uri=True)
sent={str(ja_id):japanese for ja_id,japanese in db.execute("SELECT DISTINCT ja_id, japanese FROM sentence_pairs")}
tok=re.compile(r'^(?P<head>[^\(\[\{~|]+)(?:\|\d+)?(?:\((?P<read>[^)]*)\))?(?:\[(?P<sense>\d+)\])?(?:\{(?P<surf>[^}]*)\})?(?P<ok>~)?$')
out={"held":open(f"{S}/held.jsonl","w"),"train":open(f"{S}/train.jsonl","w")}
txt={"held":open(f"{S}/held.txt","w"),"train":open(f"{S}/train.txt","w")}
seen=set()
for line in open(f"{S}/jpn_indices.csv",encoding="utf-8-sig"):
    p=line.rstrip("\n").split("\t")
    if len(p)<3 or p[0] in seen: continue
    s=sent.get(p[0])
    if s is None or "\n" in s: continue
    pos=0; spans=[]; ok=True
    for t in p[2].split():
        m=tok.match(t)
        if not m: ok=False; break
        surf=m.group("surf") or m.group("head")
        i=s.find(surf,pos)
        if i<0: ok=False; break
        spans.append([i,i+len(surf),m.group("head"),m.group("read") or "",1 if m.group("ok") else 0]); pos=i+len(surf)
    if not ok or not spans: continue
    seen.add(p[0])
    k="held" if int(p[0])%2 else "train"
    out[k].write(json.dumps({"id":p[0],"s":s,"g":spans},ensure_ascii=False)+"\n"); txt[k].write(s+"\n")
