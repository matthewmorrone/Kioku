#!/bin/zsh
# Compiles the app's real segmenter sources (cli/kioku-sources.txt) into work/segcli — no app or
# device build. The only patch: viterbiSelect / absorbingBoundCharacters are made internal so `fit`
# can build the lattice once per sentence and re-run just the path search per setting.
# If the compiler reports a missing type, add that file to cli/kioku-sources.txt.
set -e
HERE=${0:a:h}; ROOT=${HERE:h:h:h}; SRC=$ROOT/Kioku; WORK=${HERE:h}/work
mkdir -p $WORK/build
sed -e 's/private func viterbiSelect/func viterbiSelect/' -e 's/private func absorbingBoundCharacters/func absorbingBoundCharacters/' \
  $SRC/Dictionary/Segmenter/Segmenter.swift > $WORK/build/Segmenter.swift
cp $HERE/main.swift $WORK/build/main.swift
sed -i '' "s|URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().path|\"$ROOT\"|" $WORK/build/main.swift
FILES=()
for f in $(cat $HERE/kioku-sources.txt); do
  case $f in
    Dictionary/Segmenter/Segmenter.swift) FILES+=($WORK/build/Segmenter.swift) ;;
    *) FILES+=($SRC/$f) ;;
  esac
done
swiftc -O -o $WORK/segcli $FILES $HERE/Stub.swift $WORK/build/main.swift -lsqlite3
echo "built $WORK/segcli"
