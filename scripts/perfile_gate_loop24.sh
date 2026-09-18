#!/bin/bash
# Per-file test gate for loop-24 validation (reliable recipe on the 2-core/4GB box).
# Runs each test file in a separate flutter invocation, serial by construction.
cd /home/z/fkr-step1
TOTAL_PASS=0
TOTAL_FAIL=0
FILES_GREEN=0
FILES_TOTAL=0
for f in $(ls test/*_test.dart | sort); do
  FILES_TOTAL=$((FILES_TOTAL+1))
  OUT=$(/home/z/flutter/bin/flutter test "$f" --concurrency=1 2>&1 | tr '\r' '\n')
  SUMMARY=$(echo "$OUT" | grep -E '^[0-9]+:[0-9]+ \+[0-9]+( -[0-9]+)?:' | tail -1)
  if echo "$OUT" | grep -qE 'All tests passed'; then
    PASS=$(echo "$SUMMARY" | grep -oE '\+[0-9]+' | head -1 | tr -d '+')
    FAIL=$(echo "$SUMMARY" | grep -oE '\-[0-9]+' | head -1 | tr -d '-' )
    FAIL=${FAIL:-0}
  else
    PASS=0; FAIL=99
  fi
  if [ "$FAIL" = "0" ] && [ "${PASS:-0}" -gt 0 ]; then
    echo "PASS $f (+$PASS)"
    TOTAL_PASS=$((TOTAL_PASS+PASS))
    FILES_GREEN=$((FILES_GREEN+1))
  else
    echo "FAIL $f (summary: $SUMMARY)"
    TOTAL_FAIL=$((TOTAL_FAIL+FAIL))
  fi
  sleep 5
done
echo "=== GATE RESULT: $FILES_GREEN/$FILES_TOTAL files green, $TOTAL_PASS passed, $TOTAL_FAIL failed ==="
