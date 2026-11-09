#!/bin/bash
# SMS-коды вида 12345678 / ABCD1234 не должны «декодироваться» как base64/hex:
# HiLink-ветка обязана отдавать <Content> дословно и помечать тело как text.
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
RESP="$RESP</response>"

out=$(page_messages)
headers=$(printf '%s\n' "$out" | grep '^+CMGL:' || true)
bodies=$(printf '%s\n' "$out" | grep -v '^+CMGL:' || true)

[ "$(printf '%s\n' "$headers" | wc -l | tr -d ' ')" = 5 ] \
    || { echo "FAIL: expected 5 +CMGL headers"; exit 1; }
[ "$(printf '%s\n' "$headers" | grep -c ',text$' || true)" = 5 ] \
    || { echo "FAIL: headers must end with ,text"; printf '%s\n' "$headers"; exit 1; }

printf '%s\n' '12345678' 'ABCD1234' 'MTIzNDU2Nzg=' \
    'A1B2C3D4E5F60718293A4B5C6D' 'Привет' > "$TMP/want"
printf '%s\n' "$bodies" > "$TMP/got"
diff -u "$TMP/want" "$TMP/got" \
    || { echo "FAIL: SMS content was modified"; exit 1; }

echo "SMS content: 5 messages verbatim, text marker present"
