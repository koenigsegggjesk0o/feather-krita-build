#!/usr/bin/env python3
"""v0.36 release: fetch ALL real-engine artifacts from the builder repo's
green build-app run (linux zip + windows zip + android APK, each bundling
the unmodified Krita v6.0.4 engine) and publish on koenigsegggjesk0o/krita.

Loop-53 highlights this release carries: .feather projects now PERSIST the
scene key light — an additive "light" block (sun azimuthDeg/elevationDeg +
diffuse intensity) rides along at format version 2, exactly like the loop-18
camera block: older builds ignore it, older documents load with the legacy-
identical default rig. Stored quantity is the rig's canonical sky
parametrization (trig-free exact round-trip) and the rig's own clamps make
corrupt values safe. 5 new unit tests (suite 163).

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
TAG = 'v0.37-light-power-dial'
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

BODY = """## Highlights — the Light power dial

### Light intensity is finally controllable (loop-54)
- The HUD's "power %" readout existed since loop-52 but nothing could
  change it — setIntensity was reachable only from code. A dial now
  sits above the HUD while the Light tool is active.
- The dial is the app's own glassmorphism slider (same component family
  as the brush flow/hardness controls): translucent track, glowing
  thumb, "Light power" label with a live % readout, arrow-key support
  stepping exactly 1 power point (100 divisions).
- Gesture isolation, locked by tests: the slider's detector wins the
  arena over the canvas, so a dial drag can NEVER orbit the sun or the
  camera — the rig's az/el stay bit-identical across a full sweep.
- onChanged routes through the rig's own [0, 1] clamp and repaints the
  scene the same frame: stroke ribbons re-light instantly through the
  Lambert path, from the pure-ambient floor (0%) to the full key light
  (100%).

### Still true from loop-50..53
- The Light tool orbits the sun by canvas drag, with a projected gizmo
  and a live HUD readout; .feather projects persist the whole rig
  (additive light block, version-2 compatible, clamped on load).
- Per-fragment texture mapping: the guide surface maps the painted
  texture per fragment (drawVertices + ImageShader), perspective-correct
  UVs, adaptive world-space lattice subdivision on close-ups.
- Real Krita v6.0.4 brush engine (unmodified source) on all three
  platforms, wired through the thin C ABI wrapper.

### Quality gates
- `flutter analyze`: 0 errors / 0 warnings (67 infos, at baseline).
- Full test suite 163/163 green (the light widget test extended: dial
  presence, clamp pins, ambient-floor sweep, HUD follow, gesture
  isolation).
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
    os.makedirs('/tmp/fkr_rel37', exist_ok=True)
    files = {}
    for name, (asset, _) in ARTIFACTS.items():
        za = f'/tmp/fkr_rel37/{name}.zip'
        out = f'/tmp/fkr_rel37/{asset}'
        url = (f'{HEAD}/repos/{BUILD_REPO}/actions/artifacts/'
               f"{found[name]['id']}/zip")
        subprocess.run(['curl', '-sL', '-H', f'Authorization: token {TOKEN}',
                        '-o', za, url], check=True)
        with zipfile.ZipFile(za) as z:
            z.extractall(f'/tmp/fkr_rel37/x_{name}')
        inner = os.path.join('/tmp/fkr_rel37/x_' + name, asset)
        if not os.path.exists(inner):
            # some zips nest a directory
            for root, _, fs in os.walk(f'/tmp/fkr_rel37/x_{name}'):
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
            'name': 'Feather-Krita v0.37 — light power dial',
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

    print('RELEASE v0.37 OK')


if __name__ == '__main__':
    main()
