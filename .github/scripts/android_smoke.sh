#!/usr/bin/env bash
# loop-60 android emulator smoke — runs INSIDE android-emulator-runner
# after the emulator has booted (the action executes `script` one sh -c
# per LINE, so variables and line continuations do not survive there;
# this file gives the smoke real bash). Installs the real-engine APK
# pinned to arm64-v8a (Android 11+ ARM translation), launches the app,
# soaks 90 s, fails on a dead process or a FATAL EXCEPTION, and leaves a
# screenshot + per-pid logcat as evidence. Krita source untouched.
set -euo pipefail

PKG='com.featherkrita.feather_krita'
APK=$(find "${GITHUB_WORKSPACE:-.}/apk" -name '*.apk' -print -quit)
[ -n "$APK" ] || { echo 'FATAL: no APK under apk/'; exit 1; }
echo "installing: $APK"

adb install --abi arm64-v8a -r -t "$APK" \
  || { echo 'FATAL: adb install failed'; adb devices; exit 1; }

adb shell pm list packages | grep featherkrita \
  || { echo 'FATAL: package missing after install'; exit 1; }

adb logcat -c || true
# monkey's own exit code is noisy under ARM translation (it can report 1
# right after a successful launch) — treat it as informational; the
# pidof poll below is the authoritative launch check.
adb shell monkey -p "$PKG" -c android.intent.category.LAUNCHER 1 \
  || echo 'monkey exit nonzero — proceeding to the process poll'

PID=""
for i in $(seq 1 40); do
  PID=$(adb shell pidof "$PKG" | tr -d '\r')
  if [ -n "$PID" ]; then echo "process alive: $PID (after $((i*10))s)"; break; fi
  sleep 10
done
if [ -z "$PID" ]; then
  echo 'FATAL: app process never appeared'
  adb logcat -d | tail -200
  exit 1
fi

echo 'soak 90s (engine init under ARM translation)...'
sleep 90
PID2=$(adb shell pidof "$PKG" | tr -d '\r')
if [ -z "$PID2" ]; then
  echo 'FATAL: app process died during soak'
  adb logcat -d | grep -E 'FATAL EXCEPTION|AndroidRuntime' | tail -60
  exit 1
fi

adb shell dumpsys window | grep mCurrentFocus || true
adb logcat --pid="$PID2" -d > app_logcat.txt || adb logcat -d > app_logcat.txt
if grep -q 'FATAL EXCEPTION' app_logcat.txt; then
  echo 'FATAL: app crashed during soak'
  grep -A 40 'FATAL EXCEPTION' app_logcat.txt | head -80
  exit 1
fi
adb exec-out screencap -p > emulator_smoke.png
ls -la emulator_smoke.png app_logcat.txt
echo 'ANDROID EMULATOR SMOKE OK'
