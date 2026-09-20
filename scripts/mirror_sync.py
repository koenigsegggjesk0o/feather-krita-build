#!/usr/bin/env python3
"""mirror_sync.py — sync app-repo files into the builder repo via the
GitHub Contents API (protocol step 8). Reusable from loop-48 onward.

Usage:
  python3 scripts/mirror_sync.py '<commit message>' <path1> [path2 ...]

Paths are repo-relative (e.g. worklog.md lib/screens/foo.dart). The file
must exist in the APP repo working tree; it is written verbatim to the
BUILDER repo at the same path on main. Update commits fetch the existing
blob SHA first. Idempotent: unchanged content is skipped.
"""
import base64
import json
import os
import sys
import time
import urllib.error
import urllib.request

# NOTE: never hardcode a token here (GitHub push protection blocks the
# file and it would leak in every repo the script is committed to).
# Export GITHUB_TOKEN before calling.
TOKEN = os.environ.get('GITHUB_TOKEN', '')
if not TOKEN:
    sys.exit('GITHUB_TOKEN env var is required')
APP_REPO = 'koenigsegggjesk0o/krita'
BUILDER_REPO = 'koenigsegggjesk0o/feather-krita-build'
APP_DIR = '/home/z/fkr-step1'
API = f'https://api.github.com/repos/{BUILDER_REPO}/contents/'


def api(url, method='GET', payload=None):
    data = json.dumps(payload).encode() if payload is not None else None
    req = urllib.request.Request(url, data=data, method=method)
    req.add_header('Authorization', f'token {TOKEN}')
    req.add_header('Accept', 'application/vnd.github+json')
    with urllib.request.urlopen(req) as r:
        body = r.read()
    return json.loads(body) if body else {}


def sync_one(path, message):
    src = os.path.join(APP_DIR, path)
    with open(src, 'rb') as f:
        content = f.read()
    b64 = base64.b64encode(content).decode()

    sha = None
    try:
        existing = api(API + path + '?ref=main')
        sha = existing.get('sha')
        if existing.get('content', '').replace('\n', '') == b64:
            print(f'  SKIP {path} (identical)')
            return 'skipped'
    except Exception:
        pass  # new file

    last_err = None
    for attempt in range(4):
        try:
            resp = api(API + path, 'PUT', {
                'message': message,
                'content': b64,
                'sha': sha,
                'committer': {
                    'name': 'Feather-Krita Bot',
                    'email': 'bot@feather-krita.local',
                },
            })
            print(f'  PUT  {path} -> {resp["commit"]["sha"][:7]}')
            return 'pushed'
        except urllib.error.HTTPError as e:
            body = e.read().decode(errors='replace')
            last_err = f'HTTP {e.code}: {body[:200]}'
            if e.code in (409, 422) and attempt < 3:
                # Fast successive PUTs race main's ref: re-read the blob
                # sha (and detect concurrent identical content) and retry.
                time.sleep(2 + attempt * 2)
                try:
                    cur = api(API + path + '?ref=main')
                    if cur.get('content', '').replace('\n', '') == b64:
                        print(f'  SKIP {path} (identical after race)')
                        return 'skipped'
                    sha = cur.get('sha')
                except Exception:
                    pass
                continue
            sys.exit(f'PUT {path} failed: {last_err}')
    sys.exit(f'PUT {path} failed after retries: {last_err}')


def main():
    if len(sys.argv) < 3:
        sys.exit(__doc__)
    message = sys.argv[1]
    paths = sys.argv[2:]
    print(f'mirror sync: {len(paths)} file(s) -> {BUILDER_REPO}')
    for i, p in enumerate(paths):
        if i:
            time.sleep(1.5)  # let the previous PUT's ref settle
        sync_one(p, message)
    print('MIRROR SYNC OK')


if __name__ == '__main__':
    main()
