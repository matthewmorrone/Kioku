#!/bin/zsh
# Scores a trained boundary model through the real path search: per set, P(cut) from predict.py, then
# `segcli rescore` at each weight, then score.py. Weight 0 is the shipped segmentation.
#   boundary/eval.sh work/boundary-path "0 0.25 0.5 1 2" held2k kana2k
set -e
HERE=${0:a:h}; EVAL=${HERE:h}; WORK=$EVAL/work
MODEL=$1; WEIGHTS=(${=2}); shift 2
OUT=${${(s:,:)MODEL}[1]}
[[ $MODEL == *,* ]] && OUT=$OUT-ensemble && mkdir -p $OUT
print -l $WEIGHTS > $OUT/weights.txt
for SET in "$@"; do
  # MODEL may name several model folders, comma-separated: their P(cut) is averaged, and
  # results go in the first folder.
  MODELS=(${(s:,:)MODEL})
  for i in {1..${#MODELS}}; do python3 $HERE/predict.py ${MODELS[$i]} $WORK/$SET.features > $WORK/$SET.p$i.probs; done
  python3 -c 'import json,sys
files=[open(f) for f in sys.argv[1:]]
for lines in zip(*files):
    ps=[json.loads(l) for l in lines]; print(json.dumps([sum(v)/len(v) for v in zip(*ps)]))' $WORK/$SET.p{1..${#MODELS}}.probs > $OUT/$SET.probs
  mkdir -p $OUT/$SET
  $WORK/segcli rescore $OUT/$SET.probs $OUT/weights.txt $OUT/$SET < $WORK/data/$SET.txt 2> $OUT/$SET/rescore.err
  for i in {1..${#WEIGHTS}}; do
    python3 $EVAL/score.py $WORK/data/$SET.jsonl $OUT/$SET/cfg$((i - 1)).txt > $OUT/$SET/score$((i - 1)).txt
    print -n "$SET weight ${WEIGHTS[$i]}: "
    awk '/^  (exact|straddle|split|merged)/ {printf "%s %s (%s)  ", $1, $3, $2} END {print ""}' $OUT/$SET/score$((i - 1)).txt
  done
done
