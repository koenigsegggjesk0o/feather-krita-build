#!/usr/bin/env python3
"""v0.12 release: fetch artifacts from the public builder repo's latest
successful run and publish the release on koenigsegggjesk0o/krita.

Env: FEATHER_GH_TOKEN (required). Artifact downloads go through curl -L
(urllib drops the auth header on the artifact 302 redirect — see loop-14).
"""
import json
import os
import subprocess
import sys
import urllib.request
import zipfile

TOKEN = os.environ['FEATHER_GH_TOKEN']  # never hard-code tokens
REPO = 'koenigsegggjesk0o/krita'
BUILD_REPO = 'koenigsegggjesk0o/feather-krita-build'
TAG = 'v0.12-mp4-export'
HEAD = 'https://api.github.com'
AUTH = {'Authorization': f'token {TOKEN}', 'Content-Type': 'application/json'}

BODY = """## Highlights — MP4 video export, no plugins, every platform
- **MP4 export is real**: the export sheet's MP4 card now produces a
  playable **H.264 (Constrained Baseline) MP4** of the stroke replay —
  implemented in pure Dart across three new modules (encoder, ISO-BMFF
  muxer, exporter), with **no platform plugins**, so Windows and Android
  behave identically.
- **Encoder design**: every macroblock is either a flat I_16x16 prediction
  (3-6 bits; V/H/DC modes picked per block) or an I_PCM lossless block for
  brush edges — a deliberately conservative hybrid that is 100%
  spec-correct by construction and uses only two VLC codewords. Flat
  regions cost almost nothing; a 12-frame 512x512 clip runs ~0.7 MB.
- **Verified end to end against ffmpeg 7.1.5**: zero decode errors,
  correct container structure (ftyp/mdat/moov + avcC), exact 20 fps
  timing, and per-pixel colour checks for red/blue/yellow strokes.
- Fun debugging residue (see the repo worklog): three pieces of H.264
  folklore resolved by controlled experiments — the I_16x16 mb_type order,
  the standalone intra_chroma_pred_mode element (present for I_16x16 too),
  and ffmpeg's 0x40-fill rule for unavailable neighbours in nC derivation.
- Regression suite grown to **49 tests** (encoder mode selection, muxer
  structure, export scaling, plus an ffmpeg decode gate that runs when
  ffprobe is available and auto-skips otherwise).

## Artifacts
- feather-krita-windows.zip — unzip, run feather_krita.exe (krita_bridge.dll
  side by side)
- feather-krita-android.apk — universal (arm64-v8a / armeabi-v7a / x86_64),
  native brush engine bundled per ABI

Commits: d1eb3f8 (private repo) / see release notes for the CI sync sha"""


def http(url, data=None, headers=None, method=None):
    req = urllib.request.Request(url, data=data, method=method,
                                 headers={'Authorization': f'token {TOKEN}',
                                          'Content-Type': 'application/json',
                                          **(headers or {})})
    return urllib.request.urlopen(req)


def curl_download(url, path):
    r = subprocess.run(['curl', '-sL', '-H', f'Authorization: token {TOKEN}',
                        '-o', path, url], capture_output=True, text=True)
    if r.returncode != 0:
        sys.exit(f'curl failed: {r.stderr}')


def upload_asset(rid, path, name, ctype):
    data = open(path, 'rb').read()
    url = f'https://uploads.github.com/repos/{REPO}/releases/{rid}/assets?name={name}'
    for attempt in range(5):
        try:
            req = urllib.request.Request(url, data=data, method='POST',
                                         headers={'Authorization': f'token {TOKEN}',
                                                  'Content-Type': ctype})
            print(name, urllib.request.urlopen(req).status, len(data), 'bytes')
            return
        except Exception as e:  # noqa: BLE001
            print(f'upload {name} attempt {attempt + 1} failed: {e}')
            import time
            time.sleep(10)
    sys.exit(f'giving up on {name}')


def main():
    out_dir = '/home/z/fkr-step1/build/release_v12'
    os.makedirs(out_dir, exist_ok=True)

    # 1. Latest successful run on the builder repo.
    runs = json.load(http(f'{HEAD}/repos/{BUILD_REPO}/actions/runs'
                          '?status=success&per_page=3'))
    run = next(r for r in runs['workflow_runs'] if r['name'] != 'step2')
    run_id, sha = run['id'], run['head_sha'][:7]
    print(f'using run {run_id} @ {sha}')

    # 2. Download artifacts (curl -L for the 302 redirect).
    arts = json.load(http(f'{HEAD}/repos/{BUILD_REPO}/actions/runs/'
                          f'{run_id}/artifacts'))
    ready = {}
    for a in arts['artifacts']:
        name = a['name']
        if name not in ('feather-krita-windows', 'feather-krita-android'):
            continue
        dst = os.path.join(out_dir, f'artifact_{a["id"]}.zip')
        if not os.path.exists(dst):
            curl_download(f'{HEAD}/repos/{BUILD_REPO}/actions/artifacts/'
                          f'{a["id"]}/zip', dst)
        ready[name] = dst
        print('downloaded', name, os.path.getsize(dst), 'bytes')
    if len(ready) != 2:
        sys.exit(f'missing artifacts: {list(ready)}')

    # 3. Create the release.
    payload = json.dumps({
        'tag_name': TAG,
        'target_commitish': 'feather-krita-flutter',
        'name': 'Feather-Krita v0.12 — MP4 export (pure-Dart H.264)',
        'body': BODY + f'\nCI sync: {sha} (public builder repo)',
        'draft': False,
        'prerelease': False,
    }).encode()
    rel = json.load(http(f'{HEAD}/repos/{REPO}/releases', data=payload))
    print('release', rel['id'], rel['html_url'])

    # 4. Upload assets (GitHub wraps artifacts — re-extract).
    mapping = [
        ('feather-krita-windows', 'feather-krita-windows.zip',
         'application/zip'),
        ('feather-krita-android', 'feather-krita-android.apk',
         'application/vnd.android.package-archive'),
    ]
    for art_name, asset_name, ctype in mapping:
        src = ready[art_name]
        inner = os.path.join(out_dir, asset_name)
        with zipfile.ZipFile(src) as z:
            names = z.namelist()
            if len(names) == 1:
                with z.open(names[0]) as f, open(inner, 'wb') as g:
                    g.write(f.read())
            else:
                z.extractall(out_dir)
        upload_asset(rel['id'], inner, asset_name, ctype)
    print('DONE:', rel['html_url'])


if __name__ == '__main__':
    main()
