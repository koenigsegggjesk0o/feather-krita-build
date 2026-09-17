#!/usr/bin/env python3
"""Patch v0.7 release notes and upload artifacts."""
import json
import urllib.request

TOKEN = os.environ['FEATHER_GH_TOKEN']  # never hard-code tokens — pass via env
REPO = 'koenigsegggjesk0o/krita'
RELEASE_ID = 391006177

BODY = """## Highlights
- **Eraser fixed on Windows**: the Qt bridge painted eraser dabs with DestinationOut onto a transparent image (a no-op). It now returns a black+alpha erase-strength mask, verified on Windows CI (smoke-test assertion added).
- **Linux assets swapped to the Qt-free portable bridge** — the bundled .so no longer needs libEGL/Qt at runtime, so native painting loads out of the box.
- **New Flutter regression suite** (7 tests): dab generation, pressure scaling, eraser contract, .kpp preset loading (deflated + stored ZIP), error paths, EditorState wiring. All green.
- krita_bridge.dll v3 bundled (66048 bytes, zlib-backed, CI-verified) and libkrita_bridge.so for arm64-v8a / armeabi-v7a / x86_64.

## Artifacts
- feather-krita-windows.zip — unzip, run feather_krita.exe (DLL side by side)
- feather-krita-android.apk — 3 ABIs, native brush engine on-device

Commits: f2bfda8 (eraser fix + tests), 96b7aa2 (portable .so assets), e738955 (DLL v3 bundle)"""

patch = json.dumps({
    'name': 'v0.7 — Eraser fix + native painting everywhere',
    'body': BODY,
}).encode()

req = urllib.request.Request(
    f'https://api.github.com/repos/{REPO}/releases/{RELEASE_ID}',
    data=patch, method='PATCH',
    headers={'Authorization': f'token {TOKEN}', 'Content-Type': 'application/json'})
print('patch:', urllib.request.urlopen(req).status)

for path, name in [
    ('/home/z/fkr-step1/build/loop9/win-v3/feather-krita-windows.zip',
     'feather-krita-windows.zip'),
    ('/home/z/fkr-step1/build/loop9/apk-v3/feather-krita-android.apk',
     'feather-krita-android.apk'),
]:
    data = open(path, 'rb').read()
    req = urllib.request.Request(
        f'https://uploads.github.com/repos/{REPO}/releases/{RELEASE_ID}/assets?name={name}',
        data=data, method='POST',
        headers={'Authorization': f'token {TOKEN}',
                 'Content-Type': 'application/octet-stream'})
    resp = urllib.request.urlopen(req)
    print(name, '->', resp.status, json.load(resp).get('state'))
