#!/system/bin/sh
# Harmless Android mksh regression: /dev/null only, no modem commands.
set -eu
lock=${1:?path to at-lock.sh}
export WWAN_AT_LOCK_DIR=/dev/wwan-at-test-$$
trap 'rm -rf "$WWAN_AT_LOCK_DIR"' EXIT
sh "$lock" /dev/null 0 sleep 4 & owner=$!
sleep 1
set +e
result=$(sh "$lock" /dev/null 0 true 2>&1); rc=$?
set -e
[ "$rc" = 75 ] && [ "$result" = WWAN_AT_BUSY ]
[ -e "/proc/$owner/fd/8" ]
wait "$owner"
sh "$lock" /dev/null 0 true
# Also retain the lock when the wrapper execs another shell (the real AT path).
sh "$lock" /dev/null 0 sh -c 'sleep 4' & owner=$!
sleep 1
set +e
sh "$lock" /dev/null 0 true >/dev/null 2>&1; rc=$?
set -e
[ "$rc" = 75 ]
wait "$owner"
sh "$lock" /dev/null 0 true
# A surviving transaction child must retain the lock after its wrapper dies.
sh "$lock" /dev/null 0 sh -c 'sleep 4 8>&8' & owner=$!
sleep 1
kill -9 "$owner"
set +e
wait "$owner" 2>/dev/null
sh "$lock" /dev/null 0 true >/dev/null 2>&1; rc=$?
set -e
[ "$rc" = 75 ]
sleep 4
sh "$lock" /dev/null 0 true
echo 'Android mksh: direct exec, nested shell, busy exit, owner death and lock release passed'
