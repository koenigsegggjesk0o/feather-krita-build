#!/usr/bin/env python3
"""v0.34 release: fetch ALL real-engine artifacts from the builder repo's
green build-app run (linux zip + windows zip + android APK, each bundling
the unmodified Krita v6.0.4 engine) and publish on koenigsegggjesk0o/krita.

Loop-51 highlights this release carries: the Feather-3D guide surface is
now texture-mapped PER FRAGMENT — brush dabs render through
drawVertices + ImageShader at full texture resolution (replacing the
per-triangle UV-centroid flat paint), UVs interpolate perspective-correct
(u/w), and screen-large triangles subdivide over a world-space barycentric
lattice on close-ups. Shared shading contract (tint × texture × alpha)
with a single implementation; async texture-image cache keyed on a new
TexturePainter.version serial. 13 new unit tests (suite 143).

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
TAG = 'v0.34-per-fragment-texturing'
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

BODY = """## Highlights — per-fragment perspective-correct surface texturing

### The guide surface is really texture-mapped now (loop-51)
- Previously each surface triangle painted ONE texture sample taken at
  its UV centroid — brush strokes showed as flat-colored facets. The
  pipeline now emits per-vertex UV corners on every triangle and the
  painter maps the rasterized guide texture ACROSS each triangle with
  `drawVertices` + `ImageShader`: dabs appear at full 2048² texture
  resolution, interpolated per fragment.
- Perspective-correct UV interpolation (`perspectiveCorrectUv`): u/w and
  1/w are interpolated linearly in screen space then divided — the same
  math a GPU applies per fragment; reduces exactly to plain barycentric
  when clip w is uniform.
- Adaptive subdivision for close-ups: triangles larger than
  2200 px² on screen split over a triangular barycentric lattice —
  lattice vertices are evaluated in WORLD space and projected exactly,
  never lerped in screen space — so the rasterizer's affine UV
  interpolation stays faithful when the surface fills the view. The
  default orbit pose stays below the threshold (zero extra cost).
- ONE shading contract: the tint × texture × fill-alpha ramp
  (0.35 bare glass → 0.95 painted) now lives in a single
  `applySurfaceContract` used by both the whole-buffer bake (per-
  fragment path) and the painter's per-UV fallback sampler — bit-exact
  with the legacy inline math.
- Async texture-image cache keyed on the new `TexturePainter.version`
  mutation serial (bumped only by real pixel changes) + surface tint;
  throttled to one re-raster per 150 ms while a live stroke is drawing;
  two generations kept alive so in-flight shaders never see a disposed
  image; legacy flat paint covers frames before the first decode lands.

### Still true from loop-50
- Unified depth-sorted scene pipeline: strokes and the guide surface
  share ONE back-to-front list — paint occludes correctly behind curved
  guides; stroke widths are true perspective (pixel-identical at the
  default pose); stroke ribbons are Lambert-lit.
- Real Krita v6.0.4 brush engine (unmodified source) on all three
  platforms, wired through the thin C ABI wrapper.

### Quality gates
- `flutter analyze`: 0 errors / 0 warnings (67 infos, at baseline).
- Full test suite 143/143 green (13 new: shading-contract exactness,
  bake purity, perspective-UV math, lattice-subdivision geometry and
  winding, texture mutation serial).
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
    os.makedirs('/tmp/fkr_rel34', exist_ok=True)
    files = {}
    for name, (asset, _) in ARTIFACTS.items():
        za = f'/tmp/fkr_rel34/{name}.zip'
        out = f'/tmp/fkr_rel34/{asset}'
        url = (f'{HEAD}/repos/{BUILD_REPO}/actions/artifacts/'
               f"{found[name]['id']}/zip")
        subprocess.run(['curl', '-sL', '-H', f'Authorization: token {TOKEN}',
                        '-o', za, url], check=True)
        with zipfile.ZipFile(za) as z:
            z.extractall(f'/tmp/fkr_rel34/x_{name}')
        inner = os.path.join('/tmp/fkr_rel34/x_' + name, asset)
        if not os.path.exists(inner):
            # some zips nest a directory
            for root, _, fs in os.walk(f'/tmp/fkr_rel34/x_{name}'):
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
            'name': 'Feather-Krita v0.34 — per-fragment texturing',
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

    print('RELEASE v0.34 OK')


if __name__ == '__main__':
    main()
