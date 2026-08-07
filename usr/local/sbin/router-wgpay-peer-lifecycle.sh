#!/bin/sh
set -u
umask 077
export PATH='/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin'

CONFIG="${ROUTER_WGPAY_PEER_CONFIG:-/etc/router-wgpay-peer-lifecycle.conf}"
[ -r "$CONFIG" ] || { echo RESULT=STOP_PEER_LIFECYCLE; echo STOP_REASON=config_missing; exit 70; }
. "$CONFIG"
LIB="${ROUTER_WGPAY_PEER_LIB:-/usr/local/lib/router-wgpay-peer-lifecycle-lib.sh}"
[ -r "$LIB" ] || { echo RESULT=STOP_PEER_LIFECYCLE; echo STOP_REASON=library_missing; exit 70; }
. "$LIB"

MODE="${1:---status}"
WORK="/tmp/router-wgpay-peer-lifecycle.$$"
mkdir -p "$WORK" || exit 70
trap 'rm -rf "$WORK"' EXIT INT TERM

mkdir -p "$PEER_STATE_DIR" "$PEER_RECEIPT_DIR" "$(dirname "$PEER_SELECTOR_LOCK")" || exit 70
chmod 700 "$PEER_STATE_DIR" "$PEER_RECEIPT_DIR" 2>/dev/null || true

lock() { exec 9>"$PEER_SELECTOR_LOCK"; flock -n 9 || { echo RESULT=NOOP_PEER_LIFECYCLE_LOCKED; exit 75; }; }
registry_header() { printf '%s\n' '# schema=router-wgpay-peer-registry-v1' '# columns=profile_id protocol interface public_key tunnel_ip normal_selector active_selector desired_generation created_epoch updated_epoch'; }
backup_file() { src="$1" name="$2"; if [ -f "$src" ]; then cp "$src" "$WORK/$name"; echo true > "$WORK/$name.exists"; else : > "$WORK/$name"; echo false > "$WORK/$name.exists"; fi; }
restore_file() { dst="$1" name="$2"; if [ "$(cat "$WORK/$name.exists")" = true ]; then peer_atomic_write "$WORK/$name" "$dst" 600; else rm -f "$dst"; fi; }
backup_state() { backup_file "$PEER_REGISTRY_FILE" registry.before; backup_file "$PEER_ACTIVE_SELECTOR_FILE" active.before; backup_file "$PEER_CANONICAL_SELECTOR_FILE" canonical.before; backup_file "$PEER_ACTIVITY_FILE" activity.before; }
restore_state() { restore_file "$PEER_REGISTRY_FILE" registry.before; restore_file "$PEER_ACTIVE_SELECTOR_FILE" active.before; restore_file "$PEER_CANONICAL_SELECTOR_FILE" canonical.before; restore_file "$PEER_ACTIVITY_FILE" activity.before; peer_apply_runtime_tables >/dev/null 2>&1 || true; }
refresh_internal() {
    [ -s "$PEER_REGISTRY_FILE" ] || return 1
    peer_registry_sync_from_selectors "$PEER_REGISTRY_FILE" "$PEER_ACTIVE_SELECTOR_FILE" "$PEER_CANONICAL_SELECTOR_FILE" "$WORK/registry.refreshed" "$WORK" || return 1
    peer_atomic_write "$WORK/registry.refreshed" "$PEER_REGISTRY_FILE" 600
}
receipt_check() {
    op="$1" reqsha="$2" receipt="$(peer_receipt_path "$op")"
    [ -f "$receipt" ] || return 1
    oldsha="$(peer_kv_get request_sha256 "$receipt")"
    [ "$oldsha" = "$reqsha" ] || { echo RESULT=STOP_PEER_LIFECYCLE; echo STOP_REASON=operation_id_payload_mismatch; exit 66; }
    cat "$receipt"
    exit 0
}
receipt_write() {
    op="$1" reqsha="$2" action="$3" profile="$4" result="$5" noop="$6"
    tmp="$WORK/receipt"
    { echo schema=router-wgpay-peer-receipt-v1; echo operation_id="$op"; echo request_sha256="$reqsha"; echo action="$action"; echo profile_id="$profile"; echo result="$result"; echo noop="$noop"; echo completed_epoch="$(date +%s)"; } > "$tmp"
    peer_atomic_write "$tmp" "$(peer_receipt_path "$op")" 600
    cat "$(peer_receipt_path "$op")"
}

case "$MODE" in
  --status)
    echo schema=router-wgpay-peer-lifecycle-status-v1
    echo config="$CONFIG"
    if [ -s "$PEER_REGISTRY_FILE" ]; then
      if peer_registry_validate "$PEER_REGISTRY_FILE"; then valid=true; else valid=false; fi
      echo initialized=true
      echo registry_valid="$valid"
      echo profile_count="$(peer_registry_count "$PEER_REGISTRY_FILE")"
      echo wireguard_count="$(awk -F '\t' '$0!~/^#/ && $2=="wireguard"{n++} END{print n+0}' "$PEER_REGISTRY_FILE")"
      echo amneziawg_count="$(awk -F '\t' '$0!~/^#/ && $2=="amneziawg"{n++} END{print n+0}' "$PEER_REGISTRY_FILE")"
      if peer_registry_sync_from_selectors "$PEER_REGISTRY_FILE" "$PEER_ACTIVE_SELECTOR_FILE" "$PEER_CANONICAL_SELECTOR_FILE" "$WORK/status.refreshed" "$WORK" && cmp -s "$PEER_REGISTRY_FILE" "$WORK/status.refreshed"; then echo selector_registry_consistent=true; else echo selector_registry_consistent=false; fi
    else
      echo initialized=false
      echo profile_count=0
    fi
    echo RESULT=PASS_PEER_LIFECYCLE_STATUS
    ;;

  --migrate-current)
    lock
    if [ -s "$PEER_REGISTRY_FILE" ]; then
      peer_registry_validate "$PEER_REGISTRY_FILE" || { peer_stop registry_invalid 71; exit $?; }
      peer_render_registry "$PEER_REGISTRY_FILE" "$WORK/render" || { peer_stop render_failed 72; exit $?; }
      peer_install_rendered "$WORK/render" || { peer_stop render_install_failed 73; exit $?; }
      peer_apply_runtime_tables || { peer_stop apply_failed 74; exit $?; }
      echo RESULT=NOOP_PEER_LIFECYCLE_ALREADY_MIGRATED
      echo profile_count="$(peer_registry_count "$PEER_REGISTRY_FILE")"
      exit 0
    fi
    [ -r "$PEER_LEGACY_ACTIVE_SELECTOR_FILE" ] && [ -r "$PEER_LEGACY_CANONICAL_SELECTOR_FILE" ] || { peer_stop legacy_selector_missing 71; exit $?; }
    peer_selector_rows "$PEER_LEGACY_ACTIVE_SELECTOR_FILE" "$WORK/active.rows" || { peer_stop legacy_active_invalid 71; exit $?; }
    peer_selector_rows "$PEER_LEGACY_CANONICAL_SELECTOR_FILE" "$WORK/canonical.rows" || { peer_stop legacy_canonical_invalid 71; exit $?; }
    awk -F '\t' '{print $2}' "$WORK/active.rows" > "$WORK/active.ips"
    awk -F '\t' '{print $2}' "$WORK/canonical.rows" > "$WORK/canonical.ips"
    cmp -s "$WORK/active.ips" "$WORK/canonical.ips" || { peer_stop legacy_peer_set_mismatch 71; exit $?; }
    now="$(date +%s)"; generation="$(peer_kv_get accepted_generation "$PEER_TOPOLOGY_STATE_FILE")"; [ -n "$generation" ] || generation=000000000000
    runtime_count="$("$PEER_WIREGUARD_CLI" show "$PEER_WIREGUARD_INTERFACE" peers 2>/dev/null | awk 'NF{n++} END{print n+0}')"
    migrated_count=0; stale_count=0
    { registry_header; while IFS="$(printf '\t')" read -r sortkey ip active tag; do
        normal="$(awk -F '\t' -v ip="$ip" '$2==ip{print $3}' "$WORK/canonical.rows")"
        key="$(peer_runtime_key_for_ip "$PEER_WIREGUARD_CLI" "$PEER_WIREGUARD_INTERFACE" "$ip")"
        if [ -z "$key" ]; then stale_count=$((stale_count+1)); continue; fi
        id="legacy-$(printf '%s' "$ip" | tr . -)"
        printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$id" wireguard "$PEER_WIREGUARD_INTERFACE" "$key" "$ip" "$normal" "$active" "$generation" "$now" "$now"
        migrated_count=$((migrated_count+1))
      done < "$WORK/active.rows"; } > "$WORK/registry"
    [ "$migrated_count" -eq "$runtime_count" ] || { peer_stop runtime_selector_set_mismatch 72; exit $?; }
    [ "$migrated_count" -gt 0 ] || { peer_stop no_runtime_peers_to_migrate 72; exit $?; }
    peer_registry_validate "$WORK/registry" || { peer_stop migrated_registry_invalid 72; exit $?; }
    peer_render_registry "$WORK/registry" "$WORK/render" || { peer_stop migrated_render_failed 72; exit $?; }
    backup_state
    peer_atomic_write "$WORK/registry" "$PEER_REGISTRY_FILE" 600 || { restore_state; peer_stop registry_write_failed 73; exit $?; }
    peer_install_rendered "$WORK/render" || { restore_state; peer_stop render_install_failed 73; exit $?; }
    peer_apply_runtime_tables || { restore_state; peer_stop apply_failed 74; exit $?; }
    echo RESULT=PASS_PEER_LIFECYCLE_MIGRATED
    echo profile_count="$(peer_registry_count "$PEER_REGISTRY_FILE")"
    echo stale_selector_rows_pruned="$stale_count"
    ;;

  --refresh-selectors)
    lock
    refresh_internal || { peer_stop selector_refresh_failed 72; exit $?; }
    echo RESULT=PASS_PEER_LIFECYCLE_REFRESHED
    echo profile_count="$(peer_registry_count "$PEER_REGISTRY_FILE")"
    ;;

  --sync-from-selectors-unlocked)
    refresh_internal || { peer_stop selector_refresh_failed 72; exit $?; }
    echo RESULT=PASS_PEER_LIFECYCLE_SELECTOR_SYNC
    echo profile_count="$(peer_registry_count "$PEER_REGISTRY_FILE")"
    ;;

  --enable)
    request="${2:-}" psk_file="${3:-}"
    [ -r "$request" ] && [ -r "$psk_file" ] || { peer_stop enable_input_missing 64; exit $?; }
    operation_id="$(peer_request_get operation_id "$request")"; profile_id="$(peer_request_get profile_id "$request")"; protocol="$(peer_request_get protocol "$request")"; public_key="$(peer_request_get public_key "$request")"; tunnel_ip="$(peer_request_get tunnel_ip "$request")"; desired_generation="$(peer_request_get desired_generation "$request")"
    peer_valid_id "$operation_id" && peer_valid_id "$profile_id" && peer_valid_key "$public_key" && peer_valid_generation "$desired_generation" || { peer_stop enable_input_invalid 64; exit $?; }
    peer_protocol_resolve "$protocol" || { peer_stop protocol_disabled_or_invalid 64; exit $?; }
    peer_ip_in_pool "$tunnel_ip" "$PEER_PROTOCOL_POOL" || { peer_stop tunnel_ip_outside_pool 64; exit $?; }
    psk_sha="$(sha256sum "$psk_file" | awk '{print $1}')"
    reqsha="$(peer_request_hash "enable|$profile_id|$protocol|$public_key|$tunnel_ip|$desired_generation|$psk_sha")"
    lock; receipt_check "$operation_id" "$reqsha" || true
    [ -s "$PEER_REGISTRY_FILE" ] || { peer_stop registry_not_initialized 71; exit $?; }
    refresh_internal || { peer_stop selector_refresh_failed 72; exit $?; }
    existing="$(awk -F '\t' -v id="$profile_id" '$0!~/^#/ && $1==id{print;exit}' "$PEER_REGISTRY_FILE")"
    if [ -n "$existing" ]; then
      old="$(printf '%s\n' "$existing" | awk -F '\t' '{print $2"|"$3"|"$4"|"$5}')"
      [ "$old" = "$protocol|$PEER_PROTOCOL_INTERFACE|$public_key|$tunnel_ip" ] || { peer_stop profile_id_conflict 66; exit $?; }
      receipt_write "$operation_id" "$reqsha" enable "$profile_id" PASS_PEER_ENABLE true
      exit 0
    fi
    awk -F '\t' -v key="$public_key" '$0!~/^#/ && $4==key{found=1} END{exit found?0:1}' "$PEER_REGISTRY_FILE" && { peer_stop public_key_conflict 66; exit $?; }
    awk -F '\t' -v ip="$tunnel_ip" '$0!~/^#/ && $5==ip{found=1} END{exit found?0:1}' "$PEER_REGISTRY_FILE" && { peer_stop tunnel_ip_conflict 66; exit $?; }
    peer_runtime_has_key "$PEER_PROTOCOL_CLI" "$PEER_PROTOCOL_INTERFACE" "$public_key" && { peer_stop unmanaged_runtime_key_conflict 66; exit $?; }
    peer_topology_load || { peer_stop topology_state_invalid 72; exit $?; }
    normal="$(peer_choose_least "$PEER_REGISTRY_FILE" 6 cs1,cs2,cs3,cs4,cs5)" || { peer_stop normal_selector_unavailable 72; exit $?; }
    if [ "$PEER_TOPOLOGY_MODE" = NORMAL ]; then active="$normal"; else active="$(peer_choose_least "$PEER_REGISTRY_FILE" 7 "$PEER_ALLOWED_SELECTORS")" || { peer_stop no_allowed_selectors 75; exit $?; }; fi
    now="$(date +%s)"
    { cat "$PEER_REGISTRY_FILE"; printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$profile_id" "$protocol" "$PEER_PROTOCOL_INTERFACE" "$public_key" "$tunnel_ip" "$normal" "$active" "$desired_generation" "$now" "$now"; } > "$WORK/registry.candidate"
    peer_registry_validate "$WORK/registry.candidate" || { peer_stop candidate_registry_invalid 72; exit $?; }
    peer_render_registry "$WORK/registry.candidate" "$WORK/render" || { peer_stop candidate_render_failed 72; exit $?; }
    backup_state
    "$PEER_PROTOCOL_CLI" set "$PEER_PROTOCOL_INTERFACE" peer "$public_key" preshared-key "$psk_file" allowed-ips "$tunnel_ip/32" || { peer_stop runtime_peer_add_failed 73; exit $?; }
    if ! peer_atomic_write "$WORK/registry.candidate" "$PEER_REGISTRY_FILE" 600 || ! peer_install_rendered "$WORK/render" || ! peer_apply_runtime_tables; then
      restore_state; "$PEER_PROTOCOL_CLI" set "$PEER_PROTOCOL_INTERFACE" peer "$public_key" remove >/dev/null 2>&1 || true
      peer_stop enable_apply_failed 74; exit $?
    fi
    peer_runtime_has_key "$PEER_PROTOCOL_CLI" "$PEER_PROTOCOL_INTERFACE" "$public_key" || { restore_state; "$PEER_PROTOCOL_CLI" set "$PEER_PROTOCOL_INTERFACE" peer "$public_key" remove >/dev/null 2>&1 || true; peer_stop enable_verify_failed 74; exit $?; }
    receipt_write "$operation_id" "$reqsha" enable "$profile_id" PASS_PEER_ENABLE false
    ;;

  --disable)
    request="${2:-}"; [ -r "$request" ] || { peer_stop disable_input_missing 64; exit $?; }
    operation_id="$(peer_request_get operation_id "$request")"; profile_id="$(peer_request_get profile_id "$request")"; desired_generation="$(peer_request_get desired_generation "$request")"
    peer_valid_id "$operation_id" && peer_valid_id "$profile_id" && peer_valid_generation "$desired_generation" || { peer_stop disable_input_invalid 64; exit $?; }
    reqsha="$(peer_request_hash "disable|$profile_id|$desired_generation")"
    lock; receipt_check "$operation_id" "$reqsha" || true
    [ -s "$PEER_REGISTRY_FILE" ] || { receipt_write "$operation_id" "$reqsha" disable "$profile_id" PASS_PEER_DISABLE true; exit 0; }
    refresh_internal || { peer_stop selector_refresh_failed 72; exit $?; }
    existing="$(awk -F '\t' -v id="$profile_id" '$0!~/^#/ && $1==id{print;exit}' "$PEER_REGISTRY_FILE")"
    if [ -z "$existing" ]; then receipt_write "$operation_id" "$reqsha" disable "$profile_id" PASS_PEER_DISABLE true; exit 0; fi
    protocol="$(printf '%s\n' "$existing" | awk -F '\t' '{print $2}')"; public_key="$(printf '%s\n' "$existing" | awk -F '\t' '{print $4}')"
    peer_protocol_resolve "$protocol" || { peer_stop protocol_disabled_or_invalid 64; exit $?; }
    { awk -F '\t' -v id="$profile_id" 'BEGIN{OFS="\t"} /^#/{print;next} $1!=id{print}' "$PEER_REGISTRY_FILE"; } > "$WORK/registry.candidate"
    # Empty registries are valid for disable, with headers only.
    peer_render_registry "$WORK/registry.candidate" "$WORK/render" || {
      count="$(awk -F '\t' '$0!~/^#/ && NF{n++} END{print n+0}' "$WORK/registry.candidate")"; [ "$count" -eq 0 ] || { peer_stop candidate_render_failed 72; exit $?; }
      { echo '# generated from router-wgpay-peer-registry-v1; do not edit'; echo '# format: tunnel_ip dscp_class comment'; } > "$WORK/render/peers.conf"
      cp "$WORK/render/peers.conf" "$WORK/render/canonical.conf"
      { echo '# generated from router-wgpay-peer-registry-v1; do not edit'; echo 'table inet router_egress_activity {'; echo '    chain forward_activity {'; echo '        type filter hook forward priority 0; policy accept;'; echo '    }'; echo '}'; } > "$WORK/render/router_egress_activity.nft"
    }
    backup_state
    if ! peer_atomic_write "$WORK/registry.candidate" "$PEER_REGISTRY_FILE" 600 || ! peer_install_rendered "$WORK/render" || ! peer_apply_runtime_tables; then restore_state; peer_stop disable_selector_apply_failed 74; exit $?; fi
    if ! "$PEER_PROTOCOL_CLI" set "$PEER_PROTOCOL_INTERFACE" peer "$public_key" remove; then restore_state; peer_stop runtime_peer_remove_failed 74; exit $?; fi
    if peer_runtime_has_key "$PEER_PROTOCOL_CLI" "$PEER_PROTOCOL_INTERFACE" "$public_key"; then restore_state; peer_stop disable_verify_failed 74; exit $?; fi
    receipt_write "$operation_id" "$reqsha" disable "$profile_id" PASS_PEER_DISABLE false
    ;;

  *)
    echo 'Usage: router-wgpay-peer-lifecycle.sh --status|--migrate-current|--refresh-selectors|--sync-from-selectors-unlocked|--enable REQUEST PSK_FILE|--disable REQUEST' >&2
    exit 64
    ;;
esac
