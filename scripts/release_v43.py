#!/usr/bin/env python3
"""v0.43 release: fetch the real-engine artifacts from the builder repo's
GREEN build-app run (linux zip + windows zip + android APK, each bundling
the unmodified Krita v6.0.4 engine) and publish on koenigsegggjesk0o/krita.

Loop-61 milestone this release carries: ANDROID REAL-ENGINE BOOT — the
strict emulator smoke (install + launch + 90s native x86_64 soak) is GREEN
for the first time through the app's own FlutterActivity: the fat dual-ABI
APK carries the merged engine (arm64-v8a device deliverable + x86_64
emulator-testable) with the bridge host-bootstrap (Kotlin System.loadLibrary
JNI_OnLoad capture, stub Qt Java classes, try-catch load safety net, and
the KCatalog probe entry-detour that neutralizes the last JNI wall).
Krita source remains byte-identical (v6.0.4 upstream).

Env: FEATHER_GH_TOKEN (required). Artifact downloads go through curl -L.
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
TAG = 'v0.43-android-real-engine-boot'
HEAD = 'https://api.github.com'
APP_RUN_ID = int(os.environ.get('APP_RUN_ID', '35637514266'))  # green build-app run
APP_SHA = os.environ.get('APP_SHA', 'c1c7084')      # matching app-repo tree
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

BODY = """Feather-Krita v0.43 — **Android real-engine boot**.

Milestone (loop-61): the strict Android emulator smoke is GREEN for the
first time — the app's own FlutterActivity boots the REAL, unmodified
Krita v6.0.4 brush engine (merged single-.so, NDK, dual ABI) and survives
a 90s native x86_64 soak with real brush strokes. The arm64-v8a engine is
bundled and audited alongside (device deliverable).

What the Android build now carries:
- fat dual-ABI APK: per-ABI `libkrita_bridge.so` (engine + bridge in one
  image) + the full Qt5/KF5 runtime closure, DT_NEEDED-audited per ABI;
- bridge host bootstrap: Kotlin `System.loadLibrary` (JNI_OnLoad VM
  capture), stub Qt Java classes so Qt's own `JNI_OnLoad` succeeds,
  try-catch load safety net, and the KCatalog probe entry-detour
  (binding-mode-proof neutralization of the last JNI wall);
- unchanged Krita source: v6.0.4 upstream, byte-identical (builder CI
  clones it unpatched; only wrapper/Kotlin/workflow glue ever changed).

Also in this release: the Linux and Windows real-engine bundles
(unchanged behavior, rebuilt from the same engine run).

Commits: app `c1c7084` (wrapper iter-4 detour) on `feather-krita-flutter`,
builder mirror `caca17a`; green chain: engine 35634412173 -> build-app
35637514266 -> smoke 35638282571 (APK + evidence).
"""


def api(url, method='GET', payload=None):
    data = json.dumps(payload).encode() if payload is not None else None
    req = urllib.request.Request(url, data=data, method=method)
    req.add_header('Authorization', f'token {TOKEN}')
    req.add_header('Accept', 'application/vnd.github+json')
    with urllib.request.urlopen(req) as r:
        body = r.read()
    return json.loads(body) if body else {}


def main():
    # 1. resolve the green build-app run's artifacts
    arts = api(f'{HEAD}/repos/{BUILD_REPO}/actions/runs/{APP_RUN_ID}/artifacts')
    wanted = {}
    for a in arts.get('artifacts', []):
        if a['name'] in ARTIFACTS and not a['expired']:
            wanted[a['name']] = a['id']
    missing = set(ARTIFACTS) - set(wanted)
    if missing:
        sys.exit(f'FATAL: missing artifacts on run {APP_RUN_ID}: {missing}')
    print('artifacts found:', sorted(wanted))

    # 2. download + unzip each artifact to a single payload file
    os.makedirs('/tmp/v43rel', exist_ok=True)
    uploads = []
    for name, (asset, ctype) in ARTIFACTS.items():
        zpath = f'/tmp/v43rel/{name}.zip'
        out = f'/tmp/v43rel/{asset}'
        subprocess.run(['curl', '-sL', '-H', f'Authorization: token {TOKEN}',
                        f'{HEAD}/repos/{BUILD_REPO}/actions/artifacts/'
                        f'{wanted[name]}/zip', '-o', zpath], check=True)
        with zipfile.ZipFile(zpath) as z:
            # find the single payload inside the artifact zip
            cands = [n for n in z.namelist()
                     if n.endswith(('.zip', '.apk')) and not n.endswith('/')]
            if not cands:
                sys.exit(f'FATAL: no payload in artifact {name}: {z.namelist()}')
            with z.open(cands[0]) as src, open(out, 'wb') as dst:
                dst.write(src.read())
        sz = os.path.getsize(out)
        print(f'{name}: {cands[0]} -> {out} ({sz/1e6:.1f} MB)')
        if sz < 1_000_000:
            sys.exit(f'FATAL: {out} suspiciously small')
        uploads.append((out, asset, ctype))

    # 3. create the release on the app repo
    rel = api(f'{HEAD}/repos/{REPO}/releases', 'POST', {
        'tag_name': TAG,
        'target_commitish': 'feather-krita-flutter',
        'name': 'v0.43 — Android real-engine boot (strict smoke green)',
        'body': BODY,
        'draft': False,
        'prerelease': False,
    })
    rel_id = rel['id']
    print('release created:', rel['html_url'])

    # 4. upload assets
    for out, asset, ctype in uploads:
        url = (f'{HEAD}/repos/{REPO}/releases/{rel_id}/assets'
               f'?name={asset}')
        data = open(out, 'rb').read()
        req = urllib.request.Request(url, data=data, method='POST')
        req.add_header('Authorization', f'token {TOKEN}')
        req.add_header('Content-Type', ctype)
        with urllib.request.urlopen(req) as r:
            print('uploaded:', json.loads(r.read())['browser_download_url'])
    print('v0.43 release COMPLETE')


if __name__ == '__main__':
    main()
