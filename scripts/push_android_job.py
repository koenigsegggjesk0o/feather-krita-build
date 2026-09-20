#!/usr/bin/env python3
"""Push the updated krita-build.yml (adds build-android-engine job) to the
builder repo via the Contents API, then dispatch the workflow."""
import base64
import json
import os
import sys
import time
import urllib.request

TOKEN = os.environ['FEATHER_GH_TOKEN']
REPO = 'koenigsegggjesk0o/feather-krita-build'
PATH = '.github/workflows/krita-build.yml'
BRANCH = 'main'


def http(url, data=None, headers=None, method=None):
    req = urllib.request.Request(url, data=data, method=method,
                                 headers={'Authorization': f'token {TOKEN}',
                                          'Content-Type': 'application/json',
                                          'Accept': 'application/vnd.github+json',
                                          **(headers or {})})
    return urllib.request.urlopen(req)


def main():
    local = open('/home/z/fkr-step1/build/builder_files/krita-build.yml').read()
    job = open('/home/z/fkr-step1/build/android_engine_job.yml').read()
    new_content = local.rstrip('\n') + '\n' + job

    # sanity: yaml parse
    try:
        import yaml
        yaml.safe_load(new_content)
        print('YAML parse OK,', len(new_content.splitlines()), 'lines')
    except ImportError:
        print('pyyaml not available — skipping parse check')
    except Exception as e:
        sys.exit(f'YAML PARSE FAILED: {e}')

    cur = json.load(http(f'https://api.github.com/repos/{REPO}/contents/{PATH}?ref={BRANCH}'))
    sha = cur['sha']
    print('current sha:', sha, '| remote size:', cur['size'])

    body = json.dumps({
        'message': 'loop-36: add build-android-engine job (NDK cross-build, merged single-.so, roadmap c) — x86_64 bring-up first',
        'content': base64.b64encode(new_content.encode()).decode(),
        'sha': sha,
        'branch': BRANCH,
    }).encode()
    for attempt in range(5):
        try:
            r = json.load(http(f'https://api.github.com/repos/{REPO}/contents/{PATH}',
                               data=body, method='PUT'))
            print('committed:', r['commit']['sha'][:7])
            break
        except Exception as e:  # noqa: BLE001
            print(f'put attempt {attempt + 1} failed: {e}')
            time.sleep(10)
    else:
        sys.exit('giving up on contents push')

    time.sleep(3)
    for attempt in range(3):
        try:
            disp = http(f'https://api.github.com/repos/{REPO}/actions/workflows/krita-build.yml/dispatches',
                        data=json.dumps({'ref': BRANCH}).encode(), method='POST')
            print('dispatched:', disp.status)
            break
        except Exception as e:  # noqa: BLE001
            print(f'dispatch attempt {attempt + 1} failed: {e}')
            time.sleep(8)


if __name__ == '__main__':
    main()
