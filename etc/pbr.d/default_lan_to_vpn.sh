#!/bin/sh
# Client appliance default:
# LAN + admin WireGuard + QR WireGuard use VPN as default path.
# Direct destinations are handled separately by ru_to_direct.sh.

nft add element inet fw4 pbr_transit_vpn_4_src_ip_user "{ 10.71.100.0/24, 10.250.100.0/24, 10.252.100.0/24, 10.253.0.0/16 }" 2>/dev/null || true
