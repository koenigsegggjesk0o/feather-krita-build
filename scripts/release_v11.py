#!/usr/bin/env python3
"""v0.11 release: create the release on the private repo and upload installers.

Downloads the artifacts from the public builder repo's latest successful run
for head sha RELEASE_SHA, then publishes the release on koenigsegggjesk0o/krita.

Env: FEATHER_GH_TOKEN (required), RELEASE_SHA (optional; defaults to the
latest successful run's sha).
"""
import json
import os
import sys
import urllib.request

TOKEN = os.environ['FEATHER_GH_TOKEN']  # never hard-code tokens — pass via env
REPO = 'koenigsegggjesk0o/krita'
BUILD_REPO = 'koenigsegggjesk0o/feather-krita-build'
TAG = 'v0.11-memory-fix'
HEAD = 'https://api.github.com'
AUTH = {'Authorization': f'token {TOKEN}', 'Content-Type': 'application/json'}

BODY = """## Highlights — stability + the project loop closes
- **OOM fix (the big one)**: the texture undo stack used to snapshot the FULL
  2048x2048 texture (16 MB) **per brush dab** — a fast stroke stamped ~18 dabs
  and could allocate hundreds of MB of undo history, enough to get the app
  killed by the OS on low-memory devices. Undo now costs **one snapshot per
  stroke** (~40x less memory); discovered while chasing an intermittent
  CI crash, confirmed via kernel OOM logs.
- **Opening a .feather project now re-renders the canvas**: the project format
  stores strokes (no bitmap), and `applyTo` previously left the previous
  document's pixels (or a blank canvas) on screen. The document's strokes are
  now replayed into the texture through a new shared stroke-replay pipeline
  (same spacing heuristic + dab provider as GIF export), atomically, with
  per-stroke recorded thickness honored.
- Save -> open -> paint -> undo -> export now behaves as one coherent loop.
- Regression suite grown to **42 tests** (3x consecutive green), including
  undo-coalescing, replay-restore, and texture-non-empty-after-open checks.
- Housekeeping: corrected a stale FFI struct-size comment (64 bytes, not 72 —
  the exact mistake class that cost a debugging cycle in an earlier loop).

## Artifacts
- feather-krita-windows.zip — unzip, run feather_krita.exe (krita_bridge.dll
  side by side)
- feather-krita-android.apk — universal (arm64-v8a / armeabi-v7a / x86_64),
  native brush engine bundled per ABI

Commits: 44085e1 (private repo) / 1139566 (public CI repo sync)"""


def http(url, data=None, headers=None, method=None):
    req = urllib.request.Request(url, data=data, method=method,
                                 headers={'Authorization': f'token {TOKEN}',
                                          'Content-Type': 'application/json',
                                          **(headers or {})})
    return urllib.request.urlopen(req)


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
        except Exception as e:  # noqa: BLE001 — retry transient upload errors
            print(f'upload {name} attempt {attempt + 1} failed: {e}')
            import time
            time.sleep(10)
    sys.exit(f'giving up on {name}')


def main():
    out_dir = '/home/z/fkr-step1/build/release_v11'
    os.makedirs(out_dir, exist_ok=True)

    # Already downloaded + verified by hand (urllib drops the auth header on
    # the artifact 302 redirect; curl was used instead). Reuse them.
    ready = {
        'feather-krita-windows': os.path.join(out_dir, 'artifact_10523879661.zip'),
        'feather-krita-android': os.path.join(out_dir, 'artifact_10524205749.zip'),
    }
    for name, p in ready.items():
        if not os.path.exists(p):
            sys.exit(f'missing pre-downloaded artifact {name}: {p}')

    # 3. Create the release.
    payload = json.dumps({
        'tag_name': TAG,
        'target_commitish': 'feather-krita-flutter',
        'name': 'Feather-Krita v0.11 — memory-stability + project-open restore',
        'body': BODY,
        'draft': False,
        'prerelease': False,
    }).encode()
    rel = json.load(http(f'{HEAD}/repos/{REPO}/releases', data=payload))
    print('release', rel['id'], rel['html_url'])

    # 4. Upload assets (artifact zips need re-zipping — GitHub wraps them).
    import zipfile
    mapping = [
        ('feather-krita-windows', 'feather-krita-windows.zip',
         'application/zip'),
        ('feather-krita-android', 'feather-krita-android.apk',
         'application/vnd.android.package-archive'),
    ]
    for art_name, asset_name, ctype in mapping:
        src = ready.get(art_name)
        if not src:
            print('WARNING: artifact missing:', art_name)
            continue
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
