#!/usr/bin/env python3
"""v0.19 release: fetch artifacts from the public builder repo's successful
run 35324510431 @ 33413b0 (the loop-27 colour-history tree) and publish
the release on koenigsegggjesk0o/krita.

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
TAG = 'v0.19-colour-history'
HEAD = 'https://api.github.com'
EXPECTED_SHA = '33413b0'

BODY = """## Highlights — a persisted recent-colours palette

### Colour history (loop-27)
- **Every brush-colour pick is remembered** (most-recent-first, deduped,
  capped at the 12 most recent) and surfaced as tappable swatches in two
  places: the brush panel's new "Recent" row and a "Recent" section at
  the top of the colour-picker dialog.
- **Tap a swatch to reuse the colour instantly** — long-press a panel
  swatch to drop it from the palette. The active colour is outlined with
  an accent ring so you always know what you're painting with.
- **Persists across launches** via SharedPreferences; the palette is
  waiting for you on the next session. Hidden entirely until your first
  pick, so first-launch UI is unchanged.
- The picker's Recent section jumps the HSV wheel, hex field and sliders
  to the chosen colour (live preview — confirm to commit).
- Pure Dart, no native-engine coupling; 9 new unit tests (move-to-front
  dedup, cap clamping, load/restore, remove, clear, persistence hook,
  unmodifiable view). Suite grown to 92 tests, gated serially in CI.

## Also in this build (since v0.18)
- Brush stabilizer (persisted "Stroke smoothing" slider; raw live dabs +
  smooth recorded strokes — zero input lag), keyboard-driven editor
  (Ctrl+Z/Y/S/O/N, B/E/V/L hotkeys, [ / ] brush size, Delete/Esc), real
  About version label, atomic undo journal, file-picker UX polish
  (Save As, quick-pick size/time/delete, persistent recents, copy-path).

## Artifacts
- feather-krita-windows.zip — unzip, run feather_krita.exe (krita_bridge.dll
  side by side)
- feather-krita-android.apk — universal (arm64-v8a / armeabi-v7a / x86_64),
  native brush engine bundled per ABI

Commits: 9c33124 (private repo) / CI sync: sha in the footer"""


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
    import time
    for attempt in range(5):
        try:
            req = urllib.request.Request(url, data=data, method='POST',
                                         headers={'Authorization': f'token {TOKEN}',
                                                  'Content-Type': ctype})
            print(name, urllib.request.urlopen(req).status, len(data), 'bytes')
            return
        except Exception as e:  # noqa: BLE001
            print(f'upload {name} attempt {attempt + 1} failed: {e}')
            time.sleep(10)
    sys.exit(f'giving up on {name}')


def main():
    out_dir = '/home/z/fkr-step1/build/release_v19'
    os.makedirs(out_dir, exist_ok=True)

    # 1. Latest successful run on the builder repo.
    runs = json.load(http(f'{HEAD}/repos/{BUILD_REPO}/actions/runs'
                          '?status=success&per_page=3'))
    run = next(r for r in runs['workflow_runs'] if r['name'] != 'step2')
    run_id, sha = run['id'], run['head_sha'][:7]
    print(f'using run {run_id} @ {sha}')
    if sha != EXPECTED_SHA:
        print(f'WARNING: expected {EXPECTED_SHA} (loop-27 tree), got {sha}')

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
        'name': 'Feather-Krita v0.19 — colour history',
        'body': BODY + f'\nCI sync: {sha} (public builder repo, run {run_id})',
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
