#!/bin/zsh
# Scores a trained boundary model through the real path search: per set, P(cut) from predict.py, then
# `segcli rescore` at each weight, then score.py. Weight 0 is the shipped segmentation.
#   boundary/eval.sh work/boundary-path "0 0.25 0.5 1 2" held2k kana2k
set -e
HERE=${0:a:h}; EVAL=${HERE:h}; WORK=$EVAL/work
MODEL=$1; WEIGHTS=(${=2}); shift 2
print -l $WEIGHTS > $MODEL/weights.txt
for SET in "$@"; do
  python3 $HERE/predict.py $MODEL $WORK/$SET.features > $MODEL/$SET.probs
  mkdir -p $MODEL/$SET
  $WORK/segcli rescore $MODEL/$SET.probs $MODEL/weights.txt $MODEL/$SET < $WORK/data/$SET.txt 2> $MODEL/$SET/rescore.err
  for i in {1..${#WEIGHTS}}; do
    python3 $EVAL/score.py $WORK/data/$SET.jsonl $MODEL/$SET/cfg$((i - 1)).txt > $MODEL/$SET/score$((i - 1)).txt
    print -n "$SET weight ${WEIGHTS[$i]}: "
    awk '/^  (exact|straddle|split|merged)/ {printf "%s %s (%s)  ", $1, $3, $2} END {print ""}' $MODEL/$SET/score$((i - 1)).txt
  done
done
