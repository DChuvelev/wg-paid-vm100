#!/bin/sh
set -u
umask 077
export PATH='/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin'

STATE_DIR="${ROUTER_WGPAY_REVIEW_DIRECT_STATE_DIR:-/var/lib/router-wgpay-review-direct}"
STATE_FILE="${ROUTER_WGPAY_REVIEW_DIRECT_STATE_FILE:-$STATE_DIR/state.tsv}"
LOCK_FILE="${ROUTER_WGPAY_REVIEW_DIRECT_LOCK_FILE:-/var/run/router-wgpay-review-direct.lock}"
REGISTRY_FILE="${ROUTER_WGPAY_REVIEW_DIRECT_REGISTRY_FILE:-/etc/router-wgpay-peer-state/registry.tsv}"
NFT_BIN="${ROUTER_WGPAY_REVIEW_DIRECT_NFT_BIN:-nft}"
PBR_FAMILY="${ROUTER_WGPAY_REVIEW_DIRECT_PBR_FAMILY:-inet}"
PBR_TABLE="${ROUTER_WGPAY_REVIEW_DIRECT_PBR_TABLE:-fw4}"
PBR_CHAIN="${ROUTER_WGPAY_REVIEW_DIRECT_PBR_CHAIN:-pbr_prerouting}"
PBR_DIRECT_CHAIN="${ROUTER_WGPAY_REVIEW_DIRECT_PBR_DIRECT_CHAIN:-pbr_mark_0x010000}"
PBR_SET="${ROUTER_WGPAY_REVIEW_DIRECT_PBR_SET:-wgpay_review_direct_4_src_ip}"
INTERNAL_CIDR="${ROUTER_WGPAY_REVIEW_DIRECT_INTERNAL_CIDR:-10.71.100.0/24}"
RULE_COMMENT='WGPAY_REVIEW_DIRECT'
STATE_SCHEMA='router-wgpay-review-direct-state-v1'

mode="${1:---status}"
case "$mode" in --add|--remove|--clear|--reconcile|--status|--teardown-runtime) ;; *)
    echo 'Usage: router-wgpay-review-direct.sh --add TUNNEL_IP... | --remove TUNNEL_IP... | --clear | --reconcile | --status | --teardown-runtime' >&2
    exit 64
;; esac

state_header(){ printf '%s\n' '# schema=router-wgpay-review-direct-state-v1' '# columns=tunnel_ip'; }
stop(){ echo RESULT=STOP_REVIEW_DIRECT; echo "STOP_REASON=$1"; exit "${2:-70}"; }
valid_ipv4(){ printf '%s\n' "$1" | awk -F. 'NF!=4{exit 1}{for(i=1;i<=4;i++) if($i!~/^[0-9]+$/ || $i<0 || $i>255) exit 1}'; }
valid_paid_ip(){ valid_ipv4 "$1" || return 1; case "$1" in 10.253.*|10.254.*) return 0;; *) return 1;; esac; }
state_validate(){
    file="$1"; [ -s "$file" ] || return 41
    grep -Fqx '# schema=router-wgpay-review-direct-state-v1' "$file" || return 42
    grep -Fqx '# columns=tunnel_ip' "$file" || return 43
    awk '
      function validip(ip,a,i){if(ip!~/^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/)return 0;split(ip,a,".");for(i=1;i<=4;i++)if(a[i]<0||a[i]>255)return 0;return(a[1]==10&&(a[2]==253||a[2]==254))}
      /^#/{next} NF!=1{exit 51} !validip($1){exit 52} seen[$1]++{exit 53}
    ' "$file"
}
atomic_write(){ src="$1" dst="$2"; cp "$src" "$dst.tmp.$$" && chmod 600 "$dst.tmp.$$" && mv "$dst.tmp.$$" "$dst"; }
state_init(){
    mkdir -p "$STATE_DIR" "$(dirname "$LOCK_FILE")" || stop state_dir_create_failed
    chmod 700 "$STATE_DIR" 2>/dev/null || true
    if [ ! -f "$STATE_FILE" ]; then tmp="$STATE_DIR/state.init.$$"; state_header > "$tmp" || stop state_init_failed; atomic_write "$tmp" "$STATE_FILE" || { rm -f "$tmp"; stop state_init_failed; }; rm -f "$tmp"; fi
    state_validate "$STATE_FILE" || stop state_invalid 71
}
lock(){ exec 9>"$LOCK_FILE"; flock -n 9 || { echo RESULT=NOOP_REVIEW_DIRECT_LOCKED; exit 75; }; }
registry_identity_for_ip(){
    ip="$1"; [ -s "$REGISTRY_FILE" ] || return 1
    grep -Fqx '# schema=router-wgpay-peer-registry-v1' "$REGISTRY_FILE" || return 1
    grep -Fqx '# columns=profile_id protocol interface public_key tunnel_ip normal_selector active_selector desired_generation created_epoch updated_epoch' "$REGISTRY_FILE" || return 1
    awk -F '\t' -v ip="$ip" '$0!~/^#/&&$5==ip{n++;protocol=$2;iface=$3} END{if(n!=1)exit 1;printf "%s\t%s\n",protocol,iface}' "$REGISTRY_FILE"
}
validate_active_paid_ip(){
    ip="$1"; valid_paid_ip "$ip" || return 1; identity="$(registry_identity_for_ip "$ip")" || return 1
    protocol="$(printf '%s\n' "$identity" | awk -F '\t' '{print $1}')"; iface="$(printf '%s\n' "$identity" | awk -F '\t' '{print $2}')"
    case "$protocol:$iface" in wireguard:wg_paid|amneziawg:awg_paid) return 0;; *) return 1;; esac
}
pbr_rule_handles(){
    "$NFT_BIN" -a list chain "$PBR_FAMILY" "$PBR_TABLE" "$PBR_CHAIN" 2>/dev/null | awk -v c="$RULE_COMMENT" 'index($0,"comment \"" c "\""){for(i=1;i<=NF;i++)if($i=="handle")print $(i+1)}'
}
ensure_runtime(){
    "$NFT_BIN" list chain "$PBR_FAMILY" "$PBR_TABLE" "$PBR_CHAIN" >/dev/null 2>&1 || return 1
    "$NFT_BIN" list chain "$PBR_FAMILY" "$PBR_TABLE" "$PBR_DIRECT_CHAIN" >/dev/null 2>&1 || return 1
    "$NFT_BIN" list set "$PBR_FAMILY" "$PBR_TABLE" "$PBR_SET" >/dev/null 2>&1 || "$NFT_BIN" add set "$PBR_FAMILY" "$PBR_TABLE" "$PBR_SET" '{ type ipv4_addr; }' || return 1
    handles="$(pbr_rule_handles)"; count="$(printf '%s\n' "$handles" | awk 'NF{n++} END{print n+0}')"; [ "$count" -le 1 ] || return 1
    if [ "$count" -eq 0 ]; then
        "$NFT_BIN" insert rule "$PBR_FAMILY" "$PBR_TABLE" "$PBR_CHAIN" ip saddr "@$PBR_SET" ip daddr '!=' "$INTERNAL_CIDR" counter goto "$PBR_DIRECT_CHAIN" comment "$RULE_COMMENT" || return 1
    fi
    "$NFT_BIN" flush set "$PBR_FAMILY" "$PBR_TABLE" "$PBR_SET" || return 1
    awk '$0!~/^#/{print $1}' "$STATE_FILE" | while IFS= read -r ip; do [ -n "$ip" ] || continue; "$NFT_BIN" add element "$PBR_FAMILY" "$PBR_TABLE" "$PBR_SET" "{ $ip }" || exit 1; done
}
state_count(){ awk '$0!~/^#/{n++} END{print n+0}' "$STATE_FILE"; }

if [ "$mode" = --status ]; then
    if [ ! -f "$STATE_FILE" ]; then echo schema="$STATE_SCHEMA"; echo initialized=false; echo tunnel_ip_count=0; echo RESULT=PASS_REVIEW_DIRECT_STATUS; exit 0; fi
    state_validate "$STATE_FILE" || stop state_invalid 71
    echo schema="$STATE_SCHEMA"; echo initialized=true; echo tunnel_ip_count="$(state_count)"; awk '$0!~/^#/{print "tunnel_ip=" $1}' "$STATE_FILE"
    echo RESULT=PASS_REVIEW_DIRECT_STATUS; exit 0
fi

state_init; lock
case "$mode" in
  --reconcile)
    ensure_runtime || stop runtime_reconcile_failed 72
    echo tunnel_ip_count="$(state_count)"; echo RESULT=PASS_REVIEW_DIRECT_RECONCILED
    ;;
  --add)
    shift; [ "$#" -ge 1 ] || stop tunnel_ip_list_empty 64
    for ip in "$@"; do validate_active_paid_ip "$ip" || stop tunnel_ip_not_active_paid_peer 64; done
    work="$STATE_DIR/state.add.$$"; cp "$STATE_FILE" "$work" || stop candidate_copy_failed
    for ip in "$@"; do awk -v ip="$ip" '$0!~/^#/&&$1==ip{found=1} END{exit found?0:1}' "$work" || printf '%s\n' "$ip" >> "$work"; done
    state_validate "$work" || { rm -f "$work"; stop candidate_state_invalid 71; }; atomic_write "$work" "$STATE_FILE" || { rm -f "$work"; stop state_write_failed 73; }; rm -f "$work"
    ensure_runtime || stop runtime_reconcile_failed_after_add 74
    echo tunnel_ip_count="$(state_count)"; echo RESULT=PASS_REVIEW_DIRECT_ADDED
    ;;
  --remove)
    shift; [ "$#" -ge 1 ] || stop tunnel_ip_list_empty 64
    for ip in "$@"; do valid_paid_ip "$ip" || stop tunnel_ip_invalid 64; done
    base="$STATE_DIR/state.remove.base.$$"; work="$STATE_DIR/state.remove.$$"; cp "$STATE_FILE" "$base" || stop candidate_copy_failed
    { state_header; awk -v remove_list="$*" 'BEGIN{n=split(remove_list,a," ");for(i=1;i<=n;i++)rm[a[i]]=1} $0!~/^#/&&!($1 in rm){print $1}' "$base"; } > "$work"; rm -f "$base"
    state_validate "$work" || { rm -f "$work"; stop candidate_state_invalid 71; }; atomic_write "$work" "$STATE_FILE" || { rm -f "$work"; stop state_write_failed 73; }; rm -f "$work"
    ensure_runtime || stop runtime_reconcile_failed_after_remove 74
    echo tunnel_ip_count="$(state_count)"; echo RESULT=PASS_REVIEW_DIRECT_REMOVED
    ;;
  --clear)
    work="$STATE_DIR/state.clear.$$"; state_header > "$work" || stop candidate_write_failed; atomic_write "$work" "$STATE_FILE" || { rm -f "$work"; stop state_write_failed 73; }; rm -f "$work"
    ensure_runtime || stop runtime_reconcile_failed_after_clear 74
    echo tunnel_ip_count=0; echo RESULT=PASS_REVIEW_DIRECT_CLEARED
    ;;
  --teardown-runtime)
    [ "$(state_count)" -eq 0 ] || stop active_review_direct_members_present 76
    handles="$(pbr_rule_handles 2>/dev/null || true)"; printf '%s\n' "$handles" | awk 'NF' | while IFS= read -r handle; do "$NFT_BIN" delete rule "$PBR_FAMILY" "$PBR_TABLE" "$PBR_CHAIN" handle "$handle" >/dev/null 2>&1 || exit 1; done
    "$NFT_BIN" flush set "$PBR_FAMILY" "$PBR_TABLE" "$PBR_SET" >/dev/null 2>&1 || true
    "$NFT_BIN" delete set "$PBR_FAMILY" "$PBR_TABLE" "$PBR_SET" >/dev/null 2>&1 || true
    echo RESULT=PASS_REVIEW_DIRECT_RUNTIME_TORN_DOWN
    ;;
esac
