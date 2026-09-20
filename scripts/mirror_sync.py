#!/usr/bin/env python3
"""mirror_sync.py — sync app-repo files into the builder repo via the
GitHub Git Data API as ONE ATOMIC commit (protocol step 8).

Why atomic: sequential single-file Contents API PUTs (1s apart) race the
builder repo's push triggers — a build-app run fired between two commits
built a MIXED tree (new picker screen + old test file) and failed CI
(5-loop-48 postmortem). One sync == one commit makes a mixed tree
impossible and fires exactly one push event.

Usage:
  GITHUB_TOKEN=... python3 scripts/mirror_sync.py '<commit message>' \
      <path1> [path2 ...]

Paths are repo-relative (e.g. worklog.md lib/screens/foo.dart). The file
must exist in the APP repo working tree; unchanged files are skipped.
The ref update retries on 409 (racing writer) by re-basing the commit.
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
BUILDER_BRANCH = 'main'
APP_DIR = '/home/z/fkr-step1'
API = f'https://api.github.com/repos/{BUILDER_REPO}'


def api(url, method='GET', payload=None):
    data = json.dumps(payload).encode() if payload is not None else None
    req = urllib.request.Request(url, data=data, method=method)
    req.add_header('Authorization', f'token {TOKEN}')
    req.add_header('Accept', 'application/vnd.github+json')
    with urllib.request.urlopen(req) as r:
        body = r.read()
    return json.loads(body) if body else {}


def main():
    if len(sys.argv) < 3:
        sys.exit(__doc__)
    message = sys.argv[1]
    paths = sys.argv[2:]

    for attempt in range(4):
        try:
            ref = api(f'{API}/git/ref/heads/{BUILDER_BRANCH}')
            base_sha = ref['object']['sha']
            base_commit = api(f'{API}/git/commits/{base_sha}')
            base_tree = base_commit['tree']['sha']
        except Exception as e:  # noqa: BLE001
            sys.exit(f'cannot read builder ref: {e}')

        # 1. Blob per changed file (skip identical).
        entries = []
        for p in paths:
            with open(os.path.join(APP_DIR, p), 'rb') as f:
                content = f.read()
            try:
                existing = api(f'{API}/contents/{p}?ref={BUILDER_BRANCH}')
                if existing.get('content', '').replace('\n', '') == \
                        base64.b64encode(content).decode():
                    print(f'  SKIP {p} (identical)')
                    continue
            except Exception:
                pass  # new file
            blob = api(f'{API}/git/blobs', 'POST', {
                'content': base64.b64encode(content).decode(),
                'encoding': 'base64',
            })
            entries.append({'path': p, 'mode': '100644',
                            'type': 'blob', 'sha': blob['sha']})
            print(f'  BLOB {p} -> {blob["sha"][:7]}')

        if not entries:
            print('MIRROR SYNC OK (nothing changed)')
            return

        # 2. Tree on top of the base tree, 3. commit, 4. move the ref.
        tree = api(f'{API}/git/trees', 'POST', {
            'base_tree': base_tree, 'tree': entries})
        commit = api(f'{API}/git/commits', 'POST', {
            'message': message,
            'tree': tree['sha'],
            'parents': [base_sha],
            'committer': {'name': 'Feather-Krita Bot',
                          'email': 'bot@feather-krita.local'},
        })
        try:
            api(f'{API}/git/refs/heads/{BUILDER_BRANCH}', 'PATCH', {
                'sha': commit['sha'], 'force': False})
        except urllib.error.HTTPError as e:
            body = e.read().decode(errors='replace')
            if e.code == 409 and attempt < 3:
                # Racing writer moved main — rebase the whole commit.
                print(f'  ref moved (409), rebasing attempt {attempt + 1}')
                time.sleep(2 + attempt * 2)
                continue
            sys.exit(f'ref update failed: HTTP {e.code}\n{body}')
        print(f'  COMMIT {commit["sha"][:7]} ({len(entries)} file(s), atomic)')
        print('MIRROR SYNC OK')
        return
    sys.exit('mirror sync failed after retries')


if __name__ == '__main__':
    main()
