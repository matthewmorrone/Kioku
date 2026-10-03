#!/bin/zsh
# Regenerates Resources/deinflection.json from Resources/deinflection-grammar.json, the additions in
# Resources/deinflection-extras.json, and UniDic. The
# UniDic archive is the one data-manifest.json pins for pitch accent (unidic-kana-accent-src): fetched
# into a temporary folder, checked against its pinned checksum, and deleted afterwards — no cache.
set -euo pipefail
ROOT=${0:a:h:h:h}
cd $ROOT
read URL SHA MEMBER < <(python3 -c "
import json
e=next(x for x in json.load(open('Resources/data-manifest.json'))['resources'] if x['name']=='unidic-kana-accent-src')
print(e['fetch']['url'], e['fetch']['archiveSha256'], e['fetch']['member'])")
WORK=$(mktemp -d)
trap 'rm -rf $WORK' EXIT
echo "==> Fetching UniDic ($URL)…"
curl -sSL --fail -o $WORK/unidic.zip $URL
echo "$SHA  $WORK/unidic.zip" | shasum -a 256 -c --status || { echo "UniDic archive checksum mismatch" >&2; exit 1; }
unzip -q -o $WORK/unidic.zip $MEMBER -d $WORK
echo "==> Generating Resources/deinflection.json…"
python3 scripts/deinflection/generate_rules.py $WORK/$MEMBER --grammar Resources/deinflection-grammar.json --extras Resources/deinflection-extras.json > $WORK/deinflection.json
mv $WORK/deinflection.json Resources/deinflection.json
python3 -c "
import json; d=json.load(open('Resources/deinflection.json'))
print(sum(len(v) for v in d.values() if isinstance(v, list) and v and isinstance(v[0], dict)), 'rules')"
