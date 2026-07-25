#!/bin/sh
set -u
export PATH='/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin'
if [ -n "${SSH_ORIGINAL_COMMAND:-}" ]; then
    printf '%s\n' \
        'schema=router-wgpay-slot-topology-ack-v1' \
        'result=REJECTED' \
        'reason=arbitrary_command_forbidden' \
        'detail=forced_command_stdin_only'
    exit 126
fi
TOPOLOGY_APPLY="${ROUTER_TOPOLOGY_APPLY:-/usr/local/sbin/router-wgpay-slot-topology-apply.sh}"
exec "$TOPOLOGY_APPLY" --stdin
