#!/system/bin/sh
# tbox-icon.sh — иконка сотовой сети в статус-баре головы показывает сигнал USB-модема.
#
#   tbox-icon.sh start [аргументы TboxWire]   запустить (отцепленным процессом)
#   tbox-icon.sh stop                         остановить
#   tbox-icon.sh auto                         запустить, если пользователь не отключил
#   tbox-icon.sh status                       работает или нет + последние строки лога
#   tbox-icon.sh signal                       разовый опрос модема, ничего не запуская
#   tbox-icon.sh fake N [аргументы TboxWire]  показать фиксированные N палок (проверка);
#                                             например: fake 4 --reg 6
#   tbox-icon.sh capable                      умеет ли эта голова показать иконку вообще
#
# Выключатель — файл state/icon со словом on/off внутри (а не «есть файл/нет файла»:
# в этом проекте запрещено удалять что-либо, а выключатель должен сниматься). Пока там
# off, `auto` молчит, и модем поднимается без всякой иконки. Файла нет — считаем on.
# Исключение — режим bridge (машина без опции TBOX, рисует твик iSpaceToolbox): там «файла
# нет» означает «не включали», и `auto` сам не стартует, чтобы зря не занимать AT-порт модема.
#
# Под капотом — tboxwire.jar: он притворяется блоком TBOX, которого на стенде нет, и шлёт
# голове по SOME/IP цифры нашего модема. Подробности — docs/status-icon.md.
#
# ПОРЯДОК АРГУМЕНТОВ app_process. Каталог приложения идёт ПЕРЕД опциями:
#     app_process /system/bin --nice-name=tboxwire TboxWire ...
# Если написать наоборот (`app_process --nice-name=... /system/bin TboxWire`), парсер
# app_main.cpp примет "/system/bin" за имя класса и процесс молча упадёт с кодом 1,
# ничего не написав ни в stdout, ни в logcat. На этом уже потеряли полчаса.
#
# АЛИАС .37. Пакеты должны идти не с 192.168.62.4 — это адрес самой головы. Поэтому на
# vlan62 вешается secondary-адрес 192.168.62.37 (в permanent-ARP QNX на vlan62 значатся
# .1, .5, .10, .14, .37; .5 — QNX, .4 — Android; физического TBOX на стенде нет).
# Алиас переживает только до перезагрузки, поэтому вешаем его при каждом старте.
set -u

DIR=$(cd "$(dirname "$0")" && pwd)
STATE=${WWAN_STATE:-$DIR/state}
JAR=${TBOX_JAR:-$DIR/tboxwire.jar}
SRC_IP=${TBOX_SRC:-192.168.62.37}
IFACE=${TBOX_IFACE:-vlan62}
LOG=$STATE/tbox.log
PIDFILE=$STATE/tbox.pid
SWITCH=$STATE/icon
CAP_CACHE=$STATE/icon-capable
# «Новый путь» для машины БЕЗ опции TBOX (config tbox=0): tmpfs-файл, который читает Frida-твик
# iSpaceToolbox «Статус сети» и рисует иконку в статус-баре напрямую (штатная цепочка ID_CELLULAR_*
# там мертва). tmpfs (/dev), НЕ /data/local/tmp — файл переписывается каждые несколько секунд, а
# /data/local/tmp на этой голове — флеш. Формат — см. TboxWire.writeSignalFile / твик.
SIGNAL_BRIDGE=${TBOX_SIGNAL_FILE:-/dev/network-status-signal}

mkdir -p "$STATE" 2>/dev/null

enabled() { [ "$(cat "$SWITCH" 2>/dev/null)" != off ]; }

# Иконку включали явно (кнопкой «Включить» / ручным `start`), а не просто «не выключали».
# Разница важна только для bridge — см. `auto`.
switched_on() { [ "$(cat "$SWITCH" 2>/dev/null)" = on ]; }

# --- умеет ли эта голова показать штатную иконку вообще ----------------------
#
# Не на всякой машине сотовая иконка в панели есть. SystemUI заводит её, только если
# внутренний ключ ID_CELLULAR_ENABLE равен 1, иначе не подписывается на ID_CELLULAR_*
# и не создаёт вью — в панели не крестик, а пустое место. Наши цифры при этом доезжают
# до com.tbox.service целыми (видно в logcat), но слушателей у события ноль.
#
# Проверено 2026-08-12 на голове с 3G-модемом: прошивка панели там байт в байт наша,
# отличается ровно один ключ конфигурации машины. Разбор — recon/colleague-head/README.md.
#
# Спрашиваем саму голову, а не гадаем: провайдер publicadapter отдаёт ID_CELLULAR_ENABLE
# либо числом, либо JS-выражением над проперти машины (их считает Rhino в PersistenceUtil).
# Число — верим как есть; выражение — считаем сами по пропертям.
CAPABLE_WHY=
CAPABLE_SURE=1

cell_enable_expr() {
	timeout 10 content query --uri content://com.seres.publicadapter.provider/config_inner 2>/dev/null |
		sed -n 's/.*"ID_CELLULAR_ENABLE"[[:space:]]*:[[:space:]]*\([^,}]*\).*/\1/p' |
		tr -d '"' | head -1
}

# 0 — иконка возможна, 1 — нет. Человеческая причина остаётся в $CAPABLE_WHY.
capable_probe() {
	CAPABLE_SURE=1
	_expr=$(cell_enable_expr)
	case "$_expr" in
	1) CAPABLE_WHY="ID_CELLULAR_ENABLE=1"; return 0 ;;
	0) CAPABLE_WHY="ID_CELLULAR_ENABLE=0 — панель не создаёт сотовую иконку"; return 1 ;;
	esac

	_tbox=$(getprop seres.platform.config.tbox 2>/dev/null)
	_region=$(getprop persist.seres.platform.config.region.code 2>/dev/null)
	# Пусто — значит прошивка устроена иначе, чем мы знаем. Тогда не мешаем работать:
	# выключить иконку там, где она работала, хуже, чем зря погонять эмуляцию.
	if [ -z "$_tbox" ]; then
		# Не кешируем: на раннем старте провайдер и vehicle-HAL могут быть ещё не готовы,
		# и залипнуть на догадке до конца загрузки было бы хуже, чем спросить ещё раз.
		CAPABLE_SURE=0
		CAPABLE_WHY="конфиг машины не прочитался — считаем, что иконка есть"
		return 0
	fi
	if [ "$_tbox" != 1 ]; then
		CAPABLE_WHY="в машине не заявлен TBOX (config tbox=$_tbox) — иконки в панели нет"
		return 1
	fi
	if [ "$_region" = 4 ]; then
		CAPABLE_WHY="регион $_region — сотовая иконка выключена прошивкой"
		return 1
	fi
	CAPABLE_WHY="config tbox=1, регион ${_region:-неизвестен}"
	return 0
}

# Кеш привязан к boot_id: проперти машины выставляет vehicle-HAL при загрузке и внутри
# одной загрузки они не меняются, а state/ переживает перезагрузку — без привязки кеш
# протух бы незаметно.
capable() {
	if [ "${TBOX_ICON_FORCE:-0}" = 1 ]; then
		CAPABLE_WHY="принудительно (TBOX_ICON_FORCE=1)"
		return 0
	fi
	_boot=$(cat /proc/sys/kernel/random/boot_id 2>/dev/null)
	_c=$(cat "$CAP_CACHE" 2>/dev/null)
	if [ -n "$_boot" ] && [ "${_c%% *}" = "$_boot" ]; then
		_rest=${_c#* }
		CAPABLE_WHY=${_rest#* }
		[ "${_rest%% *}" = 1 ]
		return $?
	fi
	if capable_probe; then _v=1; else _v=0; fi
	[ "$CAPABLE_SURE" = 1 ] && echo "$_boot $_v $CAPABLE_WHY" >"$CAP_CACHE" 2>/dev/null
	[ "$_v" = 1 ]
}

running_pid() {
	# pidof надёжнее pidfile: имя процесса задаёт --nice-name, и переживает оно всё.
	pidof tboxwire 2>/dev/null | awk '{print $1}'
}

need_jar() {
	[ -f "$JAR" ] || {
		echo "нет $JAR — разложи содержимое tbox/prebuilt/ рядом со скриптами" >&2
		exit 1
	}
}

add_alias() {
	if ip -4 -o addr show dev "$IFACE" 2>/dev/null | grep -q " $SRC_IP/"; then
		return 0
	fi
	echo "== вешаем $SRC_IP на $IFACE"
	ip addr add "$SRC_IP/24" dev "$IFACE" label "$IFACE:tbox" || {
		echo "не смог добавить адрес — нужен root" >&2
		exit 1
	}
}

# Один и тот же запуск и для start, и для fake/signal: разница только в аргументах.
java_run() {
	exec env CLASSPATH="$JAR" app_process /system/bin --nice-name=tboxwire TboxWire \
		--src "$SRC_IP" --iface "$IFACE" --wwan-dir "$DIR" "$@"
}

case "${1:-status}" in
start)
	shift
	need_jar
	PID=$(running_pid)
	[ -n "$PID" ] && { echo "уже работает, pid $PID (остановить: $0 stop)"; exit 0; }
	# Работаем ОБОИМИ путями сразу, независимо от режима:
	#   SOME/IP  — штатная цепочка, на машине с TBOX панель рисует иконку сама;
	#   мост в файл ($SIGNAL_BRIDGE) — его читает Frida-твик iSpaceToolbox «Статус сети»
	#              и рисует иконку сам, там где штатной цепочки нет (tbox=0).
	# Раньше мост включался только при tbox=0, по ответу capable, — и в этом была беда:
	# на раннем старте конфиг машины может ещё не читаться, capable тогда отвечает «иконка
	# есть» (native) и ответ не кеширует, а режим выбирался один раз, при старте. Процесс
	# так и оставался бы без моста до ручного рестарта, то есть после ребута иконки просто
	# не было бы. Запись в tmpfs раз в 5 с не стоит ничего, а лишним быть не может: если
	# твик не установлен, файл никто не читает. Поэтому пишем всегда, а capable ниже решает
	# только один вопрос — поднимать ли поллер самим (`auto`).
	# chmod отдельной командой, а не через `&&`: файл мог остаться с прошлого запуска
	# (в /dev, но с правами 600 от того, кто создал его первым) — тогда `: >` его только
	# усечёт, а права надо всё равно поправить, иначе SystemUI молча не прочитает.
	: >"$SIGNAL_BRIDGE" 2>/dev/null
	chmod 666 "$SIGNAL_BRIDGE" 2>/dev/null
	# Кавычки внутри строки для `sh -c`: путь задаётся снаружи ($TBOX_SIGNAL_FILE).
	EXTRA="--signal-file '$SIGNAL_BRIDGE'"
	if capable; then
		echo "режим: штатная цепочка ($CAPABLE_WHY)"
	else
		echo "режим: мост в файл — $CAPABLE_WHY"
		echo "иконку рисует твик iSpaceToolbox «Статус сети» из $SIGNAL_BRIDGE (без него не видно)"
	fi
	add_alias
	# Логи только дописываются, logrotate на голове нет. Старт — самая удобная
	# точка усечения: файл ещё никем не открыт, а дальше в него будет писать
	# живой процесс (в цикле за размером следит watchdog в wwan-boot.sh).
	LOG_MAX=${WWAN_LOG_MAX:-5242880}
	_sz=$(stat -c %s "$LOG" 2>/dev/null || echo 0)
	if [ "$_sz" -gt "$LOG_MAX" ] 2>/dev/null; then
		tail -c $((LOG_MAX / 2)) "$LOG" >"$LOG.trim" 2>/dev/null &&
			cat "$LOG.trim" >"$LOG" 2>/dev/null
		rm -f "$LOG.trim" 2>/dev/null
	fi
	# setsid + закрытый stdin: процесс должен пережить обрыв adb-сессии, из которой
	# его запустили. Именно так приложение стартует и wwan-boot.sh.
	setsid sh -c "CLASSPATH=$JAR exec app_process /system/bin --nice-name=tboxwire \
		TboxWire --src $SRC_IP --iface $IFACE --wwan-dir $DIR $EXTRA $*" \
		</dev/null >>"$LOG" 2>&1 &
	i=0
	while [ $i -lt 10 ]; do
		PID=$(running_pid)
		[ -n "$PID" ] && break
		sleep 1
		i=$((i + 1))
	done
	if [ -z "$PID" ]; then
		echo "не поднялся — смотри $LOG" >&2
		tail -20 "$LOG" 2>/dev/null
		exit 1
	fi
	echo "$PID" >"$PIDFILE"
	echo on >"$SWITCH"
	echo "запущен, pid $PID, лог $LOG"
	;;

auto)
	# Вызывается из wwan-up.sh и из watchdog'а wwan-boot.sh, поэтому молчаливая и
	# ничего не ломает: выключено — вышли, уже работает — вышли.
	enabled || { echo "иконка выключена (state/icon=off)"; exit 0; }
	[ -f "$JAR" ] || { echo "иконка: нет $JAR, пропускаем"; exit 0; }
	[ -n "$(running_pid)" ] && exit 0
	# Раньше здесь стоял `capable || exit` — чтобы на голове без TBOX не гонять AT-порт впустую.
	# Мост в файл пишется теперь всегда (см. `start`), поэтому от ответа capable зависит ровно
	# одно: поднимать ли поллер САМИМ. В native — да, как было. В bridge иконку рисует твик
	# iSpaceToolbox, а включён ли он, отсюда не видно; если не включён, мы бы каждые 5 с дёргали
	# AT-порт модема, конкурируя за него с wwan-up.sh, и ничего не показывали. Поэтому там
	# автозапуск не по умолчанию, а по явному «Включить» (кнопка в приложении и ручной `start`
	# пишут в state/icon «on»). Ошибиться этот выбор может только в сторону «лишний раз спросить
	# человека»: неверно опознанный режим больше не значит, что иконки не будет.
	if ! capable && ! switched_on; then
		echo "иконка: режим bridge — автозапуск после «Включить» в приложении"
		exit 0
	fi
	sh "$0" start >/dev/null 2>&1 || echo "иконка: запустить не вышло, см. $LOG"
	;;

stop)
	PID=$(running_pid)
	if [ -z "$PID" ]; then
		echo "не запущен"
	else
		kill "$PID" 2>/dev/null || kill -9 "$PID" 2>/dev/null
		echo "остановлен (pid $PID)"
	fi
	# Пидфайл не удаляем (в проекте запрет на удаление), просто обнуляем.
	: >"$PIDFILE" 2>/dev/null
	# И запоминаем, что иконку выключили руками: иначе её снова поднимет `auto`
	# из wwan-up.sh или из watchdog'а.
	echo off >"$SWITCH"
	# Алиас $SRC_IP не снимаем: он никому не мешает и сам исчезнет при ребуте.
	;;

status)
	PID=$(running_pid)
	if [ -n "$PID" ]; then
		echo "tboxwire: работает, pid $PID"
	else
		echo "tboxwire: не запущен"
	fi
	echo "running=$([ -n "$PID" ] && echo 1 || echo 0)"
	echo "enabled=$(enabled && echo 1 || echo 0)"
	# capable = штатная цепочка (config tbox=1). mode = КЕМ рисуется иконка: native — штатной
	# панелью (tbox=1), bridge — твиком iSpaceToolbox из файла-моста (tbox=0). Отдаём мы при
	# этом всегда и то, и другое: SOME/IP и файл. В обоих режимах иконку МОЖНО показать,
	# поэтому приложение не блокирует «Включить».
	if capable; then echo "capable=1"; echo "mode=native"; else echo "capable=0"; echo "mode=bridge"; fi
	echo "capable_why=$CAPABLE_WHY"
	# Поднимет ли её `auto` сам после подъёма модема. В native это просто «не выключена»,
	# в bridge — ещё и «включали явно» (см. `auto`), поэтому отдельным полем: `enabled`
	# на такой голове может быть 1, а автозапуска всё равно нет.
	if enabled && { capable || switched_on; }; then echo "autostart=1"; else echo "autostart=0"; fi
	echo "алиас:    $(ip -4 -o addr show dev "$IFACE" 2>/dev/null | grep " $SRC_IP/" |
		sed 's/  */ /g' || echo "нет $SRC_IP на $IFACE")"
	echo "WAN:      $(cat "$STATE/wan-iface" 2>/dev/null || echo "неизвестен (модем не поднимали)")"
	# Пока тут живой pid wwan-up.sh, иконка вместо крестика гоняет палки по кругу.
	_b=$(cat "$STATE/busy" 2>/dev/null)
	_bp=${_b%% *}
	if [ -n "${_bp:-}" ] && grep -qs wwan-up "/proc/$_bp/cmdline" 2>/dev/null; then
		echo "подъём:   идёт — ${_b#* } (pid $_bp), палки анимируются"
	else
		echo "подъём:   не идёт${_b:+ (последняя стадия: ${_b#* })}"
	fi
	[ -f "$LOG" ] && { echo "-- последние строки $LOG:"; tail -8 "$LOG"; }
	;;

signal)
	need_jar
	java_run --signal
	;;

fake)
	shift
	N=${1:-4}
	[ $# -gt 0 ] && shift
	need_jar
	add_alias
	echo "показываем фиксированные $N палок, Ctrl-C чтобы прекратить"
	# Хвост аргументов уходит в TboxWire как есть: без него документированный
	# способ перебрать celluarRegisterStatus (`fake 4 --reg N`, см. genToReg в
	# TboxWire.java) молча игнорировал --reg и показывал всегда одно и то же.
	java_run --strength "$N" "$@"
	;;

capable)
	if capable; then
		echo "режим native: штатная иконка панели — $CAPABLE_WHY"
	else
		echo "режим bridge: штатной цепочки нет ($CAPABLE_WHY),"
		echo "иконку рисует твик iSpaceToolbox «Статус сети» из файла-моста $SIGNAL_BRIDGE"
		# НЕ exit 1: раньше это означало «иконки нет вообще», теперь — «другой путь».
	fi
	;;

-h | --help | help)
	sed -n '2,13p' "$0"
	;;

*)
	echo "неизвестная команда: $1 (см. --help)" >&2
	exit 64
	;;
esac
