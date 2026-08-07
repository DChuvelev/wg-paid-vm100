#!/bin/sh
# shellcheck shell=sh

peer_log() { printf '%s\n' "$*"; }
peer_stop() { peer_log "RESULT=STOP_PEER_LIFECYCLE"; peer_log "STOP_REASON=$1"; return "${2:-70}"; }
peer_kv_get() { key="$1" file="$2"; [ -f "$file" ] || return 0; awk -F= -v key="$key" '$1==key{print substr($0,index($0,"=")+1)}' "$file" | tail -n1; }
peer_atomic_write() { src="$1" dst="$2" mode="${3:-600}"; mkdir -p "$(dirname "$dst")" || return 1; cp "$src" "$dst.tmp.$$" || return 1; chmod "$mode" "$dst.tmp.$$" || return 1; mv "$dst.tmp.$$" "$dst"; }
peer_valid_id() { printf '%s' "$1" | grep -Eq '^[A-Za-z0-9][A-Za-z0-9_.:-]{0,79}$'; }
peer_valid_key() { printf '%s' "$1" | grep -Eq '^[A-Za-z0-9+/]{42}[AEIMQUYcgkosw048]=$'; }
peer_valid_generation() { printf '%s' "$1" | grep -Eq '^[0-9]{1,20}$'; }
peer_valid_ipv4() { printf '%s\n' "$1" | awk -F. 'NF!=4{exit 1}{for(i=1;i<=4;i++) if($i!~/^[0-9]+$/ || $i<0 || $i>255) exit 1}'; }
peer_ip_in_pool() {
    ip="$1" pool="$2"
    peer_valid_ipv4 "$ip" || return 1
    case "$pool" in
        */8)  p="${pool%%.*}"; [ "${ip%%.*}" = "$p" ] ;;
        */16) base="${pool%/*}"; p="${base%.*.*}"; [ "${ip%.*.*}" = "$p" ] ;;
        */24) p="${pool%.*/*}"; [ "${ip%.*}" = "$p" ] ;;
        *) return 1 ;;
    esac
}
peer_valid_selector() { case "$1" in cs1|cs2|cs3|cs4|cs5) return 0;; *) return 1;; esac; }
peer_target_for_selector() { case "$1" in cs1) echo canary_vpn3;; cs2) echo canary_vpn4;; cs3) echo canary_vpn5;; cs4) echo canary_vpn1;; cs5) echo canary_vpn2;; *) return 1;; esac; }
peer_csv_contains() { list="$1" item="$2"; [ -n "$list" ] || return 1; printf '%s\n' "$list" | awk -F, -v item="$item" '{for(i=1;i<=NF;i++) if($i==item) ok=1} END{exit ok?0:1}'; }
peer_selector_rows() {
    in="$1" out="$2"
    awk '
      function validip(ip,a,i){if(ip!~/^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/)return 0;split(ip,a,".");for(i=1;i<=4;i++)if(a[i]<0||a[i]>255)return 0;return 1}
      function key(ip,a){split(ip,a,".");return sprintf("%03d%03d%03d%03d",a[1],a[2],a[3],a[4])}
      /^[[:space:]]*($|#)/{next}
      NF!=3{exit 41}
      !validip($1){exit 42}
      $2!~/^cs[1-5]$/{exit 43}
      seen[$1]++{exit 44}
      {print key($1) "\t" $1 "\t" $2 "\t" $3}
    ' "$in" | LC_ALL=C sort -k1,1 > "$out"
}
peer_registry_validate() {
    file="$1"
    [ -s "$file" ] || return 41
    awk -F '\t' '
      function validip(ip,a,i){if(ip!~/^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/)return 0;split(ip,a,".");for(i=1;i<=4;i++)if(a[i]<0||a[i]>255)return 0;return 1}
      /^#/{next}
      NF!=10{exit 42}
      $1!~/^[A-Za-z0-9][A-Za-z0-9_.:-]{0,79}$/{exit 43}
      $2!~/^(wireguard|amneziawg)$/{exit 44}
      $3!~/^[A-Za-z0-9_.:-]+$/{exit 45}
      $4!~/^[A-Za-z0-9+\/]{42}[AEIMQUYcgkosw048]=$/{exit 46}
      !validip($5){exit 47}
      $6!~/^cs[1-5]$/ || $7!~/^cs[1-5]$/{exit 48}
      $8!~/^[0-9]{1,20}$/ || $9!~/^[0-9]{1,20}$/ || $10!~/^[0-9]{1,20}$/{exit 49}
      seen_id[$1]++ || seen_key[$2 SUBSEP $4]++ || seen_ip[$5]++ {exit 50}
      {n++}
      END{if(n<1)exit 51}
    ' "$file"
}
peer_registry_count() { awk -F '\t' '$0!~/^#/ && NF{n++} END{print n+0}' "$1"; }
peer_protocol_resolve() {
    protocol="$1"
    case "$protocol" in
      wireguard) PEER_PROTOCOL_ENABLED="$PEER_WIREGUARD_ENABLED"; PEER_PROTOCOL_INTERFACE="$PEER_WIREGUARD_INTERFACE"; PEER_PROTOCOL_CLI="$PEER_WIREGUARD_CLI"; PEER_PROTOCOL_POOL="$PEER_WIREGUARD_POOL" ;;
      amneziawg) PEER_PROTOCOL_ENABLED="$PEER_AMNEZIAWG_ENABLED"; PEER_PROTOCOL_INTERFACE="$PEER_AMNEZIAWG_INTERFACE"; PEER_PROTOCOL_CLI="$PEER_AMNEZIAWG_CLI"; PEER_PROTOCOL_POOL="$PEER_AMNEZIAWG_POOL" ;;
      *) return 1 ;;
    esac
    [ "$PEER_PROTOCOL_ENABLED" = 1 ]
}
peer_topology_load() {
    PEER_TOPOLOGY_MODE=NORMAL
    PEER_ALLOWED_SELECTORS=cs1,cs2,cs3,cs4,cs5
    PEER_TOPOLOGY_GENERATION=000000000000
    if [ -f "$PEER_TOPOLOGY_STATE_FILE" ]; then
      PEER_TOPOLOGY_MODE="$(peer_kv_get mode "$PEER_TOPOLOGY_STATE_FILE")"
      PEER_ALLOWED_SELECTORS="$(peer_kv_get allowed_selectors "$PEER_TOPOLOGY_STATE_FILE")"
      PEER_TOPOLOGY_GENERATION="$(peer_kv_get accepted_generation "$PEER_TOPOLOGY_STATE_FILE")"
      case "$PEER_TOPOLOGY_MODE" in NORMAL|SLOT_EXHAUSTED) ;; *) return 1;; esac
      [ -n "$PEER_TOPOLOGY_GENERATION" ] || return 1
      if [ "$PEER_TOPOLOGY_MODE" = NORMAL ]; then [ "$PEER_ALLOWED_SELECTORS" = cs1,cs2,cs3,cs4,cs5 ] || return 1; fi
    fi
}
peer_choose_least() {
    registry="$1" field="$2" allowed="$3"
    best='' best_count=''
    for cls in cs1 cs2 cs3 cs4 cs5; do
      peer_csv_contains "$allowed" "$cls" || continue
      count="$(awk -F '\t' -v f="$field" -v c="$cls" '$0!~/^#/ && $f==c{n++} END{print n+0}' "$registry")"
      if [ -z "$best" ] || [ "$count" -lt "$best_count" ]; then best="$cls"; best_count="$count"; fi
    done
    [ -n "$best" ] || return 1
    printf '%s\n' "$best"
}
peer_render_registry() {
    registry="$1" outdir="$2"
    mkdir -p "$outdir" || return 1
    active="$outdir/peers.conf" canonical="$outdir/canonical.conf" activity="$outdir/router_egress_activity.nft"
    {
      echo '# generated from router-wgpay-peer-registry-v1; do not edit'
      echo '# format: tunnel_ip dscp_class comment'
      awk -F '\t' '$0!~/^#/ {print $5, $7, "profile_" $1}' "$registry" | LC_ALL=C sort -t. -k1,1n -k2,2n -k3,3n -k4,4n
    } > "$active" || return 1
    {
      echo '# generated from router-wgpay-peer-registry-v1; do not edit'
      echo '# format: tunnel_ip dscp_class comment'
      awk -F '\t' '$0!~/^#/ {print $5, $6, "profile_" $1}' "$registry" | LC_ALL=C sort -t. -k1,1n -k2,2n -k3,3n -k4,4n
    } > "$canonical" || return 1
    {
      echo '# generated from router-wgpay-peer-registry-v1; do not edit'
      echo 'table inet router_egress_activity {'
      awk -F '\t' '$0!~/^#/ {gsub(/\./,"_",$5); print "    counter peer_" $5 "_out_vpn { }"; print "    counter peer_" $5 "_in_vpn { }"}' "$registry"
      echo
      echo '    chain forward_activity {'
      echo '        type filter hook forward priority 0; policy accept;'
      awk -F '\t' -v wan="$PEER_ACTIVITY_WAN_INTERFACE" '$0!~/^#/ {
        ip=$5; safe=ip; gsub(/\./,"_",safe);
        print "        iifname \"" $3 "\" oifname \"" wan "\" ip saddr " ip "/32 counter name peer_" safe "_out_vpn comment \"activity_out " ip "/32 " $7 " profile_" $1 "\"";
        print "        iifname \"" wan "\" oifname \"" $3 "\" ip daddr " ip "/32 counter name peer_" safe "_in_vpn comment \"activity_in " ip "/32 " $7 " profile_" $1 "\"";
      }' "$registry"
      echo '    }'
      echo '}'
    } > "$activity" || return 1
    peer_selector_rows "$active" "$outdir/active.rows" || return 1
    peer_selector_rows "$canonical" "$outdir/canonical.rows" || return 1
    [ "$(peer_registry_count "$registry")" -eq "$(awk 'END{print NR+0}' "$outdir/active.rows")" ] || return 1
}
peer_runtime_key_for_ip() {
    cli="$1" iface="$2" ip="$3"
    "$cli" show "$iface" dump 2>/dev/null | awk -v want="$ip/32" 'NR>1{n=split($4,a,",");for(i=1;i<=n;i++)if(a[i]==want){print $1;exit}}'
}
peer_runtime_has_key() { "$1" show "$2" peers 2>/dev/null | grep -Fx "$3" >/dev/null 2>&1; }
peer_runtime_ip_for_key() { "$1" show "$2" dump 2>/dev/null | awk -v key="$3" '$1==key{print $4;exit}'; }
peer_request_get() { peer_kv_get "$1" "$2"; }
peer_receipt_path() { printf '%s/%s.kv\n' "$PEER_RECEIPT_DIR" "$1"; }
peer_request_hash() { printf '%s\n' "$1" | sha256sum | awk '{print $1}'; }
peer_install_rendered() {
    dir="$1"
    peer_atomic_write "$dir/peers.conf" "$PEER_ACTIVE_SELECTOR_FILE" 600 || return 1
    peer_atomic_write "$dir/canonical.conf" "$PEER_CANONICAL_SELECTOR_FILE" 600 || return 1
    peer_atomic_write "$dir/router_egress_activity.nft" "$PEER_ACTIVITY_FILE" 600 || return 1
}
peer_apply_runtime_tables() {
    "$PEER_SELECTOR_APPLY" start || return 1
    "$PEER_ACTIVITY_APPLY" || return 1
}
peer_registry_sync_from_selectors() {
    registry="$1" active="$2" canonical="$3" output="$4" work="$5"
    peer_registry_validate "$registry" || return 1
    peer_selector_rows "$active" "$work/active.rows" || return 1
    peer_selector_rows "$canonical" "$work/canonical.rows" || return 1
    awk -F '\t' 'FNR==1{file_no++} file_no==1{a[$2]=$3;next} file_no==2{c[$2]=$3;next} /^#/{print;next} {if(!($5 in a)||!($5 in c))exit 61;$6=c[$5];$7=a[$5];print}' OFS='\t' "$work/active.rows" "$work/canonical.rows" "$registry" > "$output" || return 1
    peer_registry_validate "$output"
}
