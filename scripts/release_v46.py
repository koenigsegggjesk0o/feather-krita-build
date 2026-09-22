#!/usr/bin/env python3
"""v0.46 release: fetch the real-engine artifacts from the builder repo's
GREEN build-app run (linux zip + windows zip + android APK, each bundling
the unmodified Krita v6.0.4 engine) and publish on koenigsegggjesk0o/krita.

v0.46 milestone (loops 68-72): LIVE PARAM EDITING + ACTIVE-PRESET INSPECTOR.
- Active-preset inspector entry (loop-68): the brush settings panel's preset
  chip gains an inline inspect button — the engine-authoritative preset view
  is reachable for the preset the user is ACTUALLY painting with (two taps
  from anywhere in the editor); picker long-press still covers browsing.
- Live paintop-settings param editing (loops 69-72): new krita_brush_set_param
  C ABI — edits the param map of record (replace-or-append, document order)
  AND applies the live engine effect for consumed keys with the exact
  loadPreset bounds/alias semantics (Krita/opacity 0-100, OpacityValue/Flow/
  hardness/Softness/spacing/smudge aliases, eraser/CompositeOp; hardness
  edits rebuild the auto brush). Dart setParam() with an ArgumentError
  compat gate (old engine artifacts -> graceful "not supported").
  Settings panel gains the Engine params section: live count chip, filter
  field, monospace rows, tap-to-edit dialog, slider re-sync from the engine
  after each accepted edit; section hidden on engines without the symbol.
- CI-proven on real engines (loop-72, krita-build 35678879422, SMOKE OK):
  self-configuring replace-arm gate (map entry 0 edited in place, count
  flat), live opacity/flow/hardness gates, unknown-key append == exactly +1
  with read-back, argument rejections — on both desktop fixtures, Linux +
  Windows toolchains. Two empirical smoke-assertion lessons fixed en route
  (global count baseline was fixture-dependent; Krita/opacity is NOT a
  pre-existing map entry — loadPreset reads it from XML settings).
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
TAG = 'v0.46-live-param-editing'
HEAD = 'https://api.github.com'
APP_RUN_ID = int(os.environ.get('APP_RUN_ID', '0'))  # green build-app run
APP_SHA = os.environ.get('APP_SHA', '')              # app-repo commit of the built tree
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

BODY = """Feather-Krita v0.46 — **live paintop-settings param editing + active-preset inspector entry**.

Milestones (loops 68-72):
- **Live param editing** (roadmap (f) deepening): the ACTIVE preset's raw
  paintop-settings surface is now EDITABLE from the settings panel. New
  `krita_brush_set_param` C ABI: updates the param map of record
  (replace-or-append, document order preserved) and applies the live
  engine effect for consumed keys — bounds/alias semantics mirror the
  loadPreset consumption exactly (Krita/opacity 0-100,
  OpacityValue/opacity/brush_opacity, FlowValue/flow, hardness with
  auto-brush rebuild, SoftnessValue/softness, brush_spacing,
  SmudgeRateValue/smudge_rate/smudge, Krita/erase/EraserMode/eraser,
  CompositeOp=erase). Unknown keys are recorded (map of record), accepted.
- **Engine params UI**: the settings panel's new section lists the live
  param map (count chip, name/value filter, monospace rows,
  sensor-curve blobs ellipsised), tap-to-edit dialog, engine-authoritative
  apply with slider re-sync (size/opacity/spacing/smudge/flow/hardness
  re-read after each accepted edit). Graceful degradation: engines
  without the new symbol get "not supported"; stripped builds hide the
  section (the inspector's read-only DART PARSE view remains).
- **Active-preset inspector entry** (loop-68): inline inspect button on
  the settings panel's preset chip — the same throwaway-engine inspector
  the picker exposes via long-press, now two taps from the canvas.
- **Compat gate**: Dart `setParam` catches the symbol-lookup
  ArgumentError on engine artifacts predating the ABI (v0.45 and older)
  and returns false — no crash on old engines.
- **CI-proven** (loop-72): the real-engine smoke now gates the FULL
  setter contract on both desktop fixtures and toolchains —
  self-configuring replace-arm proof (map entry 0 edited in place, count
  flat, value read back), live opacity/flow/hardness effects,
  unknown-key append == exactly +1 with read-back, empty-name/null-value
  rejection. SMOKE OK on Linux + Windows (krita-build run APPRUN).
Krita source remains byte-identical (v6.0.4 upstream).

Artifacts from build-app run APPRUN (app tree APPSHA), emulator smoke
SMOKEID (boot + 90s soak with the new UI + hardened APK).
"""


def api(url, method='GET', payload=None):
    req = urllib.request.Request(url, method=method)
    req.add_header('Authorization', f'token {TOKEN}')
    req.add_header('Accept', 'application/vnd.github+json')
    data = None
    if payload is not None:
        data = json.dumps(payload).encode()
        req.add_header('Content-Type', 'application/json')
    try:
        with urllib.request.urlopen(req, data) as r:
            body = r.read()
    except urllib.error.HTTPError as e:
        if e.code == 404:
            return {}  # e.g. release tag lookup before first creation
        raise
    return json.loads(body) if body else {}


def main():
    if not APP_RUN_ID or not APP_SHA:
        print('APP_RUN_ID and APP_SHA env required (green build-app run)')
        sys.exit(1)
    run = api(f'{HEAD}/repos/{BUILD_REPO}/actions/runs/{APP_RUN_ID}')
    print('build-app run:', run['id'], run['status'], run['conclusion'],
          run['head_sha'][:7])
    if run['conclusion'] != 'success':
        print('refusing to release off a non-success run')
        sys.exit(1)

    smoke_id = os.environ.get('SMOKE_ID', '')
    if not smoke_id:
        runs = api(f'{HEAD}/repos/{BUILD_REPO}/actions/runs'
                   f'?event=workflow_run&per_page=15')
        for r in runs['workflow_runs']:
            if (r['name'] == 'Android Emulator Smoke'
                    and r['conclusion'] == 'success'
                    and r['created_at'] > run['created_at']):
                smoke_id = str(r['id'])
                break
    print('smoke run:', smoke_id or '(none found)')

    tmp = '/tmp/fkr_v46_release'
    os.makedirs(tmp, exist_ok=True)
    # 1. resolve artifacts (id + expected size) for the green run
    arts = api(f'{HEAD}/repos/{BUILD_REPO}/actions/runs/{APP_RUN_ID}'
               f'/artifacts?per_page=100')
    wanted, sizes = {}, {}
    for a in arts.get('artifacts', []):
        if a['name'] in ARTIFACTS and not a['expired']:
            wanted[a['name']] = a['id']
            sizes[a['name']] = a['size_in_bytes']
    missing = set(ARTIFACTS) - set(wanted)
    if missing:
        sys.exit(f'FATAL: missing artifacts on run {APP_RUN_ID}: {missing}')
    print('artifacts found:', sorted(wanted))

    # 2. download (curl: urllib forwards the Authorization header into the
    #    storage redirect and Azure 403s it) + size-check + retry, then
    #    extract the INNER payload (.zip/.apk) — the asset is the payload,
    #    not the artifact wrapper.
    uploads = []
    for name, (asset_name, ctype) in ARTIFACTS.items():
        zpath = f'{tmp}/{name}.zip'
        out = f'{tmp}/payload-{asset_name}'  # must differ from zpath
        for attempt in range(4):
            t = f'{zpath}.t{attempt}'
            r = subprocess.run(['curl', '-sL', '-H',
                                f'Authorization: token {TOKEN}',
                                f'{HEAD}/repos/{BUILD_REPO}/actions'
                                f'/artifacts/{wanted[name]}/zip', '-o', t])
            got = os.path.getsize(t) if os.path.exists(t) else 0
            if r.returncode != 0 or got != sizes[name]:
                print(f'{name}: attempt {attempt+1}: rc={r.returncode} '
                      f'size {got} != {sizes[name]}; retrying...')
                continue
            os.replace(t, zpath)
            try:
                with zipfile.ZipFile(zpath) as z:
                    cands = [n for n in z.namelist()
                             if n.endswith(('.zip', '.apk'))
                             and not n.endswith('/')]
                    if not cands:
                        sys.exit(f'FATAL: no payload in {name}: '
                                 f'{z.namelist()}')
                    with z.open(cands[0]) as src, open(out, 'wb') as dst:
                        while True:
                            chunk = src.read(1 << 20)
                            if not chunk:
                                break
                            dst.write(chunk)
                print(f'{name}: payload extracted -> {out} '
                      f'({os.path.getsize(out)} bytes)')
                break
            except (EOFError, zipfile.BadZipFile) as e:
                print(f'{name}: attempt {attempt+1} corrupt ({e!r}); '
                      f'retrying...')
        else:
            sys.exit(f'FATAL: {name} failed after 4 attempts')
        uploads.append((out, asset_name, ctype))

    body = (BODY.replace('APPRUN', str(APP_RUN_ID))
                .replace('APPSHA', APP_SHA)
                .replace('SMOKEID', smoke_id or 'pending'))
    rel = api(f'{HEAD}/repos/{REPO}/releases/tags/{TAG}')
    if rel.get('tag_name') != TAG:
        rel = api(f'{HEAD}/repos/{REPO}/releases', 'POST', {
            'tag_name': TAG,
            'target_commitish': 'feather-krita-flutter',
            'name': 'v0.46 — live param editing + active-preset inspector',
            'body': body,
            'draft': False,
            'prerelease': False,
        })
        print('release created:', rel['id'])
    else:
        api(f'{HEAD}/repos/{REPO}/releases/{rel["id"]}', 'PATCH',
            {'body': body, 'name': rel['name']})
        print('release updated:', rel['id'])

    existing = {a['name'] for a in api(
        f'{HEAD}/repos/{REPO}/releases/{rel["id"]}/assets?per_page=100')}
    for out, asset_name, ctype in uploads:
        if asset_name in existing:
            print('asset exists, skipping:', asset_name)
            continue
        subprocess.run([
            'curl', '-sS', '-f', '-X', 'POST',
            '-H', f'Authorization: token {TOKEN}',
            '-H', f'Content-Type: {ctype}',
            '--data-binary', f'@{out}',
            # Asset uploads go to uploads.github.com (api.github.com 404s)
            f'https://uploads.github.com/repos/{REPO}/releases'
            f'/{rel["id"]}/assets?name={asset_name}',
        ], check=True)
        print('asset uploaded:', asset_name)
    print('v0.46 release COMPLETE')


if __name__ == '__main__':
    main()
