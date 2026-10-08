#!/bin/zsh
# Drop-in for `segcli run` with the boundary model applied: sentences on stdin, `run`'s format on stdout.
# Lets the regression scorers measure a model unchanged:
#   SEGCLI_RUN="boundary/run.sh work/boundary-path 3" python3 named_cases.py
set -e
HERE=${0:a:h}; WORK=${HERE:h}/work
MODEL=$1; WEIGHT=$2
TMP=$(mktemp -d)
trap 'rm -rf $TMP' EXIT
cat > $TMP/in.txt
python3 -c 'import json,sys
for l in open(sys.argv[1], encoding="utf-8"): print(json.dumps({"s": l.rstrip("\n"), "g": []}, ensure_ascii=False))' $TMP/in.txt > $TMP/in.jsonl
$WORK/segcli features < $TMP/in.jsonl > $TMP/in.features 2> $TMP/err
# MODEL may name several model folders, comma-separated: their P(cut) is averaged.
MODELS=(${(s:,:)MODEL})
for i in {1..${#MODELS}}; do python3 $HERE/predict.py ${MODELS[$i]} $TMP/in.features > $TMP/p$i.probs; done
python3 -c 'import json,sys
files=[open(f) for f in sys.argv[1:]]
for lines in zip(*files):
    ps=[json.loads(l) for l in lines]; print(json.dumps([sum(v)/len(v) for v in zip(*ps)]))' $TMP/p*.probs > $TMP/in.probs
print $WEIGHT > $TMP/w.txt
$WORK/segcli rescore $TMP/in.probs $TMP/w.txt $TMP < $TMP/in.txt 2>> $TMP/err
cat $TMP/cfg0.txt
