#!/bin/sh

SET="pbr_transit_direct_4_dst_ip_user"
FILE="/root/ru.zone"

[ -r "$FILE" ] || exit 0
nft list set inet fw4 "$SET" >/dev/null 2>&1 || exit 0

nft flush set inet fw4 "$SET" 2>/dev/null

while read -r cidr; do
    case "$cidr" in
        ""|\#*) continue ;;
    esac
    nft add element inet fw4 "$SET" "{ $cidr }"
done < "$FILE"
