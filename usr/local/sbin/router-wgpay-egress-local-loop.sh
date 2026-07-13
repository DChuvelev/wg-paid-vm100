#!/bin/sh
set -u

CONF="${ROUTER_EGRESS_LOCAL_CONF:-/etc/router-wgpay-egress-local.conf}"

MODE="--dry-run"
INTERVAL="30"
LOG="/var/log/router-wgpay-egress-local.log"
SCRIPT="/usr/local/sbin/router-wgpay-egress-local.sh"

ROUTER_EGRESS_ALLOCATOR_ENABLED="1"
ROUTER_EGRESS_REBALANCE_PAUSED="0"
ROUTER_EGRESS_FORCE_MODE="off"
ROUTER_EGRESS_FORCE_CLASS=""
ROUTER_EGRESS_FORCE_TARGET_ID=""
ROUTER_EGRESS_FORCE_REASON=""
ROUTER_EGRESS_FORCE_UNTIL=""
ROUTER_EGRESS_ACTIVE_MIN_PACKETS="10"
ROUTER_EGRESS_ACTIVE_MIN_BYTES="16384"

if [ -f "$CONF" ]; then
  # shellcheck disable=SC1090
  . "$CONF"
fi

: "${MODE:=--dry-run}"
: "${INTERVAL:=30}"
: "${LOG:=/var/log/router-wgpay-egress-local.log}"
: "${SCRIPT:=/usr/local/sbin/router-wgpay-egress-local.sh}"

export ROUTER_EGRESS_ALLOCATOR_ENABLED
export ROUTER_EGRESS_REBALANCE_PAUSED
export ROUTER_EGRESS_FORCE_MODE
export ROUTER_EGRESS_FORCE_CLASS
export ROUTER_EGRESS_FORCE_TARGET_ID
export ROUTER_EGRESS_FORCE_REASON
export ROUTER_EGRESS_FORCE_UNTIL
export ROUTER_EGRESS_ACTIVE_MIN_PACKETS
export ROUTER_EGRESS_ACTIVE_MIN_BYTES

mkdir -p "$(dirname "$LOG")" 2>/dev/null || true

echo "__ROUTER_WGPAY_EGRESS_LOCAL_LOOP_BEGIN__ pid=$$ conf=$CONF mode=$MODE interval=$INTERVAL allocator_enabled=$ROUTER_EGRESS_ALLOCATOR_ENABLED paused=$ROUTER_EGRESS_REBALANCE_PAUSED force_mode=$ROUTER_EGRESS_FORCE_MODE started_at=$(date -Is 2>/dev/null || date)" >> "$LOG"

while true; do
  {
    echo "__ROUTER_WGPAY_EGRESS_LOCAL_RUN_BEGIN__"
    echo "run_started_at=$(date -Is 2>/dev/null || date)"
    echo "conf=$CONF"
    echo "mode=$MODE"
    echo "script=$SCRIPT"
    echo "allocator_enabled=$ROUTER_EGRESS_ALLOCATOR_ENABLED"
    echo "rebalance_paused=$ROUTER_EGRESS_REBALANCE_PAUSED"
    echo "force_mode=$ROUTER_EGRESS_FORCE_MODE"
    "$SCRIPT" "$MODE"
    rc=$?
    echo "run_rc=$rc"
    echo "run_finished_at=$(date -Is 2>/dev/null || date)"
    echo "__ROUTER_WGPAY_EGRESS_LOCAL_RUN_END__"
  } >> "$LOG" 2>&1

  sleep "$INTERVAL"
done
