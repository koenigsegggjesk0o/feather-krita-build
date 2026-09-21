#!/usr/bin/env bash
# loop-61: per-ABI DT_NEEDED closure audit for the real-engine Android
# bundle. Extracted from build-app.yml verbatim (loop-45 proven logic)
# so the fat APK can audit BOTH arm64-v8a and x86_64 jniLibs with the
# identical gate instead of arm64-only. Usage:
#   android_dt_audit.sh <jniLibs-dir> <llvm-readelf-path>
set -euo pipefail

JLIB="$1"
RE_BIN="$2"

NEEDS=$("$RE_BIN" -d "$JLIB/libkrita_bridge.so" | awk '/\(NEEDED\)/{print $NF}' | tr -d '[]')
MISSING=0
for n in $NEEDS; do
  if [ -f "$JLIB/$n" ]; then
    echo "  bundled: $n"
  else
    case "$n" in
      liblog.so|libz.so|libm.so|libdl.so|libc.so|libandroid.so)
        echo "  system: $n" ;;
      *)
        echo "  MISSING: $n"; MISSING=$((MISSING+1)) ;;
    esac
  fi
done
# libc++_shared.so must ship in the APK (Qt/KF5 DT_NEEDED it)
test -f "$JLIB/libc++_shared.so" || {
  echo 'FATAL: libc++_shared.so not bundled (required by Qt/KF5 at load)';
  MISSING=$((MISSING+1));
}
[ "$MISSING" -eq 0 ] || { echo "FATAL: $MISSING missing libs"; exit 1; }
# ---- indirect-UNDEF closure gate (loop-45): bionic resolves
# UNDEFs ONLY along the DT_NEEDED load closure; a jniLibs .so
# that is present but NOT reachable from libkrita_bridge.so
# contributes nothing to symbol resolution (the exact v0.28
# defect class: QuaZip via kritastore run 35509208740,
# QPrinter/Qt5PrintSupport via kritawidgets run 35509902482).
# BFS the NEEDED graph: every bundled lib must be reachable
# from libkrita_bridge.so and every NEEDED entry must have a
# jniLibs provider (or be a bionic system lib).
JLIB="$JLIB" RE_BIN="$RE_BIN" python3 - << 'PYEOF'
import os, re, subprocess, glob, sys
d, re_bin = os.environ['JLIB'], os.environ['RE_BIN']
rx = re.compile(r'Shared library: \[([^\]]+)\]')
def needed(p):
    out = subprocess.run([re_bin, '-d', p], capture_output=True, text=True).stdout
    return rx.findall(out)
# libEGL/libGLESv2/libjnigraphics = Android system libs (/system/lib64),
# on-device resolution proven by the loop-43/44 green harness runs
syslibs = {'liblog.so', 'libz.so', 'libm.so', 'libdl.so', 'libc.so', 'libandroid.so', 'libEGL.so', 'libGLESv2.so', 'libjnigraphics.so'}
files = {os.path.basename(p) for p in glob.glob(os.path.join(d, '*.so'))}
files.discard('libkrita_bridge.so')
seen, stack = {'libkrita_bridge.so'}, ['libkrita_bridge.so']
orphan_needed = set()
while stack:
    cur = stack.pop()
    p = os.path.join(d, cur)
    if not os.path.exists(p):
        if cur not in syslibs: orphan_needed.add(cur)
        continue
    for n in needed(p):
        if n not in seen:
            seen.add(n); stack.append(n)
unreached = sorted(files - seen)
if unreached:
    print('FATAL: jniLibs present but NOT reachable in DT_NEEDED closure:', unreached)
    sys.exit(1)
if orphan_needed:
    print('FATAL: NEEDED entries with no jniLibs provider and not system libs:', sorted(orphan_needed))
    sys.exit(1)
print('indirect closure gate OK: %d bundled libs reachable from libkrita_bridge.so' % len(files))
PYEOF
