#!/bin/sh
set -u
umask 077
export PATH='/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin'

CONFIG="${ROUTER_WGPAY_FORCED_CONFIG:-/etc/router-wgpay-forced-egress.conf}"
[ -r "$CONFIG" ] || { echo RESULT=STOP_FORCED_EGRESS; echo STOP_REASON=config_missing; exit 70; }
. "$CONFIG"

STATE_DIR="${ROUTER_WGPAY_FORCED_STATE_DIR:-${FORCED_EGRESS_STATE_DIR:-/var/lib/router-wgpay-forced-egress}}"
STATE_FILE="${ROUTER_WGPAY_FORCED_STATE_FILE:-${FORCED_EGRESS_STATE_FILE:-$STATE_DIR/overrides.tsv}}"
LOCK_FILE="${ROUTER_WGPAY_FORCED_LOCK_FILE:-${FORCED_EGRESS_LOCK_FILE:-/var/run/router-wgpay-forced-egress.lock}}"
REGISTRY_FILE="${ROUTER_WGPAY_FORCED_REGISTRY_FILE:-${FORCED_EGRESS_REGISTRY_FILE:-/etc/router-wgpay-peer-state/registry.tsv}}"
NFT_BIN="${ROUTER_WGPAY_FORCED_NFT_BIN:-nft}"
NFT_FAMILY="${ROUTER_WGPAY_FORCED_NFT_FAMILY:-${FORCED_EGRESS_NFT_FAMILY:-inet}}"
NFT_TABLE="${ROUTER_WGPAY_FORCED_NFT_TABLE:-${FORCED_EGRESS_NFT_TABLE:-wgpay_forced_egress}}"
PBR_FAMILY="${ROUTER_WGPAY_FORCED_PBR_FAMILY:-${FORCED_EGRESS_PBR_FAMILY:-inet}}"
PBR_TABLE="${ROUTER_WGPAY_FORCED_PBR_TABLE:-${FORCED_EGRESS_PBR_TABLE:-fw4}}"
PBR_CHAIN="${ROUTER_WGPAY_FORCED_PBR_CHAIN:-${FORCED_EGRESS_PBR_CHAIN:-pbr_prerouting}}"
PBR_VPN_CHAIN="${ROUTER_WGPAY_FORCED_PBR_VPN_CHAIN:-${FORCED_EGRESS_PBR_VPN_CHAIN:-pbr_mark_0x020000}}"
PBR_SET="${ROUTER_WGPAY_FORCED_PBR_SET:-${FORCED_EGRESS_PBR_SET:-wgpay_forced_vpn_4_src_ip}}"
TTL_SECONDS="${ROUTER_WGPAY_FORCED_TTL_SECONDS:-${FORCED_EGRESS_TTL_SECONDS:-1800}}"
NOW="${ROUTER_WGPAY_FORCED_NOW_EPOCH:-$(date +%s)}"
STATE_SCHEMA=router-wgpay-forced-egress-state-v1
RULE_COMMENT=WGPAY_FORCED_NO_DIRECT

mode="${1:---status}"
case "$mode" in --set|--set-until|--clear|--reconcile|--status|--teardown-runtime) ;; *)
  echo 'Usage: router-wgpay-forced-egress.sh --set OVERRIDE_ID {cs1..cs5} TUNNEL_IP... | --set-until OVERRIDE_ID {cs1..cs5} EXPIRES_EPOCH TUNNEL_IP... | --clear OVERRIDE_ID | --reconcile | --status | --teardown-runtime' >&2
  exit 64
;; esac

valid_id(){ printf '%s' "$1" | grep -Eq '^[A-Za-z0-9][A-Za-z0-9_.:-]{0,79}$'; }
valid_selector(){ case "$1" in cs1|cs2|cs3|cs4|cs5) return 0;; *) return 1;; esac; }
valid_ipv4(){ printf '%s\n' "$1" | awk -F. 'NF!=4{exit 1}{for(i=1;i<=4;i++) if($i!~/^[0-9]+$/ || $i<0 || $i>255) exit 1}'; }
valid_epoch(){ printf '%s' "$1" | grep -Eq '^[0-9]{1,20}$'; }
MAX_FUTURE_SKEW_SECONDS=30
state_header(){ printf '%s\n' '# schema=router-wgpay-forced-egress-state-v1' '# columns=override_id selector expires_epoch tunnel_ip'; }
atomic_write(){ src="$1" dst="$2"; cp "$src" "$dst.tmp.$$" && chmod 600 "$dst.tmp.$$" && mv "$dst.tmp.$$" "$dst"; }
stop(){ echo RESULT=STOP_FORCED_EGRESS; echo "STOP_REASON=$1"; exit "${2:-70}"; }

state_validate(){
  file="$1"
  [ -s "$file" ] || return 41
  grep -Fqx '# schema=router-wgpay-forced-egress-state-v1' "$file" || return 42
  grep -Fqx '# columns=override_id selector expires_epoch tunnel_ip' "$file" || return 43
  awk -F '\t' '
    function validip(ip,a,i){if(ip!~/^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/)return 0;split(ip,a,".");for(i=1;i<=4;i++)if(a[i]<0||a[i]>255)return 0;return 1}
    /^#/{next}
    NF!=4{exit 51}
    $1!~/^[A-Za-z0-9][A-Za-z0-9_.:-]{0,79}$/{exit 52}
    $2!~/^cs[1-5]$/{exit 53}
    $3!~/^[0-9]{1,20}$/{exit 54}
    !validip($4){exit 55}
    seen_ip[$4]++{exit 56}
    {key=$1 SUBSEP $2 SUBSEP $3; groups[key]++}
  ' "$file"
}

state_init(){
  mkdir -p "$STATE_DIR" "$(dirname "$LOCK_FILE")" || stop state_dir_create_failed 70
  chmod 700 "$STATE_DIR" 2>/dev/null || true
  if [ ! -f "$STATE_FILE" ]; then tmp="$STATE_DIR/state.init.$$"; state_header > "$tmp"; atomic_write "$tmp" "$STATE_FILE" || stop state_init_write_failed 70; rm -f "$tmp"; fi
  state_validate "$STATE_FILE" || stop state_invalid 71
}

lock(){ exec 9>"$LOCK_FILE"; flock -n 9 || { echo RESULT=NOOP_FORCED_EGRESS_LOCKED; exit 75; }; }

registry_identity_for_ip(){
  ip="$1"
  [ -s "$REGISTRY_FILE" ] || return 1
  grep -Fqx '# schema=router-wgpay-peer-registry-v1' "$REGISTRY_FILE" || return 1
  grep -Fqx '# columns=profile_id protocol interface public_key tunnel_ip normal_selector active_selector desired_generation created_epoch updated_epoch' "$REGISTRY_FILE" || return 1
  awk -F '\t' -v ip="$ip" '
    $0!~/^#/ && $5==ip {n++; protocol=$2; iface=$3}
    END {if(n!=1) exit 1; printf "%s\t%s\n", protocol, iface}
  ' "$REGISTRY_FILE"
}

validate_tunnel_ip(){
  ip="$1"
  valid_ipv4 "$ip" || return 1
  identity="$(registry_identity_for_ip "$ip")" || return 1
  protocol="$(printf '%s\n' "$identity" | awk -F '\t' '{print $1}')"
  iface="$(printf '%s\n' "$identity" | awk -F '\t' '{print $2}')"
  case "$protocol:$iface" in wireguard:wg_paid|amneziawg:awg_paid) return 0;; *) return 1;; esac
}

prune_state_to(){
  out="$1"
  { state_header; awk -F '\t' -v now="$NOW" 'BEGIN{OFS="\t"} $0!~/^#/ && $3>now {print $1,$2,$3,$4}' "$STATE_FILE"; } > "$out"
  state_validate "$out" || stop pruned_state_invalid 71
}

active_count(){ awk -F '\t' -v now="$NOW" '$0!~/^#/ && $3>now{n++} END{print n+0}' "$STATE_FILE"; }
override_count(){ awk -F '\t' -v now="$NOW" '$0!~/^#/ && $3>now{seen[$1]=1} END{for(k in seen)n++;print n+0}' "$STATE_FILE"; }

ensure_overlay_table(){
  "$NFT_BIN" delete table "$NFT_FAMILY" "$NFT_TABLE" >/dev/null 2>&1 || true
  "$NFT_BIN" add table "$NFT_FAMILY" "$NFT_TABLE" || return 1
  for cls in cs1 cs2 cs3 cs4 cs5; do
    "$NFT_BIN" add set "$NFT_FAMILY" "$NFT_TABLE" "forced_$cls" '{ type ipv4_addr; flags timeout; }' || return 1
  done
  "$NFT_BIN" add chain "$NFT_FAMILY" "$NFT_TABLE" prerouting '{ type filter hook prerouting priority -149; policy accept; }' || return 1
  for cls in cs1 cs2 cs3 cs4 cs5; do
    "$NFT_BIN" add rule "$NFT_FAMILY" "$NFT_TABLE" prerouting ip saddr "@forced_$cls" ip dscp set "$cls" counter comment "WGPAY_FORCED_${cls}" || return 1
  done
}

pbr_rule_handles(){
  "$NFT_BIN" -a list chain "$PBR_FAMILY" "$PBR_TABLE" "$PBR_CHAIN" 2>/dev/null | awk -v c="$RULE_COMMENT" 'index($0,"comment \"" c "\""){for(i=1;i<=NF;i++) if($i=="handle") print $(i+1)}'
}

ensure_pbr_overlay(){
  "$NFT_BIN" list chain "$PBR_FAMILY" "$PBR_TABLE" "$PBR_CHAIN" >/dev/null 2>&1 || return 1
  "$NFT_BIN" list chain "$PBR_FAMILY" "$PBR_TABLE" "$PBR_VPN_CHAIN" >/dev/null 2>&1 || return 1
  "$NFT_BIN" list set "$PBR_FAMILY" "$PBR_TABLE" "$PBR_SET" >/dev/null 2>&1 || \
    "$NFT_BIN" add set "$PBR_FAMILY" "$PBR_TABLE" "$PBR_SET" '{ type ipv4_addr; flags timeout; }' || return 1
  handles="$(pbr_rule_handles)"
  count="$(printf '%s\n' "$handles" | awk 'NF{n++} END{print n+0}')"
  [ "$count" -le 1 ] || return 1
  if [ "$count" -eq 0 ]; then
    "$NFT_BIN" insert rule "$PBR_FAMILY" "$PBR_TABLE" "$PBR_CHAIN" ip saddr "@$PBR_SET" goto "$PBR_VPN_CHAIN" comment "$RULE_COMMENT" || return 1
  fi
  "$NFT_BIN" flush set "$PBR_FAMILY" "$PBR_TABLE" "$PBR_SET" || return 1
}

populate_runtime(){
  awk -F '\t' -v now="$NOW" '$0!~/^#/ && $3>now {print $1 "\t" $2 "\t" $3 "\t" $4}' "$STATE_FILE" |
  while IFS="$(printf '\t')" read -r override selector expires ip; do
    [ -n "$ip" ] || continue
    remain=$((expires - NOW)); [ "$remain" -gt 0 ] || continue
    "$NFT_BIN" add element "$NFT_FAMILY" "$NFT_TABLE" "forced_$selector" "{ $ip timeout ${remain}s }" || exit 1
    "$NFT_BIN" add element "$PBR_FAMILY" "$PBR_TABLE" "$PBR_SET" "{ $ip timeout ${remain}s }" || exit 1
  done
}

reconcile_runtime(){
  tmp="$STATE_DIR/state.pruned.$$"
  prune_state_to "$tmp"
  if ! cmp -s "$tmp" "$STATE_FILE"; then atomic_write "$tmp" "$STATE_FILE" || { rm -f "$tmp"; return 1; }; fi
  rm -f "$tmp"
  ensure_overlay_table || return 1
  ensure_pbr_overlay || return 1
  populate_runtime || return 1
}

teardown_runtime(){
  "$NFT_BIN" delete table "$NFT_FAMILY" "$NFT_TABLE" >/dev/null 2>&1 || true
  handles="$(pbr_rule_handles 2>/dev/null || true)"
  printf '%s\n' "$handles" | awk 'NF' | while IFS= read -r handle; do "$NFT_BIN" delete rule "$PBR_FAMILY" "$PBR_TABLE" "$PBR_CHAIN" handle "$handle" >/dev/null 2>&1 || exit 1; done
  "$NFT_BIN" flush set "$PBR_FAMILY" "$PBR_TABLE" "$PBR_SET" >/dev/null 2>&1 || true
  "$NFT_BIN" delete set "$PBR_FAMILY" "$PBR_TABLE" "$PBR_SET" >/dev/null 2>&1 || true
}

if [ "$mode" = --status ]; then
  if [ ! -f "$STATE_FILE" ]; then echo schema="$STATE_SCHEMA"; echo initialized=false; echo active_override_count=0; echo active_tunnel_ip_count=0; echo RESULT=PASS_FORCED_EGRESS_STATUS; exit 0; fi
  state_validate "$STATE_FILE" || stop state_invalid 71
  echo schema="$STATE_SCHEMA"
  echo initialized=true
  echo now_epoch="$NOW"
  echo ttl_seconds="$TTL_SECONDS"
  echo active_override_count="$(override_count)"
  echo active_tunnel_ip_count="$(active_count)"
  awk -F '\t' -v now="$NOW" 'BEGIN{OFS="\t"} $0!~/^#/ && $3>now {print "override",$1,$2,$3,$4}' "$STATE_FILE"
  echo RESULT=PASS_FORCED_EGRESS_STATUS
  exit 0
fi

state_init
lock

case "$mode" in
  --reconcile)
    reconcile_runtime || stop runtime_reconcile_failed 72
    echo active_override_count="$(override_count)"
    echo active_tunnel_ip_count="$(active_count)"
    echo RESULT=PASS_FORCED_EGRESS_RECONCILED
    ;;
  --set|--set-until)
    override="${2:-}"; selector="${3:-}"
    valid_id "$override" || stop override_id_invalid 64
    valid_selector "$selector" || stop selector_invalid 64
    [ "$TTL_SECONDS" = 1800 ] || stop ttl_contract_mismatch 70
    if [ "$mode" = --set-until ]; then
      expires="${4:-}"; shift 4 || true
      valid_epoch "$expires" || stop expires_epoch_invalid 64
      [ "$expires" -gt "$NOW" ] || stop expires_epoch_not_future 64
      max_expires=$((NOW + TTL_SECONDS + MAX_FUTURE_SKEW_SECONDS))
      [ "$expires" -le "$max_expires" ] || stop expires_epoch_exceeds_ttl_window 64
    else
      shift 3 || true
      expires=$((NOW + TTL_SECONDS))
    fi
    [ "$#" -ge 1 ] || stop tunnel_ip_list_empty 64
    work="$STATE_DIR/state.set.$$"
    prune_state_to "$work.base"
    { state_header; awk -F '\t' -v id="$override" 'BEGIN{OFS="\t"} $0!~/^#/ && $1!=id {print $1,$2,$3,$4}' "$work.base"; } > "$work"
    rm -f "$work.base"
    for ip in "$@"; do
      validate_tunnel_ip "$ip" || { rm -f "$work"; stop tunnel_ip_not_active_paid_peer 64; }
      awk -F '\t' -v ip="$ip" '$0!~/^#/ && $4==ip{found=1} END{exit found?0:1}' "$work" && { rm -f "$work"; stop tunnel_ip_owned_by_other_override 66; }
      printf '%s\t%s\t%s\t%s\n' "$override" "$selector" "$expires" "$ip" >> "$work"
    done
    state_validate "$work" || { rm -f "$work"; stop candidate_state_invalid 71; }
    atomic_write "$work" "$STATE_FILE" || { rm -f "$work"; stop state_write_failed 73; }
    rm -f "$work"
    reconcile_runtime || stop runtime_reconcile_failed_after_set 74
    echo OVERRIDE_ID="$override"
    echo SELECTOR="$selector"
    echo EXPIRES_EPOCH="$expires"
    echo TTL_SECONDS="$TTL_SECONDS"
    echo REMAINING_SECONDS=$((expires - NOW))
    echo TUNNEL_IP_COUNT="$#"
    if [ "$mode" = --set-until ]; then echo RESULT=PASS_FORCED_EGRESS_SET_UNTIL; else echo RESULT=PASS_FORCED_EGRESS_SET; fi
    ;;
  --clear)
    override="${2:-}"
    valid_id "$override" || stop override_id_invalid 64
    work="$STATE_DIR/state.clear.$$"
    prune_state_to "$work.base"
    before="$(awk -F '\t' -v id="$override" '$0!~/^#/ && $1==id{n++} END{print n+0}' "$work.base")"
    { state_header; awk -F '\t' -v id="$override" 'BEGIN{OFS="\t"} $0!~/^#/ && $1!=id {print $1,$2,$3,$4}' "$work.base"; } > "$work"
    rm -f "$work.base"
    state_validate "$work" || { rm -f "$work"; stop candidate_state_invalid 71; }
    atomic_write "$work" "$STATE_FILE" || { rm -f "$work"; stop state_write_failed 73; }
    rm -f "$work"
    reconcile_runtime || stop runtime_reconcile_failed_after_clear 74
    echo OVERRIDE_ID="$override"
    echo CLEARED_TUNNEL_IP_COUNT="$before"
    if [ "$before" -eq 0 ]; then echo RESULT=NOOP_FORCED_EGRESS_ALREADY_AUTOMATIC; else echo RESULT=PASS_FORCED_EGRESS_CLEARED; fi
    ;;
  --teardown-runtime)
    [ "$(active_count)" -eq 0 ] || stop active_overrides_present_teardown_refused 76
    teardown_runtime || stop runtime_teardown_failed 74
    echo RESULT=PASS_FORCED_EGRESS_RUNTIME_TORN_DOWN
    ;;
esac
