#!/bin/sh
# Rebuild the configuration-scoped forced-egress overlay after PBR has rebuilt fw4.
HELPER="${ROUTER_WGPAY_FORCED_HELPER:-/usr/local/sbin/router-wgpay-forced-egress.sh}"
if [ -x "$HELPER" ]; then
    "$HELPER" --reconcile
fi
