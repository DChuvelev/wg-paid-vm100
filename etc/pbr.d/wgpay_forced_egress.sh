#!/bin/sh
# Rebuild the configuration-scoped forced-egress overlay after PBR has rebuilt fw4.
HELPER="${ROUTER_WGPAY_FORCED_HELPER:-/usr/local/sbin/router-wgpay-forced-egress.sh}"
[ -x "$HELPER" ] || exit 0
exec "$HELPER" --reconcile
