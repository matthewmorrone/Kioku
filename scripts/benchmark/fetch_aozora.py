#!/usr/bin/env python3
"""Fetches the benchmark's Aozora Bunko sample: up to three works per author for twelve authors, each a
public-domain work in modern spelling (新字新仮名) with ruby, chosen in catalogue order so the sample is
the same every run. Writes plain UTF-8 text to OUT/works/<author>_<title>.txt.

    fetch_aozora.py OUT"""
import csv, io, os, subprocess, sys, urllib.request, zipfile

AUTHORS = [('夏目', '漱石'), ('芥川', '竜之介'), ('宮沢', '賢治'), ('太宰', '治'), ('中島', '敦'), ('梶井', '基次郎'),
           ('坂口', '安吾'), ('新美', '南吉'), ('小川', '未明'), ('岡本', '綺堂'), ('寺田', '寅彦'), ('林', '芙美子')]
CATALOGUE = 'https://www.aozora.gr.jp/index_pages/list_person_all_extended_utf8.zip'


def main():
    out = sys.argv[1]
    os.makedirs(f'{out}/works', exist_ok=True)
    with zipfile.ZipFile(io.BytesIO(urllib.request.urlopen(CATALOGUE).read())) as archive:
        catalogue = archive.read(archive.namelist()[0]).decode('utf-8-sig')
    picked = {}
    for row in csv.DictReader(io.StringIO(catalogue)):
        author = (row['姓'], row['名'])
        if (author in AUTHORS and row['役割フラグ'] == '著者' and row['文字遣い種別'] == '新字新仮名'
                and row['作品著作権フラグ'] == 'なし' and 'ruby' in row['テキストファイルURL']
                and len(picked.setdefault(author, [])) < 3):
            picked[author].append((row['作品名'], row['テキストファイルURL']))
    count = 0
    for (family, given), works in picked.items():
        for title, url in works:
            with zipfile.ZipFile(io.BytesIO(urllib.request.urlopen(url).read())) as archive:
                for name in archive.namelist():
                    if name.endswith('.txt'):
                        text = archive.read(name).decode('shift_jis', errors='replace')
                        safe = title[:20].replace('/', '_')
                        open(f'{out}/works/{family}{given}_{safe}.txt', 'w').write(text)
                        count += 1
    print(f'aozora: {count} works from {len(picked)} authors')


if __name__ == '__main__':
    main()
