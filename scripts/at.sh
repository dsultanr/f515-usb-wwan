#!/system/bin/sh
# at.sh <порт> "AT..." ["AT..." ...] — отправить AT-команды и показать ответы.
# Без raw/-echo модем эхоит команды и ответы читать невозможно.
DIR=$(cd "$(dirname "$0")" && pwd)
locked=0
if [ "${1:-}" = --locked ]; then locked=1; shift; fi
P=${1:-}
shift
[ -c "$P" ] || { echo "нет порта $P"; exit 1; }
[ "$#" -gt 0 ] || exit 2
if [ "$locked" = 0 ]; then
    exec sh "$DIR/at-lock.sh" "$P" "${AT_LOCK_WAIT:-10}" sh "$0" --locked "$P" "$@"
fi
AT_READ_SECONDS=${AT_READ_SECONDS:-2}
case "$AT_READ_SECONDS" in ''|*[!0-9]*) exit 2 ;; esac
[ "$AT_READ_SECONDS" -ge 1 ] && [ "$AT_READ_SECONDS" -le 60 ] || exit 2
export AT_READ_SECONDS
AT_COMMAND_MARKERS=${AT_COMMAND_MARKERS:-1}
export AT_COMMAND_MARKERS
# Скорость не задаём: toybox stty её на этом драйвере поставить не может и
# тогда отбрасывает всю команду. -iuclc — иначе ответы приходят в нижнем регистре.
stty -F "$P" raw -echo -iuclc min 0 time 5 >/dev/null 2>&1
# Подоболочка + --foreground: без них порт может стать управляющим терминалом
# сессии, и чтение из фоновой группы процессов встанет на SIGTTIN навсегда
# (подробности — в комментарии к at() в wwan-up.sh).
#
# Внешний timeout — на ВСЮ подоболочку, включая `exec 3<>`. Внутренние накрывают
# только чтение, а заблокироваться умеет и само открытие порта: без CLOCAL open()
# ждёт несущую сколько угодно. Пока порт был один и заведомо рабочий, это не
# всплывало; с перебором незнакомых ttyUSB (E173 и прочая старая серия) один
# молчащий диагностический порт иначе вешает весь подъём.
AT_HARD_TIMEOUT=${AT_HARD_TIMEOUT:-$(( 3 + (AT_READ_SECONDS + 1) * $# ))}
timeout --foreground "$AT_HARD_TIMEOUT" sh -c '
	P=$1
	shift
	exec 3<>"$P" || exit 1
	timeout --foreground 1 cat <&3 >/dev/null 2>&1
	for c in "$@"; do
		printf "%s\r" "$c" >&3
		[ "$AT_COMMAND_MARKERS" = 0 ] || echo "> $c"
		timeout --foreground "$AT_READ_SECONDS" cat <&3 | tr -d "\r"
		echo
	done
' sh "$P" "$@" 8>&8
