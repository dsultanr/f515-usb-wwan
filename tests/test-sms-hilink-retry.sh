#!/bin/bash
# 125002/125003 означают, что сессию перебил другой клиент (например, LBS):
# sms-list и delete-sms обязаны повторить запрос со свежей сессией.
set -euo pipefail
TASK_ROOT=$(cd "$(dirname "$0")/.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

tr -d '\r' < "$TASK_ROOT/scripts/sms-hilink.sh" > "$TMP/sms-hilink.sh"

extract() {
    awk -v name="$1" '
        $0 == name "() {" { f = 1 }
        f { print }
        f && /^}$/ { exit }
    ' "$TMP/sms-hilink.sh"
}

{
    cat <<'EOF'
#!/bin/bash
set -u
MODE=$1
ACTION=$2
CALL_FILE=$3
GW=gw
RETRY_SMS=3
REFRESH=0
SLEEPS=0
RESP=""
MSG_TOTAL=0
warn() { :; }
err() { :; }
login_hint() { :; }
sleep() { SLEEPS=$((SLEEPS + 1)); }
refresh_session() { REFRESH=$((REFRESH + 1)); return 0; }
is_error() { printf '%s' "$1" | grep -q '<error>'; }
err_code() { printf '%s' "$1" | grep -o '<code>[0-9]*</code>' | sed 's:<code>::;s:</code>::' | head -1; }
sms_list_body() { echo body; }
page_stub() { :; }
http_post() {
    local n
    echo x >> "$CALL_FILE"
    n=$(wc -l < "$CALL_FILE" | tr -d ' ')
    case "$MODE" in
    list_retry_then_ok)
        case "$n" in
        1) echo '<error><code>125002</code></error>' ;;
        2) echo '<error><code>125003</code></error>' ;;
        *) echo '<response><Message><Index>1</Index></Message><Count>1</Count></response>' ;;
        esac ;;
    list_always_retry) echo '<error><code>125002</code></error>' ;;
    list_fatal) echo '<error><code>108001</code></error>' ;;
    delete_retry_then_ok)
        case "$n" in
        1) echo '<error><code>125002</code></error>' ;;
        *) echo '<response>OK</response>' ;;
        esac ;;
    delete_always_retry) echo '<error><code>125003</code></error>' ;;
    esac
}
EOF
    extract fetch_pages
    extract send_delete
    cat <<'EOF'
if [ "$ACTION" = list ]; then
    fetch_pages page_stub; rc=$?
else
    send_delete 7; rc=$?
fi
CALLS=$(wc -l < "$CALL_FILE" | tr -d ' ')
echo "rc=$rc CALLS=$CALLS REFRESH=$REFRESH SLEEPS=$SLEEPS MSG_TOTAL=$MSG_TOTAL"
EOF
} > "$TMP/harness.sh"

run() {
    local mode=$1 action=$2 want=$3
    local got call_file=$TMP/calls
    : > "$call_file"
    got=$(bash "$TMP/harness.sh" "$mode" "$action" "$call_file")
    [ "$got" = "$want" ] \
        || { echo "FAIL: $mode/$action"; echo "  want: $want"; echo "  got:  $got"; exit 1; }
}

run list_retry_then_ok list  'rc=0 CALLS=3 REFRESH=2 SLEEPS=2 MSG_TOTAL=1'
run list_always_retry list  'rc=1 CALLS=3 REFRESH=2 SLEEPS=2 MSG_TOTAL=0'
run list_fatal        list  'rc=1 CALLS=1 REFRESH=0 SLEEPS=0 MSG_TOTAL=0'
run delete_retry_then_ok delete 'rc=0 CALLS=2 REFRESH=2 SLEEPS=1 MSG_TOTAL=0'
run delete_always_retry delete 'rc=1 CALLS=3 REFRESH=3 SLEEPS=2 MSG_TOTAL=0'

echo "SMS retry: 125002/125003 refreshed session and retried"
