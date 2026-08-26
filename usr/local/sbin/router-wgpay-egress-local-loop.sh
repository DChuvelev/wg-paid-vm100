#!/bin/sh
# P27E5 bounded-current-snapshot logging.
# The detailed success log is replaced atomically on every cycle.
# Failures are additionally emitted to bounded OpenWrt logd.
set -u

CONF="${ROUTER_EGRESS_LOCAL_CONF:-/etc/router-wgpay-egress-local.conf}"

MODE="--dry-run"
INTERVAL="5"
LOG="/var/log/router-wgpay-egress-local.log"
SCRIPT="/usr/local/sbin/router-wgpay-egress-local.sh"
LOG_MAX_BYTES="${ROUTER_EGRESS_CURRENT_LOG_MAX_BYTES:-1048576}"

ROUTER_EGRESS_ALLOCATOR_ENABLED="1"
ROUTER_EGRESS_REBALANCE_PAUSED="0"
ROUTER_EGRESS_FORCE_MODE="off"
ROUTER_EGRESS_FORCE_CLASS=""
ROUTER_EGRESS_FORCE_TARGET_ID=""
ROUTER_EGRESS_FORCE_REASON=""
ROUTER_EGRESS_FORCE_UNTIL=""
ROUTER_EGRESS_ACTIVE_MIN_PACKETS="1"
ROUTER_EGRESS_ACTIVE_MIN_BYTES="1"
ROUTER_EGRESS_TOPOLOGY_STATE_FILE="/var/lib/router-wgpay-topology/state.kv"
ROUTER_EGRESS_MAINTENANCE_OVERRIDE="0"

if [ -f "$CONF" ]; then
  . "$CONF"
fi

: "${MODE:=--dry-run}"
: "${INTERVAL:=30}"
: "${LOG:=/var/log/router-wgpay-egress-local.log}"
: "${SCRIPT:=/usr/local/sbin/router-wgpay-egress-local.sh}"
: "${LOG_MAX_BYTES:=1048576}"

export ROUTER_EGRESS_ALLOCATOR_ENABLED
export ROUTER_EGRESS_REBALANCE_PAUSED
export ROUTER_EGRESS_FORCE_MODE
export ROUTER_EGRESS_FORCE_CLASS
export ROUTER_EGRESS_FORCE_TARGET_ID
export ROUTER_EGRESS_FORCE_REASON
export ROUTER_EGRESS_FORCE_UNTIL
export ROUTER_EGRESS_ACTIVE_MIN_PACKETS
export ROUTER_EGRESS_ACTIVE_MIN_BYTES
export ROUTER_EGRESS_TOPOLOGY_STATE_FILE
export ROUTER_EGRESS_MAINTENANCE_OVERRIDE

mkdir -p "$(dirname "$LOG")" 2>/dev/null || true
NEXT="${LOG}.next"
TRIM="${LOG}.trim"

cleanup() {
  rm -f "$NEXT" "$TRIM"
}
trap 'cleanup; exit 0' INT TERM
trap cleanup EXIT

while true; do
  rc=0
  rm -f "$NEXT" "$TRIM"

  {
    echo "__ROUTER_WGPAY_EGRESS_LOCAL_LOOP_BEGIN__ pid=$$ conf=$CONF mode=$MODE interval=$INTERVAL allocator_enabled=$ROUTER_EGRESS_ALLOCATOR_ENABLED paused=$ROUTER_EGRESS_REBALANCE_PAUSED force_mode=$ROUTER_EGRESS_FORCE_MODE topology_state=$ROUTER_EGRESS_TOPOLOGY_STATE_FILE maintenance_override=$ROUTER_EGRESS_MAINTENANCE_OVERRIDE started_at=$(date -Is 2>/dev/null || date)"
    echo "__ROUTER_WGPAY_EGRESS_LOCAL_RUN_BEGIN__"
    echo "run_started_at=$(date -Is 2>/dev/null || date)"
    echo "conf=$CONF"
    echo "mode=$MODE"
    echo "script=$SCRIPT"
    echo "allocator_enabled=$ROUTER_EGRESS_ALLOCATOR_ENABLED"
    echo "rebalance_paused=$ROUTER_EGRESS_REBALANCE_PAUSED"
    echo "force_mode=$ROUTER_EGRESS_FORCE_MODE"
    echo "topology_state_file=$ROUTER_EGRESS_TOPOLOGY_STATE_FILE"
    echo "maintenance_override=$ROUTER_EGRESS_MAINTENANCE_OVERRIDE"
    "$SCRIPT" "$MODE" || rc=$?
    echo "run_rc=$rc"
    echo "run_finished_at=$(date -Is 2>/dev/null || date)"
    echo "__ROUTER_WGPAY_EGRESS_LOCAL_RUN_END__"
  } > "$NEXT" 2>&1

  size="$(wc -c < "$NEXT" 2>/dev/null || echo 0)"
  case "$size" in
    ''|*[!0-9]*) size=0 ;;
  esac

  if [ "$size" -gt "$LOG_MAX_BYTES" ] 2>/dev/null; then
    {
      echo "__ROUTER_WGPAY_EGRESS_LOCAL_LOG_TRUNCATED__ original_bytes=$size max_bytes=$LOG_MAX_BYTES"
      tail -n 200 "$NEXT"
    } > "$TRIM" 2>/dev/null || cp "$NEXT" "$TRIM"
    mv -f "$TRIM" "$NEXT"
  fi

  chmod 0644 "$NEXT" 2>/dev/null || true
  mv -f "$NEXT" "$LOG"

  if [ "$rc" -ne 0 ]; then
    logger -t router-wgpay-egress-local "run_failed rc=$rc detailed_snapshot=$LOG" 2>/dev/null || true
  fi

  sleep "$INTERVAL"
done
