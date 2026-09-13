#!/bin/sh
set -u
CONFIG="${ROUTER_WGPAY_PEER_CONFIG:-/etc/router-wgpay-peer-lifecycle.conf}"
[ -r "$CONFIG" ] && . "$CONFIG"
SEL_FILE="${ROUTER_WGPAY_SELECTOR_FILE:-${PEER_ACTIVE_SELECTOR_FILE:-/etc/router-wgpay-selector.d/peers.conf}}"
REGISTRY_FILE="${ROUTER_WGPAY_REGISTRY_FILE:-${PEER_REGISTRY_FILE:-/etc/router-wgpay-peer-state/registry.tsv}}"
TABLE="${ROUTER_WGPAY_SELECTOR_TABLE:-wgpay_dscp_canary}"
NFT_BIN="${ROUTER_WGPAY_NFT_BIN:-nft}"
WG_BIN="${ROUTER_WGPAY_WG_BIN:-${PEER_WIREGUARD_CLI:-wg}}"
WG_INTERFACE="${ROUTER_WGPAY_WG_INTERFACE:-${PEER_WIREGUARD_INTERFACE:-wg_paid}}"
AWG_BIN="${ROUTER_WGPAY_AWG_BIN:-${PEER_AMNEZIAWG_CLI:-amneziawg}}"
AWG_INTERFACE="${ROUTER_WGPAY_AWG_INTERFACE:-${PEER_AMNEZIAWG_INTERFACE:-awg_paid}}"

registry_identity_for_ip() {
  lookup_ip="$1"
  [ -s "$REGISTRY_FILE" ] || return 1
  grep -Fqx '# schema=router-wgpay-peer-registry-v1' "$REGISTRY_FILE" || return 1
  awk -F '\t' -v ip="$lookup_ip" '
    $0 !~ /^#/ && $5==ip {n++; protocol=$2; iface=$3}
    END {if(n!=1) exit 1; printf "%s\t%s\n", protocol, iface}
  ' "$REGISTRY_FILE"
}

resolve_runtime() {
  protocol="$1"
  registry_interface="$2"
  case "$protocol" in
    wireguard) runtime_cli="$WG_BIN"; expected_interface="$WG_INTERFACE" ;;
    amneziawg) runtime_cli="$AWG_BIN"; expected_interface="$AWG_INTERFACE" ;;
    *) return 1 ;;
  esac
  [ "$registry_interface" = "$expected_interface" ] || return 2
  runtime_interface="$registry_interface"
}

apply_rules() {
  [ -f "$SEL_FILE" ] || { echo "BLOCK: selector_file_missing"; exit 2; }
  [ -s "$REGISTRY_FILE" ] || { echo "BLOCK: registry_file_missing"; exit 2; }
  grep -Fqx '# schema=router-wgpay-peer-registry-v1' "$REGISTRY_FILE" || { echo "BLOCK: registry_schema_invalid"; exit 2; }
  "$NFT_BIN" delete table inet "$TABLE" 2>/dev/null || true
  "$NFT_BIN" add table inet "$TABLE"
  "$NFT_BIN" add chain inet "$TABLE" prerouting '{ type filter hook prerouting priority mangle; policy accept; }'
  count=0
  while read ip dscp comment rest; do
    case "${ip:-}" in ""|\#*) continue;; esac
    case "${dscp:-}" in cs1|cs2|cs3|cs4|cs5|cs6|cs7|ef|af11|af12|af13|af21|af22|af23|af31|af32|af33|af41|af42|af43|be) ;; *) echo "BLOCK: unsupported_dscp_for_$ip=$dscp"; exit 3;; esac
    echo "$ip" | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' >/dev/null || { echo "BLOCK: invalid_ip=$ip"; exit 4; }
    identity="$(registry_identity_for_ip "$ip")" || { echo "BLOCK: selector_ip_registry_join_failed=$ip"; exit 5; }
    protocol="$(printf '%s\n' "$identity" | awk -F '\t' '{print $1}')"
    registry_interface="$(printf '%s\n' "$identity" | awk -F '\t' '{print $2}')"
    resolve_runtime "$protocol" "$registry_interface" || { echo "BLOCK: selector_runtime_mapping_invalid_${ip}=${protocol}:${registry_interface}"; exit 5; }
    "$runtime_cli" show "$runtime_interface" dump 2>/dev/null | grep -F "$ip/32" >/dev/null || { echo "BLOCK: selector_ip_not_in_${runtime_interface}=$ip"; exit 5; }
    safe_comment="$(echo "${comment:-selector}" | tr -cd 'A-Za-z0-9_.:-' | cut -c1-40)"; [ -n "$safe_comment" ] || safe_comment=selector
    "$NFT_BIN" add rule inet "$TABLE" prerouting iifname "$runtime_interface" ip saddr "$ip" ip dscp set "$dscp" counter comment "WGPAY_SELECTOR_${safe_comment}_${ip}_${dscp}"
    count=$((count+1))
  done < "$SEL_FILE"
  echo "applied_vm100_wgpay_selector_rules=$count"
}
case "${1:-start}" in start|restart|reload) apply_rules;; stop) "$NFT_BIN" delete table inet "$TABLE" 2>/dev/null || true; echo stopped_vm100_wgpay_selector=1;; status) "$NFT_BIN" list table inet "$TABLE" 2>/dev/null;; *) echo "usage: $0 {start|stop|restart|reload|status}"; exit 1;; esac
