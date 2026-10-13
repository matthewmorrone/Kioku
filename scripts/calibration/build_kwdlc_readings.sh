#!/bin/zsh
# Rebuilds Kioku/Read/Furigana/kwdlc-reading-contexts.tsv from the readings annotated in KWDLC (Kyoto
# University Web Document Leads Corpus), training documents only: clones KWDLC at the pinned commit into a
# throwaway folder, counts with the same rules as the Tatoeba table (count_reading_contexts.py), and deletes
# the folder. Only counts are written; no KWDLC text is kept.
#   scripts/calibration/build_kwdlc_readings.sh
# Light: one clone, then segcli over ~14k sentences. Recount when reading-contexts.tsv is recounted (new
# transition classes).
set -e
HERE=${0:a:h}; ROOT=${HERE:h:h}; EVAL=$ROOT/scripts/segmentation-eval
COMMIT=c6ae49d29eca4e1134c6676d682adf5ed6a25f5a
WORK=$(mktemp -d); trap "rm -rf $WORK" EXIT
git clone -q https://github.com/ku-nlp/KWDLC.git $WORK/KWDLC
git -C $WORK/KWDLC checkout -q $COMMIT
python3 -I $HERE/count_reading_contexts.py kwdlc $WORK/KWDLC $ROOT/Resources/dictionary.sqlite > $WORK/kwdlc.jsonl
$EVAL/cli/build.sh > $WORK/segcli-build.log 2>&1
# The words the transition table classes by themselves ("w:" names), as segcli count takes them.
cut -f1,2 $ROOT/Kioku/Dictionary/Segmenter/segmenter-transitions.tsv | tr '\t' '\n' | sed -n 's/^w://p' | sort -u > $WORK/lexical.txt
export SWIFT_DETERMINISTIC_HASHING=1
$EVAL/work/segcli count $WORK/lexical.txt < $WORK/kwdlc.jsonl > $WORK/kwdlc.classes 2> $WORK/segcli-count.log
python3 -I $HERE/count_reading_contexts.py count $WORK/kwdlc.jsonl $WORK/kwdlc.classes > $ROOT/Kioku/Read/Furigana/kwdlc-reading-contexts.tsv
echo "wrote $(wc -l < $ROOT/Kioku/Read/Furigana/kwdlc-reading-contexts.tsv) rows"
