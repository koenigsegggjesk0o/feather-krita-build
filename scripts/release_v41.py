#!/usr/bin/env python3
"""v0.41 release: fetch ALL real-engine artifacts from the builder repo's
green build-app run (linux zip + windows zip + android APK, each bundling
the unmodified Krita v6.0.4 engine) and publish on koenigsegggjesk0o/krita.

Loop-58 highlights this release carries: the GUIDE-SURFACE PARITY CHECK —
the open dialog now shows a live verdict strip for the path being opened
(exact / aliased / unknown-name fallback / missing) instead of silently
restoring a different surface, and the save dialog discloses exactly what
a .feather write stores (type name; shape reopens at defaults). Backed by
a new strict name parser (guideSurfaceTypeFromNameStrict) that keeps the
tolerant loader bit-identical. 14 new tests (suite 192).

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
TAG = 'v0.41-guide-parity'
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

BODY = """## Highlights — guide-surface parity in the open/save dialogs

### The dialogs now tell the truth about guide surfaces (loop-58)
- A .feather document stores only the guide surface's NAME; loading
  rebuilds it through the tolerant parser, which used to fall back
  SILENTLY to Sphere for unknown names — a document could open with a
  different surface than it names and nothing on screen said so.
- The open dialog now shows a parity strip for the picked file: green =
  exact roundtrip, orange = known alias ("torus", "custom_curve",
  "SPHERE") restoring the right type under a different label, red =
  unknown name or no field (both open as Sphere). The verdict renders in
  the same frame the path changes, before the user commits to loading.
- The Save-As dialog discloses exactly what a .feather write stores:
  the canonical type name, plus the honest caveat that reopening builds
  the default shape of that type (the format stores the type, not its
  dimensions).
- New strict parser (guideSurfaceTypeFromNameStrict) is the single
  source of truth for the name mapping; the tolerant loader delegates
  to it, so pre-58 documents load bit-identically.

### Still true from loop-50..57
- The Light tool is a complete controller: canvas-drag sun orbit, glass
  power dial, one-tap preset row (Noon / Golden hour / Rim), live HUD,
  and full rig persistence in .feather projects.
- Per-fragment texture mapping with perspective-correct UVs and
  adaptive lattice subdivision; contour-edge feathering on the guide
  surface silhouette; degenerate-segment shading fixed on ribbons.
- Real Krita v6.0.4 brush engine (unmodified source) on all three
  platforms, wired through the thin C ABI wrapper.

### Quality gates
- `flutter analyze`: 0 errors / 0 warnings (67 infos, at baseline).
- Full test suite 192/192 green (14 new parity tests).
- Krita source byte-identical upstream; `analysis_options.yaml` and
  `pubspec.lock` untouched.

App commit: {SHA}
"""


def api(url, method='GET', data=None, headers=None):
    req = urllib.request.Request(url, method=method)
    req.add_header('Authorization', f'token {TOKEN}')
    req.add_header('Accept', 'application/vnd.github+json')
    for k, v in (headers or {}).items():
        req.add_header(k, v)
    body = json.dumps(data).encode() if data is not None else None
    try:
        with urllib.request.urlopen(req, body) as r:
            return r.status, json.loads(r.read() or b'{}')
    except urllib.error.HTTPError as e:
        return e.code, json.loads(e.read() or b'{}')


def main():
    if not APP_RUN_ID or not APP_SHA:
        sys.exit('APP_RUN_ID and APP_SHA are required')
    # 1. Resolve the green run + its artifacts.
    status, run = api(f'{HEAD}/repos/{BUILD_REPO}/actions/runs/{APP_RUN_ID}')
    if status != 200 or run.get('conclusion') != 'success':
        sys.exit(f'run {APP_RUN_ID} is not green (status={status}, '
                 f"conclusion={run.get('conclusion')})")
    status, arts = api(
        f'{HEAD}/repos/{BUILD_REPO}/actions/runs/{APP_RUN_ID}/artifacts')
    if status != 200:
        sys.exit(f'cannot list artifacts: {status}')
    found = {a['name']: a for a in arts.get('artifacts', [])}
    missing = [n for n in ARTIFACTS if n not in found]
    if missing:
        sys.exit(f'missing artifacts: {missing}')

    # 2. Download + unzip each artifact.
    os.makedirs('/tmp/fkr_rel41', exist_ok=True)
    files = {}
    for name, (asset, _) in ARTIFACTS.items():
        za = f'/tmp/fkr_rel41/{name}.zip'
        out = f'/tmp/fkr_rel41/{asset}'
        url = (f'{HEAD}/repos/{BUILD_REPO}/actions/artifacts/'
               f"{found[name]['id']}/zip")
        subprocess.run(['curl', '-sL', '-H', f'Authorization: token {TOKEN}',
                        '-o', za, url], check=True)
        with zipfile.ZipFile(za) as z:
            z.extractall(f'/tmp/fkr_rel41/x_{name}')
        inner = os.path.join('/tmp/fkr_rel41/x_' + name, asset)
        if not os.path.exists(inner):
            # some zips nest a directory
            for root, _, fs in os.walk(f'/tmp/fkr_rel41/x_{name}'):
                if asset in fs:
                    inner = os.path.join(root, asset)
                    break
        size = os.path.getsize(inner)
        print(f'{asset}: {size/1e6:.1f} MB')
        files[name] = (inner, asset, size)

    # 3. Create or reuse the release.
    status, rel = api(f'{HEAD}/repos/{REPO}/releases/tags/{TAG}')
    if status == 200:
        print(f'release {TAG} exists — idempotent re-run, reusing')
        rel_id = rel['id']
    else:
        status, rel = api(f'{HEAD}/repos/{REPO}/releases', 'POST', {
            'tag_name': TAG,
            'target_commitish': 'feather-krita-flutter',
            'name': 'Feather-Krita v0.41 — guide-surface parity',
            'body': BODY.replace('{SHA}', APP_SHA),
            'draft': False,
            'prerelease': False,
        })
        if status not in (201, 200):
            sys.exit(f'release create failed: {status} {rel}')
        rel_id = rel['id']
        print(f'release created: id={rel_id}')

    # 4. Upload assets (idempotent: delete-then-upload).
    for name, (path, asset, _) in files.items():
        status, existing = api(
            f'{HEAD}/repos/{REPO}/releases/{rel_id}/assets?per_page=100')
        for e in existing if isinstance(existing, list) else []:
            if e['name'] == asset:
                api(f"{HEAD}/repos/{REPO}/releases/assets/{e['id']}",
                    'DELETE')
                print(f"deleted stale asset {asset}")
        url = (f'https://uploads.github.com/repos/{REPO}/releases/'
               f'{rel_id}/assets?name={asset}')
        ctype = ARTIFACTS[name][1]
        cmd = ['curl', '-s', '-X', 'POST',
               '-H', f'Authorization: token {TOKEN}',
               '-H', f'Content-Type: {ctype}',
               '--data-binary', f'@{path}', url]
        r = subprocess.run(cmd, capture_output=True, text=True)
        ok = False
        try:
            resp = json.loads(r.stdout)
            ok = resp.get('state') == 'uploaded'
        except (ValueError, TypeError):
            ok = False
        if r.returncode != 0 or not ok:
            print(f'upload {asset}: rc={r.returncode} out={r.stdout[:200]}')
            sys.exit(f'asset upload failed: {asset}')
        print(f'uploaded {asset} (state=uploaded)')

    print('RELEASE v0.41 OK')


if __name__ == '__main__':
    main()
