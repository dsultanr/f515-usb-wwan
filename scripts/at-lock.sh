#!/system/bin/sh
# All WWAN AT consumers lock the character device (major/minor), including aliases.
# Never unlink lock files: flock is released by the kernel when the last fd closes.
set -u
port=${1:-}
budget=${2:-}
shift 2 || exit 2
[ -c "$port" ] && [ "$#" -gt 0 ] || exit 2
case "$budget" in ''|*[!0-9]*) exit 2 ;; esac
[ "$budget" -le 30 ] || exit 2
umask 077
locks=${WWAN_AT_LOCK_DIR:-/dev/wwan-at-locks}
[ ! -L "$locks" ] || exit 2
mkdir -p "$locks" || exit 2
chmod 0700 "$locks" || exit 2
key=$(stat -Lc '%t-%T' "$port") || exit 2
case "$key" in ''|*[!0-9a-fA-F-]*) exit 2 ;; esac
[ ! -L "$locks/$key" ] || exit 2
exec 8>"$locks/$key" || exit 2
ticks=0
while ! flock -n 8 8>&8; do
    if [ "$ticks" -ge $((budget * 10)) ]; then
        echo WWAN_AT_BUSY >&2
        exit 75
    fi
    sleep 0.1
    ticks=$((ticks + 1))
done
# Android mksh otherwise closes fd 8 on exec, silently releasing the lock.
exec "$@" 8>&8
