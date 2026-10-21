#!/system/bin/sh
# wwan-boot.sh — то, что запускается САМО после перезагрузки головы: поднимает
# модем и дальше сторожит связь. Запускает его приложение (BootService) через
# локальный adb, отцепленным процессом (setsid), поэтому обрыв adb-сессии его не
# убивает.
#
#   wwan-boot.sh             автозапуск: защита -> подъём -> watchdog-цикл
#   wwan-boot.sh --now       то же, но без задержки после загрузки
#   wwan-boot.sh --status    состояние в вида key=value (читает приложение)
#   wwan-boot.sh --reset     снять защиту и снова разрешить автозапуск
#   wwan-boot.sh --disable   выключить автозапуск (создать файл-выключатель)
#   wwan-boot.sh --stop      остановить watchdog (модем не трогает)
#
# ЗАЩИТА ОТ БУТЛУПА — тут главная мысль всего файла:
#
#   1. Счётчик `attempts` увеличивается ПЕРЕД работой и обнуляется СРАЗУ ПОСЛЕ
#      того, как wwan-up.sh вернул управление — неважно, успешно или с ошибкой.
#      То есть счётчик считает не «неудачные подъёмы», а «заходы, из которых мы
#      не вернулись»: если голова умерла посреди работы и перезагрузилась,
#      счётчик так и остался увеличенным. MAX_ATTEMPTS таких подряд — и
#      автозапуск выключает сам себя. Обычная ошибка («модем не воткнут»)
#      счётчик не копит и в безопасный режим не уводит.
#   2. Маркер insmod-inflight (его ставит wwan-up.sh --boot вокруг insmod, с
#      sync) — точная подпись «упали именно на загрузке модуля ядра».
#      Единственная операция во всём проекте, способная уронить ядро целиком.
#      Остался маркер — автозапуск выключается сразу, не дожидаясь счётчика.
#   3. Файл-выключатель `disabled` с причиной внутри: пока он есть, автозапуск
#      не делает ничего. Снимается только вручную (--reset) или из приложения.
#   4. Задержка перед подъёмом: система после BOOT_COMPLETED ещё догружается,
#      лезть в USB/ядро в этот момент незачем.

DIR=$(cd "$(dirname "$0")" && pwd)
STATE=${WWAN_STATE:-$DIR/state}
LOG=$STATE/boot.log
UP=$DIR/wwan-up.sh

ATTEMPTS=$STATE/attempts
DISABLED=$STATE/disabled
INFLIGHT=$STATE/insmod-inflight
LAST_OK=$STATE/last-ok
WAN_FILE=$STATE/wan-iface
PIDFILE=$STATE/watchdog.pid
RESTARTS=$STATE/restarts

MAX_ATTEMPTS=${WWAN_MAX_ATTEMPTS:-3}
# Пауза перед первым заходом. Была 45 с «на всякий случай», но ждать тут нечего:
# приложение и так стартует нас только после того, как дождалось adbd, а всё
# остальное (модуль, порты, регистрация) wwan-up.sh проверяет сам и с ретраями.
# Пять секунд оставлены как фора планировщику: сразу после BOOT_COMPLETED голова
# занята собой, и торопиться в эту секунду смысла нет.
BOOT_DELAY=${WWAN_BOOT_DELAY:-5}
WATCH_INTERVAL=${WWAN_WATCH_INTERVAL:-60}
# Как часто пересматривать приоритет Wi-Fi над модемом. Чаще, чем проверку связи:
# минута — это минута, в которую системный трафик идёт через модем и жжёт
# мобильный трафик, хотя Wi-Fi уже вернулся. Проверка стоит ~0,3 с (из них ~0,1 —
# dumpsys) и молчит, когда менять нечего, поэтому пятнадцать секунд ничего не
# стоят даже на этой голове.
WIFI_INTERVAL=${WWAN_WIFI_INTERVAL:-15}
# На сколько секунд время с загрузки должно обогнать длину паузы, чтобы считать,
# что голова спала (подробности — у uptime_s). Двадцати секунд достаточно:
# обычная погрешность планировщика в доли секунды, а любой реальный сон длиннее.
WAKE_SLACK=${WWAN_WAKE_SLACK:-20}
# Сколько раз подряд пробовать поднять модем внутри ОДНОГО захода и с какой паузой.
# Первый заход после перезагрузки часто падает не потому, что что-то сломано, а
# потому, что модем только что перещёлкнули modeswitch'ем: порты уже есть, а AT в
# них ещё не отвечает. Раньше это стоило минуты простоя — заход сдавался, и связь
# появлялась только со следующей проверкой watchdog'а. Ретраи живут внутри bring_up
# и в счётчик перезапусков за час не идут: голова между ними не перезагружается.
BRINGUP_RETRIES=${WWAN_BRINGUP_RETRIES:-3}
BRINGUP_RETRY_DELAY=${WWAN_BRINGUP_RETRY_DELAY:-5}
# Больше стольких перезапусков за час — считаем, что чиним не то, и уходим спать
# надолго, чтобы не долбить модем и не жечь трафик впустую.
MAX_RESTARTS_PER_HOUR=${WWAN_MAX_RESTARTS:-4}
COOLDOWN=${WWAN_COOLDOWN:-180}
CHECK_HOST=${WWAN_CHECK_HOST:-77.88.8.8}

mkdir -p "$STATE" 2>/dev/null
: >"$RESTARTS" 2>/dev/null

log() {
	echo "$(date '+%F %T') $*" >>"$LOG" 2>/dev/null
	echo "$*"
}

# Усечение логов: logrotate на голове нет, а все файлы только дописываются.
# Перевалил за LOG_MAX — оставляем последнюю половину. Пишем в ТОТ ЖЕ inode
# (`cat`, а не `mv`): tbox.log держит открытым живой tboxwire, и подмена файла
# оставила бы его писать в отвязанный inode — место на флеше не освободилось бы,
# а видимый файл замер бы навсегда.
LOG_MAX=${WWAN_LOG_MAX:-5242880}
log_trim() {
	for _lt_f in "$@"; do
		[ -f "$_lt_f" ] || continue
		_lt_sz=$(stat -c %s "$_lt_f" 2>/dev/null) || continue
		[ "$_lt_sz" -gt "$LOG_MAX" ] 2>/dev/null || continue
		log "усекаю $_lt_f: $_lt_sz байт больше потолка $LOG_MAX"
		tail -c $((LOG_MAX / 2)) "$_lt_f" >"$_lt_f.trim" 2>/dev/null &&
			cat "$_lt_f.trim" >"$_lt_f" 2>/dev/null
		rm -f "$_lt_f.trim" 2>/dev/null
	done
}

# Все логи проекта в одном месте: сторож — единственный, кто работает постоянно,
# и следить за размерами удобнее ему. Список полный намеренно, включая те, что
# пишет не он: ppp.log принадлежит pppd, f515usbwwan.log — format-sdcard.sh (туда
# уходит вывод fdisk и mkfs.exfat, то есть растёт он рывками и без потолка).
LOG_FILES="$LOG $STATE/boot-stdout.log $STATE/tbox.log
	/data/local/tmp/wwan.log /data/local/tmp/ppp.log /data/local/tmp/f515usbwwan.log"

disable() {
	echo "$(date '+%F %T') $1" >"$DISABLED"
	sync
	log "АВТОЗАПУСК ВЫКЛЮЧЕН: $1"
	log "включить обратно: sh $0 --reset (или кнопкой в приложении)"
}

read_num() { n=$(cat "$1" 2>/dev/null); case "$n" in ''|*[!0-9]*) echo 0 ;; *) echo "$n" ;; esac; }

wan_iface() { cat "$WAN_FILE" 2>/dev/null; }

# Живой ли записанный watchdog: печатает его pid или ничего. Проверка cmdline
# обязательна — pidfile переживает перезагрузку, и номер вполне может оказаться
# занят посторонним процессом (см. подробности у проверки экземпляра ниже).
# Для --stop это ещё и вопрос безопасности: по голому `kill -0` мы бы отстрелили
# чужой процесс.
watchdog_pid() {
	_w=$(cat "$PIDFILE" 2>/dev/null)
	if [ -n "$_w" ] && kill -0 "$_w" 2>/dev/null && grep -qs wwan-boot /proc/$_w/cmdline; then
		echo "$_w"
		return 0
	fi
	# Если pidfile потерян, ищем процесс по cmdline
	for _p in $(ps -A -o PID,CMD 2>/dev/null | grep wwan-boot | awk '{print $1}'); do
		[ "$_p" = "$$" ] && continue
		if kill -0 "$_p" 2>/dev/null && grep -qs wwan-boot /proc/$_p/cmdline; then
			echo "$_p" >"$PIDFILE" 2>/dev/null
			echo "$_p"
			return 0
		fi
	done
	return 1
}

iface_addr() { ip -4 -o addr show "$1" 2>/dev/null | awk '{print $4}' | cut -d/ -f1; }

# Секунды с загрузки. Именно /proc/uptime, а не `date`: стенные часы на этой
# голове прыгают — система стартует с 1970 годом и переставляется на реальное
# время через несколько десятков секунд после BOOT_COMPLETED, и такой прыжок
# выглядел бы как пробуждение из сна.
#
# Для определения сна это ещё и точнее по существу: /proc/uptime считает время
# по boottime, в которое сон ВХОДИТ, а sleep спит по монотонным часам, в которых
# сна НЕТ. Расхождение между ними и есть длительность сна. Если на каком-то ядре
# boottime сон не считает, определение просто не сработает — и связь всё равно
# будет поднята ближайшим быстрым тактом, максимум через WIFI_INTERVAL.
uptime_s() { cut -d. -f1 /proc/uptime 2>/dev/null || echo 0; }

# ------------------------------------------------------------ команды UI ----
case "$1" in
--status)
	echo "disabled=$([ -f "$DISABLED" ] && echo 1 || echo 0)"
	echo "disabled_reason=$(cat "$DISABLED" 2>/dev/null)"
	echo "attempts=$(read_num "$ATTEMPTS")"
	echo "max_attempts=$MAX_ATTEMPTS"
	echo "inflight=$([ -f "$INFLIGHT" ] && echo 1 || echo 0)"
	echo "last_ok=$(cat "$LAST_OK" 2>/dev/null)"
	_p=$(watchdog_pid)
	if [ -n "$_p" ]; then
		echo "watchdog=1 pid=$_p"
	else
		echo "watchdog=0"
	fi
	_if=$(wan_iface)
	echo "wan_iface=$_if"
	echo "wan_addr=$([ -n "$_if" ] && iface_addr "$_if")"
	exit 0 ;;
--reset)
	rm -f "$DISABLED" "$INFLIGHT" "$RESTARTS"
	echo 0 >"$ATTEMPTS"
	sync
	log "защита сброшена вручную, автозапуск снова разрешён"
	exit 0 ;;
--disable)
	disable "выключено вручную"
	exit 0 ;;
--stop)
	_p=$(watchdog_pid)
	if [ -n "$_p" ]; then
		kill "$_p" && log "watchdog остановлен (pid $_p)"
	else
		log "watchdog не запущен"
	fi
	rm -f "$PIDFILE"
	exit 0 ;;
esac

NOW_MODE=0
[ "$1" = "--now" ] && NOW_MODE=1

# ------------------------------------------------------------- проверки -----
log "=================================================================="
log "wwan-boot: старт (uptime $(cut -d. -f1 /proc/uptime 2>/dev/null) с, режим now=$NOW_MODE)"

if [ -f "$DISABLED" ]; then
	log "автозапуск выключен: $(cat "$DISABLED" 2>/dev/null)"
	log "снять: sh $0 --reset"
	exit 0
fi

if [ -f "$INFLIGHT" ]; then
	# Маркер должен был сняться сразу после insmod. Раз он тут — прошлый заход
	# оборвался на загрузке модуля, то есть голова упала именно из-за нас.
	disable "прошлый заход оборвался на insmod ($(cat "$INFLIGHT" 2>/dev/null)) — похоже, голова упала из-за загрузки модуля"
	rm -f "$INFLIGHT"
	sync
	exit 0
fi

A=$(read_num "$ATTEMPTS")
if [ "$A" -ge "$MAX_ATTEMPTS" ]; then
	disable "$A подряд заходов не дошли до конца (порог $MAX_ATTEMPTS) — похоже на цикл перезагрузок"
	exit 0
fi

# Уже работает другой экземпляр — второй watchdog не нужен.
#
# Одного `kill -0` тут мало, и это не теория: pidfile лежит в /data и переживает
# перезагрузку, а номера pid на раннем старте раздаются почти детерминированно.
# 2026-08-11 после двух ребутов подряд в pidfile оставался pid 5681 от прошлой
# загрузки, на 45-й секунде аптайма этот номер был занят посторонним процессом —
# и автозапуск оба раза выходил с «уже работает экземпляр», модем не поднимался
# вообще, хотя приложение честно рапортовало, что автозапуск включён. Поэтому
# проверяем не «номер занят», а «занят именно нами»: cmdline процесса должен
# содержать имя этого скрипта.
P=$(cat "$PIDFILE" 2>/dev/null)
if [ -n "$P" ] && [ "$P" != "$$" ] && kill -0 "$P" 2>/dev/null &&
   grep -qs wwan-boot /proc/$P/cmdline; then
	log "уже работает экземпляр (pid $P) — выхожу"
	exit 0
fi
[ -n "$P" ] && [ "$P" != "$$" ] && log "pidfile от прошлой загрузки (pid $P мёртв или чужой) — забираю себе"

# Занимаем pidfile СРАЗУ, до задержки и до подъёма. Иначе после ребута
# получается гонка: BOOT_COMPLETED прилетает следом за LOCKED_BOOT_COMPLETED,
# приложение запускает нас дважды с разницей в пару секунд, обе копии видят
# пустой pidfile, обе поднимают модем и обе остаются сторожить. Проверено на
# стенде: после первого же ребута работали два экземпляра.
echo $$ >"$PIDFILE"
trap 'rm -f "$PIDFILE"; exit 0' TERM INT

[ -x "$UP" ] || chmod 755 "$UP" 2>/dev/null
[ -f "$UP" ] || { log "нет $UP — нечего запускать"; rm -f "$PIDFILE"; exit 1; }

if [ "$NOW_MODE" = 0 ] && [ "$BOOT_DELAY" -gt 0 ]; then
	log "жду $BOOT_DELAY с, пока система догрузится"
	sleep "$BOOT_DELAY"
fi

# -------------------------------------------------------------- подъём ------
bring_up() {
	_extra_args="${*:-}"
	_a=$(read_num "$ATTEMPTS")
	echo $((_a + 1)) >"$ATTEMPTS"
	sync
	_try=1
	while :; do
		log "--- wwan-up.sh --system --boot ${_extra_args:+$_extra_args }(заход $((_a + 1)), попытка $_try/$BRINGUP_RETRIES) ---"
		# Вывод wwan-up.sh в boot.log НЕ перенаправляем: он и так пишет каждую
		# свою строку в wwan.log со своими отметками времени, и копия здесь
		# означала бы вторую запись тех же двух-трёх килобайт на флеш за заход.
		# Наружу вывод всё же идёт: запущенному руками он нужен на экране, а у
		# отцепленного сторожа stdout уводит в /dev/null само приложение.
		sh "$UP" --system --boot $_extra_args
		_rc=$?
		# Управление вернулось — значит голова пережила заход, что бы там ни было
		# с модемом. Именно это и обнуляет счётчик (см. шапку файла).
		echo 0 >"$ATTEMPTS"
		sync
		_if=$(wan_iface)
		_ad=$([ -n "$_if" ] && iface_addr "$_if")
		if [ -n "$_ad" ] && [ "$_rc" -eq 0 ]; then
			date '+%F %T' >"$LAST_OK"
			log "подъём ок: $_if $_ad (rc=$_rc)"
			return 0
		fi
		[ "$_try" -ge "$BRINGUP_RETRIES" ] && break
		log "попытка $_try не удалась (rc=$_rc) — повтор через $BRINGUP_RETRY_DELAY с"
		sleep "$BRINGUP_RETRY_DELAY"
		_try=$((_try + 1))
	done
	log "подъём не удался (rc=$_rc), подробности в wwan.log"
	return 1
}

bring_up

# Пауза между проверками связи, но не одним куском: на каждом куске
# пересматриваем приоритет Wi-Fi над модемом (см. wifi_priority в wwan-up.sh).
# Появление и пропажу Wi-Fi ядро отрабатывает само — маршруты гаснут вместе с
# интерфейсом, — а вот вернуть приоритет после возврата Wi-Fi некому, кроме нас,
# и ждать этого целую минуту незачем. Скрипт молчит, когда менять нечего, так что
# в лог попадают только переключения.
watch_sleep() {
	_ws_left=$WATCH_INTERVAL
	while [ "$_ws_left" -gt 0 ]; do
		_ws_step=$WIFI_INTERVAL
		[ "$_ws_left" -lt "$_ws_step" ] && _ws_step=$_ws_left
		_ws_t0=$(uptime_s)
		sleep "$_ws_step"
		_ws_slept=$(( $(uptime_s) - _ws_t0 ))

		# Голова просыпалась. Модем на резюме переподключается к шине заново и
		# возвращается в storage-режим, то есть связь заведомо надо поднимать —
		# ждать для этого конца минутной паузы незачем. Выходим сразу, сбрасывая
		# счётчики ошибок, проверки основного цикла всё увидят и сами.
		if [ "$_ws_slept" -gt $((_ws_step + WAKE_SLACK)) ]; then
			log "watchdog: голова просыпалась (пауза $_ws_step с заняла $_ws_slept с) — проверяю связь сразу"
			soft_fails=0
			: >"$RESTARTS"
			return 0
		fi

		_ws_out=$(sh "$DIR/wwan-up.sh" --wifi-prio 2>/dev/null)
		if [ -n "$_ws_out" ]; then
			log "watchdog: $_ws_out"
		fi

		# Жёсткий отказ ловим на каждом куске, а не раз в минуту: проверка стоит
		# одного чтения из /sys, а минута простоя на ровном месте не нужна никому.
		# Мягкий (пинг не проходит при живом адресе) по-прежнему раз в такт: он
		# дороже и торопиться с ним некуда.
		_ws_if=$(wan_iface)
		if [ -n "$_ws_if" ] && [ -z "$(iface_addr "$_ws_if")" ]; then
			return 0
		fi

		# Из бюджета вычитаем фактически потраченное, а не длину паузы. Проверка
		# приоритета быстрая, только когда интернет в Wi-Fi есть; когда его нет,
		# она честно ждёт curl и ping — до восьми секунд. Вычитая одну лишь паузу,
		# мы растягивали бы минутный цикл проверки связи почти до полутора минут
		# ровно в той ситуации, когда связь и надо проверять чаще.
		_ws_spent=$(( $(uptime_s) - _ws_t0 ))
		[ "$_ws_spent" -lt 1 ] && _ws_spent=1
		_ws_left=$((_ws_left - _ws_spent))
	done
}

# ------------------------------------------------------------ watchdog ------
# pidfile уже занят выше, перед задержкой — здесь заново его писать не нужно.
log "watchdog: проверка каждые $WATCH_INTERVAL с (не больше $MAX_RESTARTS_PER_HOUR перезапусков в час)"

[ -x "$DIR/wwan-cells.sh" ] && sh "$DIR/wwan-cells.sh" auto >/dev/null 2>&1
soft_fails=0
while :; do
	watch_sleep

	if [ -f "$DISABLED" ]; then
		log "watchdog: появился файл-выключатель — выхожу"
		break
	fi

	# Проверка «сторож всё ещё я» — не только на старте, но и в цикле. Стартовой
	# мало: пока мы спим, роль может перехватить другой экземпляр (перезапуск
	# приложения, ручной старт), и тогда оба начинают поднимать модем
	# одновременно. Ровно это и вышло 2026-08-12 после сна: два сторожа, два
	# захода wwan-up.sh с разницей в пять секунд, оба до конца.
	_own=$(cat "$PIDFILE" 2>/dev/null)
	if [ -n "$_own" ] && [ "$_own" != "$$" ]; then
		log "watchdog: pidfile занят другим экземпляром (pid $_own) — выхожу, дальше он"
		exit 0
	fi
	[ -z "$_own" ] && echo $$ >"$PIDFILE" 2>/dev/null

	# Иконка сотовой сети живёт отдельным процессом и к связи отношения не имеет:
	# проверяем её тут же, но молча и не влияя ни на что (см. docs/status-icon.md).
	[ -x "$DIR/tbox-icon.sh" ] && sh "$DIR/tbox-icon.sh" auto >/dev/null 2>&1
	[ -x "$DIR/wwan-cells.sh" ] && sh "$DIR/wwan-cells.sh" auto >/dev/null 2>&1

	log_trim $LOG_FILES

	IF=$(wan_iface)
	if [ -z "$IF" ]; then
		log "watchdog: интерфейс неизвестен (подъём ни разу не удался) — пробую поднять"
		bring_up --reconnect
		continue
	fi

	ADDR=$(iface_addr "$IF")
	HARD=0
	if [ -z "$ADDR" ]; then
		HARD=1
		REASON="у $IF нет адреса"
	elif [ "$IF" = ppp0 ] && ! pidof pppd >/dev/null 2>&1; then
		HARD=1
		REASON="ppp0 есть, а pppd не запущен"
	fi

	if [ "$HARD" = 0 ]; then
		# Адрес на месте — ещё не значит, что связь живая. Но и ронять сессию
		# из-за одного потерянного пинга нельзя: у части операторов ICMP режется,
		# поэтому реагируем только на три неудачи подряд.
		if timeout 15 ping -c 2 -W 5 -I "$IF" "$CHECK_HOST" >/dev/null 2>&1; then
			soft_fails=0
			continue
		fi
		soft_fails=$((soft_fails + 1))
		log "watchdog: $IF $ADDR есть, но пинг не проходит ($soft_fails/3)"
		[ "$soft_fails" -lt 3 ] && continue
		REASON="три проверки связи подряд не прошли"
	fi

	# Ограничитель частоты: считаем отметки перезапусков за последний час.
	# Валидируем таймстемпы ($1 <= now), чтобы скачки часов назад при выходе из сна
	# не консервировали старые записи из «будущего».
	NOW=$(date +%s)
	touch "$RESTARTS" 2>/dev/null
	RECENT=$(awk -v now="$NOW" '$1 <= now && now - $1 < 3600' "$RESTARTS" 2>/dev/null)
	CNT=$(echo "$RECENT" | grep -c '[0-9]')
	if [ "$CNT" -ge "$MAX_RESTARTS_PER_HOUR" ]; then
		log "watchdog: уже $CNT перезапусков за час ($REASON) — пауза $COOLDOWN с"
		_cd_t0=$(uptime_s)
		sleep "$COOLDOWN"
		_cd_slept=$(( $(uptime_s) - _cd_t0 ))
		if [ "$_cd_slept" -gt $((COOLDOWN + WAKE_SLACK)) ]; then
			log "watchdog: голова спала во время паузы ($_cd_slept с) — сбрасываю историю"
		fi
		: >"$RESTARTS"
		soft_fails=0
		continue
	fi
	{ echo "$RECENT"; echo "$NOW"; } | grep '[0-9]' >"$RESTARTS.new" 2>/dev/null
	mv "$RESTARTS.new" "$RESTARTS" 2>/dev/null

	log "watchdog: связь потеряна ($REASON) — поднимаю заново"
	soft_fails=0
	bring_up --reconnect
done

rm -f "$PIDFILE"
exit 0
