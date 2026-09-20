# Joins Tatoeba indices to repo sentences; writes held-out/train sentence files + gold spans (json lines).
import re, sys, json
import os
S=sys.argv[1]
sent={}
for line in open(os.path.join(os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__)))),"Resources","sentence-pairs.tsv"),encoding="utf-8-sig"):
    p=line.rstrip("\n").split("\t")
    if len(p)>=2: sent[p[0]]=p[1]
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
