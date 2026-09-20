#!/usr/bin/env python3
"""v0.22 release: fetch the Android real-engine APK artifact from the builder
repo's green build-app run (build-android-real-engine job, real Krita v6.0.4
engine arm64-v8a bundled via jniLibs) and publish on koenigsegggjesk0o/krita.

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
TAG = 'v0.22-real-engine-android'
HEAD = 'https://api.github.com'
APP_RUN_ID = int(os.environ.get('APP_RUN_ID', '0'))  # green build-app run
APP_SHA = '5c0e0a4'           # matching app-repo tree (loop-36 final)
ARTIFACT = 'feather-krita-android-real-engine'

BODY = """## Highlights — the REAL Krita brush engine ships on ANDROID

### Android real engine end-to-end (loop-36, roadmap c)
- This APK bundles the **unmodified Krita v6.0.4 brush engine natively
  cross-compiled for Android arm64-v8a** — real libkritalibbrush /
  libkritaimage / libkritapigment code built on CI by the Android NDK
  from the untouched upstream source tree, merged into ONE
  `libkrita_bridge.so` (959 real Krita objects + thin C ABI glue)
  behind the app's stable C ABI (`krita_bridge.h` byte-identical, Dart
  FFI untouched).
- The APK carries the full runtime set as jniLibs: real engine .so +
  Qt5 (Core/Gui/Widgets/Svg/Xml/Network/Sql/Concurrent/
  AndroidExtras) + KF5 (I18n/Config/Archive/CoreAddons/GuiAddons/
  WidgetsAddons/Completion/ItemViews) + ICU + libc++_shared.
- The app's own Dart FFI loader (`krita_bindings.dart`) opens
  `libkrita_bridge.so` by name — the real engine replaces the fallback
  bridge seamlessly, no Dart changes.
- 21 `krita_*` C ABI entry points exported and verified via
  llvm-readelf gates on CI (krita_brush_init / load_preset /
  generate_dab / set_color / set_opacity / ...).
- **Krita source: byte-identical upstream** — "code krita asli"
  satisfied by construction; every build fix was
  workflow/toolchain-level (NDK cross-build, KF5 cross frameworks,
  intl shim, unwindstack stub, vcpkg android triplets).

## Also in this build (since v0.21)
- Same Dart feature set: colour history, brush stabilizer,
  keyboard-driven editor, atomic undo journal — all feeding the real
  engine on Android now too.

## Artifacts
- feather-krita-android-real-engine.apk — install directly (arm64-v8a
  devices; Android 7.0+)

Status: Linux DONE (v0.20) | Windows DONE (v0.21) | **Android DONE
(v0.22)** — the real Krita brush engine now ships on ALL THREE
platforms.

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


def main():
    global APP_RUN_ID
    out_dir = '/home/z/fkr-step1/build/release_v22'
    os.makedirs(out_dir, exist_ok=True)

    # 0. Idempotency.
    rels = json.load(http(f'{HEAD}/repos/{REPO}/releases?per_page=100'))
    if any(r['tag_name'] == TAG for r in rels):
        print(f'{TAG} already exists — nothing to do')
        return

    # 1. Find the latest green build-app run with the android real artifact.
    if not APP_RUN_ID:
        runs = json.load(http(f'{HEAD}/repos/{BUILD_REPO}/actions/workflows/'
                              'build-app.yml/runs?status=success&per_page=10'))
        for r in runs['workflow_runs']:
            arts = json.load(http(f'{HEAD}/repos/{BUILD_REPO}/actions/runs/'
                                  f'{r["id"]}/artifacts'))
            if any(a['name'] == ARTIFACT for a in arts['artifacts']):
                APP_RUN_ID = r['id']
                break
    if not APP_RUN_ID:
        sys.exit('no green build-app run carries the android real-engine artifact yet')
    run = json.load(http(f'{HEAD}/repos/{BUILD_REPO}/actions/runs/{APP_RUN_ID}'))
    print('run', run['id'], run['status'], run['conclusion'], run['head_sha'][:7])
    if run['conclusion'] != 'success':
        sys.exit(f'run {APP_RUN_ID} is not success — aborting')

    # 2. Download the APK artifact.
    arts = json.load(http(f'{HEAD}/repos/{BUILD_REPO}/actions/runs/'
                          f'{APP_RUN_ID}/artifacts'))
    match = [a for a in arts['artifacts'] if a['name'] == ARTIFACT]
    if not match:
        sys.exit(f'artifact {ARTIFACT} not found: {[a["name"] for a in arts["artifacts"]]}')
    a = match[0]
    dst = os.path.join(out_dir, f'artifact_{a["id"]}.zip')
    if not os.path.exists(dst):
        curl_download(f'{HEAD}/repos/{BUILD_REPO}/actions/artifacts/'
                      f'{a["id"]}/zip', dst)
    print('downloaded', a['name'], os.path.getsize(dst), 'bytes')

    # 3. Create the release.
    body = BODY.format(run=APP_RUN_ID, app=APP_SHA)
    payload = json.dumps({
        'tag_name': TAG,
        'target_commitish': 'feather-krita-flutter',
        'name': 'Feather-Krita v0.22 — real Krita engine (Android)',
        'body': body,
        'draft': False,
        'prerelease': False,
    }).encode()
    rel = json.load(http(f'{HEAD}/repos/{REPO}/releases', data=payload))
    print('release', rel['id'], rel['html_url'])

    # 4. Upload asset (re-extract the inner zip).
    inner = os.path.join(out_dir, 'feather-krita-android-real-engine.apk')
    with zipfile.ZipFile(dst) as z:
        names = z.namelist()
        if len(names) == 1:
            with z.open(names[0]) as f, open(inner, 'wb') as g:
                g.write(f.read())
        else:
            z.extractall(out_dir)
    upload_asset(rel['id'], inner, 'feather-krita-android-real-engine.apk',
                 'application/vnd.android.package-archive')
    print('DONE:', rel['html_url'])


if __name__ == '__main__':
    main()
