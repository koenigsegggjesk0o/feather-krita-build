#!/usr/bin/env python3
"""v0.14 release: fetch artifacts from the public builder repo's latest
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
TAG = 'v0.14-camera-persistence'
HEAD = 'https://api.github.com'
AUTH = {'Authorization': f'token {TOKEN}', 'Content-Type': 'application/json'}

BODY = """## Highlights — orbit camera pose now persists in project files
- **.feather project documents save and restore the orbit-camera pose**
  (yaw, pitch, distance, target) — reopening a project puts you back
  exactly where you left off (loop-18).
- **No fly-in animation on open**: CameraController.snapTo() jumps the
  damped orbit values and target together, so loading a project never
  plays a camera animation.
- **Additive format extension, zero breakage**: the camera block is an
  optional key inside format version 2 — older builds ignore it, older
  documents leave the camera untouched (covered by tests).
- **MP4 size win measured** (loop-18 benchmark, ships in v0.13's residual
  encoder): realistic painting content exports 30-33% smaller MP4s with
  CAVLC residuals vs the flat+PCM fallback; enableResiduals:false remains
  available on Mp4Exporter for the legacy shape.

## Also in this build (since v0.12)
- Real CAVLC residual coding by default, ffmpeg-exact (v0.13).
- GIF / glTF / PNG / MP4 export suite, camera persistence, 57-test
  regression suite, Linux portable native brush engine (no libEGL needed).

## Artifacts
- feather-krita-windows.zip — unzip, run feather_krita.exe (krita_bridge.dll
  side by side)
- feather-krita-android.apk — universal (arm64-v8a / armeabi-v7a / x86_64),
  native brush engine bundled per ABI

Commits: 6b71b74 (private repo) / see release notes for the CI sync sha"""


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
    out_dir = '/home/z/fkr-step1/build/release_v14'
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
        'name': 'Feather-Krita v0.14 — camera pose persists in project files',
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
