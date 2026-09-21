#!/usr/bin/env bash
# loop-60/61 android emulator smoke — runs INSIDE android-emulator-runner
# after the emulator has booted (the action executes `script` one sh -c
# per LINE, so variables and line continuations do not survive there;
# this file gives the smoke real bash). Installs the real-engine APK
# WITHOUT an ABI pin (since loop-61 the fat APK carries the x86_64
# engine, so on the x86_64 CI emulator the native x86_64 set extracts —
# no Android 11+ ARM translation; the loop-60 translation wall is
# retired), starts the activity explicitly via am start -W, polls for
# the process, soaks 90 s, fails on a dead process or a FATAL EXCEPTION,
# and leaves a screenshot + filtered logcat as evidence. Krita source
# untouched.
set -euo pipefail

PKG='com.featherkrita.feather_krita'
APK=$(find "${GITHUB_WORKSPACE:-.}/apk" -name '*.apk' -print -quit)
[ -n "$APK" ] || { echo 'FATAL: no APK under apk/'; exit 1; }
echo "installing: $APK"

# No --abi pin: the x86_64 emulator extracts its native x86_64 set,
# which includes the real engine since loop-61 (fat APK). The package
# manager's ABI selection is the real-world install path.
adb install -r -t "$APK" \
  || { echo 'FATAL: adb install failed'; adb devices; exit 1; }

adb shell pm list packages | grep featherkrita \
  || { echo 'FATAL: package missing after install'; exit 1; }

adb logcat -c || true

# Explicit deterministic launch (monkey's single event proved unreliable
# in the loop-60 arm64-translation runs — attempt 5 injected it and
# nothing forked). -W waits for the launch to complete and prints its
# Status.
echo '--- am start -W ---'
adb shell am start -W -n "$PKG/.MainActivity" || true
echo '--- end am start ---'

PID=""
for i in $(seq 1 40); do
  # pidof exits 1 when no process matches yet — MUST be non-fatal inside
  # the poll (set -e would kill the script on the first pre-fork pass).
  PID=$(adb shell pidof "$PKG" | tr -d '\r' || true)
  if [ -n "$PID" ]; then echo "process alive: $PID (after $((i*10))s)"; break; fi
  sleep 10
done
if [ -z "$PID" ]; then
  echo 'FATAL: app process never appeared'
  adb logcat -d 2>/dev/null \
    | grep -iE 'featherkrita|FATAL EXCEPTION|AndroidRuntime|ActivityTaskManager|ActivityManager|Unsupported|CANNOT LINK|linker|Fatal signal' \
    | tail -300 || true
  adb logcat -d 2>/dev/null | tail -80 || true
  exit 1
fi

echo 'soak 90s (engine init, native x86_64)...'
sleep 90
PID2=$(adb shell pidof "$PKG" | tr -d '\r' || true)
if [ -z "$PID2" ]; then
  echo 'FATAL: app process died during soak'
  adb logcat -d 2>/dev/null \
    | grep -iE 'featherkrita|FATAL EXCEPTION|AndroidRuntime|Unsupported|CANNOT LINK|linker|Fatal signal' \
    | tail -300 || true
  exit 1
fi

adb shell dumpsys window | grep mCurrentFocus || true
adb logcat --pid="$PID2" -d > app_logcat.txt 2>/dev/null \
  || adb logcat -d > app_logcat.txt || true
if grep -q 'FATAL EXCEPTION' app_logcat.txt 2>/dev/null; then
  echo 'FATAL: app crashed during soak'
  grep -A 40 'FATAL EXCEPTION' app_logcat.txt | head -80
  exit 1
fi
adb exec-out screencap -p > emulator_smoke.png
ls -la emulator_smoke.png app_logcat.txt
echo 'ANDROID EMULATOR SMOKE OK'
