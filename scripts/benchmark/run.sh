#!/bin/zsh
# Reproduces docs/ACCURACY.md: fetches the external data and the open-source analyzers into a
# throwaway folder, builds the gold sets, runs Kioku (its real furigana and segmentation code, through
# scripts/segmentation-eval's segcli) and each analyzer, and scores them all with the same rules.
#   scripts/benchmark/run.sh [WORK]        (default: a new temp folder; ~1 GB, deleted only by you)
# Needs: the `mecab` command with IPADic (Homebrew `mecab` + `mecab-ipadic`), python3, git, curl, and
# Resources/dictionary.sqlite (scripts/ensure_dictionary.sh). Kioku reads DB=<path> instead when set: the
# furigana's web and literature counts live in the dictionary (generate_db.py, import_reading_registers), so measure
# with one built since they were added. Heavy: run it on an idle, cool Mac.
set -e
HERE=${0:a:h}; ROOT=${HERE:h:h}; EVAL=$ROOT/scripts/segmentation-eval
WORK=${1:-$(mktemp -d)}; mkdir -p $WORK
echo "work folder: $WORK"

# Data: KWDLC (Kyoto University web corpus, research use) and a sample of Aozora Bunko works with ruby.
[ -d $WORK/KWDLC ] || git clone -q --depth 1 https://github.com/ku-nlp/KWDLC.git $WORK/KWDLC
[ -d $WORK/aozora/works ] || python3 $HERE/fetch_aozora.py $WORK/aozora
python3 $HERE/build_gold.py $WORK

# Analyzers in their own environment.
if [ ! -x $WORK/venv/bin/python ]; then
  python3 -m venv $WORK/venv
  $WORK/venv/bin/pip install -q sudachipy sudachidict_core fugashi unidic
  $WORK/venv/bin/python -m unidic download
fi

SETS=(tatoeba-held2k tatoeba-fresh5k aozora kwdlc)
$EVAL/cli/build.sh > $WORK/segcli-build.log 2>&1
export SWIFT_DETERMINISTIC_HASHING=1
for set in $SETS; do
  echo "$(date +%T)  $set: kioku, mecab, unidic, sudachi"
  $EVAL/work/segcli furigana < $WORK/$set.txt > $WORK/$set.kioku.fur 2>/dev/null
  $EVAL/work/segcli run < $WORK/$set.txt > $WORK/$set.kioku.seg 2>/dev/null
  python3 -I $HERE/run_analyzer.py mecab $WORK/$set.txt $WORK/$set.mecab
  for tool in unidic sudachiA sudachiC; do
    $WORK/venv/bin/python -I $HERE/run_analyzer.py $tool $WORK/$set.txt $WORK/$set.$tool
  done
done
python3 $HERE/score.py $WORK $ROOT/Resources/dictionary.sqlite ${(j:,:)SETS} kioku,mecab,unidic,sudachiA,sudachiC | tee $WORK/results.txt
echo "versions: kioku $(git -C $ROOT rev-parse --short HEAD), $($WORK/venv/bin/pip show sudachipy sudachidict_core fugashi unidic 2>/dev/null | grep -E '^(Name|Version)' | paste -sd' ' -), mecab $(mecab -v 2>&1 | head -1)" | tee -a $WORK/results.txt
