#!/bin/sh
set -u
export PATH='/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin'
STATE_FILE="${ROUTER_EXIT_CATALOG_STATE_FILE:-/var/lib/router-wgpay-exit-catalog/current.kv}"
case "${1:---status}" in
    --status)
        if [ -r "$STATE_FILE" ]; then
            cat "$STATE_FILE"
        else
            printf '%s\n' \
                'schema=router-wgpay-exit-catalog-v1' \
                'result=EMPTY' \
                'reason=no_catalog_state'
        fi
        ;;
    *)
        echo 'Usage: router-wgpay-exit-catalog.sh --status' >&2
        exit 64
        ;;
esac
