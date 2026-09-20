#!/usr/bin/env python3
"""v0.29 release: fetch ALL real-engine artifacts from the builder repo's
green build-app run (linux zip + windows zip + android APK, each bundling
the unmodified Krita v6.0.4 engine behind the flow/hardness ABI, now
user-controllable from the editor UI) and publish on koenigsegggjesk0o/krita.

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
TAG = 'v0.29-apk-runtime-closure'
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

BODY = """## Highlights — the shipped Android APK now carries a complete, modern load closure

### APK runtime defect campaign (loop-45)
- The android real-engine merge now ships a MODERN per-ABI libc++_shared
  runtime (NDK r29 sysroot copy, symbol-gated for
  __cxa_init_primary_exception). The previous r27c-era runtime genuinely
  lacked that symbol while the merged engine is compiled by the r29 clang
  — on-device CANNOT LINK proven by run 35507751331 and fixed
  harness-side in loop-43/44; this release brings the fix ENGINE-side.
- The merge link line now carries libQt5PrintSupport (kritawidgets
  QPrinter references, run 35509902482) and QuaZip (kritastore
  references, run 35509208740). Bionic resolves undefined symbols ONLY
  along the DT_NEEDED load closure, so without these edges the shipped
  APK would fail to dlopen libkrita_bridge.so on device.
- The staged runtime now satisfies the on-device-proven closure
  invariant by construction (DT_NEEDED completion + BFS reachability
  gate engine-side, transitive-closure audit in the APK build job) —
  an APK built from any unclosed artifact now fails CI loudly.
- Zero app-facing API changes; the full engine gate set (engine init,
  size, dab alpha, flow, hardness, paintop identity, real preset loads)
  re-validated on-device against the new artifact.

## Also in this build
- Everything from v0.28: brush picker family badges + name/family sort;
  v0.27: krita_brush_get_paintop_id + per-family hardness gating;
  v0.26: flow + hardness sliders in the editor UI; v0.25: the
  flow/hardness C ABI; v0.24: 16 real stock Krita presets +
  auto-eraser switching; v0.23: paintop-settings preset loading;
  v0.20-v0.22: the real Krita v6.0.4 brush engine (unmodified upstream
  source) on Linux, Windows and Android arm64-v8a behind one stable ABI.

## Artifacts
- feather-krita-linux-real-engine.zip — self-contained Linux bundle
  ($ORIGIN rpath; system Qt5/KF5 documented runtime deps)
- feather-krita-windows-real-engine.zip — Windows x64 (merged engine
  DLL + Qt5/KF5/vcpkg runtime DLLs beside the exe)
- feather-krita-android-real-engine.apk — arm64-v8a device APK
  (engine + Qt5 + KF5 + ICU + modern libc++_shared as jniLibs, closed
  DT_NEEDED load closure)

Status: real engine on ALL platforms + real preset loading + flow and
hardness user-controllable + paintop family identity end-to-end AND
visible across the editor UI + on-device-proven Android load closure
(this release).

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
    out_dir = '/home/z/fkr-step1/build/release_v29'
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
        'name': 'Feather-Krita v0.29 — Android load closure and modern libc++ runtime',
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
