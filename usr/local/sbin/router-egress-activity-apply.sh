#!/bin/sh
set -eu
CONFIG="${ROUTER_WGPAY_PEER_CONFIG:-/etc/router-wgpay-peer-lifecycle.conf}"
[ -r "$CONFIG" ] && . "$CONFIG"
TABLE_FILE="${ROUTER_EGRESS_ACTIVITY_FILE:-${PEER_ACTIVITY_FILE:-/etc/router-egress-activity/router_egress_activity.nft}}"
NFT_BIN="${ROUTER_WGPAY_NFT_BIN:-nft}"
[ -s "$TABLE_FILE" ] || { echo "missing or empty $TABLE_FILE" >&2; exit 1; }
"$NFT_BIN" delete table inet router_egress_activity 2>/dev/null || true
"$NFT_BIN" -f "$TABLE_FILE"
"$NFT_BIN" list table inet router_egress_activity >/dev/null
