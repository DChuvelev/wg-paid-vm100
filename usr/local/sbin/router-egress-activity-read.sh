#!/bin/sh
set -eu
nft list counters table inet router_egress_activity 2>/dev/null || nft list table inet router_egress_activity
