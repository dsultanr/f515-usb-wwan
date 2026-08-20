#!/system/bin/sh
# wwan-up.sh — подъём USB-модема как WWAN на голове F515.
#
# Умеет два типа модемов и определяет тип сам:
#   hilink — модем сам роутер и отдаёт себя как USB-сетевую карту (ZTE MF833R и любой
#            другой CDC-Ethernet/RNDIS): нужен только DHCP, ядро уже умеет всё само.
#            Huawei-модемы с HiLink-прошивкой (E8278, E8372, E3372 в NCM-режиме)
#            сюда же, но им сначала нужны три модуля ядра — см. стадию «NCM»;
#   ppp    — модем отдаёт AT/PPP-порты (Huawei E17x/E1750/E3272, 12d1:*): нужен
#            modeswitch, два модуля ядра и дозвон через pppd.
# Принудительно тип задаётся через WWAN_MODE=hilink|ppp.
#
# Скрипт идёт стадиями и каждую сначала ПРОВЕРЯЕТ: уже сделано — пропускает,
# не хватает предусловия — останавливается с понятным сообщением и подсказкой,
# а не падает где-то в середине. Повторный запуск безопасен.
#
#   wwan-up.sh              подъём
#   wwan-up.sh --check      только диагностика, ничего не меняет
#   wwan-up.sh --system     дополнительно отдать интернет приложениям Android
#   wwan-up.sh --down       остановить pppd (маршруты не трогает)
#   wwan-up.sh --boot       режим автозапуска: вокруг insmod ставится маркер, по
#                           которому wwan-boot.sh после ребута понимает, что голова
#                           упала именно на загрузке модуля (см. docs/autostart.md)
#   wwan-up.sh --wifi-prio  только пересчитать приоритет Wi-Fi над модемом в main
#                           и выйти; молчит, если менять нечего (зовёт watchdog)
#   wwan-up.sh --dns        показать, какой DNS выдаётся приложениям
#   wwan-up.sh --dns=1.1.1.1  запомнить кастомный DNS и применить его сейчас
#   wwan-up.sh --dns=auto   вернуться к DNS оператора/модема (см. docs/app-network.md)
#
# Настройки: переменные окружения или /data/local/tmp/wwan.conf (см. wwan.conf.example).

DIR=$(cd "$(dirname "$0")" && pwd)
TMP=/data/local/tmp
LOG=${WWAN_LOG:-$TMP/wwan.log}
PPP_LOG=$TMP/ppp.log
CONF=${WWAN_CONF:-$TMP/wwan.conf}
STATE=${WWAN_STATE:-$DIR/state}
INFLIGHT=$STATE/insmod-inflight
# Счётчик подряд неудачных проверок интернета в Wi-Fi: живёт между запусками,
# потому что проверку дёргает watchdog отдельным процессом раз в несколько секунд.
WIFI_FAILS=$STATE/wifi-fails

[ -f "$CONF" ] && . "$CONF"

APN=${WWAN_APN:-internet}
PPP_USER=${WWAN_USER:-}
PPP_PASS=${WWAN_PASS:-}
DIAL=${WWAN_DIAL:-*99#}
# Куда класть маршрут модема. 99 = «legacy_system» в терминах Android; таблица
# служебная, основной main при этом не трогается и управляющий adb не рвётся.
TABLE=${WWAN_TABLE:-99}
# Сколько секунд перебирать ttyUSB в поисках отвечающего на AT, прежде чем считать
# модем мёртвым. Бюджет по времени, а не по числу попыток: портов у устройства может
# быть и три, и круг по ним сам по себе занимает несколько секунд. На стенде порт
# отзывается на первом же круге, потолок нужен только чтобы не висеть на мёртвом.
AT_WAIT_SECS=${WWAN_AT_WAIT_SECS:-20}
# Запасные значения для hilink-ветки, если DHCP почему-то ничего не отдал.
HILINK_ADDR=${WWAN_HILINK_ADDR:-192.168.0.178}
HILINK_GW=${WWAN_HILINK_GW:-192.168.0.1}
# Метрика default'а Wi-Fi в main. Должна быть ЛУЧШЕ (меньше) модемной двадцатки:
# модем — резерв, а не основной канал. Ноль не берём, чтобы отличать наш маршрут
# от чужих.
WIFI_METRIC=${WWAN_WIFI_METRIC:-10}
# Сколько проверок подряд должны не пройти, чтобы отобрать у Wi-Fi приоритет.
# Одна — слишком нервно: потерянный пакет или моргнувшая точка доступа не повод
# уводить трафик на мобильный.
WIFI_MAX_FAILS=${WWAN_WIFI_MAX_FAILS:-2}
# Кастомный DNS для приложений. Пусто или auto — как раньше: адрес спрашиваем у
# модема/оператора. Настройка из wwan.conf/окружения главнее файла state/dns, в
# который пишет кнопка в приложении: правка руками не должна молча переигрываться
# кнопкой, нажатой полгода назад.
# Где это применяется и почему только так — см. dns_nat ниже.
DNS_SETTING=$STATE/dns
DNS_AUTO_LAST=$STATE/dns-auto
DNS_WANT=${WWAN_DNS:-}
[ -n "$DNS_WANT" ] || DNS_WANT=$(cat "$DNS_SETTING" 2>/dev/null)
CHECK_HOST=${WWAN_CHECK_HOST:-77.88.8.8}

CHECK_ONLY=0
DO_SYSTEM=0
DO_DOWN=0
BOOT_MODE=0
DO_WIFI_PRIO=0
DO_DNS=0
DNS_SET=0
DO_RECONNECT=0
for a in "$@"; do
	case "$a" in
	-c | --check)     CHECK_ONLY=1 ;;
	-s | --system)    DO_SYSTEM=1 ;;
	-r | --reconnect) DO_RECONNECT=1 ;;
	--down)           DO_DOWN=1 ;;
	--boot)           BOOT_MODE=1 ;;
	--wifi-prio)      DO_WIFI_PRIO=1 ;;
	--dns)            DO_DNS=1 ;;
	# Значение с аргументом главнее и wwan.conf, и файла: человек только что
	# назвал адрес явно, спорить с ним нечему.
	--dns=*)          DO_DNS=1; DNS_SET=1; DNS_WANT=${a#--dns=} ;;
	-h | --help)      sed -n '2,33p' "$0"; exit 0 ;;
	*) echo "неизвестный аргумент: $a (см. --help)"; exit 64 ;;
	esac
done

# ---------------------------------------------------------------- вывод/логи --
STAGE_NO=0

# Логи только дописываются, а logrotate на голове нет — значит усекать надо самим.
# Перевалил за LOG_MAX — оставляем последнюю половину: свежее всегда нужнее, а
# резать ровно по границе значит резать каждую следующую строку.
#
# Именно `cat` в существующий файл, а не `mv` поверх: tbox.log держит открытым
# живой процесс (tbox-icon.sh перенаправляет в него stdout tboxwire). Подмена
# файла оставила бы его писать в отвязанный inode — место на флеше так и не
# освободилось бы, а видимый файл замер бы навсегда. Перезапись того же inode
# такой процесс переживает: он пишет с O_APPEND, то есть в новый конец.
LOG_MAX=${WWAN_LOG_MAX:-5242880}
log_trim() {
	for _lt_f in "$@"; do
		[ -f "$_lt_f" ] || continue
		_lt_sz=$(stat -c %s "$_lt_f" 2>/dev/null) || continue
		[ "$_lt_sz" -gt "$LOG_MAX" ] 2>/dev/null || continue
		tail -c $((LOG_MAX / 2)) "$_lt_f" >"$_lt_f.trim" 2>/dev/null &&
			cat "$_lt_f.trim" >"$_lt_f" 2>/dev/null
		rm -f "$_lt_f.trim" 2>/dev/null
	done
}

say()   { echo "$*"; echo "$(date '+%F %T') $*" >>"$LOG" 2>/dev/null; }
stage() {
	STAGE_NO=$((STAGE_NO + 1))
	say ""
	say "== $STAGE_NO. $1"
	busy "$1"
}

# Признак «подъём прямо сейчас идёт» — для иконки в статус-баре. Первое слово в
# файле это наш pid, дальше название текущей стадии. Пока модем не
# зарегистрировался в сети, tboxwire по этому файлу гоняет палки по кругу вместо
# крестика: видно, что процесс идёт, а не «сети нет и не будет». Именно pid, а не
# отметка времени: сверив cmdline, tboxwire отличает живой подъём от брошенного
# файла (state/ переживает и падение скрипта, и перезагрузку), и как только
# скрипт умер — палки сразу сменяются честным крестиком. Проверке --check
# анимация не положена: она ничего не поднимает.
busy() {
	[ "$CHECK_ONLY" = 0 ] || return 0
	mkdir -p "$STATE" 2>/dev/null
	echo "$$ $1" >"$STATE/busy" 2>/dev/null
	# Стадия приложения («жду adbd, раскладываю файлы, жду догрузки системы») на этом
	# закончилась: дальше показываем подъём. Признак снимается здесь, а не в самом
	# приложении, потому что между его запуском и первой стадией лежат ещё 45 секунд
	# задержки в wwan-boot.sh, и всё это время анимация приложения уместна.
	echo 0 >"$STATE/appboot" 2>/dev/null
}
# Вышли как угодно, в том числе через die, — подъём больше не идёт.
idle() { [ "$CHECK_ONLY" = 0 ] && echo "0 -" >"$STATE/busy" 2>/dev/null; }
trap idle EXIT
ok()    { say "   [ ok ] $*"; }
skip()  { say "   [ -- ] $*"; }
warn()  { say "   [warn] $*"; }
# die <что не так> <что делать>
die() {
	say "   [FAIL] $1"
	[ -n "$2" ] && say "          -> $2"
	exit 1
}

# Действие, которое в режиме --check только печатается.
do_it() {
	if [ "$CHECK_ONLY" = 1 ]; then
		say "   [dry ] $*"
		return 0
	fi
	"$@"
}

have() { command -v "$1" >/dev/null 2>&1; }

# ------------------------------------------------------------------ хелперы --
# Сетевой интерфейс HiLink-модема ищем по драйверу, а не по вендору/MAC/имени:
# HiLink-модемы любого производителя отдают себя как USB CDC-Ethernet устройство
# и привязываются к cdc_ether (реже rndis_host/cdc_ncm); ни MAC, ни имя
# интерфейса, ни VID между моделями не совпадают, а класс USB-устройства — да.
find_hilink_iface() {
	for d in /sys/class/net/*; do
		[ -f "$d/address" ] || continue
		drv=$(readlink -f "$d/device/driver" 2>/dev/null) || continue
		dev=$(readlink -f "$d/device" 2>/dev/null)
		case "$dev" in
		*/usb*/*) ;;   # интерфейс должен висеть на USB, а не быть встроенным
		*) continue ;;
		esac
		case "$(basename "$drv")" in
		cdc_ether | rndis_host* | f515_rndis | cdc_ncm | huawei_cdc_ncm)
			HILINK_IF=$(basename "$d")
			HILINK_DRV=$(basename "$drv")
			return 0 ;;
		esac
	done
	return 1
}

# NCM-интерфейс Huawei: канал данных HiLink-прошивки, спрятанный за
# vendor-specific классом. Апстримный huawei_cdc_ncm ловит его по
# (12d1, class ff, subclass 02|03, protocol 16|46|76) — здесь та же четвёрка,
# чтобы решать «есть кого поднимать» до загрузки модулей. Значения в sysfs
# шестнадцатеричные, ровно как в таблице драйвера.
find_ncm_iface() {
	# Сначала отсекаем обычные AT/PPP-свистки. Интерфейс ff/02/16 есть и у них: на
	# E3272 (12d1:1506) это ttyUSB2, живой последовательный порт под option, и
	# именно на нём у E173 отвечает AT. Без этой проверки стадия отбирала порт у
	# option на исправном PPP-модеме, сетевой интерфейс не появлялся, и подъём падал
	# (проверено на стенде 2026-08-12). Признак настоящей HiLink/NCM-прошивки —
	# ОТСУТСТВИЕ модемного порта ff/02/10: у E8278 и родни PPP-порта нет вовсе,
	# AT^SETPORT отвергает код 10. Дескрипторы есть на шине всегда, поэтому проверка
	# работает и на холодном старте, когда ttyUSB ещё не созданы.
	for i in /sys/bus/usb/devices/*:*; do
		[ -f "$i/bInterfaceClass" ] || continue
		[ "$(cat "$i/../idVendor" 2>/dev/null)" = "12d1" ] || continue
		[ "$(cat "$i/bInterfaceClass" 2>/dev/null)" = "ff" ] || continue
		[ "$(cat "$i/bInterfaceSubClass" 2>/dev/null)" = "02" ] || continue
		if [ "$(cat "$i/bInterfaceProtocol" 2>/dev/null)" = "10" ]; then
			NCM_SKIP="есть модемный порт ff/02/10 ($(basename "$i")) — это AT/PPP-свисток"
			return 1
		fi
	done
	for i in /sys/bus/usb/devices/*:*; do
		[ -f "$i/bInterfaceClass" ] || continue
		[ "$(cat "$i/../idVendor" 2>/dev/null)" = "12d1" ] || continue
		[ "$(cat "$i/bInterfaceClass" 2>/dev/null)" = "ff" ] || continue
		_sc=$(cat "$i/bInterfaceSubClass" 2>/dev/null)
		_pr=$(cat "$i/bInterfaceProtocol" 2>/dev/null)
		case "$_sc:$_pr" in
		02:16 | 02:46 | 02:76 | 03:16) ;;
		*) continue ;;
		esac
		NCM_IF=$i
		NCM_ID="ff/$_sc/$_pr"
		return 0
	done
	return 1
}

# RNDIS-интерфейс (MTS 81332FT / ZTE MF90 / Marvell PXA1802 и любые другие RNDIS-устройства):
# класс wireless (e0/01/03) или comm (02/02/ff).
find_rndis_iface() {
	for i in /sys/bus/usb/devices/*:*; do
		[ -f "$i/bInterfaceClass" ] || continue
		_cl=$(cat "$i/bInterfaceClass" 2>/dev/null)
		_sc=$(cat "$i/bInterfaceSubClass" 2>/dev/null)
		_pr=$(cat "$i/bInterfaceProtocol" 2>/dev/null)
		case "$_cl:$_sc:$_pr" in
		e0:01:03 | 02:02:ff)
			RNDIS_IF=$i
			RNDIS_ID="$_cl/$_sc/$_pr"
			return 0 ;;
		esac
	done
	return 1
}

# Каталог с .ko: рядом со скриптом, иначе /data/local/tmp, куда их кладёт
# приложение. Аргумент — файл-маркер, по которому каталог опознаётся.
mod_dir() {
	_d=${WWAN_MODDIR:-$DIR}
	[ -f "$_d/$1" ] || _d=$TMP
	echo "$_d"
}

# ------------------------------------------------------- приоритет Wi-Fi ----
# Модем — резерв, а не основной канал: пока в Wi-Fi есть интернет, ходить надо
# через него.
#
# У приложений Android это и так работает само: ConnectivityService предпочитает
# валидированный Wi-Fi сотовой сети и переключает их на модем, как только Wi-Fi
# перестаёт быть валидированным. Чинить нужно трафик БЕЗ метки — системные
# демоны, root-шелл, adb-команды: он идёт по main, а там до сих пор был только
# модемный default.
#
# Кладём в main default через Wi-Fi с метрикой лучше модемной. Именно метрику, а
# не удаление модемного маршрута: когда wlan0 гаснет, ядро само выносит все его
# маршруты, и модем остаётся единственным default'ом — без чьего-либо участия и
# без гонки.
#
# Отсюда три правила, по которым эта стадия и живёт:
#   1. приоритет достаётся Wi-Fi, как только через него ПРОШЛА проба интернета
#      (см. wifi_online) — больше ничего не спрашиваем: ни вердикта Android, ни
#      предыстории. Обратная сторона честная: на Wi-Fi без интернета (роутер жив,
#      WAN лежит) приоритет не появится вообще, в том числе в первый раз, — и это
#      правильно, иначе системный трафик уходил бы в никуда;
#   2. приоритет снижается ТОЛЬКО при доказанном «подключён, но интернета нет» и
#      только если есть куда падать — модемный default в main;
#   3. выключенный Wi-Fi — не наше дело: интерфейса нет, функция молча выходит,
#      маршруты уже снял кто надо. Ничего «на всякий случай» не сносим.

# Шлюз Wi-Fi берём из ЕГО таблицы (Android держит маршруты сетей в отдельных
# таблицах по имени интерфейса), в main его нет и не будет.
wifi_gw() {
	ip route show table "$1" 2>/dev/null |
		sed -n 's/^default via \([0-9.]*\).*/\1/p' | head -1
}

# Клиентский Wi-Fi: первый wlan*, у которого есть И адрес, И default в своей
# таблице.
#
# Наличие default'а тут не формальность, а способ отличить клиента от точки
# доступа. На этой голове wlan1 бывает SoftAP с адресом 192.168.37.1/24: адрес у
# него есть, а шлюза нет и быть не может. Раньше перебор останавливался на первом
# же wlan с адресом — то есть при включённой раздаче мог упереться в AP и до
# настоящего клиентского интерфейса не дойти вовсе. Полагаться на то, что wlan0
# идёт в глобе первым, нельзя.
wifi_iface() {
	for _wi_d in /sys/class/net/wlan*; do
		[ -e "$_wi_d/address" ] || continue
		_wi_n=$(basename "$_wi_d")
		[ -n "$(iface_addr "$_wi_n")" ] || continue
		[ -n "$(wifi_gw "$_wi_n")" ] || continue
		echo "$_wi_n"
		return 0
	done
	return 1
}

# Есть ли интернет ИМЕННО через Wi-Fi. Спрашиваем сеть сами, двумя независимыми
# способами, и хватает одного удачного:
#   - HTTP-проба на 204 — тот же адрес, которым проверяет сети сам Android;
#     проходит там, где режут ICMP;
#   - пинг — на случай, если HTTP-пробу перехватывает или блокирует провайдер.
# Обе привязаны к интерфейсу (--interface / -I), иначе они уйдут туда, куда
# смотрит main, и будут мерить не Wi-Fi, а модем.
#
# Вердикт самого Android (lastValidated) сознательно НЕ используется: он
# остаётся true минутами после реальной пропажи интернета — проверено на стенде,
# три минуты без единого пакета наружу, а флаг не шелохнулся. Для «приоритет
# по умолчанию у Wi-Fi» это неважно, а вот понижать по устаревшему флагу нельзя.
# Счётчик неудач пишем только когда он реально меняется: файл в /data, а зовут
# нас раз в 15 секунд.
wifi_fails_set() {
	[ "$(cat "$WIFI_FAILS" 2>/dev/null)" = "$1" ] && return 0
	echo "$1" >"$WIFI_FAILS" 2>/dev/null
}

wifi_online() {
	if have curl; then
		[ "$(curl -s -m 5 --interface "$1" -o /dev/null -w '%{http_code}' \
			http://connectivitycheck.gstatic.com/generate_204 2>/dev/null)" = "204" ] &&
			return 0
	fi
	timeout 5 ping -c 1 -W 3 -I "$1" "$CHECK_HOST" >/dev/null 2>&1
}

# Печатает строку и возвращает 0, ТОЛЬКО если что-то изменил: функцию дёргает
# watchdog раз в минуту, и молчание — нормальное состояние.
wifi_priority() {
	_wp_if=$(wifi_iface) || _wp_if=""
	_wp_gw=$([ -n "$_wp_if" ] && wifi_gw "$_wp_if" || echo "")

	# Если Wi-Fi интерфейса нет или у него нет шлюза (сеть отключена):
	if [ -z "$_wp_if" ] || [ -z "$_wp_gw" ]; then
		wifi_fails_set 0
		# Удаляем любые зависшие маршруты default через wlan* в main
		_stale_wifi=$(ip route show table main 2>/dev/null | grep '^default.* dev wlan')
		if [ -n "$_stale_wifi" ]; then
			if [ "$CHECK_ONLY" = 1 ]; then
				echo "Wi-Fi отключён — устаревший маршрут в main был бы удалён"
				return 0
			fi
			for _g in $(echo "$_stale_wifi" | sed -n 's/^default via \([0-9.]*\).*/\1/p'); do
				ip route del default via "$_g" table main 2>/dev/null || true
			done
			ip route del default dev wlan0 table main 2>/dev/null || true
			ip route del default dev wlan1 table main 2>/dev/null || true
			echo "Wi-Fi отключён — устаревший default удалён из main, приоритет у модема"
			return 0
		fi
		return 1
	fi

	_wp_have=$(ip route show table main 2>/dev/null |
		grep "^default via $_wp_gw dev $_wp_if ")

	if ! wifi_online "$_wp_if"; then
		# Одна неудачная проба — ещё не приговор: пакет теряется, точка доступа
		# моргает. Понижаем после WIFI_MAX_FAILS подряд.
		#
		# Считаем до порога и на нём останавливаемся: дальше число ни на что не
		# влияет, а файл лежит в /data. Пишем только при изменении — иначе такт в
		# 15 секунд даёт под шесть тысяч записей в сутки об одном и том же.
		_wp_n=$(($(cat "$WIFI_FAILS" 2>/dev/null || echo 0) + 1))
		[ "$_wp_n" -gt "$WIFI_MAX_FAILS" ] && _wp_n=$WIFI_MAX_FAILS
		wifi_fails_set "$_wp_n"
		[ "$_wp_n" -lt "$WIFI_MAX_FAILS" ] && return 1
		[ -z "$_wp_have" ] && return 1
		# Падать есть куда только при живом модемном default'е. Иначе оставляем
		# Wi-Fi как есть: плохой интернет лучше никакого, а пустой main — это
		# отсутствие связи вообще, в том числе для управляющего adb.
		_wp_fallback=$(ip route show table main 2>/dev/null |
			grep '^default' | grep -v "dev $_wp_if ")
		[ -z "$_wp_fallback" ] && return 1
		if [ "$CHECK_ONLY" = 1 ]; then
			echo "в Wi-Fi $_wp_if нет интернета ($_wp_n проверки подряд) — приоритет вернулся бы модему"
			return 0
		fi
		ip route del default via "$_wp_gw" dev "$_wp_if" table main \
			metric "$WIFI_METRIC" 2>/dev/null || return 1
		echo "в Wi-Fi $_wp_if нет интернета ($_wp_n проверки подряд) — приоритет вернулся модему"
	else
		wifi_fails_set 0
		[ -n "$_wp_have" ] && return 1
		if [ "$CHECK_ONLY" = 1 ]; then
			echo "Wi-Fi $_wp_if ($_wp_gw) стал бы приоритетнее модема в main"
			return 0
		fi
		ip route replace default via "$_wp_gw" dev "$_wp_if" table main \
			metric "$WIFI_METRIC" 2>/dev/null || return 1
		echo "Wi-Fi $_wp_if ($_wp_gw) приоритетнее модема в main (metric $WIFI_METRIC)"
	fi
	return 0
}

# Каталог модема в sysfs + его VID/PID (Huawei-семейство).
# PID'ы, в которых Huawei притворяется флешкой/CD-ROM и рабочих интерфейсов не
# отдаёт. Тот же список зашит в tools/huawei-modeswitch.c — если правишь здесь,
# правь и там.
is_storage_pid() {
	case "$1" in
	14fe | 1f01 | 1f02 | 1446 | 14ad | 1c0b | 1c1b) return 0 ;;
	esac
	return 1
}

find_usb_dev() {
	for d in /sys/bus/usb/devices/*; do
		[ -f "$d/idVendor" ] || continue
		v=$(cat "$d/idVendor" 2>/dev/null)
		[ "$v" = "12d1" ] || continue
		USB_DEV=$d
		USB_VID=$v
		USB_PID=$(cat "$d/idProduct" 2>/dev/null)
		return 0
	done
	return 1
}

# ttyUSB, соответствующий интерфейсу с заданным bInterfaceProtocol
# (10 = modem/PPP-порт, 12 = PCUI/AT-порт).
#
# Работает только на «новых» свистках (E303, E3272, E353). Старая серия — E173
# (12d1:1c05), E1750, E220 — выставляет 0xFF у ВСЕХ интерфейсов сразу, никакого
# протокола 12 там нет вовсе, и догадка уходит в никуда. Поэтому результат этой
# функции — только первый кандидат, а не приговор: реальный порт ищется опросом,
# см. at_candidates() и стадию «SIM и регистрация в сети».
port_for_proto() {
	for i in "$USB_DEV":*; do
		[ -f "$i/bInterfaceProtocol" ] || continue
		[ "$(cat "$i/bInterfaceProtocol" 2>/dev/null)" = "$1" ] || continue
		for t in "$i"/ttyUSB*; do
			[ -e "$t" ] || continue
			echo "/dev/$(basename "$t")"
			return 0
		done
	done
	return 1
}

# Все ttyUSB этого устройства — в том порядке, в каком имеет смысл спрашивать AT:
# сначала догадка по протоколу, потом остальные, модемный последним (на нём AT
# обычно тоже отвечает, но занимать его до дозвона незачем).
at_candidates() {
	_ac_list=""
	[ -c "$CTRL_TTY" ] && _ac_list="$CTRL_TTY"
	for _ac_t in $(ls -d "$USB_DEV":*/ttyUSB* 2>/dev/null | sed 's|.*/||' | sort -u); do
		[ -c "/dev/$_ac_t" ] || continue
		[ "/dev/$_ac_t" = "$CTRL_TTY" ] && continue
		[ "/dev/$_ac_t" = "$MODEM_TTY" ] && continue
		_ac_list="$_ac_list /dev/$_ac_t"
	done
	[ -c "$MODEM_TTY" ] && [ "$MODEM_TTY" != "$CTRL_TTY" ] &&
		_ac_list="$_ac_list $MODEM_TTY"
	echo $_ac_list
}

ko_vermagic() { grep -ao 'vermagic=[^[:space:]]*' "$1" 2>/dev/null | head -1 | cut -d= -f2; }

# Загрузка модуля с переводом ошибок insmod на человеческий.
load_module() {
	_ko=$1
	_name=$2
	_probe=$3 # путь в sysfs/procfs, по которому видно, что модуль уже работает

	if [ -n "$_probe" ] && [ -e "$_probe" ]; then
		skip "$_name: уже загружен ($_probe на месте)"
		return 0
	fi
	if lsmod 2>/dev/null | grep -q "^$_name "; then
		skip "$_name: уже в lsmod"
		return 0
	fi
	[ -f "$_ko" ] || die "$_name: нет файла $_ko" \
		"положи .ko рядом со скриптом или укажи WWAN_MODDIR"

	# Главная проверка перед insmod: vermagic. Несовпадение = гарантированная
	# порча памяти ядра вплоть до паники, поэтому дальше не идём.
	_vm=$(ko_vermagic "$_ko")
	_kr=$(uname -r)
	if [ -z "$_vm" ]; then
		warn "$_name: в модуле нет vermagic — проверить не получилось"
	elif [ "$_vm" != "$_kr" ]; then
		die "$_name: модуль собран для ядра '$_vm', а на голове '$_kr'" \
			"пересобрать модули под это ядро (modules/build-cfi.sh)"
	else
		ok "$_name: vermagic совпадает ($_vm)"
	fi
	if [ "$(grep -ac '__cfi_check' "$_ko" 2>/dev/null)" = "0" ]; then
		die "$_name: в модуле нет __cfi_check" \
			"ядро собрано с CONFIG_CFI_CLANG и не-CFI модули не принимает — собирать modules/build-cfi.sh"
	fi

	if [ "$CHECK_ONLY" = 1 ]; then
		say "   [dry ] insmod $_ko"
		return 0
	fi

	# Единственная операция во всём скрипте, которая может уронить ядро целиком
	# (и тем самым устроить бутлуп при автозапуске). Маркер ставится ДО и
	# снимается ПОСЛЕ, sync — чтобы он пережил панику; wwan-boot.sh по
	# оставшемуся маркеру понимает, что прошлый заход умер именно здесь.
	if [ "$BOOT_MODE" = 1 ]; then
		mkdir -p "$STATE" 2>/dev/null
		echo "$(date '+%F %T') $_name $_ko" >"$INFLIGHT"
		sync
	fi
	_err=$(insmod "$_ko" 2>&1)
	_rc=$?
	if [ "$BOOT_MODE" = 1 ]; then
		rm -f "$INFLIGHT"
		sync
	fi

	if [ $_rc -eq 0 ]; then
		ok "$_name: загружен"
		return 0
	fi
	case "$_err" in
	*"File exists"* | *"уже существует"*)
		skip "$_name: уже загружен"
		return 0 ;;
	*"Invalid module format"* | *"invalid module format"*)
		die "$_name: ядро отвергло формат модуля ($_err)" \
			"почти всегда это несовпадение vermagic/раскладки struct module — пересобрать" ;;
	*"Unknown symbol"*)
		die "$_name: не хватает символов ядра ($_err)" \
			"смотри dmesg: ядро печатает, какого именно символа нет" ;;
	*"Operation not permitted"*)
		die "$_name: insmod запрещён ($_err)" \
			"проверь, что шелл root и SELinux не Enforcing" ;;
	*)
		die "$_name: insmod не сработал ($_err)" "смотри dmesg" ;;
	esac
}

# Одна AT-команда, ответ на stdout. Порт переводим в raw без эха, иначе ответы
# перемешиваются с эхом и распарсить их нельзя. Скорость не трогаем: у USB-модема
# она виртуальная, а toybox stty на этом драйвере её выставить не может и тогда
# отбрасывает всю команду целиком. -iuclc обязателен — иначе порт отдаёт ответы
# в нижнем регистре ("ok" вместо "OK").
#
# Открытие порта и чтение из него живут в подоболочке, и это не косметика:
# скрипт, запущенный через `adb shell 'sh wwan-up.sh'` (без pty), оказывается
# лидером сессии без управляющего терминала, и тогда открытие /dev/ttyUSB1
# делает этот порт управляющим терминалом. Дальше любое чтение из фоновой
# группы процессов ловит SIGTTIN и останавливается НАВСЕГДА - скрипт висит на
# стадии 8 и его приходится убивать. Форкнутый ребёнок лидером сессии не
# является, поэтому ctty не захватывается вообще. Под приложением проблема не
# видна: там pty уже есть, и ttyUSB управляющим стать не может.
# --foreground - второй слой той же защиты: toybox timeout по умолчанию уводит
# ребёнка в собственную группу процессов, то есть в фоновую.
at() {
	_tty=$1
	_cmd=$2
	_wait=${3:-2}
	[ -c "$_tty" ] || return 1
	stty -F "$_tty" raw -echo -iuclc min 0 time 5 >/dev/null 2>&1
	(
		exec 9<>"$_tty" || exit 1
		timeout --foreground 1 cat <&9 >/dev/null 2>&1
		printf '%s\r' "$_cmd" >&9
		timeout --foreground "$_wait" cat <&9 | tr -d '\r'
	)
}

iface_addr() { ip -4 -o addr show "$1" 2>/dev/null | awk '{print $4}' | cut -d/ -f1; }

# Отвечает ли DNS-сервер. На голове нет ни nslookup, ни dig — есть только
# busybox (и то не всегда), поэтому «проверить не смогли» и «не отвечает» надо
# различать: молча считать сервер мёртвым и переписывать netfilter нельзя.
dns_answers() {
	if have nslookup; then
		timeout 5 nslookup connectivitycheck.gstatic.com "$1" >/dev/null 2>&1
	elif have busybox; then
		timeout 5 busybox nslookup connectivitycheck.gstatic.com "$1" >/dev/null 2>&1
	else
		warn "нечем проверить DNS $1 (нет nslookup/busybox) — считаю, что не отвечает"
		return 1
	fi
}

# Похоже на IPv4-адрес. Строгость тут не самоцель, но и «примем что дали» нельзя:
# строка уходит в командную строку iptables, а сообщить о промахе по цифре надо
# человеку сразу, а не молча оставить голову без резолвинга.
is_ipv4() {
	case "$1" in
	"" | *[!0-9.]* | *..* | .* | *.) return 1 ;;
	esac
	_ip_n=0
	for _ip_o in $(echo "$1" | tr '.' ' '); do
		[ "$_ip_o" -ge 0 ] 2>/dev/null && [ "$_ip_o" -le 255 ] 2>/dev/null || return 1
		_ip_n=$((_ip_n + 1))
	done
	[ "$_ip_n" = 4 ]
}

# Какой адрес станет DNS-сервером приложений: кастомный из настройки, если задан
# и осмысленный, иначе тот, что нашли у оператора ($1). Заодно запоминаем
# автоматический — по нему режим --dns умеет вернуться к «как было», не поднимая
# модем заново и не отбирая AT-порт у pppd.
dns_pick() {
	DNS_AUTO=$1
	[ "$CHECK_ONLY" = 1 ] || [ -z "$DNS_AUTO" ] ||
		{ mkdir -p "$STATE" 2>/dev/null; echo "$DNS_AUTO" >"$DNS_AUTO_LAST" 2>/dev/null; }
	case "$DNS_WANT" in
	"" | auto | AUTO)
		DNS=$DNS_AUTO
		DNS_IS_CUSTOM=0 ;;
	*)
		if is_ipv4 "$DNS_WANT"; then
			DNS=$DNS_WANT
			DNS_IS_CUSTOM=1
		else
			warn "кастомный DNS '$DNS_WANT' не похож на IPv4-адрес — беру $DNS_AUTO"
			DNS=$DNS_AUTO
			DNS_IS_CUSTOM=0
		fi ;;
	esac
}

# Фантомная TBOX-сеть: блок из машины снят, но Android держит его сеть
# подключённой, и именно её DNS спрашивают приложения (см. docs/app-network.md).
tbox_net() {
	_tn_line=$(dumpsys connectivity 2>/dev/null | grep -m1 'type: Tbox')
	[ -n "$_tn_line" ] || _tn_line=$(dumpsys connectivity 2>/dev/null | grep -m1 'Transports: CELLULAR')
	TB_IF=$(echo "$_tn_line" | sed -n 's/.*InterfaceName: \([a-z0-9._-]*\).*/\1/p')
	TB_DNS=$(echo "$_tn_line" | sed -n 's/.*DnsAddresses: \[ *\/\([0-9.]*\).*/\1/p')
	TB_IF=${TB_IF:-vlan72}
	TB_DNS=${TB_DNS:-192.168.72.1}
	TB_SRC=$(iface_addr "$TB_IF")
}

# Снять СВОИ ЖЕ DNAT-правила на 53-й порт, которые ведут не туда, куда нужно
# сейчас. Без этого смена адреса не сработала бы вовсе: правила в цепочке
# проверяются по порядку, и первым сработало бы старое. Своими считаем ровно
# DNAT на $TB_DNS:53 — всё прочее в цепочке не наше, про такое только
# предупреждаем и не трогаем.
dns_nat_clean() {
	_keep=$1
	iptables -w 10 -t nat -S OUTPUT 2>/dev/null |
		grep -e "-d $TB_DNS/32 " | grep -e "--dport 53 " | grep -e "-j DNAT" |
		while read -r _rule; do
			case "$_rule" in
			*"--to-destination $_keep:53") continue ;;
			"-A OUTPUT "*) ;;
			*) continue ;;
			esac
			warn "снимаю своё прежнее правило: ${_rule#-A }"
			# Спецификация правила разбивается на слова намеренно: iptables
			# ждёт её отдельными аргументами, а не одной строкой.
			# shellcheck disable=SC2086
			do_it iptables -w 10 -t nat -D ${_rule#-A }
		done
}

# Подменить приложениям DNS-сервер.
#
# Точка применения ровно одна, и выбрана она не от хорошей жизни: приложения
# резолвят через netd, а тот шлёт запросы на DNS-адрес из конфигурации СВОЕЙ сети
# — фантомной TBOX (на стенде 2026-08-16 счётчик правила показывал 3548 пакетов,
# то есть весь резолвинг головы идёт именно так). Перенастроить netd нечем:
# легаси-команды `ndc resolver setnetdns` на этой прошивке нет («Command not
# recognized»), а «Приватный DNS» — это DoT по имени хоста, IP-адресом его не
# задать. Перемаршрутизировать тоже нельзя: адрес сервера лежит внутри подсети
# vlan72/24, и per-host маршрут туда всегда сильнее любого default. Значит —
# переписывать адрес назначения.
#
# MASQUERADE рядом нужен не маршрутам, а этому же пути: запрос уходит с адресом
# vlan72 (192.168.72.4), и без подмены источника ответ не вернулся бы.
dns_nat() {
	_dns=$1
	if [ -z "$TB_SRC" ]; then
		warn "у $TB_IF нет адреса — эта сеть сейчас не активна, DNS не трогаю"
		return 0
	fi
	if [ -z "$_dns" ]; then
		warn "неизвестно, какой DNS ставить приложениям — пропускаю"
		return 0
	fi
	if [ "$TB_DNS" = "$_dns" ]; then
		skip "DNS приложений и так $TB_DNS — подменять нечего"
		return 0
	fi
	# Автоматический режим уважает живой DNS сети: раз он отвечает, netfilter не
	# наше дело. Но спрашивать об этом можно, только пока нашего правила нет:
	# проверка идёт через netd и потому упирается в это же правило, то есть
	# отвечает «жив» ровно потому, что мы уже перенаправили запросы на живой
	# сервер (замерено на стенде: с правилом на 8.8.8.8 проверка проходит, хотя
	# сам 192.168.72.1 не пингуется вовсе). Без этой оговорки возврат `--dns=auto`
	# молча не сработал бы: проверка прошла бы через кастомное правило и оставила
	# бы его на месте. Явно названный человеком адрес ставим всегда.
	_dns_active=$(dns_nat_active)
	if [ "$DNS_IS_CUSTOM" = 0 ] && [ -z "$_dns_active" ] && dns_answers "$TB_DNS"; then
		skip "DNS $TB_DNS отвечает сам — netfilter не трогаю"
		return 0
	fi
	# «Уже стоит нужное» отдельной веткой не обрабатываем: ниже всё равно надо
	# проверить обе строки (udp и tcp) и MASQUERADE, а проверки -C идемпотентны.
	dns_nat_clean "$_dns"
	for proto in udp tcp; do
		iptables -w 10 -t nat -C OUTPUT -d "$TB_DNS" -p $proto --dport 53 \
			-j DNAT --to-destination "$_dns:53" 2>/dev/null ||
			do_it iptables -w 10 -t nat -A OUTPUT -d "$TB_DNS" -p $proto --dport 53 \
				-j DNAT --to-destination "$_dns:53"
	done
	iptables -w 10 -t nat -C POSTROUTING -s "$TB_SRC" -o "$WAN_IF" -j MASQUERADE 2>/dev/null ||
		do_it iptables -w 10 -t nat -A POSTROUTING -s "$TB_SRC" -o "$WAN_IF" -j MASQUERADE
	if [ "$DNS_IS_CUSTOM" = 1 ]; then
		ok "DNS приложений: $_dns (задан вручную; было $TB_DNS) через $WAN_IF"
	else
		ok "DNS приложений: $_dns (от оператора; было $TB_DNS) через $WAN_IF"
	fi
}

# Что сейчас реально стоит в цепочке — для режима --dns и итога.
dns_nat_active() {
	iptables -w 10 -t nat -S OUTPUT 2>/dev/null |
		sed -n "s/^-A OUTPUT -d $TB_DNS\/32 -p udp .*--to-destination \([0-9.]*\):53.*/\1/p" |
		head -1
}

# Маршрут по умолчанию через модем в заданную таблицу. У ppp0 маршрут
# point-to-point (без шлюза), у hilink за интерфейсом настоящий L3-роутер.
add_default() {
	_tbl=$1
	_metric=$2
	if [ "$MODE" = ppp ]; then
		do_it ip route replace default dev "$WAN_IF" table "$_tbl" metric "$_metric"
	else
		do_it ip route replace default via "$GW" dev "$WAN_IF" table "$_tbl" metric "$_metric"
	fi
}

# ------------------------------------------------------------------- --down --
# Отдельный короткий режим для watchdog'а: ни логов, ни стадий, ни шапки —
# только пересчёт приоритета. Печатает строку, если что-то поменял.
if [ "$DO_WIFI_PRIO" = 1 ]; then
	wifi_priority
	exit 0
fi

# -------------------------------------------------------------------- --dns --
# Короткий режим для кнопки в приложении: сохранить адрес и применить его прямо
# сейчас, на живом соединении. Полный --system сюда не годится — он проверяет
# модули, порты и дёргает AT, а смена DNS не должна ничего этого стоить.
if [ "$DO_DNS" = 1 ]; then
	if [ "$DNS_SET" = 1 ]; then
		case "$DNS_WANT" in
		"" | auto | AUTO) DNS_WANT=auto ;;
		*)
			is_ipv4 "$DNS_WANT" ||
				die "'$DNS_WANT' не похож на IPv4-адрес" "настройка не изменена; для возврата к DNS оператора: --dns=auto" ;;
		esac
		mkdir -p "$STATE" 2>/dev/null
		echo "$DNS_WANT" >"$DNS_SETTING" || die "не смог записать $DNS_SETTING" "проверь права на $STATE"
	fi

	WAN_IF=$(cat "$STATE/wan-iface" 2>/dev/null)
	tbox_net
	_dns_auto=$(cat "$DNS_AUTO_LAST" 2>/dev/null)
	dns_pick "${_dns_auto:-$CHECK_HOST}"

	say "настройка DNS: ${DNS_WANT:-auto}"
	if [ -z "$WAN_IF" ] || ! iface_addr "$WAN_IF" >/dev/null 2>&1 || [ -z "$(iface_addr "$WAN_IF")" ]; then
		# Правило без поднятого модема ставить бессмысленно: заворачивать запросы
		# некуда, а MASQUERADE не на что вешать. Настройка сохранена — её применит
		# ближайший подъём (в том числе автозапуск после ребута).
		warn "модем не поднят — правило поставлю при следующем подъёме"
	else
		dns_nat "$DNS"
	fi
	_dns_now=$(dns_nat_active)
	say "сейчас приложения спрашивают: ${_dns_now:-$TB_DNS (штатный DNS сети, правила нет)}"
	# Машиночитаемо — для кнопки в приложении; формат тот же, что у tbox-icon.sh status.
	echo "dns=${DNS_WANT:-auto}"
	echo "dns_active=${_dns_now:-$TB_DNS}"
	echo "dns_auto=$DNS_AUTO"
	echo "wan=$WAN_IF"
	exit 0
fi

if [ "$DO_DOWN" = 1 ]; then
	stage "остановка"
	_pids=$(pidof pppd 2>/dev/null)
	if [ -n "$_pids" ]; then
		kill $_pids && ok "pppd остановлен (pid $_pids)"
	else
		skip "pppd не запущен"
	fi
	say ""
	say "Маршруты, правила и hilink-интерфейс скрипт НЕ трогает. Убрать вручную:"
	say "   ip route del default table $TABLE"
	say "   ip rule del oif ppp0 table $TABLE"
	exit 0
fi

# Раз в запуск, до первой строки: заход добавляет пару килобайт, так что чаще
# проверять нечего, а по одному stat на запуск не стоит ничего.
log_trim "$LOG" "$PPP_LOG"

say "=================================================================="
say "wwan-up $(date '+%F %T')  APN=$APN  check=$CHECK_ONLY  system=$DO_SYSTEM boot=$BOOT_MODE"

# --------------------------------------------------------- окружение --------
stage "окружение"

[ "$(id -u)" = "0" ] || die "нужен root (сейчас uid=$(id -u))" \
	"adbd на этой прошивке уже root: adb shell должен давать uid=0"
ok "root"

KREL=$(uname -r)
ok "ядро $KREL"

if have getenforce; then
	_se=$(getenforce 2>/dev/null)
	case "$_se" in
	Enforcing) warn "SELinux Enforcing — insmod может быть запрещён" ;;
	*)         ok "SELinux $_se" ;;
	esac
fi

_missing=""
for t in ip timeout; do
	have "$t" || _missing="$_missing $t"
done
[ -z "$_missing" ] || die "в системе нет:$_missing" "без них подъём невозможен"
ok "базовые утилиты на месте"

# Иконку поднимаем ЗДЕСЬ, а не в конце вместе с итогом: подъём модема после
# перезагрузки занимает до минуты с лишним (загрузка модулей, modeswitch,
# регистрация в сети, дозвон), и всё это время в статус-баре не должно быть
# пусто — по бегущим палкам видно, что процесс идёт. К самому подъёму иконка
# отношения не имеет, поэтому молча и без права что-либо уронить.
if [ "$CHECK_ONLY" = 0 ] && [ -x "$DIR/tbox-icon.sh" ]; then
	sh "$DIR/tbox-icon.sh" auto >/dev/null 2>&1 &
fi

# --------------------------------------------------- режим модема ---------
# Huawei приходит на шину виртуальным CD-ROM'ом (storage-PID) и показывает
# настоящие интерфейсы только после SCSI-команды переключения. Стадия стоит ДО
# определения типа модема: пока модем в storage-режиме, его не опознать ни как
# NCM, ни как PPP — нужных интерфейсов на шине просто нет.
stage "режим модема"
NEED_SWITCH=0
if ! find_usb_dev; then
	skip "Huawei (12d1:*) на шине нет — переключать нечего"
else
	MODESWITCH=${WWAN_MODESWITCH:-$(mod_dir huawei-modeswitch)/huawei-modeswitch}
	if is_storage_pid "$USB_PID"; then
		NEED_SWITCH=1
		warn "модем в storage-режиме — нужен modeswitch"
	else
		case "$USB_PID" in
		# AT/PPP-режимы.
		1506 | 1465 | 140c | 1c05 | 14ac) ok "режим с рабочими интерфейсами" ;;
		# HiLink: модем отдаёт себя сетевой картой (NCM/RNDIS), а не портами.
		# E8372h-153 и E3372h-153 после переключения приходят именно сюда, в 14dc.
		14db | 14dc | 1442 | 1c1e | 155e) ok "HiLink-режим ($USB_PID) — сетевой интерфейс" ;;
		*) warn "PID $USB_PID незнакомый — пробуем как есть" ;;
		esac
	fi

	if [ "$NEED_SWITCH" = 0 ]; then
		skip "modeswitch не требуется"
	else
		[ -f "$MODESWITCH" ] || die "нужен modeswitch, но $MODESWITCH отсутствует" \
			"собрать tools/build-tools.sh и положить бинарь рядом"
		[ -x "$MODESWITCH" ] || chmod 755 "$MODESWITCH"
		if [ "$CHECK_ONLY" = 1 ]; then
			say "   [dry ] $MODESWITCH"
		else
			"$MODESWITCH" 2>&1 | while read -r l; do say "   $l"; done
			# Ждём нового PID. Раньше здесь стояло `[ "$USB_PID" != "14fe" ]`:
			# для 14fe (E3372) двадцать секунд отрабатывали как надо, а любой
			# другой storage-PID — 1f01 у E8372h-153, например — выходил из
			# цикла на ПЕРВОЙ же секунде и получал «modeswitch не сработал» ещё
			# до того, как модем успевал переподключиться. Проверять надо весь
			# набор storage-режимов, а не один PID.
			#
			# Сам modeswitch тоже ждёт после каждой своей попытки, так что сюда
			# мы приходим уже с результатом; этот цикл — на случай, когда модем
			# доезжает до нового PID чуть позже, чем инструмент сдался.
			i=0
			while [ $i -lt 20 ]; do
				if find_usb_dev && ! is_storage_pid "$USB_PID"; then break; fi
				sleep 1
				i=$((i + 1))
			done
			find_usb_dev || die "после modeswitch модем пропал с шины" \
				"вытащить и вставить модем, затем запустить скрипт заново"
			if is_storage_pid "$USB_PID"; then
				die "modeswitch не сработал, PID остался $USB_PID" \
					"пришли строки разбора дескрипторов выше — по ним видно режим"
			fi
			ok "переключён в $USB_VID:$USB_PID"
		fi
	fi
fi

# ----------------------------------------------------------- NCM -----------
# HiLink-прошивка Huawei отдаёт канал данных не AT/PPP-портом, а сетевым
# интерфейсом NCM, спрятанным за vendor-specific классом (ff/02/16). Каркас для
# него — usbnet — в ядре головы встроен (CONFIG_USB_USBNET=y, CONFIG_MII=y), а
# сами драйверы выключены (CONFIG_USB_NET_CDC_NCM / CONFIG_USB_NET_HUAWEI_CDC_NCM
# / CONFIG_USB_WDM = n), поэтому интерфейс не появляется сам. Довозим их
# модулями — ровно так же, как usbserial+option для PPP-ветки. После этого модем
# становится обычным HiLink и идёт по общей ветке: DHCP + маршруты.
stage "NCM-интерфейс Huawei"
if [ "${WWAN_MODE:-}" = ppp ]; then
	skip "задан WWAN_MODE=ppp — NCM не трогаем"
elif find_hilink_iface; then
	skip "сетевой интерфейс модема уже есть ($HILINK_IF, драйвер $HILINK_DRV)"
elif ! find_ncm_iface; then
	skip "${NCM_SKIP:-NCM-интерфейса Huawei на шине нет} — стадия не нужна"
else
	ok "NCM-интерфейс $(basename "$NCM_IF") ($NCM_ID)"
	NCMDIR=$(mod_dir huawei_cdc_ncm.ko)
	for f in cdc-wdm.ko cdc_ncm.ko huawei_cdc_ncm.ko; do
		[ -f "$NCMDIR/$f" ] || die "нет файла $NCMDIR/$f" \
			"положи modules/prebuilt/*.ko в $TMP или собери: modules/build-cfi.sh src/ncm"
	done
	# Порядок обязателен: huawei_cdc_ncm тянет символы из обоих остальных
	# (usb_cdc_wdm_register, cdc_ncm_bind_common). rmmod на этой голове роняет
	# ядро — модули только загружаются, никогда не выгружаются.
	load_module "$NCMDIR/cdc-wdm.ko"        cdc_wdm        /sys/bus/usb/drivers/cdc_wdm
	load_module "$NCMDIR/cdc_ncm.ko"        cdc_ncm        /sys/bus/usb/drivers/cdc_ncm
	load_module "$NCMDIR/huawei_cdc_ncm.ko" huawei_cdc_ncm /sys/bus/usb/drivers/huawei_cdc_ncm

	# option из PPP-ветки забирает vendor-specific интерфейсы Huawei целиком,
	# включая NCM-овский, и тогда huawei_cdc_ncm до него не доберётся: драйвер
	# у интерфейса может быть только один. Отцепляем и отдаём кому надо — на
	# самом модеме это ничего не меняет и обратимо перевтыканием.
	_i=$(basename "$NCM_IF")
	if [ "$(basename "$(readlink -f "$NCM_IF/driver" 2>/dev/null)" 2>/dev/null)" = option ]; then
		do_it sh -c "printf %s $_i >/sys/bus/usb/drivers/option/unbind"
		do_it sh -c "printf %s $_i >/sys/bus/usb/drivers/huawei_cdc_ncm/bind"
		ok "интерфейс $_i отобран у option и отдан huawei_cdc_ncm"
	fi

	if [ "$CHECK_ONLY" = 0 ]; then
		# Интерфейс появляется не мгновенно: huawei_cdc_ncm ещё договаривается
		# с модемом о формате NTB и заводит WDM-канал.
		i=0
		while [ $i -lt 10 ]; do
			find_hilink_iface && break
			sleep 1
			i=$((i + 1))
		done
		find_hilink_iface || die "модули загружены, а сетевой интерфейс не появился" \
			"смотри dmesg на предмет huawei_cdc_ncm/cdc_ncm: интерфейс мог остаться за option"
		ok "сетевой интерфейс $HILINK_IF (драйвер $HILINK_DRV)"
	fi
fi

# --------------------------------------------------------- RNDIS -----------
# RNDIS-устройства (MTS 81332FT / ZTE MF90 и аналоги) отдают сетевой интерфейс
# через класс e0/01/03 (Wireless Controller / RNDIS) или 02/02/ff. В ядре головы
# CONFIG_USB_NET_RNDIS_HOST выключен, поэтому подвозим rndis_host.ko модулем.
stage "RNDIS-интерфейс"
if [ "${WWAN_MODE:-}" = ppp ]; then
	skip "задан WWAN_MODE=ppp — RNDIS не трогаем"
elif find_hilink_iface; then
	skip "сетевой интерфейс модема уже есть ($HILINK_IF, драйвер $HILINK_DRV)"
elif ! find_rndis_iface; then
	skip "RNDIS-устройств на шине нет — стадия не нужна"
else
	ok "RNDIS-интерфейс $(basename "$RNDIS_IF") ($RNDIS_ID)"
	RNDISDIR=$(mod_dir f515_rndis.ko)
	[ -f "$RNDISDIR/f515_rndis.ko" ] || die "нет файла $RNDISDIR/f515_rndis.ko" \
		"положи modules/prebuilt/f515_rndis.ko в $TMP или собери: modules/build-cfi.sh src/rndis"
	load_module "$RNDISDIR/f515_rndis.ko" f515_rndis /sys/bus/usb/drivers/f515_rndis

	_i=$(basename "$RNDIS_IF")
	if [ -e "/sys/bus/usb/drivers/f515_rndis" ] && [ ! -e "$RNDIS_IF/driver" ]; then
		do_it sh -c "printf %s $_i >/sys/bus/usb/drivers/f515_rndis/bind 2>/dev/null" || true
	fi

	if [ "$CHECK_ONLY" = 0 ]; then
		i=0
		while [ $i -lt 10 ]; do
			find_hilink_iface && break
			sleep 1
			i=$((i + 1))
		done
		find_hilink_iface || die "модуль f515_rndis загружен, а сетевой интерфейс не появился" \
			"смотри dmesg на предмет f515_rndis"
		ok "сетевой интерфейс $HILINK_IF (драйвер $HILINK_DRV)"
	fi
fi

# --------------------------------------------------------- модем -----------
stage "какой модем подключён"

MODE=${WWAN_MODE:-}
if [ -n "$MODE" ]; then
	ok "тип задан вручную: WWAN_MODE=$MODE"
	[ "$MODE" = hilink ] && { find_hilink_iface || die "hilink-интерфейс не найден" \
		"убери WWAN_MODE, чтобы скрипт определил тип сам"; }
	[ "$MODE" = ppp ] && { find_usb_dev || die "модем 12d1:* не найден" \
		"убери WWAN_MODE, чтобы скрипт определил тип сам"; }
elif find_hilink_iface; then
	MODE=hilink
	ok "HiLink-модем: сетевой интерфейс $HILINK_IF (драйвер $HILINK_DRV)"
elif find_usb_dev; then
	MODE=ppp
	ok "найден $USB_VID:$USB_PID ($(basename "$USB_DEV")) — ветка AT/PPP"
else
	say "   видимые USB-устройства:"
	for d in /sys/bus/usb/devices/*; do
		[ -f "$d/idVendor" ] || continue
		say "      $(basename "$d")  $(cat "$d/idVendor" 2>/dev/null):$(cat "$d/idProduct" 2>/dev/null)" \
			"\"$(cat "$d/product" 2>/dev/null)\""
	done
	say "   сетевые интерфейсы:"
	for d in /sys/class/net/*; do
		[ -f "$d/address" ] || continue
		say "      $(basename "$d") driver=$(basename "$(readlink -f "$d/device/driver" 2>/dev/null)")"
	done
	die "модем не найден ни как сетевой интерфейс, ни как 12d1:*" \
		"проверь кабель и питание USB-порта; Huawei после перевтыкания возвращается в storage-режим"
fi

# ================================================================ HILINK ====
if [ "$MODE" = hilink ]; then
	WAN_IF=$HILINK_IF

	if [ "$DO_RECONNECT" = 1 ] && [ "$CHECK_ONLY" = 0 ]; then
		say "   [reconnect] сброс сетевого интерфейса $WAN_IF..."
		ip link set "$WAN_IF" down 2>/dev/null || true
		sleep 1
		ADDR=""
		GW=""
	fi

	stage "адрес по DHCP на $WAN_IF"
	ADDR=$(iface_addr "$WAN_IF")
	if [ "$DO_RECONNECT" = 0 ] && [ -n "$ADDR" ]; then
		skip "$WAN_IF уже с адресом: $ADDR"
	elif [ "$CHECK_ONLY" = 1 ]; then
		say "   [dry ] ip link set $WAN_IF up + udhcpc"
	else
		ip link set "$WAN_IF" up
		i=0
		while [ $i -lt 30 ]; do
			[ "$(cat /sys/class/net/$WAN_IF/carrier 2>/dev/null)" = "1" ] && break
			sleep 1
			i=$((i + 1))
		done
		[ "$(cat /sys/class/net/$WAN_IF/carrier 2>/dev/null)" = "1" ] ||
			warn "carrier так и не появился за 30 с — пробуем DHCP всё равно"

		# HiLink-модем сам раздаёт DHCP и делает NAT, но udhcpc здесь без
		# default-скрипта: аренду получает, а применить её некому — разбираем
		# вывод и настраиваем интерфейс руками.
		have busybox || die "нет busybox — нечем взять DHCP-аренду" \
			"задай адрес вручную: WWAN_HILINK_ADDR/WWAN_HILINK_GW"
		LEASE=$(busybox udhcpc -i "$WAN_IF" -q -n -f 2>&1)
		ADDR=$(echo "$LEASE" | sed -n 's/.*lease of \([0-9.]*\) obtained from \([0-9.]*\).*/\1/p' | tail -1)
		GW=$(echo "$LEASE" | sed -n 's/.*lease of \([0-9.]*\) obtained from \([0-9.]*\).*/\2/p' | tail -1)
		if [ -z "$ADDR" ]; then
			warn "DHCP молчит, беру запасной адрес $HILINK_ADDR/$HILINK_GW"
			ADDR=$HILINK_ADDR
			GW=$HILINK_GW
		fi
		ip addr replace "$ADDR/24" dev "$WAN_IF"
		ok "$WAN_IF: $ADDR (шлюз $GW)"
	fi

	stage "шлюз"
	if [ -z "$GW" ]; then
		# Адрес уже был (или его поставил прошлый запуск) — шлюз берём из
		# существующего маршрута, а если и его нет, то у HiLink-модемов это
		# всегда .1 своей же подсети.
		GW=$(ip route show table all 2>/dev/null |
			sed -n "s/^default via \([0-9.]*\) dev $WAN_IF.*/\1/p" | head -1)
		[ -n "$GW" ] || GW=$(echo "${ADDR:-$HILINK_ADDR}" | sed 's/\.[0-9]*$/.1/')
	fi
	[ -n "$ADDR" ] || ADDR=$(iface_addr "$WAN_IF")
	ok "шлюз модема $GW"

	# DNS у HiLink-модема раздаёт он сам (прокси на своём же адресе).
	DNS=$GW
fi

# =================================================================== PPP ====
if [ "$MODE" = ppp ]; then
	WAN_IF=ppp0

	stage "файлы"
	MODDIR=$(mod_dir usbserialmerged2.ko)
	KO_USB=$MODDIR/usbserialmerged2.ko
	KO_PPP=$MODDIR/ppp_async.ko
	DIAL_SH=${WWAN_DIALSH:-$DIR/dial.sh}
	[ -f "$DIAL_SH" ] || DIAL_SH=$TMP/dial.sh

	for f in "$KO_USB" "$KO_PPP" "$DIAL_SH"; do
		[ -f "$f" ] || die "нет файла $f" "разложи содержимое scripts/ и modules/prebuilt/ в $TMP"
	done
	[ -x "$DIAL_SH" ] || chmod 755 "$DIAL_SH" 2>/dev/null
	ok "модули и dial.sh найдены в $MODDIR"

	_missing=""
	for t in insmod lsmod pppd stty; do
		have "$t" || _missing="$_missing $t"
	done
	[ -z "$_missing" ] || die "в системе нет:$_missing" \
		"без них PPP-подъём невозможен; pppd обычно /system/bin/pppd"

	# Стадия «режим модема» (modeswitch из storage-режима) отработала раньше, до
	# определения типа: без неё на шине нет ни NCM-, ни AT/PPP-интерфейсов.
	# NEED_SWITCH оттуда нужен ниже, в стадии последовательных портов.

	stage "модуль usbserial+option"
	# rmmod на этой голове роняет ядро — выгружать модули нельзя ни при каких условиях.
	load_module "$KO_USB" usbserialmerged2 /sys/bus/usb/drivers/option

	stage "последовательные порты"
	if [ "$CHECK_ONLY" = 1 ] && [ "$NEED_SWITCH" = 1 ]; then
		# В сухом прогоне modeswitch только печатается, но не выполняется, поэтому
		# модем так и остался флешкой и AT/PPP-интерфейсов на шине физически нет.
		# Это не поломка, а прямое следствие --check, и советовать тут dmesg вредно.
		skip "модем ещё в storage-режиме (в --check modeswitch не выполняется) — портам взяться неоткуда"
	elif [ "$CHECK_ONLY" = 1 ] && [ ! -e /sys/bus/usb/drivers/option ]; then
		skip "модуль не загружен (--check), порты проверить нечем"
	else
		i=0
		while [ $i -lt 15 ]; do
			[ -c /dev/ttyUSB0 ] && break
			sleep 1
			i=$((i + 1))
		done

		if [ ! -c /dev/ttyUSB0 ]; then
			# Драйвер есть, но интерфейсы не подхватились — чаще всего PID не в
			# таблице option. Это лечится штатным механизмом new_id.
			warn "ttyUSB не появились, пробуем добавить $USB_VID:$USB_PID через new_id"
			for p in /sys/bus/usb-serial/drivers/option1/new_id /sys/bus/usb/drivers/option/new_id; do
				[ -w "$p" ] && do_it sh -c "echo '$USB_VID $USB_PID' > $p"
			done
			sleep 2
		fi
		[ -c /dev/ttyUSB0 ] || die "порты ttyUSB не появились" \
			"смотри dmesg: привязался ли option к интерфейсам $(basename "$USB_DEV"):1.*"

		# У части прошивок Huawei своя нумерация вместо 10/12: 61 = 4G MODEM,
		# 62 = 4G PCUI, 76 = NCM (E3272, AT^SETPORT=? это подтверждает).
		MODEM_TTY=$(port_for_proto 10) || MODEM_TTY=$(port_for_proto 61) ||
			MODEM_TTY=/dev/ttyUSB0
		CTRL_TTY=$(port_for_proto 12) || CTRL_TTY=$(port_for_proto 62) ||
			CTRL_TTY=/dev/ttyUSB1
		[ -c "$CTRL_TTY" ] || CTRL_TTY=$MODEM_TTY
		ok "модемный порт $MODEM_TTY, управляющий $CTRL_TTY (предположительно)"
		ok "привязано интерфейсов: $(ls -d "$USB_DEV":*/ttyUSB* 2>/dev/null | wc -l)"
		# Раскладку печатаем всегда: на незнакомом свистке это единственный способ
		# понять, почему выбран тот порт, а не другой, — особенно когда до головы
		# нет доступа по adb и весь разбор идёт по этому тексту на экране.
		for _i in "$USB_DEV":*; do
			[ -f "$_i/bInterfaceProtocol" ] || continue
			_pr=$(cat "$_i/bInterfaceProtocol" 2>/dev/null)
			_tt=$(ls -d "$_i"/ttyUSB* 2>/dev/null | sed 's|.*/||' | tr '\n' ' ')
			say "      $(basename "$_i")  protocol=$_pr  ${_tt:-без ttyUSB}"
		done
	fi

	stage "PPP в ядре"
	[ -c /dev/ppp ] || die "нет /dev/ppp — в ядре не собран CONFIG_PPP" \
		"это уже не лечится модулем, нужен другой способ (NCM/NDIS)"
	ok "/dev/ppp на месте"

	if grep -q '^ppp' /proc/tty/ldiscs 2>/dev/null; then
		skip "line discipline ppp уже зарегистрирована"
	else
		load_module "$KO_PPP" ppp_async ""
		[ "$CHECK_ONLY" = 1 ] || grep -q '^ppp' /proc/tty/ldiscs 2>/dev/null ||
			die "ppp_async загрузился, но ldisc ppp не появилась" "смотри dmesg"
		[ "$CHECK_ONLY" = 1 ] || ok "line discipline ppp зарегистрирована"
	fi

	stage "SIM и регистрация в сети"
	if [ "$DO_RECONNECT" = 1 ] && [ "$CHECK_ONLY" = 0 ]; then
		_pids=$(pidof pppd 2>/dev/null)
		if [ -n "$_pids" ]; then
			say "   [reconnect] останавливаю старый pppd (pid $_pids)..."
			kill $_pids 2>/dev/null
			sleep 1
			pidof pppd >/dev/null 2>&1 && kill -9 $(pidof pppd) 2>/dev/null
			sleep 1
		fi
		# Чистим старые ip rule для прежних адресов
		for _rip in $(ip rule show 2>/dev/null | grep -E 'lookup (99|legacy_system)' | grep 'from ' | grep -v 'from all' | awk '{print $3}'); do
			case "$_rip" in
			10.* | 192.168.* | 172.*) ip rule del from "$_rip" 2>/dev/null || true ;;
			esac
		done
		ADDR=""
	fi

	if [ "$DO_RECONNECT" = 0 ] && pidof pppd >/dev/null 2>&1; then
		skip "pppd уже держит порт — AT-опрос пропускаем"
	elif [ "$CHECK_ONLY" = 1 ] && [ ! -c "${CTRL_TTY:-/dev/null}" ]; then
		skip "нет управляющего порта"
	else
		# Ждём ответа, а не спрашиваем один раз. Сразу после modeswitch устройство
		# перечисляется заново: ttyUSB* уже созданы, а прошивка модема ещё не готова
		# разговаривать, и первый AT уходит в пустоту. Единственный вопрос стоил
		# минуты простоя после каждой перезагрузки: заход падал с «не отвечает на AT»,
		# и связь появлялась только со следующей проверкой watchdog'а. Ожидание тут
		# не фиксированное: обычно порт отвечает с первой-второй попытки, а потолок
		# нужен ровно для того, чтобы не висеть вечно на мёртвом модеме.
		# Спрашиваем КАЖДЫЙ ttyUSB устройства, а не только тот, на который указал
		# bInterfaceProtocol. На E173 (12d1:1c05) протокола 12 нет ни у одного
		# интерфейса, догадка даёт ttyUSB1, а он молчит — и весь подъём падал здесь,
		# хотя модем исправен и AT отвечает на соседнем порту.
		_guess=$CTRL_TTY
		_cands=$(at_candidates)
		[ -n "$_cands" ] || die "у устройства нет ни одного ttyUSB" \
			"смотри стадию 6: привязался ли option к интерфейсам"
		_deadline=$(( $(date +%s) + AT_WAIT_SECS ))
		_found=""
		while :; do
			for _cand in $_cands; do
				at "$_cand" "ATE0" 1 >/dev/null 2>&1
				# Регистр ответов приводим к верхнему: на части портов включён iuclc
				# и модем отвечает "ok" вместо "OK".
				case "$(at "$_cand" "AT" 2 | tr 'a-z' 'A-Z')" in
				*OK*) _found=$_cand; break ;;
				esac
			done
			[ -n "$_found" ] && break
			[ "$(date +%s)" -ge "$_deadline" ] && break
			sleep 2
		done
		if [ -n "$_found" ]; then
			CTRL_TTY=$_found
			if [ "$_found" = "$_guess" ]; then
				ok "порт $CTRL_TTY отвечает"
			else
				ok "AT отвечает $CTRL_TTY (догадка $_guess молчит)"
			fi
			# Кладём найденный порт рядом: иконка сети берёт его отсюда и не
			# повторяет тот же перебор со своей стороны.
			[ "$CHECK_ONLY" = 1 ] || echo "$CTRL_TTY" >"$STATE/at-tty" 2>/dev/null
		else
			die "ни один порт не отвечает на AT: $_cands (ждали $AT_WAIT_SECS с)" \
			    "порт мог занять другой процесс, либо модем ещё не готов"
		fi

		_r=$(at "$CTRL_TTY" "AT+CPIN?" 3 | tr 'a-z' 'A-Z')
		case "$_r" in
		*READY*)      ok "SIM готова" ;;
		*"SIM PIN"*)  die "SIM требует PIN" "сними PIN на телефоне или задай его вручную: AT+CPIN=\"1234\"" ;;
		*"SIM PUK"*)  die "SIM заблокирована (PUK)" "разблокируй SIM на телефоне" ;;
		*ERROR*)      die "модем не видит SIM" "проверь, что SIM вставлена и контакты чистые" ;;
		*)            warn "непонятный ответ на AT+CPIN?: $(echo "$_r" | tr '\n' ' ')" ;;
		esac

		# Сигнал и регистрация появляются не мгновенно после включения модема.
		i=0
		REG=""
		while [ $i -lt 30 ]; do
			_r=$(at "$CTRL_TTY" "AT+CREG?" 2)$(at "$CTRL_TTY" "AT+CGREG?" 2)
			case "$_r" in
			*",1"* | *",5"*) REG=1; break ;;
			esac
			sleep 2
			i=$((i + 2))
		done
		if [ -n "$REG" ]; then
			ok "зарегистрирован в сети"
		else
			die "модем не регистрируется в сети (30 с ожидания)" \
				"проверь баланс/активность SIM и уровень сигнала, вынеси антенну"
		fi

		_r=$(at "$CTRL_TTY" "AT+CSQ" 2)
		_csq=$(echo "$_r" | sed -n 's/.*+CSQ: \([0-9]*\),.*/\1/p' | head -1)
		case "$_csq" in
		99 | "") warn "уровень сигнала неизвестен (+CSQ: $_csq)" ;;
		*)
			if [ "$_csq" -lt 8 ] 2>/dev/null; then
				warn "слабый сигнал (+CSQ: $_csq, меньше 8) — связь может рваться"
			else
				ok "сигнал +CSQ: $_csq"
			fi ;;
		esac

		_r=$(at "$CTRL_TTY" "AT+COPS?" 3)
		_op=$(echo "$_r" | sed -n 's/.*+COPS: [0-9]*,[0-9]*,"\([^"]*\)".*/\1/p' | head -1)
		[ -n "$_op" ] && ok "оператор: $_op"
	fi

	stage "дозвон"
	ADDR=$(iface_addr ppp0)
	if [ "$DO_RECONNECT" = 0 ] && [ -n "$ADDR" ]; then
		skip "ppp0 уже поднят: $ADDR"
	elif [ "$CHECK_ONLY" = 1 ]; then
		say "   [dry ] pppd $MODEM_TTY ... connect $DIAL_SH"
	else
		if pidof pppd >/dev/null 2>&1; then
			# Даём ему шанс: возможно, дозвон идёт прямо сейчас.
			_w=0
			while [ $_w -lt 10 ] && [ -z "$ADDR" ] && pidof pppd >/dev/null 2>&1; do
				sleep 1
				_w=$((_w + 1))
				ADDR=$(iface_addr ppp0)
			done
		fi
		if [ -n "$ADDR" ]; then
			ok "ppp0 поднялся сам: $ADDR"
		elif pidof pppd >/dev/null 2>&1; then
			# Живой pppd без адреса — это зависший pppd (обычно встал на
			# connect-скрипте, когда модем остался в data-режиме). Он держит
			# модемный порт, поэтому просто ждать бессмысленно: снимаем его,
			# иначе ни одна следующая попытка не начнётся.
			warn "pppd запущен, но ppp0 без адреса — снимаю зависший pppd"
			kill -9 $(pidof pppd) 2>/dev/null
			sleep 2
		fi
		if [ -z "$ADDR" ]; then
			# nodefaultroute — принципиально: подмена основного маршрута оборвала бы
			# управляющий adb. Маршрутизацией занимается отдельная стадия ниже.
			_auth=""
			[ -n "$PPP_USER" ] && _auth="user $PPP_USER"
			APN="$APN" WWAN_DIAL="$DIAL" setsid pppd "$MODEM_TTY" 115200 \
				nodetach noauth nodefaultroute noipdefault \
				ipcp-accept-local ipcp-accept-remote novj novjccomp local \
				lcp-echo-interval 30 lcp-echo-failure 4 \
				$_auth logfile "$PPP_LOG" connect "$DIAL_SH" \
				</dev/null >/dev/null 2>&1 &
			say "   pppd запущен на $MODEM_TTY (APN $APN)"
		fi

		i=0
		while [ $i -lt 60 ]; do
			ADDR=$(iface_addr ppp0)
			[ -n "$ADDR" ] && break
			pidof pppd >/dev/null 2>&1 || break
			sleep 1
			i=$((i + 1))
		done

		if [ -z "$ADDR" ]; then
			# Уходим с ошибкой — но не оставляем за собой pppd, который держит
			# модемный порт: следующая попытка должна начинаться с чистого места.
			pidof pppd >/dev/null 2>&1 && kill -9 $(pidof pppd) 2>/dev/null
			say "   последние строки $PPP_LOG:"
			tail -n 12 "$PPP_LOG" 2>/dev/null | tr -d '\r' | while read -r l; do say "      $l"; done
			_t=$(tail -n 40 "$PPP_LOG" 2>/dev/null)
			case "$_t" in
			*"status = 0x2"*)
				die "модем отверг APN" "проверь APN оператора: сейчас '$APN' (WWAN_APN=...)" ;;
			*"status = 0x3"* | *"NO CARRIER"*)
				die "нет ответа CONNECT на дозвон" "модем не зарегистрирован либо номер дозвона не '$DIAL'" ;;
			*"timeout sending"*)
				die "нет ответа по LCP" "скорее всего это не модемный порт; попробуй WWAN_TTY=/dev/ttyUSB2" ;;
			*"authentication failed"* | *"Peer refused"* | *"CHAP authentication failed"*)
				die "оператор требует логин/пароль" "задай WWAN_USER и WWAN_PASS" ;;
			*)
				die "ppp0 не поднялся за 45 с" "разбирайся по $PPP_LOG" ;;
			esac
		fi
		ok "ppp0 поднят: $ADDR"
	fi

	# DNS оператора спрашиваем у самого модема, CHECK_HOST — запасной вариант.
	DNS=""
	if [ -n "$CTRL_TTY" ] && [ -c "$CTRL_TTY" ] && ! pidof pppd >/dev/null 2>&1; then
		DNS=$(at "$CTRL_TTY" "AT+CGCONTRDP=1" 3 |
			sed -n 's/.*+CGCONTRDP: [^"]*"[^"]*","[^"]*","[^"]*","\([0-9.]*\)".*/\1/p' | head -1)
	fi
	DNS=${DNS:-$CHECK_HOST}
fi

# Найденное выше — это «как отдал оператор»; последнее слово за настройкой.
dns_pick "$DNS"

# ============================================================== ОБЩЕЕ =======
stage "маршруты и проверка связи"

if [ -z "$ADDR" ] && [ "$CHECK_ONLY" = 1 ]; then
	skip "$WAN_IF не поднят"
else
	add_default "$TABLE" 10
	ip rule show 2>/dev/null | grep -q "from $ADDR " || do_it ip rule add from "$ADDR" table "$TABLE"
	ip rule show 2>/dev/null | grep -q "oif $WAN_IF " || do_it ip rule add oif "$WAN_IF" table "$TABLE"
	ok "маршрут по умолчанию для $WAN_IF в таблице $TABLE"

	if [ "$CHECK_ONLY" = 0 ]; then
		if ping -c 2 -W 4 -I "$WAN_IF" "$CHECK_HOST" >/dev/null 2>&1; then
			ok "связь есть (ping $CHECK_HOST через $WAN_IF)"
		else
			warn "$WAN_IF поднят, но ping $CHECK_HOST не проходит"
			warn "у оператора может быть заблокирован ICMP — проверь curl/nslookup"
		fi
	fi
fi

# ------------------------------------------------- опционально: приложения --
if [ "$DO_SYSTEM" = 1 ]; then
	stage "интернет для приложений Android"

	# Правила вендора 9990-9999 «from all lookup main» идут раньше fwmark-правил,
	# поэтому root/adb-сессиям достаточно default в main.
	_cur=$(ip route show table main 2>/dev/null | grep '^default')
	# Свой же Wi-Fi-маршрут (его кладёт wifi_priority) за чужой считать нельзя:
	# иначе после первого подъёма модемный default в main не появится вовсе, и
	# резерва не будет — падать станет некуда ровно тогда, когда это нужно.
	_alien=$(echo "$_cur" | grep '^default' |
		grep -v "dev $WAN_IF " | grep -v "dev wlan[0-9]* metric $WIFI_METRIC")
	if echo "$_cur" | grep -q "dev $WAN_IF "; then
		skip "в main уже default через $WAN_IF"
	elif [ -n "$_alien" ]; then
		warn "в main уже есть чужой default: $_alien"
		warn "не трогаю — убери его вручную, если нужен модем"
	else
		add_default main 20
		ok "default через $WAN_IF добавлен в main (metric 20 — резерв под Wi-Fi)"
	fi

	# ...но модем в main — резерв: пока в Wi-Fi есть интернет, он должен быть
	# приоритетнее (см. wifi_priority выше). Дальше за этим следит watchdog.
	_wp=$(wifi_priority) && ok "$_wp" || {
		_wp_if=$(wifi_iface) || _wp_if=""
		if [ -z "$_wp_if" ]; then
			skip "Wi-Fi не поднят — в main остаётся только модем"
		else
			skip "приоритет Wi-Fi над модемом уже расставлен"
		fi
	}

	# У приложений маршрутизация другая: ConnectivityService помечает их сокеты
	# fwmark'ом конкретной сети (netd, per-app default network) и заворачивает
	# в СВОЮ таблицу маршрутизации ("vlan72" для этой сети) — правило main здесь
	# вообще не участвует. Штатный TBOX физически снят, но Android держит его
	# "призрачную" сотовую сеть (единственную с CELLULAR/INTERNET, когда Wi-Fi
	# выключен), и таблица vlan72 указывает default на мёртвый шлюз
	# 192.168.72.1 (постоянная ARP-запись без реального устройства за ней) —
	# трафик приложений туда просто проваливается.
	#
	# Насколько эта правка нужна — зависит от прошивки, и на стенде (2026-08-16)
	# она оказалась лишней: у вендора правило «9999: from all lookup main» стоит
	# ВЫШЕ fwmark-правил сети (13000/14000), поэтому трафик приложений разрешается
	# в main и до таблицы vlan72 не доходит вовсе —
	# `ip route get 8.8.8.8 mark 0x50066` отвечает `dev ppp0`. Интернет приложениям
	# на этой голове даёт default в main, а не строка ниже. Оставлена как
	# страховка для голов с другим порядком правил: стоит она одного ip route.
	tbox_net

	if [ -z "$TB_SRC" ]; then
		warn "у $TB_IF нет адреса — эта сеть сейчас не активна, пропускаю"
	elif ip route show table "$TB_IF" 2>/dev/null | grep -q "^default.* dev $WAN_IF"; then
		skip "таблица $TB_IF уже указывает на $WAN_IF"
	else
		add_default "$TB_IF" 5
		ok "таблица $TB_IF: default переключён на $WAN_IF (приложения теперь идут через модем)"
	fi

	# DNS — отдельная история от правки таблицы выше, и, в отличие от неё, вполне
	# рабочая: сам сервер 192.168.72.1 лежит внутри подсети vlan72/24, для него
	# per-host маршрут (scope link) важнее default и всегда уводит пакет в мёртвый
	# L2 — что бы мы ни клали в default какой угодно таблицы. Поэтому адрес
	# подменяем DNAT'ом на живой, после чего пакет выходит из подсети и идёт
	# наружу обычным путём. Здесь же применяется кастомный DNS — подробности,
	# почему другого места для него нет, в комментарии к dns_nat.
	dns_nat "$DNS"

	# Признак, который реально видят приложения (не заглядывая внутрь netd):
	# ConnectivityService перепроверяет валидацию не мгновенно — сразу после
	# этой стадии сеть ещё может числиться невалидированной.
	if [ "$CHECK_ONLY" = 0 ]; then
		_val=$(dumpsys connectivity 2>/dev/null | grep -m1 'type: Tbox' | grep -o 'everValidated{[a-z]*}')
		case "$_val" in
		*true*) ok "сеть приложений (Tbox) уже провалидирована" ;;
		*) warn "сеть приложений (Tbox) ещё не провалидирована — Android перепроверяет её не сразу, подожди и посмотри снова: dumpsys connectivity | grep -A1 'type: Tbox'" ;;
		esac
	fi
fi

# ------------------------------------------------------------------ итог ----
say ""
say "== итог"
say "   тип:       $MODE"
say "   $WAN_IF:      ${ADDR:-не поднят}"
say "   маршрут:   $(ip route show table "$TABLE" 2>/dev/null | head -1)"
if [ "$DO_SYSTEM" = 1 ]; then
	if [ "$DNS_IS_CUSTOM" = 1 ]; then
		say "   DNS:       $DNS (задан вручную)"
	else
		say "   DNS:       $DNS (от оператора)"
	fi
fi
if [ "$CHECK_ONLY" = 0 ] && [ -n "$ADDR" ]; then
	if timeout 10 ping -c 1 -W 5 -I "$WAN_IF" "$CHECK_HOST" >/dev/null 2>&1; then
		say "   интернет:  есть"
	else
		say "   интернет:  ping не проходит (см. предупреждения выше)"
		if [ "$DO_RECONNECT" = 1 ]; then
			exit 1
		fi
	fi
fi
say "   лог:       $LOG"

# Состояние для wwan-boot.sh: какой интерфейс сторожить в watchdog-цикле.
if [ "$CHECK_ONLY" = 0 ] && [ -n "$ADDR" ]; then
	mkdir -p "$STATE" 2>/dev/null
	echo "$WAN_IF" >"$STATE/wan-iface" 2>/dev/null
	# Иконка сотовой сети в статус-баре: показать сигнал этого модема вместо крестика.
	# Отдельный отцепленный процесс, к подъёму модема отношения не имеет — поэтому и
	# запускается последним, молча и без права уронить результат (см. tbox-icon.sh auto
	# и docs/status-icon.md).
	[ -x "$DIR/tbox-icon.sh" ] && sh "$DIR/tbox-icon.sh" auto 2>&1 | sed 's/^/   /'
fi
exit 0
