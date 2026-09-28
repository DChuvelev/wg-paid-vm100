#!/bin/sh
set -u
umask 077
export PATH='/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin'

INPUT_SCHEMA='router-wgpay-exit-catalog-v1'
ACK_SCHEMA='router-wgpay-exit-catalog-ack-v1'
STATE_DIR="${ROUTER_EXIT_CATALOG_STATE_DIR:-/var/lib/router-wgpay-exit-catalog}"
STATE_FILE="${ROUTER_EXIT_CATALOG_STATE_FILE:-${STATE_DIR}/current.kv}"
LOCK_FILE="${ROUTER_EXIT_CATALOG_LOCK_FILE:-/var/run/router-wgpay-exit-catalog.lock}"
MAX_BYTES="${ROUTER_EXIT_CATALOG_MAX_BYTES:-2048}"

reject() {
    reason="$1"
    detail="${2:-none}"
    rc="${3:-65}"
    printf '%s\n' \
        "schema=$ACK_SCHEMA" \
        'result=REJECTED' \
        "reason=$reason" \
        "detail=$detail"
    exit "$rc"
}

case "${1:---stdin}" in
    --stdin) ;;
    *) reject invalid_mode mode 64 ;;
esac
case "$MAX_BYTES" in ''|*[!0-9]*) reject invalid_max_bytes config 70 ;; esac
[ "$MAX_BYTES" -ge 256 ] && [ "$MAX_BYTES" -le 16384 ] || reject invalid_max_bytes_range config 70

TMP_ROOT="${TMPDIR:-/tmp}/router-wgpay-exit-catalog.$$"
RAW="$TMP_ROOT/input.kv"
BODY="$TMP_ROOT/body.kv"
CAND="$TMP_ROOT/current.kv"
cleanup() { rc="$?"; trap - EXIT HUP INT TERM; rm -rf "$TMP_ROOT"; exit "$rc"; }
trap cleanup EXIT HUP INT TERM
mkdir -p "$TMP_ROOT" "$STATE_DIR" "$(dirname "$LOCK_FILE")" || reject state_dir_create_failed local 70
chmod 700 "$STATE_DIR" 2>/dev/null || true
exec 9>"$LOCK_FILE"
flock -n 9 || reject catalog_locked local 75

dd bs=$((MAX_BYTES + 1)) count=1 of="$RAW" 2>/dev/null
bytes="$(wc -c < "$RAW" | tr -d ' ')"
[ "$bytes" -gt 0 ] || reject empty_input none 65
[ "$bytes" -le "$MAX_BYTES" ] || reject input_too_large "$bytes" 65
[ "$(wc -l < "$RAW" | tr -d ' ')" -eq 9 ] || reject line_count_invalid count 65
LC_ALL=C grep -q '[[:cntrl:]]' "$RAW" && reject control_character_forbidden input 65

schema="$(sed -n '1s/^schema=//p' "$RAW")"
source_generation="$(sed -n '2s/^source_generation=//p' "$RAW")"
generated_epoch="$(sed -n '3s/^generated_epoch=//p' "$RAW")"
selector1="$(sed -n '4s/^selector1=//p' "$RAW")"
selector2="$(sed -n '5s/^selector2=//p' "$RAW")"
selector3="$(sed -n '6s/^selector3=//p' "$RAW")"
selector4="$(sed -n '7s/^selector4=//p' "$RAW")"
selector5="$(sed -n '8s/^selector5=//p' "$RAW")"
confirm="$(sed -n '9s/^confirm_sha256=//p' "$RAW")"

[ "$schema" = "$INPUT_SCHEMA" ] || reject schema_invalid schema 65
printf '%s' "$source_generation" | grep -Eq '^[A-Za-z0-9_.:-]{1,128}$' || reject source_generation_invalid source_generation 65
printf '%s' "$generated_epoch" | grep -Eq '^[0-9]{1,12}$' || reject generated_epoch_invalid generated_epoch 65
for value in "$selector1" "$selector2" "$selector3" "$selector4" "$selector5"; do
    [ "${#value}" -ge 1 ] && [ "${#value}" -le 96 ] || reject display_name_length_invalid display_name 65
    printf '%s\n' "$value" | LC_ALL=C grep -Eq "^[A-Za-z0-9][A-Za-z0-9 .,'&()/_-]*$" || reject display_name_invalid display_name 65
done
printf '%s' "$confirm" | grep -Eq '^[0-9a-f]{64}$' || reject confirm_invalid confirm_sha256 65

sed '$d' "$RAW" > "$BODY" || reject body_extract_failed local 70
actual="$(sha256sum "$BODY" | awk '{print $1}')"
[ "$actual" = "$confirm" ] || reject confirm_mismatch payload 65

cat "$BODY" > "$CAND"
printf 'confirm_sha256=%s\n' "$confirm" >> "$CAND"
TMP_STATE="${STATE_FILE}.tmp.$$"
cp "$CAND" "$TMP_STATE" || reject state_copy_failed local 70
chmod 600 "$TMP_STATE" || { rm -f "$TMP_STATE"; reject state_chmod_failed local 70; }
mv "$TMP_STATE" "$STATE_FILE" || { rm -f "$TMP_STATE"; reject state_commit_failed local 70; }

printf '%s\n' \
    "schema=$ACK_SCHEMA" \
    'result=PASS' \
    "source_generation=$source_generation" \
    "generated_epoch=$generated_epoch" \
    "payload_sha256=$confirm"
