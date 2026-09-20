#!/usr/bin/env python3
"""v0.24 release: fetch ALL real-engine artifacts from the builder repo's
green build-app run (linux zip + windows zip + android APK, each bundling
the unmodified Krita v6.0.4 engine behind the upgraded paintop-settings
preset loader) and publish on koenigsegggjesk0o/krita.

Env: FEATHER_GH_TOKEN (required). Artifact downloads go through curl -L.
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
TAG = 'v0.24-bundled-stock-presets'
HEAD = 'https://api.github.com'
APP_RUN_ID = int(os.environ.get('APP_RUN_ID', '0'))  # green build-app run
APP_SHA = os.environ.get('APP_SHA', '')      # matching app-repo tree
# artifact name -> (release asset name, content type)
ARTIFACTS = {
    'feather-krita-linux-real-engine': (
        'feather-krita-linux-real-engine.zip', 'application/zip'),
    'feather-krita-windows-real-engine': (
        'feather-krita-windows-real-engine.zip', 'application/zip'),
    'feather-krita-android-real-engine': (
        'feather-krita-android-real-engine.apk',
        'application/vnd.android.package-archive'),
}

BODY = """## Highlights — 16 REAL Krita stock presets bundled out of the box

### Bundled stock preset library (loop-38)
- The app now ships **16 unmodified Krita stock presets** as bundled
  assets, seeded into the preset browser on first launch: the
  per-paintop default presets (Paintbrush, Eraser, Round Marker,
  Airbrush Spray, Smudge, Color Smudge, Sketch, Curve, Particle, Deform,
  Hairy) plus named stock presets (Basic-5 Size, Eraser Circle, and
  three Watercolor variants) — all legacy PNG preset containers sourced
  from the KDE/krita repo (GPL-2.0-or-later, provenance in
  assets/brushes/README.md, fetch script in scripts/).
- **Curated display names** replace generic embedded XML names
  ("defaultPreset" -> "Paintbrush", "my_round_preset" -> "Round
  Marker", ...); user presets and custom names are untouched.
- **Auto-eraser UX**: loading an eraser preset now switches the active
  tool to the eraser automatically; loading a non-eraser preset
  afterwards returns to draw — but never overrides a manual tool
  choice. Detection mirrors the native bridge signals (Krita/erase,
  EraserMode, CompositeOp=erase, paintopid=eraser) as a pure-Dart
  `BrushPreset.isEraserPreset`, so it works identically with the real
  engine, the fallback bridge, and in tests (new unit tests included).
- Every bundled asset is parse-gated by a new flutter test (paintopId,
  settings, PNG thumbnail presence).

## Also in this build
- Everything from v0.23: paintop-settings-level preset loading through
  the real engine; v0.20-v0.22: the real Krita v6.0.4 brush engine
  (unmodified upstream source) shipping natively on Linux, Windows and
  Android arm64-v8a behind one stable C ABI with byte-identical Dart FFI
  bindings on every platform.

## Artifacts
- feather-krita-linux-real-engine.zip — self-contained Linux bundle
  ($ORIGIN rpath; system Qt5/KF5 documented runtime deps)
- feather-krita-windows-real-engine.zip — Windows x64 (merged engine
  DLL + Qt5/KF5/vcpkg runtime DLLs beside the exe)
- feather-krita-android-real-engine.apk — arm64-v8a device APK
  (engine + Qt5 + KF5 + ICU + libc++_shared as jniLibs)

Status: real engine on ALL platforms + real preset loading + real
stock presets bundled out of the box (this release).

Commits: {app} (private repo) / CI: builder repo (build-app run {run})
"""


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


def fetch_artifact(arts, name, out_dir):
    match = [a for a in arts['artifacts'] if a['name'] == name]
    if not match:
        sys.exit(f'artifact {name} not found: '
                 f'{[a["name"] for a in arts["artifacts"]]}')
    a = match[0]
    dst = os.path.join(out_dir, f'artifact_{a["id"]}.zip')
    if not os.path.exists(dst):
        curl_download(f'{HEAD}/repos/{BUILD_REPO}/actions/artifacts/'
                      f'{a["id"]}/zip', dst)
    print('downloaded', a['name'], os.path.getsize(dst), 'bytes')
    return dst


def extract_inner(artifact_zip, out_dir):
    """CI artifacts are a zip around the actual payload file(s)."""
    with zipfile.ZipFile(artifact_zip) as z:
        names = z.namelist()
        if len(names) == 1:
            inner = os.path.join(out_dir, names[0])
            with z.open(names[0]) as f, open(inner, 'wb') as g:
                g.write(f.read())
            return inner
        z.extractall(out_dir)
        return out_dir


def main():
    global APP_RUN_ID
    out_dir = '/home/z/fkr-step1/build/release_v23'
    os.makedirs(out_dir, exist_ok=True)

    # 0. Idempotency.
    rels = json.load(http(f'{HEAD}/repos/{REPO}/releases?per_page=100'))
    if any(r['tag_name'] == TAG for r in rels):
        print(f'{TAG} already exists — nothing to do')
        return

    # 1. Find the latest green build-app run carrying ALL three artifacts.
    if not APP_RUN_ID:
        runs = json.load(http(f'{HEAD}/repos/{BUILD_REPO}/actions/workflows/'
                              'build-app.yml/runs?status=success&per_page=10'))
        for r in runs['workflow_runs']:
            arts = json.load(http(f'{HEAD}/repos/{BUILD_REPO}/actions/runs/'
                                  f'{r["id"]}/artifacts'))
            names = {a['name'] for a in arts['artifacts']}
            if all(n in names for n in ARTIFACTS):
                APP_RUN_ID = r['id']
                break
    if not APP_RUN_ID:
        sys.exit('no green build-app run carries all three real-engine '
                 'artifacts yet')
    run = json.load(http(f'{HEAD}/repos/{BUILD_REPO}/actions/runs/{APP_RUN_ID}'))
    print('run', run['id'], run['status'], run['conclusion'],
          run['head_sha'][:7])
    if run['conclusion'] != 'success':
        sys.exit(f'run {APP_RUN_ID} is not success — aborting')
    sha = APP_SHA or run['head_sha'][:7]

    arts = json.load(http(f'{HEAD}/repos/{BUILD_REPO}/actions/runs/'
                          f'{APP_RUN_ID}/artifacts'))

    # 2. Download + extract every artifact BEFORE creating the release.
    payloads = {}
    for name, (asset_name, ctype) in ARTIFACTS.items():
        zpath = fetch_artifact(arts, name, out_dir)
        payloads[name] = (extract_inner(zpath, out_dir), asset_name, ctype)

    # 3. Create the release.
    body = BODY.format(run=APP_RUN_ID, app=sha)
    payload = json.dumps({
        'tag_name': TAG,
        'target_commitish': 'feather-krita-flutter',
        'name': 'Feather-Krita v0.23 — real Krita presets end-to-end',
        'body': body,
        'draft': False,
        'prerelease': False,
    }).encode()
    rel = json.load(http(f'{HEAD}/repos/{REPO}/releases', data=payload))
    print('release', rel['id'], rel['html_url'])

    # 4. Upload assets.
    for name, (path, asset_name, ctype) in payloads.items():
        if os.path.isdir(path):
            sys.exit(f'{name}: extracted to a directory, expected one file')
        upload_asset(rel['id'], path, asset_name, ctype)
    print('DONE:', rel['html_url'])


if __name__ == '__main__':
    main()
