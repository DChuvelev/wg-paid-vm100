#!/bin/sh
set -u
export PATH='/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin'

TOPOLOGY_APPLY="${ROUTER_TOPOLOGY_APPLY:-/usr/local/sbin/router-wgpay-slot-topology-apply.sh}"
EXIT_CATALOG_APPLY="${ROUTER_EXIT_CATALOG_APPLY:-/usr/local/sbin/router-wgpay-exit-catalog-apply.sh}"

case "${SSH_ORIGINAL_COMMAND:-}" in
    '')
        exec "$TOPOLOGY_APPLY" --stdin
        ;;
    router-wgpay-exit-catalog)
        exec "$EXIT_CATALOG_APPLY" --stdin
        ;;
    *)
        printf '%s\n' \
            'schema=router-wgpay-slot-topology-ack-v1' \
            'result=REJECTED' \
            'reason=arbitrary_command_forbidden' \
            'detail=forced_command_stdin_only_or_exit_catalog'
        exit 126
        ;;
esac
