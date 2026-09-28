#!/bin/zsh
# Compiles the app's real segmenter sources (cli/kioku-sources.txt) into work/segcli — no app or
# device build. The only patch: absorbingBoundCharacters is made internal so `fit`
# can build the lattice once per sentence and re-run just the path search per setting.
# If the compiler reports a missing type, add that file to cli/kioku-sources.txt.
set -e
HERE=${0:a:h}; ROOT=${HERE:h:h:h}; SRC=$ROOT/Kioku; WORK=${HERE:h}/work
mkdir -p $WORK/build
sed -e 's/private func absorbingBoundCharacters/func absorbingBoundCharacters/' \
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
# MeCab (optional): with Homebrew's mecab installed, a `mecab` module map over its header lets the
# app's MeCabTokenizer / MeCabSegmenter compile (they're `#if canImport(mecab)`) and enables
# `segcli mecab`. Without it the CLI builds as before, minus that mode.
MECAB_PREFIX=$(brew --prefix mecab 2>/dev/null || true)
MECAB_FLAGS=()
if [[ -n $MECAB_PREFIX && -f $MECAB_PREFIX/include/mecab.h ]]; then
  mkdir -p $WORK/build/mecab-module
  print -r -- "module mecab [system] { header \"$MECAB_PREFIX/include/mecab.h\" link \"mecab\" export * }" \
    > $WORK/build/mecab-module/module.modulemap
  MECAB_FLAGS=(-I $WORK/build/mecab-module -L $MECAB_PREFIX/lib)
  FILES+=($SRC/Dictionary/Segmenter/MeCabNode.swift $SRC/Dictionary/Segmenter/MeCabTokenizer.swift $SRC/Dictionary/Segmenter/MeCabSegmenter.swift)
fi
swiftc -O -o $WORK/segcli $FILES $HERE/Stub.swift $WORK/build/main.swift -lsqlite3 $MECAB_FLAGS
echo "built $WORK/segcli"
