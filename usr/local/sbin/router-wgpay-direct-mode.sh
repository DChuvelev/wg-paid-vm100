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
LEGACY_PAID_CIDR="${ROUTER_WGPAY_DIRECT_PAID_SOURCE_CIDR:-${TOPOLOGY_DIRECT_PAID_SOURCE_CIDR:-10.253.0.0/16}}"
AWG_PAID_CIDR="${ROUTER_WGPAY_DIRECT_AWG_SOURCE_CIDR:-${TOPOLOGY_DIRECT_AWG_SOURCE_CIDR:-10.254.0.0/16}}"
PAID_CIDRS="${ROUTER_WGPAY_DIRECT_PAID_SOURCE_CIDRS:-${TOPOLOGY_DIRECT_PAID_SOURCE_CIDRS:-$LEGACY_PAID_CIDR $AWG_PAID_CIDR}}"
NOW="${ROUTER_WGPAY_DIRECT_NOW_EPOCH:-$(date +%s)}"
SCHEMA=router-wgpay-direct-mode-state-v1
TEST_FAULT="${ROUTER_WGPAY_DIRECT_TEST_FAULT:-}"

mode="${1:---status}"
reason="${2:-manual}"
source_generation="${3:-unknown}"
topology_generation="${4:-unknown}"
case "$mode" in --request|--enable|--disable|--probe|--status) ;; *) echo 'Usage: router-wgpay-direct-mode.sh --request DIRECT_REQUIRED [source_generation] [topology_generation] | --enable [reason] | --disable [reason] | --probe | --status' >&2; exit 64;; esac

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

set -- $PAID_CIDRS
[ "$#" -gt 0 ] || { echo RESULT=STOP_DIRECT_PAID_SOURCE_LIST_EMPTY; exit 70; }

mkdir -p "$STATE_DIR" "$(dirname "$LOCK_FILE")" || exit 70
chmod 700 "$STATE_DIR" 2>/dev/null || true
exec 9>"$LOCK_FILE"
flock -n 9 || { echo RESULT=NOOP_DIRECT_MODE_LOCKED; exit 75; }

atomic_write() { src="$1" dst="$2"; cp "$src" "$dst.tmp.$$" && chmod 600 "$dst.tmp.$$" && mv "$dst.tmp.$$" "$dst"; }
set_dump() { "$NFT_BIN" list set "$NFT_FAMILY" "$NFT_TABLE" "$VPN_SET" 2>/dev/null; }
set_contains_cidr() {
    cidr="$1"
    probe="${cidr%/*}"
    printf 'get element %s %s %s { %s }\n' "$NFT_FAMILY" "$NFT_TABLE" "$VPN_SET" "$probe" | "$NFT_BIN" -f - >/dev/null 2>&1
}
paid_total() { n=0; for cidr in $PAID_CIDRS; do n=$((n + 1)); done; echo "$n"; }
paid_present_count() { n=0; for cidr in $PAID_CIDRS; do set_contains_cidr "$cidr" && n=$((n + 1)); done; echo "$n"; }
snapshot_membership() { out=''; for cidr in $PAID_CIDRS; do if set_contains_cidr "$cidr"; then out="$out $cidr"; fi; done; echo "${out# }"; }
add_cidr() { cidr="$1"; printf 'add element %s %s %s { %s }\n' "$NFT_FAMILY" "$NFT_TABLE" "$VPN_SET" "$cidr" | "$NFT_BIN" -f -; }
delete_cidr() { cidr="$1"; printf 'delete element %s %s %s { %s }\n' "$NFT_FAMILY" "$NFT_TABLE" "$VPN_SET" "$cidr" | "$NFT_BIN" -f -; }
add_all_paid() { for cidr in $PAID_CIDRS; do set_contains_cidr "$cidr" || add_cidr "$cidr" || return 1; done; }
delete_all_paid() { for cidr in $PAID_CIDRS; do if set_contains_cidr "$cidr"; then delete_cidr "$cidr" || return 1; fi; done; }
restore_membership() {
    desired="$1"
    delete_all_paid >/dev/null 2>&1 || return 1
    for cidr in $desired; do add_cidr "$cidr" >/dev/null 2>&1 || return 1; done
}
write_state() {
    active="$1"; state_mode="$2"; result="$3"
    [ "$TEST_FAULT" != state_write ] || return 1
    tmp="$STATE_DIR/state.$$"
    {
        echo schema="$SCHEMA"
        echo active="$active"
        echo mode="$state_mode"
        echo updated_epoch="$NOW"
        echo reason="$reason"
        echo source_vm101_generation="$source_generation"
        echo topology_generation="$topology_generation"
        echo paid_source_cidr="$LEGACY_PAID_CIDR"
        echo paid_source_cidrs="$PAID_CIDRS"
        echo vpn_source_set="$VPN_SET"
        echo last_result="$result"
    } > "$tmp" || return 1
    atomic_write "$tmp" "$STATE_FILE" || return 1
    rm -f "$tmp"
}

set_dump >/dev/null 2>&1 || { echo RESULT=STOP_DIRECT_VPN_SOURCE_SET_MISSING; echo VPN_SOURCE_SET="$VPN_SET"; exit 70; }
TOTAL="$(paid_total)"
PRESENT="$(paid_present_count)"

if [ "$mode" = --probe ]; then
    if [ "$PRESENT" -eq "$TOTAL" ]; then
        probe_active=false
    elif [ "$PRESENT" -eq 0 ]; then
        probe_active=true
    else
        echo RESULT=STOP_DIRECT_PAID_SOURCE_SET_PARTIAL
        echo PAID_SOURCE_TOTAL="$TOTAL"
        echo PAID_SOURCE_PRESENT="$PRESENT"
        exit 72
    fi
    echo RESULT=PASS_DIRECT_MODE_PROBE
    echo DIRECT_MODE_ACTIVE="$probe_active"
    echo DIRECT_MODE_CHANGED=false
    echo PAID_SOURCE_CIDRS="$PAID_CIDRS"
    exit 0
fi

if [ "$mode" = --enable ]; then
    if [ "$PRESENT" -eq 0 ]; then
        write_state true DIRECT NOOP_ALREADY_DIRECT || exit 70
        echo RESULT=NOOP_DIRECT_ALREADY_ACTIVE
        echo DIRECT_MODE_ACTIVE=true
        echo DIRECT_MODE_CHANGED=false
        exit 0
    fi
    before_membership="$(snapshot_membership)"
    delete_all_paid || { echo RESULT=STOP_DIRECT_NFT_ENABLE_FAILED; exit 71; }
    [ "$(paid_present_count)" -eq 0 ] || { echo RESULT=STOP_DIRECT_NFT_ENABLE_VERIFY; exit 72; }
    if ! write_state true DIRECT PASS_DIRECT_ENABLED; then
        restore_membership "$before_membership" || { echo RESULT=STOP_DIRECT_ENABLE_STATE_ROLLBACK_FAILED; exit 74; }
        echo RESULT=STOP_DIRECT_STATE_WRITE_FAILED
        exit 73
    fi
    echo RESULT=PASS_DIRECT_MODE_ENABLED
    echo DIRECT_MODE_ACTIVE=true
    echo DIRECT_MODE_CHANGED=true
    exit 0
fi

if [ "$PRESENT" -eq "$TOTAL" ]; then
    write_state false NORMAL NOOP_ALREADY_NORMAL || exit 70
    echo RESULT=NOOP_DIRECT_ALREADY_DISABLED
    echo DIRECT_MODE_ACTIVE=false
    echo DIRECT_MODE_CHANGED=false
    exit 0
fi
before_membership="$(snapshot_membership)"
add_all_paid || { echo RESULT=STOP_DIRECT_NFT_DISABLE_FAILED; exit 71; }
[ "$(paid_present_count)" -eq "$TOTAL" ] || { echo RESULT=STOP_DIRECT_NFT_DISABLE_VERIFY; exit 72; }
if ! write_state false NORMAL PASS_DIRECT_DISABLED; then
    restore_membership "$before_membership" || { echo RESULT=STOP_DIRECT_DISABLE_STATE_ROLLBACK_FAILED; exit 74; }
    echo RESULT=STOP_DIRECT_STATE_WRITE_FAILED
    exit 73
fi
echo RESULT=PASS_DIRECT_MODE_DISABLED
echo DIRECT_MODE_ACTIVE=false
echo DIRECT_MODE_CHANGED=true
