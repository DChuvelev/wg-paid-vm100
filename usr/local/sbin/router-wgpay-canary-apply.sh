#!/bin/sh
set -u

SEL_FILE="/etc/router-wgpay-selector.d/peers.conf"
TABLE="wgpay_dscp_canary"

apply_rules() {
  [ -f "$SEL_FILE" ] || {
    echo "BLOCK: selector_file_missing"
    exit 2
  }

  nft delete table inet "$TABLE" 2>/dev/null || true
  nft add table inet "$TABLE"
  nft add chain inet "$TABLE" prerouting '{ type filter hook prerouting priority mangle; policy accept; }'

  count=0

  while read ip dscp comment rest; do
    case "${ip:-}" in
      ""|\#*) continue ;;
    esac

    case "${dscp:-}" in
      cs1|cs2|cs3|cs4|cs5|cs6|cs7|ef|af11|af12|af13|af21|af22|af23|af31|af32|af33|af41|af42|af43|be) ;;
      *)
        echo "BLOCK: unsupported_dscp_for_$ip=$dscp"
        exit 3
        ;;
    esac

    echo "$ip" | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' >/dev/null || {
      echo "BLOCK: invalid_ip=$ip"
      exit 4
    }

    wg show wg_paid dump 2>/dev/null | grep -F "$ip/32" >/dev/null || {
      echo "BLOCK: selector_ip_not_in_wg_paid=$ip"
      exit 5
    }

    safe_comment="$(echo "${comment:-selector}" | tr -cd 'A-Za-z0-9_.:-' | cut -c1-40)"
    [ -n "$safe_comment" ] || safe_comment="selector"

    nft add rule inet "$TABLE" prerouting iifname "wg_paid" ip saddr "$ip" ip dscp set "$dscp" counter comment "STEP_035B_SELECTOR_WGPAY_${safe_comment}_${ip}_${dscp}"
    count=$((count + 1))
  done < "$SEL_FILE"

  [ "$count" -gt 0 ] || {
    echo "BLOCK: selector_file_no_active_entries"
    exit 6
  }

  echo "applied_vm100_wgpay_selector_rules=$count"
}

case "${1:-start}" in
  start|restart|reload)
    apply_rules
    ;;

  stop)
    nft delete table inet "$TABLE" 2>/dev/null || true
    echo "stopped_vm100_wgpay_selector=1"
    ;;

  status)
    nft list table inet "$TABLE" 2>/dev/null
    ;;

  *)
    echo "usage: $0 {start|stop|restart|reload|status}"
    exit 1
    ;;
esac
