#!/bin/sh
set -eu
TABLE_FILE="/etc/router-egress-activity/router_egress_activity.nft"
if [ ! -s "$TABLE_FILE" ]; then
  echo "missing or empty $TABLE_FILE" >&2
  exit 1
fi
nft delete table inet router_egress_activity 2>/dev/null || true
nft -f "$TABLE_FILE"
nft list table inet router_egress_activity >/dev/null
