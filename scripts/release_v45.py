#!/usr/bin/env python3
"""v0.45 release: fetch the real-engine artifacts from the builder repo's
GREEN build-app run (linux zip + windows zip + android APK, each bundling
the unmodified Krita v6.0.4 engine) and publish on koenigsegggjesk0o/krita.

v0.45 milestone (loops 65-67): PRESET INSPECTOR + ANDROID JNI HARDENING.
- Preset inspector UI (loop-65): long-press a brush-picker card opens an
  engine-authoritative view of the loaded preset — curated identity chips
  plus the FULL raw paintop-settings <param> map via the v0.44 param ABI
  (throwaway engine instance, never clobbers the active brush session;
  graceful Dart-parse fallback on stripped builds).
- Android JNI_OnLoad hardening (loops 66-67, corrected-approach-A): the
  build-app android job now renames JNI_OnLoad inside .dynstr of every
  staged Qt/KF5 runtime .so (both ABIs; byte-length preserving,
  structure-safe — GNU objcopy --localize-symbol was fixture-proven NOT
  to touch .dynsym) so ART's JNI_OnLoad search can never land on the Qt
  hooks that FindClass the absent Qt Android bootstrap (5-loop-61
  evidence). libkrita_bridge.so keeps its own hook (JavaVM capture +
  g_javaVm injection). A readelf audit gate asserts the bridge is the
  ONLY exporter on both ABIs. CI-proven: patcher localized
  libQt5Core/libQt5AndroidExtras on arm64-v8a + x86_64, gates green,
  emulator boot + 90s soak PASSING on the hardened APK.
- Roadmap (e): build-app.yml diagnostic step (flutter doctor -v) removed;
  push trigger + paths filter byte-identical.
Krita source remains byte-identical (v6.0.4 upstream).

Env: FEATHER_GH_TOKEN (required). APP_RUN_ID / APP_SHA / SMOKE_ID optional.
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
TAG = 'v0.45-android-jni-hardening'
HEAD = 'https://api.github.com'
APP_RUN_ID = int(os.environ.get('APP_RUN_ID', '35665622608'))  # green build-app run
APP_SHA = os.environ.get('APP_SHA', '7966a0a')      # app-repo commit of the built tree
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

BODY = """Feather-Krita v0.45 — **preset inspector UI + Android JNI hardening**.

Milestones (loops 65-67):
- **Preset inspector**: long-press any brush-picker card for the
  engine-authoritative view of the preset — curated identity chips plus
  the full raw paintop-settings `<param>` map (document order) read
  through the v0.44 param ABI on a throwaway engine (the active brush
  session is never clobbered); search-as-you-type, tap-to-expand long
  values, graceful Dart-parse fallback on stripped builds.
- **Android JNI_OnLoad hardening (corrected-approach-A)**: staged Qt/KF5
  runtime libs can no longer answer ART's JNI_OnLoad search — their
  hooks (which FindClass the absent Qt Android bootstrap and return
  JNI_ERR, killing the app at System.loadLibrary time) are renamed
  inside .dynstr at APK assembly (structure-preserving, idempotent;
  GNU objcopy --localize-symbol fixture-proven ineffective on
  .dynsym). libkrita_bridge.so keeps its own hook: JavaVM capture +
  g_javaVm injection + AssetManager. A readelf audit gate asserts the
  bridge is the ONLY exporter on arm64-v8a and x86_64.
- **CI hygiene (roadmap e)**: the loop-20-era flutter doctor -v
  diagnostic step removed from build-app.yml; trigger + paths filter
  untouched.

Evidence chain: engine 35651091002 -> build-app APPRUN (5/5; patcher +
audit gates green on real Qt/KF5 libs, NDK-install CDN flake cleared on
rerun) -> emulator smoke SMOKEID (boot + 90s soak PASSING on the
hardened APK). Krita source byte-identical.
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
    sizes = {}
    for a in arts.get('artifacts', []):
        if a['name'] in ARTIFACTS and not a['expired']:
            wanted[a['name']] = a['id']
            sizes[a['name']] = a['size_in_bytes']
    missing = set(ARTIFACTS) - set(wanted)
    if missing:
        sys.exit(f'FATAL: missing artifacts on run {APP_RUN_ID}: {missing}')
    print('artifacts found:', sorted(wanted))

    # 2. download + unzip each artifact to a single payload file
    os.makedirs('/tmp/v45rel', exist_ok=True)
    uploads = []
    for name, (asset, ctype) in ARTIFACTS.items():
        zpath = f'/tmp/v45rel/{name}.zip'
        # NOTE: out MUST differ from zpath — asset names share the artifact
        # name, and extracting onto the open archive truncates it mid-read
        # (the exact EOFError loop release_v43.py shipped with).
        out = f'/tmp/v45rel/payload-{asset}'
        member = None
        want_sz = sizes[name]
        for attempt in range(4):  # CDN truncation retries
            tmp = f'{zpath}.t{attempt}'
            r = subprocess.run(['curl', '-sL', '-H', f'Authorization: token {TOKEN}',
                                f'{HEAD}/repos/{BUILD_REPO}/actions/artifacts/'
                                f'{wanted[name]}/zip', '-o', tmp])
            if r.returncode != 0 or os.path.getsize(tmp) != want_sz:
                print(f'{name}: attempt {attempt+1}: rc={r.returncode} size '
                      f'{os.path.getsize(tmp) if os.path.exists(tmp) else 0} != {want_sz}; retrying...')
                continue
            os.replace(tmp, zpath)
            try:
                with zipfile.ZipFile(zpath) as z:
                    cands = [n for n in z.namelist()
                             if n.endswith(('.zip', '.apk')) and not n.endswith('/')]
                    if not cands:
                        sys.exit(f'FATAL: no payload in artifact {name}: {z.namelist()}')
                    member = cands[0]
                    with z.open(member) as src, open(out, 'wb') as dst:
                        while True:
                            chunk = src.read(1 << 20)
                            if not chunk:
                                break
                            dst.write(chunk)
                break  # clean extraction
            except (EOFError, zipfile.BadZipFile) as e:
                print(f'{name}: attempt {attempt+1} failed ({e!r}); retrying...')
                member = None
        if member is None:
            sys.exit(f'FATAL: {name} extraction failed after retries')
        sz = os.path.getsize(out)
        print(f'{name}: {member} -> {out} ({sz/1e6:.1f} MB)')
        if sz < 1_000_000:
            sys.exit(f'FATAL: {out} suspiciously small')
        uploads.append((out, asset, ctype))

    # 3. create the release on the app repo (idempotent: reuse if exists)
    smoke_id = os.environ.get('SMOKE_ID', 'PENDING')
    body = BODY.replace('APPRUN', str(APP_RUN_ID)).replace('SMOKEID', str(smoke_id))
    try:
        rel = api(f'{HEAD}/repos/{REPO}/releases/tags/{TAG}')
        print('release exists, reusing:', rel['html_url'])
    except urllib.error.HTTPError as e:
        if e.code != 404:
            raise
        rel = api(f'{HEAD}/repos/{REPO}/releases', 'POST', {
            'tag_name': TAG,
            'target_commitish': 'feather-krita-flutter',
            'name': 'v0.45 — preset inspector + Android JNI hardening',
            'body': body,
            'draft': False,
            'prerelease': False,
        })
        print('release created:', rel['html_url'])
    rel_id = rel['id']
    have = {a['name'] for a in api(f'{HEAD}/repos/{REPO}/releases/{rel_id}').get('assets', [])}

    # 4. upload assets (skip any already present)
    for out, asset, ctype in uploads:
        if asset in have:
            print('asset already present:', asset)
            continue
        url = (f'https://uploads.github.com/repos/{REPO}/releases/{rel_id}/assets'
               f'?name={asset}')
        data = open(out, 'rb').read()
        req = urllib.request.Request(url, data=data, method='POST')
        req.add_header('Authorization', f'token {TOKEN}')
        req.add_header('Content-Type', ctype)
        with urllib.request.urlopen(req) as r:
            print('uploaded:', json.loads(r.read())['browser_download_url'])
    print('v0.45 release COMPLETE')


if __name__ == '__main__':
    main()
