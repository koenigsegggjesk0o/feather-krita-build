#!/usr/bin/env python3
"""v0.21 release: fetch the Windows real-engine artifact from the builder
repo's successful run 35450545562 @ 8ed0efd (loop-35 tree: real Krita
v6.0.4 engine end-to-end on WINDOWS through the app's own Dart FFI
bindings) and publish the release on koenigsegggjesk0o/krita.

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
TAG = 'v0.21-real-engine-windows'
HEAD = 'https://api.github.com'
RUN_ID = 35450545562          # loop-35 green run (build-windows-real-engine)
RUN_SHA = '8ed0efd'
APP_SHA = 'aab7642'           # matching app-repo tree (loop-35 final)
ARTIFACT = 'feather-krita-windows-real-engine'

BODY = """## Highlights — the REAL Krita brush engine ships on WINDOWS

### Windows real engine end-to-end (loop-35)
- This build bundles the **unmodified Krita v6.0.4 brush engine
  natively compiled for Windows** — real libkritalibbrush /
  libkritaimage / libkritapigment code built on CI by MSVC/clang-cl from
  the untouched upstream source tree, merged into ONE
  `krita_bridge.dll` behind the app's stable C ABI (`krita_bridge.h`
  byte-identical, Dart FFI untouched).
- **Dart FFI smoke green through the app's own `krita_bindings.dart` on
  the Windows CI runner**: exact colour passthrough (32/64/160/255 for
  0x2040A0), real gaussian falloff (centre alpha 255 vs edge
  transparent), pressure-to-alpha (128 = 255 x 0.5), pressure-to-size
  (width 39 = 64 x 0.6), eraser black-alpha mask — "FFI REAL-ENGINE
  SMOKE OK".
- The merged DLL carries 956 real Krita objects (image + brush +
  pigment + resources + store + command + metadata + psdutils + vendored
  raqm + ...) with Qt5/KF5 runtime DLLs bundled beside the exe — no
  system Qt/KF5 needed on the target machine.
- **Krita source: byte-identical upstream** — the directive
  "code krita asli" is satisfied by construction; every build fix in the
  chain was workflow/toolchain-level.

## Also in this build (since v0.20)
- Same Dart feature set as v0.20: colour history, brush stabilizer,
  keyboard-driven editor, atomic undo journal — all feeding the real
  engine on Windows now too.

## Artifacts
- feather-krita-windows-real-engine.zip — unzip, run
  feather_krita.exe (real engine loaded via the app's own FFI bindings)

Status: Linux DONE (v0.20) | Windows DONE (v0.21) | Next: Android
(NDK per-ABI, arm64-v8a first).

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
    out_dir = '/home/z/fkr-step1/build/release_v21'
    os.makedirs(out_dir, exist_ok=True)

    # 0. Idempotency: bail early if v0.21 already exists (422 lesson).
    rels = json.load(http(f'{HEAD}/repos/{REPO}/releases?per_page=100'))
    if any(r['tag_name'] == TAG for r in rels):
        print(f'{TAG} already exists — nothing to do')
        return

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
        'name': 'Feather-Krita v0.21 — real Krita engine (Windows)',
        'body': BODY,
        'draft': False,
        'prerelease': False,
    }).encode()
    rel = json.load(http(f'{HEAD}/repos/{REPO}/releases', data=payload))
    print('release', rel['id'], rel['html_url'])

    # 4. Upload asset (GitHub wraps artifacts — re-extract the inner zip).
    inner = os.path.join(out_dir, 'feather-krita-windows-real-engine.zip')
    with zipfile.ZipFile(dst) as z:
        names = z.namelist()
        if len(names) == 1:
            with z.open(names[0]) as f, open(inner, 'wb') as g:
                g.write(f.read())
        else:
            z.extractall(out_dir)
    upload_asset(rel['id'], inner, 'feather-krita-windows-real-engine.zip',
                 'application/zip')
    print('DONE:', rel['html_url'])


if __name__ == '__main__':
    main()
