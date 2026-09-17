#!/usr/bin/env python3
"""v0.8 release: create release on the private repo and upload installers."""
import json
import urllib.request

TOKEN = os.environ['FEATHER_GH_TOKEN']  # never hard-code tokens — pass via env
REPO = 'koenigsegggjesk0o/krita'
TAG = 'v0.8-editor-wired'
HEAD = 'https://api.github.com'
AUTH = {'Authorization': f'token {TOKEN}', 'Content-Type': 'application/json'}

BODY = """## Highlights — the editor is finally REAL
Previous builds shipped a beta placeholder screen: the "3D canvas" was a static
image and undo/redo did nothing. The engine underneath was done, but never
mounted. **v0.8 wires it all together.**

- **Real editor screen**: the actual 3D viewport (CanvasWidget) is now the app —
  touch/stylus drag raycasts onto the guide surface and stamps native Krita
  brush dabs into the 2048² texture. Undo/redo, tool dock (Draw/Erase/Shapes/
  Liquify/Select/Light), brush panel (size/opacity/spacing/smudge/color/mirror),
  Layers panel and the move/rotate/scale/liquify joystick are all live.
- **Real exporters**: PNG, JPEG (quality), OBJ (guide-surface mesh with
  normals/UVs), and the versioned .feather project JSON (strokes + brush +
  surface). GIF/MP4/glTF honestly report "coming in a future build".
- **Regression suite grown to 22 tests**: 7 bridge + 8 engine + **7 new GUI
  widget tests** that drive the real app through the gesture system (a drag on
  the canvas must raycast, paint, and appear in history; the export dialog must
  actually write a file).
- UI bugs fixed on the way: export dialog overflowed short screens (buttons
  pushed off-screen), export stalled under fake-async, Layers header overflow.

## Artifacts
- feather-krita-windows.zip — unzip, run feather_krita.exe (krita_bridge.dll
  side by side, v3 eraser-fixed)
- feather-krita-android.apk — arm64-v8a / armeabi-v7a / x86_64, native brush
  engine bundled per ABI

Commits: 10385ab (private repo, editor wiring) / 7a69bf4 (public CI repo sync)"""


import time


def http(url, data=None, headers=None, method=None):
    req = urllib.request.Request(url, data=data, method=method,
                                 headers={'Authorization': f'token {TOKEN}',
                                          'Content-Type': 'application/json',
                                          **(headers or {})})
    return urllib.request.urlopen(req)


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
        except Exception as e:  # transient GitHub 5xx
            print(f'upload {name} attempt {attempt + 1} failed: {e}')
            time.sleep(5 * (attempt + 1))
    raise SystemExit(f'asset upload failed permanently: {name}')


# 1. reuse existing release for the tag if present
try:
    info = json.loads(http(f'{HEAD}/repos/{REPO}/releases/tags/{TAG}').read())
    print('reusing existing release', info['id'])
except Exception:
    payload = json.dumps({
        'tag_name': TAG,
        'target_commitish': 'feather-krita-flutter',
        'name': 'v0.8 — The real editor, wired end-to-end',
        'body': BODY,
    }).encode()
    resp = http(f'{HEAD}/repos/{REPO}/releases', payload)
    info = json.loads(resp.read())
    print('created release', info['id'], info.get('html_url'))
rid = info['id']

# 2. upload assets
for path, name, ctype in [
    ('/home/z/fkr-step1/build/loop11/win/feather-krita-windows.zip',
     'feather-krita-windows.zip', 'application/zip'),
    ('/home/z/fkr-step1/build/loop11/apk/feather-krita-android.apk',
     'feather-krita-android.apk', 'application/vnd.android.package-archive'),
]:
    upload_asset(rid, path, name, ctype)
