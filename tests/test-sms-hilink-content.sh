#!/bin/bash
# HiLink-ветка обязана передавать <Content> без искажений: тело кодируется в
# base64 (маркер ",base64"), поэтому коды вида 12345678 / ABCD1234 не должны
# приниматься за base64/hex, а переводы строк и XML-сущности должны выживать.
set -euo pipefail
TASK_ROOT=$(cd "$(dirname "$0")/.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

tr -d '\r' < "$TASK_ROOT/scripts/sms-hilink.sh" > "$TMP/sms-hilink.sh"
awk '/^page_messages\(\) \{/{f=1} f{print} f && /^\}$/{exit}' \
    "$TMP/sms-hilink.sh" > "$TMP/page_messages.sh"
# shellcheck disable=SC1090
. "$TMP/page_messages.sh"

RESP='<response>'
RESP="$RESP<Message><Index>1</Index><Phone>+79001234567</Phone><Date>24/11/09 10:00:00</Date><Content>12345678</Content><Smstat>0</Smstat></Message>"
RESP="$RESP<Message><Index>2</Index><Phone>+7900</Phone><Date>24/11/09 10:01:00</Date><Content>ABCD1234</Content><Smstat>1</Smstat></Message>"
RESP="$RESP<Message><Index>3</Index><Phone>+7900</Phone><Date>24/11/09 10:02:00</Date><Content>MTIzNDU2Nzg=</Content><Smstat>0</Smstat></Message>"
RESP="$RESP<Message><Index>4</Index><Phone>+7900</Phone><Date>24/11/09 10:03:00</Date><Content>A1B2C3D4E5F60718293A4B5C6D</Content><Smstat>0</Smstat></Message>"
RESP="$RESP<Message><Index>5</Index><Phone>+7900</Phone><Date>24/11/09 10:04:00</Date><Content>Привет</Content><Smstat>0</Smstat></Message>"
RESP="$RESP<Message><Index>6</Index><Phone>+7900</Phone><Date>24/11/09 10:05:00</Date><Content>line1
line2</Content><Smstat>0</Smstat></Message>"
RESP="$RESP<Message><Index>7</Index><Phone>+7900</Phone><Date>24/11/09 10:06:00</Date><Content>A &amp; B &lt; C &gt; D &quot;E&quot; &apos;F&apos; \\ back</Content><Smstat>0</Smstat></Message>"
RESP="$RESP</response>"

out=$(page_messages)
headers=$(printf '%s\n' "$out" | grep '^+CMGL:' || true)

[ "$(printf '%s\n' "$headers" | wc -l | tr -d ' ')" = 7 ] \
    || { echo "FAIL: expected 7 +CMGL headers"; exit 1; }
[ "$(printf '%s\n' "$headers" | grep -c ',base64$' || true)" = 7 ] \
    || { echo "FAIL: headers must end with ,base64"; printf '%s\n' "$headers"; exit 1; }

# Шестое поле заголовка — длина base64-тела, а не исходного текста.
bad_len=$(printf '%s\n' "$out" | awk -F, '
    /^\+CMGL:/ { hdr=$0; len=$6; getline body; if (length(body) != len+0) print hdr }
')
[ -z "$bad_len" ] \
    || { echo "FAIL: length field does not match base64 body"; printf '%s\n' "$bad_len"; exit 1; }

# Тело — ровно одна строка base64 сразу после заголовка, поэтому разбираем
# вывод парами строк и декодируем каждое тело. Записи разделяем US (0x1f).
while IFS= read -r line; do
    case "$line" in
        +CMGL:*) continue ;;
    esac
    printf '%s' "$line" | base64 -d
    printf '\037'
done <<< "$out" > "$TMP/got"

{
    printf '12345678\037'
    printf 'ABCD1234\037'
    printf 'MTIzNDU2Nzg=\037'
    printf 'A1B2C3D4E5F60718293A4B5C6D\037'
    printf 'Привет\037'
    printf 'line1\nline2\037'
    printf '%s\037' "A & B < C > D \"E\" 'F' \\ back"
} > "$TMP/want"

cmp -s "$TMP/want" "$TMP/got" \
    || {
        echo "FAIL: SMS content was modified"
        echo "--- want ---"; tr '\037' '\n' < "$TMP/want" | cat -v
        echo "--- got ---"; tr '\037' '\n' < "$TMP/got" | cat -v
        exit 1
    }

echo "SMS content: 7 messages preserved, base64 marker present"
