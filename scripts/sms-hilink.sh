#!/system/bin/sh
# scripts/sms-hilink.sh — чтение и управление SMS через Web API HiLink-модема.
#
# У HiLink-прошивки (E8278, E8372, E3372h в NCM-режиме и родня) нет рабочего
# AT-порта: модем отдаёт себя сетевой картой (NCM/RNDIS) и роутером с
# веб-интерфейсом. SMS читаются и удаляются по HTTP API (все эндпоинты ниже):
#
#   GET  /api/webserver/SesTokInfo     сессия: SesInfo + TokInfo
#   POST /api/sms/sms-list             список сообщений (BoxType=1 — входящие)
#   POST /api/sms/delete-sms           удалить одну  (<Index>N</Index>)
#   POST /api/sms/delete-sms-list      удалить много (<Index>1,2,3</Index>)
#
# Каждый запрос, кроме SesTokInfo, должен нести два заголовка:
#   Cookie: SessionID=<SesInfo>
#   __RequestVerificationToken: <TokInfo>
#
# Если прошивка отвечает errorcode 108001 (требуется логин), SMS-эндпоинтам
# нужен предварительный POST /api/user/login с
#   <request><Username>admin</Username><Password>base64(md5(пароль))</Password></request>
# — сессия SesTokInfo при этом получается обычным образом.
#
# Вывод list совместим с SmsHelper.parseResponse() (text-mode формат +CMGL:),
# чтобы Java-слой приложения не менялся.
set -u

DIR=$(cd "$(dirname "$0")" && pwd)
ACTION="${1:-list}"
TARGET_ID="${2:-}"
case "$ACTION" in list|delete|delete_all) ;; *) echo 'Unknown SMS action'; exit 2 ;; esac
if [ "$ACTION" = delete ]; then
	case "$TARGET_ID" in ''|*[!0-9]*) echo 'Invalid SMS index'; exit 2 ;; esac
fi

# ---------------------------------------------------------------------------
# HTTP-клиент. curl есть в Android (/system/bin/curl); wget (toybox) — запасной.
# HDR_COOKIE/HDR_TOKEN заполняются ниже, после получения сессии; функции
# читают их в момент вызова.
# ---------------------------------------------------------------------------
if command -v curl >/dev/null 2>&1; then
	http_session() { curl -s --max-time 5 "$1"; }
	http_get() { curl -s --max-time 10 -H "$HDR_COOKIE" -H "$HDR_TOKEN" "$1"; }
	http_post() { curl -s --max-time 10 -X POST \
		-H "$HDR_COOKIE" -H "$HDR_TOKEN" \
		-H "Content-Type: application/x-www-form-urlencoded; charset=UTF-8" \
		--data "$2" "$1"; }
else
	http_session() { wget -q -O - "$1"; }
	http_get() { wget -q -O - --header "$HDR_COOKIE" --header "$HDR_TOKEN" "$1"; }
	http_post() { wget -q -O - \
		--header "$HDR_COOKIE" --header "$HDR_TOKEN" \
		--header "Content-Type: application/x-www-form-urlencoded; charset=UTF-8" \
		--post-data "$2" "$1"; }
fi

is_error() { printf '%s' "$1" | grep -q '<error>'; }

# Подсказка, если прошивка требует логин для SMS-эндпоинтов (errorcode 108001).
login_hint() {
	case "$1" in *'108001'*) echo "подсказка: прошивка требует логин — POST /api/user/login (см. шапку скрипта)" >&2 ;; esac
}

# Шлюз модема: настоящий сохранил wwan-up.sh в state/system-uplink (поле 4 —
# GW), запасные — типовые адреса HiLink-роутеров. Проверяем живым ответом
# SesTokInfo, а не пингом: часть прошивок режет ICMP.
find_gw() {
	local gw
	gw=$(awk '{print $4}' "$DIR/state/system-uplink" 2>/dev/null | tr -d '\r')
	if [ -n "$gw" ] && [ -n "$(http_session "http://$gw/api/webserver/SesTokInfo" 2>/dev/null)" ]; then
		echo "$gw"; return 0
	fi
	for gw in 192.168.1.1 192.168.0.1 192.168.8.1; do
		if [ -n "$(http_session "http://$gw/api/webserver/SesTokInfo" 2>/dev/null)" ]; then
			echo "$gw"; return 0
		fi
	done
	return 1
}

GW=$(find_gw) || { echo "ERROR: не найден веб-интерфейс HiLink-модема"; exit 1; }

# Сессия: SesInfo идёт в Cookie, TokInfo — в __RequestVerificationToken.
# Ответ может прийти и в одну строку, и в несколько, и с CRLF — нормализуем.
get_session() {
	local resp flat
	resp=$(http_session "http://$GW/api/webserver/SesTokInfo") || return 1
	flat=$(printf '%s' "$resp" | tr -d '\r\n')
	is_error "$flat" && return 1
	SES=$(printf '%s' "$flat" | sed -n 's:.*<SesInfo>\([^<]*\)</SesInfo>.*:\1:p')
	TOK=$(printf '%s' "$flat" | sed -n 's:.*<TokInfo>\([^<]*\)</TokInfo>.*:\1:p')
	[ -n "$SES" ] && [ -n "$TOK" ]
}
get_session || { echo "ERROR: SesTokInfo не получен с http://$GW"; exit 1; }
HDR_COOKIE="Cookie: SessionID=$SES"
HDR_TOKEN="__RequestVerificationToken: $TOK"

sms_list_body() {
	printf '<?xml version="1.0" encoding="UTF-8"?><request><PageIndex>%s</PageIndex><ReadCount>50</ReadCount><BoxType>1</BoxType><SortType>0</SortType><Ascending>0</Ascending><UnreadPreferred>0</UnreadPreferred></request>' "$1"
}

# Хитрость прошивок: если в сообщении есть символы вне ISO-8859-1 (кириллица
# и т.п.), <Content> приходит в base64. Явного признака нет, поэтому декодируем
# строки из алфавита base64 с длиной, кратной 4 и длиной >= 8 — короткий
# ASCII-текст вроде "OK" или "Test" не заденешь.
maybe_decode() {
	local s="$1" d
	case "$s" in
	''|*[!A-Za-z0-9+/=]*) echo "$s"; return ;;
	esac
	if [ $(( ${#s} % 4 )) -eq 0 ] && [ ${#s} -ge 8 ]; then
		d=$(printf '%s' "$s" | base64 -d 2>/dev/null) && { echo "$d"; return; }
	fi
	echo "$s"
}

# Печать одной страницы ответа sms-list в формате +CMGL (text-mode):
#   +CMGL: <index>,<stat>,"<phone>",,"<date>",<len>
#   <content>
# stat: 0 = непрочитано, 1 = прочитано (как в AT-ветке). Читает глобальный RESP.
page_messages() {
	local flat
	flat=$(printf '%s' "$RESP" | tr -d '\r')
	printf '%s' "$flat" | sed 's/></>\n</g' | awk '
		/<Message>/ { inmsg=1; idx=""; phone=""; cdate=""; content=""; stat=""; next }
		inmsg && /<Index>/   { v=$0; sub(/.*<Index>/,"",v);   sub(/<\/Index>.*/,"",v);   gsub(/^[ \t]+|[ \t]+$/,"",v); idx=v; next }
		inmsg && /<Phone>/   { v=$0; sub(/.*<Phone>/,"",v);   sub(/<\/Phone>.*/,"",v);   gsub(/^[ \t]+|[ \t]+$/,"",v); phone=v; next }
		inmsg && /<Date>/    { v=$0; sub(/.*<Date>/,"",v);    sub(/<\/Date>.*/,"",v);    gsub(/^[ \t]+|[ \t]+$/,"",v); cdate=v; next }
		inmsg && /<Content>/ { v=$0; sub(/.*<Content>/,"",v); sub(/<\/Content>.*/,"",v); content=v; next }
		inmsg && /<Smstat>/  { v=$0; sub(/.*<Smstat>/,"",v);  sub(/<\/Smstat>.*/,"",v);  gsub(/^[ \t]+|[ \t]+$/,"",v); stat=v; next }
		/<\/Message>/ { if (idx != "") { printf "+CMGL: %s,%s,\"%s\",,\"%s\",%d\n", idx, stat, phone, cdate, length(content); print content } inmsg=0; next }
	' | while IFS= read -r l; do
		case "$l" in
		+CMGL:*) echo "$l" ;;
		*) maybe_decode "$l" ;;
		esac
	done
}

# Хелпер delete_all: собрать индексы текущей страницы в глобальный PAGE_IDS.
collect_page_ids() {
	local ids
	ids=$(printf '%s' "$RESP" | grep -o '<Index>[0-9]*</Index>' | sed 's:<Index>::; s:</Index>::' | tr '\n' ' ')
	PAGE_IDS="$PAGE_IDS $ids"
}

# Перелистывает sms-list (страницы по 50, максимум 20) и на каждой странице
# зовёт $1 (без аргументов; ответ лежит в глобальном RESP).
fetch_pages() {
	local page=1
	RESP=""
	while [ "$page" -le 20 ]; do
		RESP=$(http_post "http://$GW/api/sms/sms-list" "$(sms_list_body "$page")") || return 1
		if [ -z "$RESP" ]; then
			echo "ERROR: модем не ответил на sms-list (страница $page)" >&2
			return 1
		fi
		if is_error "$RESP"; then
			login_hint "$RESP"
			echo "ERROR: sms-list (страница $page): $RESP" >&2
			return 1
		fi
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
}

delete_one() {
	local body resp
	body=$(printf '<?xml version="1.0" encoding="UTF-8"?><request><Index>%s</Index></request>' "$TARGET_ID")
	resp=$(http_post "http://$GW/api/sms/delete-sms" "$body")
	[ -n "$resp" ] || { echo "ERROR: модем не ответил на delete-sms" >&2; return 1; }
	if is_error "$resp"; then
		login_hint "$resp"
		echo "ERROR: delete-sms ($TARGET_ID): $resp" >&2
		return 1
	fi
	echo "OK: удалено $TARGET_ID"
}

send_delete_list() {
	local body resp
	body=$(printf '<?xml version="1.0" encoding="UTF-8"?><request><Index>%s</Index></request>' "$1")
	resp=$(http_post "http://$GW/api/sms/delete-sms-list" "$body")
	[ -n "$resp" ] || { echo "ERROR: модем не ответил на delete-sms-list" >&2; return 1; }
	if is_error "$resp"; then
		login_hint "$resp"
		echo "ERROR: delete-sms-list: $resp" >&2
		return 1
	fi
}

delete_all() {
	local ids id chunk n total
	PAGE_IDS=""
	fetch_pages collect_page_ids || return 1
	ids=$(printf '%s' "$PAGE_IDS" | tr ' ' '\n' | sed '/^$/d' | sort -n -u | tr '\n' ' ')
	[ -n "$ids" ] || { echo "OK: нечего удалять"; return 0; }
	# Часть прошивок режет длинный список индексов — бьём по 20 за запрос.
	chunk=""; n=0; total=0
	for id in $ids; do
		chunk="${chunk}${id},"
		n=$((n + 1)); total=$((total + 1))
		if [ "$n" -ge 20 ]; then
			send_delete_list "${chunk%,}" || return 1
			chunk=""; n=0
		fi
	done
	if [ -n "$chunk" ]; then
		send_delete_list "${chunk%,}" || return 1
	fi
	echo "OK: удалено SMS: $total"
}

case "$ACTION" in
list)       list_sms ;;
delete)     delete_one ;;
delete_all) delete_all ;;
esac
