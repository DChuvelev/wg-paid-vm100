#!/bin/sh
set -u
umask 077
export PATH='/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin'

CONFIG="${ROUTER_WGPAY_DIRECT_CONFIG:-/etc/router-wgpay-slot-topology.conf}"
[ -r "$CONFIG" ] || { echo RESULT=STOP_DIRECT_CONFIG_MISSING; exit 70; }
. "$CONFIG"

POLICY_ENABLED="${ROUTER_WGPAY_DIRECT_POLICY_ENABLED:-${TOPOLOGY_DIRECT_POLICY_ENABLED:-0}}"
STATE_DIR="${ROUTER_WGPAY_DIRECT_STATE_DIR:-${TOPOLOGY_DIRECT_STATE_DIR:-/var/lib/router-wgpay-direct-mode}}"
STATE_FILE="${ROUTER_WGPAY_DIRECT_STATE_FILE:-${TOPOLOGY_DIRECT_STATE_FILE:-${STATE_DIR}/state.kv}}"
LOCK_FILE="${ROUTER_WGPAY_DIRECT_LOCK_FILE:-${TOPOLOGY_DIRECT_LOCK_FILE:-/var/run/router-wgpay-direct-mode.lock}}"
NFT_BIN="${ROUTER_WGPAY_DIRECT_NFT_BIN:-nft}"
NFT_FAMILY="${ROUTER_WGPAY_DIRECT_NFT_FAMILY:-${TOPOLOGY_DIRECT_NFT_FAMILY:-inet}}"
NFT_TABLE="${ROUTER_WGPAY_DIRECT_NFT_TABLE:-${TOPOLOGY_DIRECT_NFT_TABLE:-fw4}}"
VPN_SET="${ROUTER_WGPAY_DIRECT_VPN_SOURCE_SET:-${TOPOLOGY_DIRECT_VPN_SOURCE_SET:-pbr_transit_vpn_4_src_ip_user}}"
PAID_CIDR="${ROUTER_WGPAY_DIRECT_PAID_SOURCE_CIDR:-${TOPOLOGY_DIRECT_PAID_SOURCE_CIDR:-10.253.0.0/16}}"
NOW="${ROUTER_WGPAY_DIRECT_NOW_EPOCH:-$(date +%s)}"
SCHEMA=router-wgpay-direct-mode-state-v1

mode="${1:---status}"
reason="${2:-manual}"
source_generation="${3:-unknown}"
topology_generation="${4:-unknown}"
case "$mode" in --request|--enable|--disable|--status) ;; *) echo 'Usage: router-wgpay-direct-mode.sh --request DIRECT_REQUIRED [source_generation] [topology_generation] | --enable [reason] | --disable [reason] | --status' >&2; exit 64;; esac

if [ "$mode" = --status ]; then
    if [ -f "$STATE_FILE" ]; then cat "$STATE_FILE"; else echo schema="$SCHEMA"; echo initialized=false; echo policy_enabled="$POLICY_ENABLED"; fi
    exit 0
fi

if [ "$mode" = --request ]; then
    [ "$reason" = DIRECT_REQUIRED ] || { echo RESULT=STOP_DIRECT_REQUEST_INVALID; exit 64; }
    if [ "$POLICY_ENABLED" != 1 ]; then
        echo RESULT=NOOP_DIRECT_POLICY_DISABLED
        echo DIRECT_POLICY_ENABLED=false
        echo DIRECT_MODE_CHANGED=false
        exit 0
    fi
    mode=--enable
fi

mkdir -p "$STATE_DIR" "$(dirname "$LOCK_FILE")" || exit 70
chmod 700 "$STATE_DIR" 2>/dev/null || true
exec 9>"$LOCK_FILE"
flock -n 9 || { echo RESULT=NOOP_DIRECT_MODE_LOCKED; exit 75; }

atomic_write() { src="$1" dst="$2"; cp "$src" "$dst.tmp.$$" && chmod 600 "$dst.tmp.$$" && mv "$dst.tmp.$$" "$dst"; }
set_dump() { "$NFT_BIN" list set "$NFT_FAMILY" "$NFT_TABLE" "$VPN_SET" 2>/dev/null; }
set_contains_paid() { set_dump | grep -Fq "$PAID_CIDR"; }
write_state() {
    active="$1"; state_mode="$2"; result="$3"
    tmp="$STATE_DIR/state.$$"
    {
        echo schema="$SCHEMA"
        echo active="$active"
        echo mode="$state_mode"
        echo updated_epoch="$NOW"
        echo reason="$reason"
        echo source_vm101_generation="$source_generation"
        echo topology_generation="$topology_generation"
        echo paid_source_cidr="$PAID_CIDR"
        echo vpn_source_set="$VPN_SET"
        echo last_result="$result"
    } > "$tmp" || return 1
    atomic_write "$tmp" "$STATE_FILE" || return 1
    rm -f "$tmp"
}

set_dump >/dev/null 2>&1 || { echo RESULT=STOP_DIRECT_VPN_SOURCE_SET_MISSING; echo VPN_SOURCE_SET="$VPN_SET"; exit 70; }

if [ "$mode" = --enable ]; then
    if ! set_contains_paid; then
        write_state true DIRECT NOOP_ALREADY_DIRECT || exit 70
        echo RESULT=NOOP_DIRECT_ALREADY_ACTIVE
        echo DIRECT_MODE_ACTIVE=true
        echo DIRECT_MODE_CHANGED=false
        exit 0
    fi
    printf 'delete element %s %s %s { %s }\n' "$NFT_FAMILY" "$NFT_TABLE" "$VPN_SET" "$PAID_CIDR" | "$NFT_BIN" -f - || { echo RESULT=STOP_DIRECT_NFT_ENABLE_FAILED; exit 71; }
    ! set_contains_paid || { echo RESULT=STOP_DIRECT_NFT_ENABLE_VERIFY; exit 72; }
    write_state true DIRECT PASS_DIRECT_ENABLED || exit 70
    echo RESULT=PASS_DIRECT_MODE_ENABLED
    echo DIRECT_MODE_ACTIVE=true
    echo DIRECT_MODE_CHANGED=true
    exit 0
fi

if set_contains_paid; then
    write_state false NORMAL NOOP_ALREADY_NORMAL || exit 70
    echo RESULT=NOOP_DIRECT_ALREADY_DISABLED
    echo DIRECT_MODE_ACTIVE=false
    echo DIRECT_MODE_CHANGED=false
    exit 0
fi
printf 'add element %s %s %s { %s }\n' "$NFT_FAMILY" "$NFT_TABLE" "$VPN_SET" "$PAID_CIDR" | "$NFT_BIN" -f - || { echo RESULT=STOP_DIRECT_NFT_DISABLE_FAILED; exit 71; }
set_contains_paid || { echo RESULT=STOP_DIRECT_NFT_DISABLE_VERIFY; exit 72; }
write_state false NORMAL PASS_DIRECT_DISABLED || exit 70
echo RESULT=PASS_DIRECT_MODE_DISABLED
echo DIRECT_MODE_ACTIVE=false
echo DIRECT_MODE_CHANGED=true
