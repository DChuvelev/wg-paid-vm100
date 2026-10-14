#!/bin/sh
# Restore exact review-peer Direct overrides after PBR rebuilds its own table/rules.
HELPER="${ROUTER_WGPAY_REVIEW_DIRECT_HELPER:-/usr/local/sbin/router-wgpay-review-direct.sh}"
if [ -x "$HELPER" ]; then
    "$HELPER" --reconcile
fi
