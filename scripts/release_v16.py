#!/usr/bin/env python3
"""v0.16 release: fetch artifacts from the public builder repo's latest
successful run (35317284942 @ fc1c919 — the loop-21 tree) and publish the
release on koenigsegggjesk0o/krita.

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
TAG = 'v0.16-undo-journal-ux'
HEAD = 'https://api.github.com'

BODY = """## Highlights — undo that finally matches the canvas, plus file-picker UX

### Unified undo journal (loop-20)
- **One journal drives strokes AND texture in lockstep.** Undoing a
  painted stroke now removes the 3D stroke AND reverts the canvas
  pixels together — previously the pixels stayed behind (divergence
  bug). Move / rotate / scale / liquify / mirror / delete stay
  strokes-only entries, so their undo never allocates the 16 MB pixel
  buffer.
- **Project open and New document are fully undoable** — undoing an
  open restores the pre-load pixels too (new).
- **Fixed a real memory leak**: 16 MB per project open was retained by
  a never-consumed texture snapshot. Gone.
- 7 new journal tests; suite grown to 68 tests, gated serially in CI.

### File-picker UX polish (loop-21)
- **Save As…** in the export sheet — name your export and save it
  anywhere (or browse via the system dialog); the default Export flow
  is unchanged.
- **Open dialog quick-picks** now show file size + relative modified
  time ("2 MB · 5m ago") and a per-row delete, with up to 10 recent
  exports.
- **Persistent "Recent projects"** — files you opened (e.g. copied in
  from email/cloud) reappear in the open dialog even when the exports
  folder is empty.
- **Post-export actions**: Copy path (clipboard) and Show in folder
  (file manager) straight from the success card.

## Also in this build (since v0.14)
- Camera pose persistence in project files, CAVLC residual MP4 encoder
  (30-33% smaller exports), GIF / glTF / PNG / MP4 export suite, Linux
  portable native brush engine (no libEGL needed).

## Artifacts
- feather-krita-windows.zip — unzip, run feather_krita.exe (krita_bridge.dll
  side by side)
- feather-krita-android.apk — universal (arm64-v8a / armeabi-v7a / x86_64),
  native brush engine bundled per ABI

Commits: a23cb1d (private repo) / CI sync: sha in the footer"""


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
    out_dir = '/home/z/fkr-step1/build/release_v16'
    os.makedirs(out_dir, exist_ok=True)

    # 1. Latest successful run on the builder repo.
    runs = json.load(http(f'{HEAD}/repos/{BUILD_REPO}/actions/runs'
                          '?status=success&per_page=3'))
    run = next(r for r in runs['workflow_runs'] if r['name'] != 'step2')
    run_id, sha = run['id'], run['head_sha'][:7]
    print(f'using run {run_id} @ {sha}')
    if sha != 'fc1c919':
        print(f'WARNING: expected fc1c919 (loop-21 tree), got {sha}')

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
        'name': 'Feather-Krita v0.16 — atomic undo journal + file picker UX',
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
