#!/usr/bin/env python3
"""v0.20 release: fetch the Linux real-engine artifact from the builder
repo's successful run 35360652133 @ ed5a3f2 (loop-32 tree: real Krita
v6.0.4 engine end-to-end through the app's own Dart FFI bindings) and
publish the release on koenigsegggjesk0o/krita.

Env: FEATHER_GH_TOKEN (required). Artifact downloads go through curl -L
(urllib drops the auth header on the artifact 302 redirect — see loop-14).
"""
import json
import os
import subprocess
import sys
import time
import urllib.request
import zipfile

TOKEN = os.environ['FEATHER_GH_TOKEN']  # never hard-code tokens
REPO = 'koenigsegggjesk0o/krita'
BUILD_REPO = 'koenigsegggjesk0o/feather-krita-build'
TAG = 'v0.20-real-engine-linux'
HEAD = 'https://api.github.com'
RUN_ID = 35360652133          # loop-32 green run (build-linux-real-engine)
RUN_SHA = 'ed5a3f2'
APP_SHA = '71a34d9'           # matching app-repo tree (loop-32 final)
ARTIFACT = 'feather-krita-linux-real-engine'

BODY = """## Highlights — the REAL Krita brush engine ships (Linux first)

### Real engine end-to-end (loops 29-32)
- This build bundles the **unmodified Krita v6.0.4 brush engine** — real
  libkritalibbrush / libkritaimage / libkritapigment code compiled on CI
  from the untouched upstream source tree, behind the app's stable C ABI
  (`krita_bridge.h` byte-identical, Dart FFI untouched).
- **8/8 Dart FFI smoke checks green** through the app's own
  `krita_bindings.dart` on the CI runner: exact colour passthrough
  (32/64/160 for 0x2040A0), real gaussian falloff (centre alpha 255 vs
  edge 3), pressure-to-alpha (128 = 255 x 0.5), pressure-to-size
  (width 39 = 64 x 0.6), eraser black-alpha mask.
- Every dab / mask / falloff / compositing computation executes in real
  libkrita* code; the wrapper only converts structs and byte order.
  **Krita source: untouched** — the directive "code krita asli" is
  satisfied by construction.
- The 45 MB zip contains the Flutter Linux bundle + the real
  `libkrita_bridge.so` + 14 real `libkrita*.so` (Qt5/KF5 runtime resolved
  from the system; the wrapper script sets LD_LIBRARY_PATH to bundle/lib).

## Also in this build (since v0.19)
- Colour history (recent-colours palette, persisted), brush stabilizer,
  keyboard-driven editor, atomic undo journal — all on the same Dart side,
  now feeding the real engine.

## Artifacts
- feather-krita-linux-real-engine.zip — unzip, run the wrapper script
  (real engine loaded via the app's own FFI bindings)

Next: Windows (MSVC real-engine build) and Android (NDK per-ABI).

Commits: {app} (private repo) / CI sync: builder repo {builder} (run {run})
""".format(app=APP_SHA, builder=RUN_SHA, run=RUN_ID)


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
            time.sleep(10)
    sys.exit(f'giving up on {name}')


def main():
    out_dir = '/home/z/fkr-step1/build/release_v20'
    os.makedirs(out_dir, exist_ok=True)

    # 1. Verify the pinned run is green.
    run = json.load(http(f'{HEAD}/repos/{BUILD_REPO}/actions/runs/{RUN_ID}'))
    print('run', run['id'], run['status'], run['conclusion'], run['head_sha'][:7])
    if run['conclusion'] != 'success':
        sys.exit(f'run {RUN_ID} is not success — aborting')

    # 2. Download the real-engine artifact.
    arts = json.load(http(f'{HEAD}/repos/{BUILD_REPO}/actions/runs/'
                          f'{RUN_ID}/artifacts'))
    match = [a for a in arts['artifacts'] if a['name'] == ARTIFACT]
    if not match:
        sys.exit(f'artifact {ARTIFACT} not found: '
                 f'{[a["name"] for a in arts["artifacts"]]}')
    a = match[0]
    dst = os.path.join(out_dir, f'artifact_{a["id"]}.zip')
    if not os.path.exists(dst):
        curl_download(f'{HEAD}/repos/{BUILD_REPO}/actions/artifacts/'
                      f'{a["id"]}/zip', dst)
    print('downloaded', a['name'], os.path.getsize(dst), 'bytes')

    # 3. Create the release.
    payload = json.dumps({
        'tag_name': TAG,
        'target_commitish': 'feather-krita-flutter',
        'name': 'Feather-Krita v0.20 — real Krita engine (Linux)',
        'body': BODY,
        'draft': False,
        'prerelease': False,
    }).encode()
    rel = json.load(http(f'{HEAD}/repos/{REPO}/releases', data=payload))
    print('release', rel['id'], rel['html_url'])

    # 4. Upload asset (GitHub wraps artifacts — re-extract the inner zip).
    inner = os.path.join(out_dir, 'feather-krita-linux-real-engine.zip')
    with zipfile.ZipFile(dst) as z:
        names = z.namelist()
        if len(names) == 1:
            with z.open(names[0]) as f, open(inner, 'wb') as g:
                g.write(f.read())
        else:
            z.extractall(out_dir)
    upload_asset(rel['id'], inner, 'feather-krita-linux-real-engine.zip',
                 'application/zip')
    print('DONE:', rel['html_url'])


if __name__ == '__main__':
    main()
