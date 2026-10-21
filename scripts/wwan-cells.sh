#!/system/bin/sh
# Direct cell delivery is opt-in and independent of the icon. No Navigator launch/kill.
set -u
umask 077
DIR=$(cd "$(dirname "$0")" && pwd)
ROOT=/dev/wwan-cells
[ "$(id -u)" = 0 ] || exit 1
mkdir -p "$DIR/state" "$ROOT/private"
chmod 0755 "$ROOT" "$DIR" "$DIR/state"
chmod 0600 "$ROOT/daemon.lock" "$ROOT/stderr" 2>/dev/null || true
chown 0:1001 "$ROOT/private"
chmod 0750 "$ROOT/private"
case "${1:-status}" in
    enable) rm -f "$ROOT/disabled"; echo on >"$DIR/state/cells"; chmod 0600 "$DIR/state/cells" ;;
    disable)
        : >"$ROOT/disabled"
        echo off >"$DIR/state/cells"
        rm -f "$ROOT/lease" "$ROOT/private/cell.json"
        echo 'Данные соты выключены; адаптеры отключатся в течение 15 секунд.'
        exit 0 ;;
    status)
        echo "enabled=$(cat "$DIR/state/cells" 2>/dev/null || echo off)"
        cat "$ROOT/status.json" 2>/dev/null
        exit 0 ;;
    pause)
        : >"$ROOT/maintenance"
        rm -f "$ROOT/lease"
        i=0
        while [ "$i" -lt 35 ]; do
            p=$(cat "$ROOT/pid" 2>/dev/null || true)
            case "$p" in ''|*[!0-9]*) break ;; esac
            [ -r "/proc/$p/cmdline" ] || break
            [ "$(tr '\000' '\n' <"/proc/$p/cmdline" | head -1)" = wwan-cells ] || break
            sleep 1; i=$((i + 1))
        done
        [ "$i" -lt 35 ] || exit 1
        exit 0 ;;
    resume) rm -f "$ROOT/maintenance" ;;
    auto) ;;
    *) exit 2 ;;
esac
[ ! -f "$ROOT/maintenance" ] || exit 0
if [ "$(getprop ro.build.version.sdk)" != 30 ]; then
    echo 'Передача данных соты поддерживает Android 11.'; exit 1
fi
case "$(getprop ro.product.cpu.abilist64)" in *arm64-v8a*) ;; *)
    echo 'Передача данных соты требует arm64.'; exit 1 ;; esac
[ "$(cat "$DIR/state/cells" 2>/dev/null)" = on ] || exit 0
p=$(cat "$ROOT/pid" 2>/dev/null || true)
case "$p" in ''|*[!0-9]*) ;; *)
    if [ -r "/proc/$p/cmdline" ] && [ "$(tr '\000' '\n' <"/proc/$p/cmdline" 2>/dev/null | head -1)" = wwan-cells ]; then exit 0; fi ;;
esac
chmod 0700 "$DIR/cell-native-inject"
chmod 0600 "$DIR/cell-collector.jar"
hash=$(sha256sum "$DIR/libwwan_cells.so" | cut -d' ' -f1)
[ ${#hash} = 64 ] || exit 1
mkdir -p "$DIR/cell-runtime"
chmod 0755 "$DIR/cell-runtime"
lib="$DIR/cell-runtime/libwwan_cells-$hash.so"
# Never overwrite an inode that may be mapped in a running process.
if [ ! -f "$lib" ]; then
    cp "$DIR/libwwan_cells.so" "$lib.tmp.$$" && [ "$(sha256sum "$lib.tmp.$$" | cut -d' ' -f1)" = "$hash" ] && chmod 0644 "$lib.tmp.$$" && mv "$lib.tmp.$$" "$lib" || exit 1
fi
setsid env CLASSPATH="$DIR/cell-collector.jar" app_process /system/bin --nice-name=wwan-cells \
    CellDaemon "$DIR" "$lib" </dev/null >/dev/null 2>"$ROOT/stderr" &
i=0
while [ "$i" -lt 10 ]; do
    p=$(cat "$ROOT/pid" 2>/dev/null || true)
    case "$p" in ''|*[!0-9]*) ;; *)
        if [ -r "/proc/$p/cmdline" ] && [ "$(tr '\000' '\n' <"/proc/$p/cmdline" 2>/dev/null | head -1)" = wwan-cells ]; then
            echo "Служба данных соты запущена; готовность подключения — в status."; exit 0
        fi ;;
    esac
    sleep 1; i=$((i + 1))
done
echo 'Служба данных соты не запустилась.'
exit 1
