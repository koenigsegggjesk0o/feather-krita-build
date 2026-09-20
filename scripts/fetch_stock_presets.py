#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Feather-Krita App Contributors
# SPDX-License-Identifier: GPL-2.0-or-later
#
# fetch_stock_presets.py — download + validate real Krita stock presets
# for the bundled asset library (assets/brushes/).
#
# Source: github.com/KDE/krita (mirror of invent.kde.org), branch master.
# The GitHub mirror carries the repo under a "krita/" path prefix.
# License of the downloaded presets: GPL-2.0-or-later (same as this app).
#
# Validation mirrors the app's own parsing rules:
#   - PNG preset container: walk chunks, inflate zTXt/tEXt keyed "preset",
#     parse <Preset paintopid= name=>, extract MaskGenerator diameter.
#   - Bare XML preset: parse <Paintop>/<Preset> root.
#   - ZIP .kpp: (not present in the stock set; loader supports it.)
#
# Usage: python3 scripts/fetch_stock_presets.py [--out assets/brushes]

import os
import re
import sys
import urllib.parse
import urllib.request
import zlib
import xml.etree.ElementTree as ET

BASE = 'https://raw.githubusercontent.com/KDE/krita/master/'

# (source path in the KDE/krita mirror, bundled asset filename)
CANDIDATES = [
    # per-paintop default presets (plugins/paintops/defaultpresets)
    # NOTE: the GitHub KDE/krita mirror has a mixed layout —
    # plugins/* at the root, data/* under krita/ (verified via the
    # git trees API; see worklog 5-loop-38).
    ('plugins/paintops/defaultpresets/paintbrush.kpp',    'krita_paintbrush.kpp'),
    ('plugins/paintops/defaultpresets/eraser.kpp',        'krita_eraser.kpp'),
    ('plugins/paintops/defaultpresets/roundmarker.kpp',   'krita_roundmarker.kpp'),
    ('plugins/paintops/defaultpresets/spraybrush.kpp',    'krita_spraybrush.kpp'),
    ('plugins/paintops/defaultpresets/smudge.kpp',        'krita_smudge.kpp'),
    ('plugins/paintops/defaultpresets/colorsmudge.kpp',   'krita_colorsmudge.kpp'),
    ('plugins/paintops/defaultpresets/sketchbrush.kpp',   'krita_sketchbrush.kpp'),
    ('plugins/paintops/defaultpresets/curvebrush.kpp',    'krita_curvebrush.kpp'),
    ('plugins/paintops/defaultpresets/particlebrush.kpp', 'krita_particlebrush.kpp'),
    ('plugins/paintops/defaultpresets/deformbrush.kpp',   'krita_deformbrush.kpp'),
    ('plugins/paintops/defaultpresets/hairybrush.kpp',    'krita_hairybrush.kpp'),
    # named stock presets (data/paintoppresets) — small watercolors
    ('krita/data/paintoppresets/j)_WaterC_Basic_Round-Grain.kpp',     'krita_waterc_round_grain.kpp'),
    ('krita/data/paintoppresets/j)_WaterC_Basic_Round-Fringe_02.kpp', 'krita_waterc_round_fringe.kpp'),
    ('krita/data/paintoppresets/j)_WaterC_Spread.kpp',                'krita_waterc_spread.kpp'),
]


def fetch(src: str) -> bytes:
    url = BASE + urllib.parse.quote(src)
    last = None
    for attempt in range(5):
        try:
            req = urllib.request.Request(url, headers={'User-Agent': 'feather-krita-fetch/1.0'})
            with urllib.request.urlopen(req, timeout=60) as r:
                return r.read()
        except Exception as e:  # noqa: BLE001
            last = e
            print(f'    retry {attempt + 1}: {e}')
    raise RuntimeError(f'download failed: {url}: {last}')


def be32(b: bytes, o: int) -> int:
    return (b[o] << 24) | (b[o + 1] << 16) | (b[o + 2] << 8) | b[o + 3]


def png_extract_preset(png: bytes):
    """Walk PNG chunks; return (xml_bytes, None) for the 'preset' zTXt/tEXt."""
    pos = 8
    while pos + 8 <= len(png):
        length = be32(png, pos)
        ctype = png[pos + 4:pos + 8].decode('ascii', 'replace')
        if pos + 12 + length > len(png):
            return None, 'corrupt chunk'
        data = png[pos + 8:pos + 8 + length]
        if ctype in ('zTXt', 'tEXt'):
            nul = data.find(0)
            if nul > 0 and data[:nul].decode('latin-1').lower() == 'preset':
                if ctype == 'tEXt':
                    return data[nul + 1:], None
                if len(data) > nul + 2 and data[nul + 1] == 0:
                    try:
                        return zlib.decompress(data[nul + 2:]), None
                    except zlib.error as e:
                        return None, f'zlib: {e}'
        if ctype == 'IEND':
            break
        pos += 12 + length
    return None, 'no preset zTXt/tEXt chunk'


def summarize(xml_bytes: bytes) -> dict:
    root = ET.fromstring(xml_bytes)
    tag = root.tag.lower()
    paintop = root.get('paintopid') or root.get('paintop') or root.get('id') or '?'
    name = root.get('name') or root.get('id') or '?'
    params = {}
    for p in root.iter('param'):
        pn = p.get('name') or p.get('id')
        if pn:
            params[pn] = (p.get('value') or (p.text or '').strip())
    bd = params.get('brush_definition', '')
    m = re.search(r'diameter="(\d+)"', bd)
    diameter = m.group(1) if m else '-'
    return {
        'tag': tag,
        'paintop': paintop,
        'name': name,
        'diameter': diameter,
        'nparams': len(params),
        'erase': params.get('Krita/erase', params.get('EraserMode',
                    params.get('CompositeOp', '-'))),
        'opacity': params.get('Krita/opacity', '-'),
    }


def validate(data: bytes) -> dict:
    if data[:8] == b'\x89PNG\r\n\x1a\n':
        xml_bytes, err = png_extract_preset(data)
        if err:
            return {'format': 'PNG', 'ok': False, 'err': err}
        info = summarize(xml_bytes)
        info.update(format='PNG-preset', ok=True, size=len(data))
        return info
    if data[:4] == b'PK\x03\x04':
        return {'format': 'ZIP', 'ok': False, 'err': 'zip not expected in stock set'}
    # bare XML
    try:
        info = summarize(data)
        info.update(format='XML', ok=True, size=len(data))
        return info
    except ET.ParseError as e:
        return {'format': '?', 'ok': False, 'err': f'xml: {e}'}


def main() -> int:
    out_dir = 'assets/brushes'
    if '--out' in sys.argv:
        out_dir = sys.argv[sys.argv.index('--out') + 1]
    os.makedirs(out_dir, exist_ok=True)

    report = []
    for src, dest in CANDIDATES:
        print(f'  {src}')
        data = fetch(src)
        info = validate(data)
        info['dest'] = dest
        report.append((src, dest, info))
        flag = 'OK ' if info.get('ok') else 'FAIL'
        print(f'    [{flag}] {info.get("format")} {len(data)}B '
              f'paintop={info.get("paintop")} name={info.get("name")!r} '
              f'diameter={info.get("diameter")} params={info.get("nparams")} '
              f'erase={info.get("erase")} opacity={info.get("opacity")} '
              f'{info.get("err", "")}')
        if info.get('ok'):
            with open(os.path.join(out_dir, dest), 'wb') as f:
                f.write(data)

    ok = [r for r in report if r[2].get('ok')]
    print(f'\n{len(ok)}/{len(report)} presets validated and written to {out_dir}/')
    total = sum(r[2]['size'] for r in ok)
    print(f'total bundled payload: {total} bytes')
    return 0 if ok else 1


if __name__ == '__main__':
    sys.exit(main())
