#!/system/bin/sh
# scripts/sms-hilink.sh — чтение и управление SMS через Web API HiLink-модема.
#
# У HiLink-прошивки (E8278, E8372, E3372h в NCM-режиме и родня) нет рабочего
# AT-порта: модем отдаёт себя сетевой картой (NCM/RNDIS) и роутером с
# веб-интерфейсом. SMS читаются и удаляются по HTTP API:
#
#   GET  /api/webserver/SesTokInfo     сессия: SesInfo + TokInfo
#   POST /api/sms/sms-list             список сообщений (BoxType=1 — входящие)
#   POST /api/sms/delete-sms           удалить одну  (<Index>N</Index>)
#
# Особенности прошивки, учтённые здесь:
#   - <SesInfo> может содержать готовый Cookie-заголовок ("SessionID=...") —
#     префикс не дублируем, иначе модем отвечает 125002;
#   - токен одноразовый/быстро протухает — сессия обновляется перед каждым
#     изменяющим запросом (refresh_session), а 125002/125003 повторяются со
#     свежей сессией: токен может перебить другой клиент (например, LBS);
#   - изменяющие запросы требуют Origin/Referer/User-Agent как у веб-интерфейса,
#     иначе модем отвечает 125003;
#   - массовый delete-sms-list не поддерживается (125003) — удаляем по одному;
#   - errorcode 108001 — требуется логин (POST /api/user/login, см. ниже).
#
# Если прошивка отвечает errorcode 108001 (требуется логин), SMS-эндпоинтам
# нужен предварительный POST /api/user/login с
#   <request><Username>admin</Username><Password>base64(md5(пароль))</Password></request>
# — сессия SesTokInfo при этом получается обычным образом.
#
# Вывод list — формат +CMGL:, совместимый с SmsHelper.parseResponse(). Тело
# сообщения передаётся в base64 с явным маркером, поэтому переводы строк и
# XML-сущности не теряются; SmsHelper декодирует его только по маркеру.
set -u

DIR=$(cd "$(dirname "$0")" && pwd)
ACTION="${1:-list}"
TARGET_ID="${2:-}"
case "$ACTION" in list|delete|delete_all) ;; *) echo 'Unknown SMS action'; exit 2 ;; esac
if [ "$ACTION" = delete ]; then
	case "$TARGET_ID" in ''|*[!0-9]*) echo 'Invalid SMS index'; exit 2 ;; esac
fi

# Логи, как в wwan-up.sh / sms.sh: на экран приложения (stdout скрипта Keeper
# отдаёт построчно в окно) и в общий файл /data/local/tmp/wwan.log. Данные
# чтения (+CMGL:/текст сообщений) печатаются обычным echo и в файл не дублируются.
LOG=${WWAN_LOG:-/data/local/tmp/wwan.log}
say()  { echo "$*"; echo "$(date '+%F %T') $*" >>"$LOG" 2>/dev/null; }
ok()   { say "   [ ok ] $*"; }
warn() { say "   [warn] $*"; }
# Ошибка — в stderr (у Keeper 2>&1, тоже в окно) и в файл.
err()  { echo "   [FAIL] $*" >&2; echo "$(date '+%F %T')   [FAIL] $*" >>"$LOG" 2>/dev/null; }

# Код ошибки из XML-ответа модема (<error><code>N</code>...).
err_code() { printf '%s' "$1" | grep -o '<code>[0-9]*</code>' | sed 's:<code>::;s:</code>::' | head -1; }

# Cookie-файл для curl (-c/-b) и файл заголовков ответа.
mkdir -p "$DIR/state" 2>/dev/null
CK="$DIR/state/hilink-cookies"
CK_HEADER="$DIR/state/hilink-cookies.header"

# Заголовки как у веб-интерфейса модема (эталон из DevTools Firefox). Без них
# модем заводит «неполную» сессию: чтение работает, а удаление отвечает 125003.
UA_BROWSER="Mozilla/5.0 (Windows NT 10.0; Win64; x64) Gecko/20100101 Firefox/128.0"

say "==== sms-hilink.sh: действие=$ACTION${TARGET_ID:+ индекс=$TARGET_ID}"

# ---------------------------------------------------------------------------
# HTTP-клиент. HiLink Web API требует Cookie, CSRF-токен, Origin/Referer и
# POST-тело, поэтому нужен именно curl. wget из toybox (Android 11) умеет
# только GET -O и не понимает --header/--post-data: тихо ломаться он не должен.
# HDR_COOKIE/HDR_TOKEN заполняются ниже, после получения сессии; функции
# читают их в момент вызова. Тело ответа отдаётся ТОЛЬКО на stdout (его забирает
# $(...) — иначе RESP был бы засорён логами). Код возврата curl сохраняется.
# ---------------------------------------------------------------------------
if ! command -v curl >/dev/null 2>&1; then
	err "для HiLink нужен curl: wget из toybox не умеет заголовки и POST"
	err "установи curl или используй прошивку/систему с /system/bin/curl"
	exit 1
fi

# SesTokInfo: сохраняем Set-Cookie (-c) и заголовки ответа (-D).
http_session() {
	local _r _o
	# Сессию создаём с теми же Origin/Referer/UA, что и веб-интерфейс.
	# Origin берём из URL: на момент пробы шлюз ещё неизвестен.
	_o=$(printf '%s' "$1" | sed -n 's|\(http://[^/]*\).*|\1|p')
	_r=$(curl -s --max-time 5 -D "$CK_HEADER" -c "$CK" \
		-H "Origin: $_o" \
		-H "Referer: $_o/html/index.html" \
		-H "User-Agent: $UA_BROWSER" \
		"$1"); _rc=$?
	printf '%s' "$_r"
	return $_rc
}
# Остальные запросы: COOKIE_MODE выбирает, чем слать сессию — cookie-файлом
# (-b, Set-Cookie c модема) или ручным заголовком из <SesInfo> тела.
http_get() {
	local _r
	if [ "$COOKIE_MODE" = jar ]; then
		_r=$(curl -s --max-time 10 -b "$CK" -H "$HDR_TOKEN" \
			-H "Origin: http://$GW" \
			-H "Referer: http://$GW/html/smsinbox.html" \
			-H "User-Agent: $UA_BROWSER" "$1"); _rc=$?
	else
		_r=$(curl -s --max-time 10 -H "$HDR_COOKIE" -H "$HDR_TOKEN" \
			-H "Origin: http://$GW" \
			-H "Referer: http://$GW/html/smsinbox.html" \
			-H "User-Agent: $UA_BROWSER" "$1"); _rc=$?
	fi
	printf '%s' "$_r"
	return $_rc
}
http_post() {
	local _r
	# Заголовки ровно как у веб-интерфейса модема (эталон из DevTools):
	# Origin + Referer на страницу SMS. Без них модем режет изменяющие
	# запросы (delete-sms и т.п.) ошибкой 125003, хотя sms-list проходит.
	if [ "$COOKIE_MODE" = jar ]; then
		_r=$(curl -s --max-time 10 -X POST -b "$CK" -H "$HDR_TOKEN" \
			-H "Origin: http://$GW" \
			-H "Referer: http://$GW/html/smsinbox.html" \
			-H "User-Agent: $UA_BROWSER" \
			-H "X-Requested-With: XMLHttpRequest" \
			-H "Content-Type: application/x-www-form-urlencoded; charset=UTF-8" \
			--data "$2" "$1"); _rc=$?
	else
		_r=$(curl -s --max-time 10 -X POST -H "$HDR_COOKIE" -H "$HDR_TOKEN" \
			-H "Origin: http://$GW" \
			-H "Referer: http://$GW/html/smsinbox.html" \
			-H "User-Agent: $UA_BROWSER" \
			-H "X-Requested-With: XMLHttpRequest" \
			-H "Content-Type: application/x-www-form-urlencoded; charset=UTF-8" \
			--data "$2" "$1"); _rc=$?
	fi
	printf '%s' "$_r"
	return $_rc
}

is_error() { printf '%s' "$1" | grep -q '<error>'; }

# Подсказка, если прошивка требует логин для SMS-эндпоинтов (errorcode 108001).
login_hint() {
	case "$1" in *'108001'*) echo "подсказка: прошивка требует логин — POST /api/user/login (см. шапку скрипта)" >&2 ;; esac
}

# Шлюз модема: настоящий сохранил wwan-up.sh в state/system-uplink (поле 4 —
# GW), запасные — типовые адреса HiLink-роутеров. Проверяем живым ответом
# SesTokInfo, а не пингом: часть прошивок режет ICMP. 192.168.1.1 пробуем
# последним: это ещё и штатный шлюз Huawei E8278, но на некоторых головах
# этот адрес занят локальной точкой доступа, и запрос к ней был бы лишним.
find_gw() {
	local gw
	gw=$(awk '{print $4}' "$DIR/state/system-uplink" 2>/dev/null | tr -d '\r')
	if [ -n "$gw" ] && [ -n "$(http_session "http://$gw/api/webserver/SesTokInfo" 2>/dev/null)" ]; then
		echo "$gw"; return 0
	fi
	for gw in 192.168.0.1 192.168.8.1 192.168.1.1; do
		if [ -n "$(http_session "http://$gw/api/webserver/SesTokInfo" 2>/dev/null)" ]; then
			echo "$gw"; return 0
		fi
	done
	return 1
}

GW=$(find_gw) || {
	err "не найден веб-интерфейс HiLink-модема"
	err "проверь: модем поднят (wwan-up.sh), есть маршрут до шлюза, curl отвечает на http://<gw>/api/webserver/SesTokInfo"
	exit 1
}
ok "шлюз: $GW"

# Сессия: SesInfo идёт в Cookie, TokInfo — в __RequestVerificationToken.
# Ответ может прийти и в одну строку, и в несколько, и с CRLF — нормализуем.
get_session() {
	local resp flat
	resp=$(http_session "http://$GW/api/webserver/SesTokInfo") || return 1
	flat=$(printf '%s' "$resp" | tr -d '\r\n')
	is_error "$flat" && return 1
	SES=$(printf '%s' "$flat" | grep -o '<SesInfo>[^<]*</SesInfo>' | sed 's:<SesInfo>::;s:</SesInfo>::' | head -1)
	TOK=$(printf '%s' "$flat" | grep -o '<TokInfo>[^<]*</TokInfo>' | sed 's:<TokInfo>::;s:</TokInfo>::' | head -1)
	[ -n "$SES" ] && [ -n "$TOK" ]
}

# Собрать заголовки из свежих SES/TOK. Вызывается и при старте, и при каждом
# обновлении сессии перед удалением.
apply_session() {
	# Нормализация Cookie: на части прошивок <SesInfo> уже содержит готовый
	# Cookie-заголовок целиком ("SessionID=qS8/AW..."), на других — только голый
	# токен ("1f2e3d4c..."). Префикс не дублируем: "Cookie: SessionID=SessionID=..."
	# даёт модему 125002 (Session error).
	case "$SES" in
	SessionID=*) HDR_COOKIE="Cookie: $SES" ;;
	*)           HDR_COOKIE="Cookie: SessionID=$SES" ;;
	esac
	HDR_TOKEN="__RequestVerificationToken: $TOK"
	# Если модем отдал SessionID в Set-Cookie (ответ попал в cookie-файл),
	# ходим через jar (-b) — это то, что модем считает настоящей сессией.
	# Если Set-Cookie нет — фолбэк на ручной заголовок $HDR_COOKIE.
	rm -f "$CK_HEADER"
	if [ -s "$CK" ] && grep -qs 'SessionID' "$CK"; then
		COOKIE_MODE=jar
	else
		COOKIE_MODE=manual
	fi
}

# Токен на этой прошивке одноразовый/быстро протухает — перед каждым
# изменяющим запросом перевызываем SesTokInfo и пересобираем заголовки.
# Cookie-файл чистим заранее: иначе в jar останется сессия прошлого запроса.
refresh_session() {
	rm -f "$CK" "$CK_HEADER"
	get_session || return 1
	apply_session
}

rm -f "$CK" "$CK_HEADER"
get_session || { err "SesTokInfo не получен с http://$GW"; exit 1; }
apply_session

sms_list_body() {
	printf '<?xml version="1.0" encoding="UTF-8"?><request><PageIndex>%s</PageIndex><ReadCount>50</ReadCount><BoxType>1</BoxType><SortType>0</SortType><Ascending>0</Ascending><UnreadPreferred>0</UnreadPreferred></request>' "$1"
}

# Печать одной страницы ответа sms-list в формате +CMGL:
#   +CMGL: <index>,<stat>,"<phone>",,"<date>",<len>,base64
#   <content-base64>
# stat: 0 = непрочитано, 1 = прочитано (как в AT-ветке). Читает глобальный RESP.
# Тело передаётся в base64: переводы строк и XML-сущности (&amp;, &lt;, ...)
# сохраняются без потерь, а разбор ответа больше не зависит от того, на сколько
# строк растянулся <Content>. Явный маркер "base64" говорит приложению, что
# тело закодировано, — угадывать по виду строки (12345678, ABCD1234) нельзя.
page_messages() {
	local flat
	flat=$(printf '%s' "$RESP" | tr -d '\r')
	printf '%s' "$flat" | awk '
		BEGIN { RS = sprintf("%c", 1) }
		function field(s, name,    open, closetag, a, b) {
			open = "<" name ">"
			a = index(s, open)
			if (a == 0) return ""
			a += length(open)
			closetag = "</" name ">"
			b = index(substr(s, a), closetag)
			if (b == 0) return ""
			return substr(s, a, b - 1)
		}
		function decode(s) {
			gsub(/&lt;/, "<", s)
			gsub(/&gt;/, ">", s)
			gsub(/&quot;/, "\042", s)
			gsub(/&apos;/, "\047", s)
			gsub(/&amp;/, "\\&", s)
			return s
		}
		{
			s = $0
			while ((a = index(s, "<Message>")) > 0) {
				s = substr(s, a + 9)
				b = index(s, "</Message>")
				if (b == 0) break
				msg = substr(s, 1, b - 1)
				s = substr(s, b + 10)
				idx = field(msg, "Index")
				stat = field(msg, "Smstat")
				phone = field(msg, "Phone")
				cdate = field(msg, "Date")
				content = decode(field(msg, "Content"))
				# SOH не может встречаться в XML 1.0: используем его как
				# внутренний маркер перевода строки, чтобы запись осталась
				# однострочной для while read.
				gsub(/\n/, sprintf("%c", 1), content)
				printf "%s\037%s\037%s\037%s\037%s\n", idx, stat, phone, cdate, content
			}
		}
	' | while IFS=$(printf '\037') read -r idx stat phone cdate content; do
		body=$(printf '%s' "$content" | tr '\001' '\n' | base64 | tr -d '\n')
		printf '+CMGL: %s,%s,"%s",,"%s",%d,base64\n%s\n' \
			"$idx" "$stat" "$phone" "$cdate" "${#body}" "$body"
	done
}

# Хелпер delete_all: собрать индексы текущей страницы в глобальный PAGE_IDS.
collect_page_ids() {
	local ids
	ids=$(printf '%s' "$RESP" | grep -o '<Index>[0-9]*</Index>' | sed 's:<Index>::; s:</Index>::' | tr '\n' ' ')
	PAGE_IDS="$PAGE_IDS $ids"
}

# Перелистывает sms-list (страницы по 50, максимум 20) и на каждой странице
# зовёт $1 (без аргументов; ответ лежит в глобальном RESP). Считает сообщения
# в глобальный MSG_TOTAL.
fetch_pages() {
	local page=1 n _c attempt
	RESP=""
	MSG_TOTAL=0
	while [ "$page" -le 20 ]; do
		attempt=0
		while :; do
			RESP=$(http_post "http://$GW/api/sms/sms-list" "$(sms_list_body "$page")") || return 1
			if [ -z "$RESP" ]; then
				err "модем не ответил на sms-list (страница $page)"
				return 1
			fi
			is_error "$RESP" || break
			_c=$(err_code "$RESP")
			case "$_c" in
			125002|125003)
				attempt=$((attempt + 1))
				if [ "$attempt" -lt "$RETRY_SMS" ]; then
					warn "sms-list ($page): $_c — повтор со свежей сессией ($attempt/$RETRY_SMS)"
					refresh_session || return 1
					sleep 1
					continue
				fi
				;;
			esac
			login_hint "$RESP"
			err "sms-list: ошибка ${_c:-неизвестна}"
			return 1
		done
		n=$(printf '%s' "$RESP" | grep -o '<Message>' | wc -l | tr -d ' ')
		MSG_TOTAL=$((MSG_TOTAL + n))
		case "$RESP" in
		*'<Message>'*) ;;
		*) return 0 ;;   # пустая страница — сообщений больше нет
		esac
		"$1"
		case "$RESP" in
		*'<Count>50</Count>'*) page=$((page + 1)) ;;
		*) return 0 ;;
		esac
	done
}

list_sms() {
	fetch_pages page_messages || return 1
	ok "найдено SMS: $MSG_TOTAL"
}

# Удалить одно сообщение (POST /api/sms/delete-sms). Массовый delete-sms-list
# на этой прошивке отвечает 125003, поэтому delete_all ходит по одному индексу,
# как веб-интерфейс модема. Токен одноразовый — сессия обновляется перед каждым
# удалением; при 125002/125003 (сессию перебил другой клиент, например LBS)
# повторяем со свежей сессией.
RETRY_SMS=3
send_delete() {
	local id=$1 body resp attempt _c
	body=$(printf '<?xml version="1.0" encoding="UTF-8"?><request><Index>%s</Index></request>' "$id")
	refresh_session || { err "не удалось обновить сессию перед удалением $id"; return 1; }
	attempt=0
	while :; do
		resp=$(http_post "http://$GW/api/sms/delete-sms" "$body")
		if [ -n "$resp" ] && ! is_error "$resp"; then
			return 0
		fi
		_c=$(err_code "$resp")
		case "$_c" in
		125002|125003)
			attempt=$((attempt + 1))
			if [ "$attempt" -lt "$RETRY_SMS" ]; then
				warn "delete-sms ($id): $_c — повтор со свежей сессией ($attempt/$RETRY_SMS)"
				refresh_session || return 1
				sleep 1
				continue
			fi
			login_hint "$resp"
			err "delete-sms ($id): ошибка $_c после $RETRY_SMS попыток"
			return 1 ;;
		*)
			login_hint "$resp"
			err "delete-sms ($id): ошибка ${_c:-неизвестна}"
			return 1 ;;
		esac
	done
}

delete_one() {
	if send_delete "$TARGET_ID"; then
		ok "удалено: $TARGET_ID"
	fi
}

delete_all() {
	local ids id removed
	PAGE_IDS=""
	fetch_pages collect_page_ids || return 1
	ids=$(printf '%s' "$PAGE_IDS" | tr ' ' '\n' | sed '/^$/d' | sort -n -u | tr '\n' ' ')
	[ -n "$ids" ] || { ok "нечего удалять"; return 0; }
	removed=0
	for id in $ids; do
		if ! send_delete "$id"; then
			err "стоп на индексе $id (удалено до этого: $removed)"
			return 1
		fi
		removed=$((removed + 1))
	done
	ok "удалено SMS: $removed"
}

case "$ACTION" in
list)       list_sms ;;
delete)     delete_one ;;
delete_all) delete_all ;;
esac
