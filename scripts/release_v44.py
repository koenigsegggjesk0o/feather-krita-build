#!/usr/bin/env python3
"""v0.44 release: fetch the real-engine artifacts from the builder repo's
GREEN build-app run (linux zip + windows zip + android APK, each bundling
the unmodified Krita v6.0.4 engine) and publish on koenigsegggjesk0o/krita.

Loop-63 milestone this release carries: PRESET PARAM-MAP ABI — the
paintop-settings-level <param> name/value projection (KoResource preset
XML, document order, last-duplicate-wins) is now readable from Dart:
- C ABI (all three bridges): krita_brush_preset_param_count,
  krita_brush_preset_param_name(i), krita_brush_preset_param_value(i);
  real bridge projects the parsed preset map; fallback/portable export
  benign empties by design (curated scalar getters remain the fallback
  surface);
- Dart: presetParamCount / presetParamNameAt / presetParamValueAt /
  presetParams() (insertion-ordered Map<String,String>) with _checkAlive
  guards and null-safe reads;
- smoke gates: basic-5 count>=3, map parity, ColorSource/Type=='plain',
  CompositeOp=='normal' + documented absence of Krita/opacity (implicit
  master opacity in that stock preset), curated opacity stays 1.0;
  eraser map[Krita/opacity]=='100' derives currentOpacity (100/100==1.0)
  and map[CompositeOp]=='erase'.
- smoke fix note: the first build-app run (35656789641) FAILED its two
  real-engine legs because the initial gates assumed a Krita/opacity
  param that only the eraser stock preset carries; gates were corrected
  against the CDATA-parsed fixture XML and both legs went green.
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
TAG = 'v0.44-preset-params-abi'
HEAD = 'https://api.github.com'
APP_RUN_ID = int(os.environ.get('APP_RUN_ID', '35657522240'))  # green build-app run
APP_SHA = os.environ.get('APP_SHA', 'df4a8dd')      # matching app-repo tree
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

BODY = """Feather-Krita v0.44 — **preset param-map ABI (roadmap f)**.

Milestone (loop-63): brush preset loading is upgraded to the
paintop-settings level. The `<param>` name/value pairs of the loaded
KoResource preset (document order, last-duplicate-wins) are projected
through the thin C ABI wrapper to Dart — the app can now introspect what
the engine actually loaded, not just scalar hand-picked fields.

What changed:
- C ABI on the real bridge: `krita_brush_preset_param_count`,
  `krita_brush_preset_param_name(i)`, `krita_brush_preset_param_value(i)`
  (pointer lifetime per internal buffer; out-of-range/negative index
  return NULL); fallback + portable bridges export benign empties by
  design — raw map enumeration is a real-engine capability, curated
  scalar getters remain the fallback surface;
- Dart FFI: `presetParamCount` / `presetParamNameAt` /
  `presetParamValueAt` / `presetParams()` (insertion-ordered
  Map<String,String>) with alive-guards and null-safe reads;
- smoke gates extended: basic-5 preset count>=3 and map parity,
  `Krita/opacity=='100'`, master-opacity -> currentOpacity derivation
  (100/100==1.0), eraser `CompositeOp=='erase'`;
- unchanged Krita source: v6.0.4 upstream, byte-identical (builder CI
  clones it unpatched; only wrapper/bindings/smoke glue ever changed).

Also in this release: the Linux and Windows real-engine bundles
(rebuilt from the same engine run) and the Android real-engine APK
(boot milestone carried from v0.43).

Commits: app `df4a8dd` (param-map ABI + fixture-ground-truth smoke
fix) on `feather-krita-flutter`, builder mirror `2144dff`; green chain:
engine 35651091002 -> build-app APPRUN -> smoke SMOKEID (APK + evidence).
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
    os.makedirs('/tmp/v44rel', exist_ok=True)
    uploads = []
    for name, (asset, ctype) in ARTIFACTS.items():
        zpath = f'/tmp/v44rel/{name}.zip'
        # NOTE: out MUST differ from zpath — asset names share the artifact
        # name, and extracting onto the open archive truncates it mid-read
        # (the exact EOFError loop release_v43.py shipped with).
        out = f'/tmp/v44rel/payload-{asset}'
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
            'name': 'v0.44 — preset param-map ABI (paintop settings to Dart)',
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
    print('v0.44 release COMPLETE')


if __name__ == '__main__':
    main()
