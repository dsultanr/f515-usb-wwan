#!/system/bin/sh
# scripts/sms.sh — чтение и управление SMS. Диспетчер: stick-модем (PPP/AT) —
# через AT-порт (см. ниже), HiLink — через sms-hilink.sh (Web API модема).
set -e

DIR=$(cd "$(dirname "$0")" && pwd)

# Логи, как в wwan-up.sh: на экран приложения (stdout скрипта Keeper отдаёт
# построчно в окно) и в общий файл /data/local/tmp/wwan.log.
LOG=${WWAN_LOG:-/data/local/tmp/wwan.log}
say()  { echo "$*"; echo "$(date '+%F %T') $*" >>"$LOG" 2>/dev/null; }
ok()   { say "   [ ok ] $*"; }
warn() { say "   [warn] $*"; }
# Ошибка — в stderr (у Keeper 2>&1, так что тоже попадает в окно) и в файл.
err()  { echo "   [FAIL] $*" >&2; echo "$(date '+%F %T')   [FAIL] $*" >>"$LOG" 2>/dev/null; }

# HiLink-модем (E8278, E8372 и родня) SMS отдаёт не AT-портом, а Web API
# роутера; тип определил wwan-up.sh и сохранил в state/mode — переключаем
# ветку целиком, аргументы передаются как есть.
MODE_SMS=$(cat "$DIR/state/mode" 2>/dev/null | tr -d '\r')
if [ "$MODE_SMS" = hilink ]; then
	say "==== SMS: тип модема hilink — читаю через Web API: $DIR/sms-hilink.sh"
	exec sh "$DIR/sms-hilink.sh" "$@"
fi
say "==== SMS: тип модема: ${MODE_SMS:-не определён (нет state/mode)} — ветка AT/PPP"

ACTION="${1:-list}"
TARGET_ID="${2:-}"
LOCKED=0
if [ "$ACTION" = --locked ]; then
	PORT=$2; ACTION=$3; TARGET_ID=${4:-}; LOCKED=1
fi
case "$ACTION" in list|delete|delete_all) ;; *) echo 'Unknown SMS action'; exit 2 ;; esac
if [ "$ACTION" = delete ]; then
	case "$TARGET_ID" in ''|*[!0-9]*) echo 'Invalid SMS index'; exit 2 ;; esac
fi

# 1. Поиск свободного AT-порта
find_at_port() {
	PPP_TTY=""
	if pgrep pppd >/dev/null 2>&1; then
		PPP_TTY=$(ps -ef 2>/dev/null | grep pppd | grep -o 'ttyUSB[0-9]*' | head -1)
		[ -n "$PPP_TTY" ] && PPP_TTY="/dev/$PPP_TTY"
	fi
	selected=${WWAN_CTRL_TTY:-$(cat "$DIR/state/at-tty" 2>/dev/null || true)}
	if [ -n "$selected" ] && [ -c "$selected" ] && [ "$selected" != "$PPP_TTY" ]; then
		echo "$selected"; return 0
	fi

	for t in /dev/ttyUSB1 /dev/ttyUSB2 /dev/ttyUSB3 /dev/ttyUSB0; do
		[ -c "$t" ] || continue
		[ "$t" = "$PPP_TTY" ] && continue
		# Быстрый опрос AT
		RESP=$(AT_LOCK_WAIT=2 sh "$DIR/at.sh" "$t" AT 2>/dev/null || true)
		if echo "$RESP" | grep -q "OK"; then
			echo "$t"
			return 0
		fi
	done

	return 1
}

[ "$LOCKED" = 1 ] || PORT=$(find_at_port) || PORT=
if [ -z "$PORT" ] || [ ! -c "$PORT" ]; then
	err "не найден свободный AT-порт модема (ttyUSB)"
	err "если модем с HiLink-прошивкой — проверь state/mode: его пишет wwan-up.sh при реальном подъёме (кнопка Включить), а не в --check"
	exit 1
fi
ok "AT-порт: $PORT"

if [ "$LOCKED" = 0 ]; then
	exec sh "$DIR/at-lock.sh" "$PORT" 15 sh "$0" --locked "$PORT" "$ACTION" "$TARGET_ID"
fi

stty -F "$PORT" raw -echo -iuclc min 0 time 5 >/dev/null 2>&1 || true
ok "действие: $ACTION${TARGET_ID:+ (индекс $TARGET_ID)} на $PORT"

case "$ACTION" in
list)
	timeout --foreground 10 sh -c '
		P=$1
		exec 3<>"$P" || exit 1
		timeout --foreground 1 cat <&3 >/dev/null 2>&1 || true

		run_cmd() {
			printf "%s\r" "$1" >&3
			while read -t 1 -r line <&3; do
				echo "$line"
				case "$line" in
					*OK*|*ERROR*|*+CMS\ ERROR*) break ;;
				esac
			done
		}

		run_cmd "AT"
		run_cmd "AT+CPMS=\"SM\",\"SM\",\"SM\""
		run_cmd "AT+CMGF=0"
		run_cmd "AT+CMGL=4"
		run_cmd "AT+CPMS=\"ME\",\"ME\",\"ME\""
		run_cmd "AT+CMGF=0"
		run_cmd "AT+CMGL=4"
	' sh "$PORT" 8>&8
	;;

delete)
	if [ -z "$TARGET_ID" ]; then
		err "укажите индекс SMS для удаления"
		exit 1
	fi
	timeout --foreground 5 sh -c '
		P=$1
		ID=$2
		exec 3<>"$P" || exit 1
		printf "AT+CMGD=%s\r" "$ID" >&3
		while read -t 1 -r line <&3; do
			echo "$line"
			case "$line" in
				*OK*|*ERROR*|*+CMS\ ERROR*) break ;;
			esac
		done
	' sh "$PORT" "$TARGET_ID" 8>&8
	;;

delete_all)
	timeout --foreground 12 sh -c '
		P=$1
		exec 3<>"$P" || exit 1
		run_cmd() {
			printf "%s\r" "$1" >&3
			while read -t 1 -r line <&3; do
				case "$line" in
					*OK*|*ERROR*|*+CMS\ ERROR*) break ;;
				esac
			done
		}
		run_cmd "AT+CPMS=\"SM\",\"SM\",\"SM\""
		run_cmd "AT+CMGD=1,4"
		for i in 0 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do
			run_cmd "AT+CMGD=$i"
		done

		run_cmd "AT+CPMS=\"ME\",\"ME\",\"ME\""
		run_cmd "AT+CMGD=1,4"
		for i in 0 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
			run_cmd "AT+CMGD=$i"
		done
		echo "OK"
	' sh "$PORT" 8>&8
	;;

*)
	echo "Unknown action: $ACTION"
	exit 1
	;;
esac
