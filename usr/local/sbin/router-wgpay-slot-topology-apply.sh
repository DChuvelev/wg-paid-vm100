#!/bin/sh
set -u
umask 077
export PATH='/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin'

TOPOLOGY_CONFIG="${ROUTER_TOPOLOGY_CONFIG:-/etc/router-wgpay-slot-topology.conf}"
TOPOLOGY_LIB="${ROUTER_TOPOLOGY_LIB:-/usr/local/lib/router-wgpay-slot-topology-lib.sh}"
TOPOLOGY_SELECTOR_FILE="${ROUTER_TOPOLOGY_SELECTOR_FILE:-/etc/router-wgpay-selector.d/peers.conf}"
TOPOLOGY_STATE_DIR="${ROUTER_TOPOLOGY_STATE_DIR:-/var/lib/router-wgpay-topology}"
TOPOLOGY_STATE_FILE="${ROUTER_TOPOLOGY_STATE_FILE:-${TOPOLOGY_STATE_DIR}/state.kv}"
TOPOLOGY_PLAN_FILE="${ROUTER_TOPOLOGY_PLAN_FILE:-${TOPOLOGY_STATE_DIR}/plan.kv}"
TOPOLOGY_ACK_FILE="${ROUTER_TOPOLOGY_ACK_FILE:-${TOPOLOGY_STATE_DIR}/ack.kv}"
TOPOLOGY_LOCK_FILE="${ROUTER_TOPOLOGY_LOCK_FILE:-/var/run/router-wgpay-selector.lock}"
TOPOLOGY_NOW_EPOCH="${ROUTER_TOPOLOGY_NOW_EPOCH:-$(date +%s)}"

[ -r "$TOPOLOGY_CONFIG" ] || { echo 'RESULT=STOP_TOPOLOGY_CONFIG_MISSING'; exit 70; }
[ -r "$TOPOLOGY_LIB" ] || { echo 'RESULT=STOP_TOPOLOGY_LIBRARY_MISSING'; exit 70; }
# shellcheck disable=SC1090
. "$TOPOLOGY_CONFIG"
# shellcheck disable=SC1090
. "$TOPOLOGY_LIB"

# Re-resolve dependent paths after configuration load while preserving explicit environment overrides.
TOPOLOGY_SELECTOR_FILE="${ROUTER_TOPOLOGY_SELECTOR_FILE:-${TOPOLOGY_SELECTOR_FILE:-/etc/router-wgpay-selector.d/peers.conf}}"
TOPOLOGY_SELECTOR_APPLY="${ROUTER_TOPOLOGY_SELECTOR_APPLY:-${TOPOLOGY_SELECTOR_APPLY:-/usr/local/sbin/router-wgpay-canary-apply.sh}}"
TOPOLOGY_SELECTOR_TABLE="${ROUTER_TOPOLOGY_SELECTOR_TABLE:-${TOPOLOGY_SELECTOR_TABLE:-wgpay_dscp_canary}}"
TOPOLOGY_STATE_DIR="${ROUTER_TOPOLOGY_STATE_DIR:-${TOPOLOGY_STATE_DIR:-/var/lib/router-wgpay-topology}}"
TOPOLOGY_STATE_FILE="${ROUTER_TOPOLOGY_STATE_FILE:-${TOPOLOGY_STATE_DIR}/state.kv}"
TOPOLOGY_PLAN_FILE="${ROUTER_TOPOLOGY_PLAN_FILE:-${TOPOLOGY_STATE_DIR}/plan.kv}"
TOPOLOGY_ACK_FILE="${ROUTER_TOPOLOGY_ACK_FILE:-${TOPOLOGY_STATE_DIR}/ack.kv}"
TOPOLOGY_LOCK_FILE="${ROUTER_TOPOLOGY_LOCK_FILE:-${TOPOLOGY_LOCK_FILE:-/var/run/router-wgpay-selector.lock}}"
TOPOLOGY_DIRECT_MODE_HELPER="${ROUTER_TOPOLOGY_DIRECT_MODE_HELPER:-${TOPOLOGY_DIRECT_MODE_HELPER:-/usr/local/sbin/router-wgpay-direct-mode.sh}}"
TOPOLOGY_DIRECT_POLICY_ENABLED="${ROUTER_TOPOLOGY_DIRECT_POLICY_ENABLED:-${TOPOLOGY_DIRECT_POLICY_ENABLED:-0}}"

case "${1:---stdin}" in
    --status)
        if [ -f "$TOPOLOGY_ACK_FILE" ]; then
            cat "$TOPOLOGY_ACK_FILE"
        else
            printf '%s\n' "schema=${TOPOLOGY_ACK_SCHEMA}" 'result=EMPTY' 'reason=no_topology_state'
        fi
        exit 0
        ;;
    --stdin) ;;
    *) router_topology_reject invalid_mode "${1:-}" 64; exit $? ;;
esac

TOPOLOGY_TMP_ROOT="${TMPDIR:-/tmp}/router-wgpay-slot-topology.$$"
TOPOLOGY_RAW="$TOPOLOGY_TMP_ROOT/input.kv"
TOPOLOGY_BODY="$TOPOLOGY_TMP_ROOT/body.kv"
TOPOLOGY_EXPECTED="$TOPOLOGY_TMP_ROOT/expected.kv"
TOPOLOGY_ROWS="$TOPOLOGY_TMP_ROOT/selector-rows.tsv"
TOPOLOGY_COUNTS="$TOPOLOGY_TMP_ROOT/counts.kv"
TOPOLOGY_MOVES="$TOPOLOGY_TMP_ROOT/moves.kv"
TOPOLOGY_MOVE_MAP="$TOPOLOGY_TMP_ROOT/move-map.tsv"
TOPOLOGY_CANDIDATE="$TOPOLOGY_TMP_ROOT/selector.candidate"
TOPOLOGY_CANDIDATE_ROWS="$TOPOLOGY_TMP_ROOT/selector-candidate-rows.tsv"
TOPOLOGY_APPLY_LOG="$TOPOLOGY_TMP_ROOT/selector-apply.log"
TOPOLOGY_ROLLBACK_LOG="$TOPOLOGY_TMP_ROOT/rollback.log"
TOPOLOGY_TXN_DIR="$TOPOLOGY_TMP_ROOT/transaction"
TOPOLOGY_PLAN_TMP="$TOPOLOGY_TMP_ROOT/plan.kv"
TOPOLOGY_STATE_TMP="$TOPOLOGY_TMP_ROOT/state.kv"
TOPOLOGY_ACK_TMP="$TOPOLOGY_TMP_ROOT/ack.kv"
TOPOLOGY_TXN_ACTIVE=false
TOPOLOGY_TXN_COMMITTED=false
TOPOLOGY_SELECTOR_CHANGED=false
TOPOLOGY_DIRECT_CHANGED=false
TOPOLOGY_OLD_STATE_EXISTED=false
TOPOLOGY_OLD_PLAN_EXISTED=false
TOPOLOGY_OLD_ACK_EXISTED=false

router_topology_transaction_rollback() {
    router_topology_rb_rc=0
    if [ "$TOPOLOGY_SELECTOR_CHANGED" = true ] && [ -f "$TOPOLOGY_TXN_DIR/selector.before" ]; then
        router_topology_atomic_write "$TOPOLOGY_TXN_DIR/selector.before" "$TOPOLOGY_SELECTOR_FILE" 600 || router_topology_rb_rc=1
        if [ "$router_topology_rb_rc" -eq 0 ]; then
            "$TOPOLOGY_SELECTOR_APPLY" start >> "$TOPOLOGY_ROLLBACK_LOG" 2>&1 || router_topology_rb_rc=1
        fi
        if [ "$router_topology_rb_rc" -eq 0 ]; then
            mkdir -p "$TOPOLOGY_TMP_ROOT/rollback-verify" || router_topology_rb_rc=1
        fi
        if [ "$router_topology_rb_rc" -eq 0 ]; then
            router_topology_verify_selector_runtime "$TOPOLOGY_SELECTOR_FILE" "$TOPOLOGY_SELECTOR_TABLE" "${TOPOLOGY_peer_count:-0}" '' "$TOPOLOGY_TMP_ROOT/rollback-verify" >> "$TOPOLOGY_ROLLBACK_LOG" 2>&1 || router_topology_rb_rc=1
        fi
    fi
    if [ "$TOPOLOGY_DIRECT_CHANGED" = true ] && [ -x "$TOPOLOGY_DIRECT_MODE_HELPER" ]; then
        ROUTER_WGPAY_DIRECT_CONFIG="$TOPOLOGY_CONFIG" "$TOPOLOGY_DIRECT_MODE_HELPER" --disable topology_transaction_rollback "$TOPOLOGY_msg_source_generation" "$TOPOLOGY_msg_generation" >> "$TOPOLOGY_ROLLBACK_LOG" 2>&1 || router_topology_rb_rc=1
    fi
    router_topology_restore_file_state "$TOPOLOGY_OLD_STATE_EXISTED" "$TOPOLOGY_TXN_DIR/state.before" "$TOPOLOGY_STATE_FILE" 600 || router_topology_rb_rc=1
    router_topology_restore_file_state "$TOPOLOGY_OLD_PLAN_EXISTED" "$TOPOLOGY_TXN_DIR/plan.before" "$TOPOLOGY_PLAN_FILE" 600 || router_topology_rb_rc=1
    router_topology_restore_file_state "$TOPOLOGY_OLD_ACK_EXISTED" "$TOPOLOGY_TXN_DIR/ack.before" "$TOPOLOGY_ACK_FILE" 600 || router_topology_rb_rc=1
    TOPOLOGY_TXN_ACTIVE=false
    return "$router_topology_rb_rc"
}

router_topology_cleanup() {
    router_topology_cleanup_rc="$1"
    trap - EXIT HUP INT TERM
    if [ "$TOPOLOGY_TXN_ACTIVE" = true ] && [ "$TOPOLOGY_TXN_COMMITTED" != true ]; then
        router_topology_transaction_rollback >/dev/null 2>&1 || true
    fi
    rm -rf "$TOPOLOGY_TMP_ROOT"
    exit "$router_topology_cleanup_rc"
}
trap 'router_topology_cleanup $?' EXIT HUP INT TERM
mkdir -p "$TOPOLOGY_TMP_ROOT" "$TOPOLOGY_TXN_DIR" || exit 70

# Read no more than the contract limit plus one byte.
dd bs=$((TOPOLOGY_INPUT_MAX_BYTES + 1)) count=1 of="$TOPOLOGY_RAW" 2>/dev/null
TOPOLOGY_INPUT_BYTES="$(wc -c < "$TOPOLOGY_RAW" | tr -d ' ')"
if [ "$TOPOLOGY_INPUT_BYTES" -gt "$TOPOLOGY_INPUT_MAX_BYTES" ]; then
    router_topology_reject input_too_large "$TOPOLOGY_INPUT_BYTES" 65
    exit $?
fi
[ "$TOPOLOGY_INPUT_BYTES" -gt 0 ] || { router_topology_reject empty_input none 65; exit $?; }
if LC_ALL=C grep -n '[ 	
]' "$TOPOLOGY_RAW" >/dev/null 2>&1; then
    router_topology_reject whitespace_forbidden input 65
    exit $?
fi

TOPOLOGY_msg_schema=''
TOPOLOGY_msg_generation=''
TOPOLOGY_msg_mode=''
TOPOLOGY_msg_source_generation=''
TOPOLOGY_msg_healthy_slots=''
TOPOLOGY_msg_exhausted_slots=''
TOPOLOGY_msg_healthy_selectors=''
TOPOLOGY_msg_exhausted_selectors=''
TOPOLOGY_msg_created_epoch=''
TOPOLOGY_msg_confirm=''
TOPOLOGY_seen='|'
TOPOLOGY_parse_error=''
while IFS='=' read -r TOPOLOGY_key TOPOLOGY_value; do
    [ -n "$TOPOLOGY_key" ] || { TOPOLOGY_parse_error=blank_key; break; }
    case "$TOPOLOGY_seen" in *"|${TOPOLOGY_key}|"*) TOPOLOGY_parse_error="duplicate_${TOPOLOGY_key}"; break;; esac
    TOPOLOGY_seen="${TOPOLOGY_seen}${TOPOLOGY_key}|"
    case "$TOPOLOGY_key" in
        schema) TOPOLOGY_msg_schema="$TOPOLOGY_value" ;;
        generation) TOPOLOGY_msg_generation="$TOPOLOGY_value" ;;
        mode) TOPOLOGY_msg_mode="$TOPOLOGY_value" ;;
        source_vm101_generation) TOPOLOGY_msg_source_generation="$TOPOLOGY_value" ;;
        healthy_slots) TOPOLOGY_msg_healthy_slots="$TOPOLOGY_value" ;;
        exhausted_slots) TOPOLOGY_msg_exhausted_slots="$TOPOLOGY_value" ;;
        healthy_selectors) TOPOLOGY_msg_healthy_selectors="$TOPOLOGY_value" ;;
        exhausted_selectors) TOPOLOGY_msg_exhausted_selectors="$TOPOLOGY_value" ;;
        created_epoch) TOPOLOGY_msg_created_epoch="$TOPOLOGY_value" ;;
        confirm_sha256) TOPOLOGY_msg_confirm="$TOPOLOGY_value" ;;
        *) TOPOLOGY_parse_error="unknown_${TOPOLOGY_key}"; break ;;
    esac
done < "$TOPOLOGY_RAW"
if [ -n "$TOPOLOGY_parse_error" ]; then
    router_topology_reject parse_error "$TOPOLOGY_parse_error" 66
    exit $?
fi

[ "$TOPOLOGY_msg_schema" = "$TOPOLOGY_SCHEMA" ] || { router_topology_reject schema_unsupported "$TOPOLOGY_msg_schema" 66; exit $?; }
printf '%s' "$TOPOLOGY_msg_generation" | grep -Eq '^[0-9]{12}$' || { router_topology_reject generation_invalid "$TOPOLOGY_msg_generation" 66; exit $?; }
case "$TOPOLOGY_msg_mode" in SLOT_EXHAUSTED|NORMAL) ;; *) router_topology_reject mode_invalid "$TOPOLOGY_msg_mode" 66; exit $?;; esac
printf '%s' "$TOPOLOGY_msg_source_generation" | grep -Eq '^[A-Za-z0-9_.:-]{1,128}$' || { router_topology_reject source_generation_invalid "$TOPOLOGY_msg_source_generation" 66; exit $?; }
printf '%s' "$TOPOLOGY_msg_created_epoch" | grep -Eq '^[0-9]{1,12}$' || { router_topology_reject created_epoch_invalid "$TOPOLOGY_msg_created_epoch" 66; exit $?; }
printf '%s' "$TOPOLOGY_msg_confirm" | grep -Eq '^[0-9a-f]{64}$' || { router_topology_reject confirm_sha256_invalid "$TOPOLOGY_msg_confirm" 66; exit $?; }
router_topology_csv_validate_subsequence "$TOPOLOGY_msg_healthy_slots" "$TOPOLOGY_CANONICAL_SLOTS" true || { router_topology_reject healthy_slots_invalid "$TOPOLOGY_msg_healthy_slots" 66; exit $?; }
router_topology_csv_validate_subsequence "$TOPOLOGY_msg_exhausted_slots" "$TOPOLOGY_CANONICAL_SLOTS" true || { router_topology_reject exhausted_slots_invalid "$TOPOLOGY_msg_exhausted_slots" 66; exit $?; }
router_topology_csv_validate_subsequence "$TOPOLOGY_msg_healthy_selectors" "$TOPOLOGY_CANONICAL_SELECTORS" true || { router_topology_reject healthy_selectors_invalid "$TOPOLOGY_msg_healthy_selectors" 66; exit $?; }
router_topology_csv_validate_subsequence "$TOPOLOGY_msg_exhausted_selectors" "$TOPOLOGY_CANONICAL_SELECTORS" true || { router_topology_reject exhausted_selectors_invalid "$TOPOLOGY_msg_exhausted_selectors" 66; exit $?; }
router_topology_sets_complete_disjoint "$TOPOLOGY_msg_healthy_slots" "$TOPOLOGY_msg_exhausted_slots" "$TOPOLOGY_CANONICAL_SLOTS" || { router_topology_reject slot_sets_not_complete_disjoint sets 66; exit $?; }
router_topology_sets_complete_disjoint "$TOPOLOGY_msg_healthy_selectors" "$TOPOLOGY_msg_exhausted_selectors" "$TOPOLOGY_CANONICAL_SELECTORS" || { router_topology_reject selector_sets_not_complete_disjoint sets 66; exit $?; }
router_topology_validate_slot_selector_alignment "$TOPOLOGY_msg_healthy_slots" "$TOPOLOGY_msg_exhausted_slots" "$TOPOLOGY_msg_healthy_selectors" "$TOPOLOGY_msg_exhausted_selectors" || { router_topology_reject slot_selector_mapping_invalid sets 66; exit $?; }
if [ "$TOPOLOGY_msg_mode" = NORMAL ]; then
    [ "$TOPOLOGY_msg_healthy_slots" = "$TOPOLOGY_CANONICAL_SLOTS" ] && [ -z "$TOPOLOGY_msg_exhausted_slots" ] && [ "$TOPOLOGY_msg_healthy_selectors" = "$TOPOLOGY_CANONICAL_SELECTORS" ] && [ -z "$TOPOLOGY_msg_exhausted_selectors" ] || { router_topology_reject normal_sets_invalid sets 66; exit $?; }
else
    [ -n "$TOPOLOGY_msg_exhausted_slots" ] && [ -n "$TOPOLOGY_msg_exhausted_selectors" ] || { router_topology_reject exhausted_sets_empty sets 66; exit $?; }
fi

{
    printf 'schema=%s\n' "$TOPOLOGY_msg_schema"
    printf 'generation=%s\n' "$TOPOLOGY_msg_generation"
    printf 'mode=%s\n' "$TOPOLOGY_msg_mode"
    printf 'source_vm101_generation=%s\n' "$TOPOLOGY_msg_source_generation"
    printf 'healthy_slots=%s\n' "$TOPOLOGY_msg_healthy_slots"
    printf 'exhausted_slots=%s\n' "$TOPOLOGY_msg_exhausted_slots"
    printf 'healthy_selectors=%s\n' "$TOPOLOGY_msg_healthy_selectors"
    printf 'exhausted_selectors=%s\n' "$TOPOLOGY_msg_exhausted_selectors"
    printf 'created_epoch=%s\n' "$TOPOLOGY_msg_created_epoch"
} > "$TOPOLOGY_BODY"
TOPOLOGY_payload_sha="$(sha256sum "$TOPOLOGY_BODY" | awk '{print $1}')"
[ "$TOPOLOGY_payload_sha" = "$TOPOLOGY_msg_confirm" ] || { router_topology_reject confirm_sha256_mismatch "$TOPOLOGY_payload_sha" 67; exit $?; }
cat "$TOPOLOGY_BODY" > "$TOPOLOGY_EXPECTED"
printf 'confirm_sha256=%s\n' "$TOPOLOGY_msg_confirm" >> "$TOPOLOGY_EXPECTED"
cmp -s "$TOPOLOGY_RAW" "$TOPOLOGY_EXPECTED" || { router_topology_reject noncanonical_document input 67; exit $?; }

mkdir -p "$(dirname "$TOPOLOGY_LOCK_FILE")" "$TOPOLOGY_STATE_DIR" || exit 70
chmod 700 "$TOPOLOGY_STATE_DIR" 2>/dev/null || true
exec 9>"$TOPOLOGY_LOCK_FILE"
flock -n 9 || { router_topology_reject operation_locked lock 75; exit $?; }

TOPOLOGY_previous_generation="$(router_topology_kv_get accepted_generation "$TOPOLOGY_STATE_FILE")"
TOPOLOGY_previous_payload="$(router_topology_kv_get payload_sha256 "$TOPOLOGY_STATE_FILE")"
if [ -n "$TOPOLOGY_previous_generation" ]; then
    TOPOLOGY_cmp="$(router_topology_generation_compare "$TOPOLOGY_msg_generation" "$TOPOLOGY_previous_generation")"
    if [ "$TOPOLOGY_cmp" = '-1' ]; then
        router_topology_reject older_generation "${TOPOLOGY_msg_generation}_lt_${TOPOLOGY_previous_generation}" 68
        exit $?
    fi
    if [ "$TOPOLOGY_cmp" = '0' ]; then
        if [ "$TOPOLOGY_previous_payload" != "$TOPOLOGY_payload_sha" ]; then
            router_topology_reject generation_payload_conflict "$TOPOLOGY_msg_generation" 69
            exit $?
        fi
        [ -f "$TOPOLOGY_ACK_FILE" ] || { router_topology_reject replay_ack_missing "$TOPOLOGY_msg_generation" 70; exit $?; }
        cat "$TOPOLOGY_ACK_FILE"
        exit 0
    fi
fi

[ -r "$TOPOLOGY_SELECTOR_FILE" ] || { router_topology_reject selector_file_missing "$TOPOLOGY_SELECTOR_FILE" 70; exit $?; }
router_topology_selector_to_rows "$TOPOLOGY_SELECTOR_FILE" "$TOPOLOGY_ROWS"
TOPOLOGY_selector_parse_rc=$?
[ "$TOPOLOGY_selector_parse_rc" -eq 0 ] || { router_topology_reject selector_parse_failed "$TOPOLOGY_selector_parse_rc" 71; exit $?; }
TOPOLOGY_peer_count="$(awk 'END{print NR+0}' "$TOPOLOGY_ROWS")"
TOPOLOGY_selector_sha="$(sha256sum "$TOPOLOGY_SELECTOR_FILE" | awk '{print $1}')"
: > "$TOPOLOGY_COUNTS"
for TOPOLOGY_cls in cs1 cs2 cs3 cs4 cs5; do
    TOPOLOGY_cls_count="$(router_topology_count_class "$TOPOLOGY_ROWS" "$TOPOLOGY_cls")"
    printf 'counts.before.%s=%s\n' "$TOPOLOGY_cls" "$TOPOLOGY_cls_count" >> "$TOPOLOGY_COUNTS"
    printf 'counts.after.%s=%s\n' "$TOPOLOGY_cls" "$TOPOLOGY_cls_count" >> "$TOPOLOGY_COUNTS"
done
: > "$TOPOLOGY_MOVES"
: > "$TOPOLOGY_MOVE_MAP"
TOPOLOGY_moved=0
TOPOLOGY_remaining=0
TOPOLOGY_result=PLANNED
if [ "$TOPOLOGY_msg_mode" = SLOT_EXHAUSTED ] && [ -z "$TOPOLOGY_msg_healthy_selectors" ]; then
    TOPOLOGY_result=DIRECT_REQUIRED
    TOPOLOGY_remaining="$(awk -F '\t' -v exhausted="$TOPOLOGY_msg_exhausted_selectors" '
        function has(csv,item, a,n,i){n=split(csv,a,",");for(i=1;i<=n;i++)if(a[i]==item)return 1;return 0}
        has(exhausted,$3){n++} END{print n+0}
    ' "$TOPOLOGY_ROWS")"
elif [ "$TOPOLOGY_msg_mode" = SLOT_EXHAUSTED ]; then
    while IFS="$(printf '\t')" read -r TOPOLOGY_sortkey TOPOLOGY_ip TOPOLOGY_from_cls TOPOLOGY_from_tag; do
        router_topology_csv_contains "$TOPOLOGY_msg_exhausted_selectors" "$TOPOLOGY_from_cls" || continue
        TOPOLOGY_to_cls="$(router_topology_choose_min_selector "$TOPOLOGY_msg_healthy_selectors" "$TOPOLOGY_COUNTS")" || { router_topology_reject planner_no_healthy_selector planner 72; exit $?; }
        TOPOLOGY_to_tag="$(router_topology_target_for_selector "$TOPOLOGY_to_cls")" || { router_topology_reject planner_target_missing "$TOPOLOGY_to_cls" 72; exit $?; }
        TOPOLOGY_moved=$((TOPOLOGY_moved + 1))
        TOPOLOGY_move_index="$(printf '%04d' "$TOPOLOGY_moved")"
        printf 'move.%s.tunnel_ip=%s\n' "$TOPOLOGY_move_index" "$TOPOLOGY_ip" >> "$TOPOLOGY_MOVES"
        printf 'move.%s.from_selector=%s\n' "$TOPOLOGY_move_index" "$TOPOLOGY_from_cls" >> "$TOPOLOGY_MOVES"
        printf 'move.%s.from_target=%s\n' "$TOPOLOGY_move_index" "$TOPOLOGY_from_tag" >> "$TOPOLOGY_MOVES"
        printf 'move.%s.to_selector=%s\n' "$TOPOLOGY_move_index" "$TOPOLOGY_to_cls" >> "$TOPOLOGY_MOVES"
        printf 'move.%s.to_target=%s\n' "$TOPOLOGY_move_index" "$TOPOLOGY_to_tag" >> "$TOPOLOGY_MOVES"
        printf '%s\t%s\t%s\n' "$TOPOLOGY_ip" "$TOPOLOGY_to_cls" "$TOPOLOGY_to_tag" >> "$TOPOLOGY_MOVE_MAP"
        router_topology_increment_count "$TOPOLOGY_COUNTS" "counts.after.${TOPOLOGY_to_cls}" || exit 72
        router_topology_decrement_count "$TOPOLOGY_COUNTS" "counts.after.${TOPOLOGY_from_cls}" || exit 72
    done < "$TOPOLOGY_ROWS"
fi

{
    printf 'schema=%s\n' "$TOPOLOGY_PLAN_SCHEMA"
    printf 'result=%s\n' "$TOPOLOGY_result"
    printf 'generation=%s\n' "$TOPOLOGY_msg_generation"
    printf 'payload_sha256=%s\n' "$TOPOLOGY_payload_sha"
    printf 'mode=%s\n' "$TOPOLOGY_msg_mode"
    printf 'source_vm101_generation=%s\n' "$TOPOLOGY_msg_source_generation"
    printf 'selector_file=%s\n' "$TOPOLOGY_SELECTOR_FILE"
    printf 'selector_sha256_before=%s\n' "$TOPOLOGY_selector_sha"
    printf 'peer_count=%s\n' "$TOPOLOGY_peer_count"
    printf 'allowed_selectors=%s\n' "$TOPOLOGY_msg_healthy_selectors"
    printf 'exhausted_selectors=%s\n' "$TOPOLOGY_msg_exhausted_selectors"
    printf 'planned_moved_peer_count=%s\n' "$TOPOLOGY_moved"
    printf 'planned_exhausted_rows_remaining=%s\n' "$TOPOLOGY_remaining"
    cat "$TOPOLOGY_COUNTS"
    cat "$TOPOLOGY_MOVES"
} > "$TOPOLOGY_PLAN_TMP"
TOPOLOGY_plan_sha="$(sha256sum "$TOPOLOGY_PLAN_TMP" | awk '{print $1}')"

router_topology_emit_failed_ack() {
    router_topology_fail_reason="$1"
    router_topology_fail_detail="$(router_topology_sanitize_detail "${2:-}")"
    router_topology_fail_rollback_performed="$3"
    router_topology_fail_rollback_result="$4"
    printf '%s\n' \
        "schema=${TOPOLOGY_ACK_SCHEMA}" \
        'result=FAILED' \
        "reason=${router_topology_fail_reason}" \
        "detail=${router_topology_fail_detail}" \
        "attempted_generation=${TOPOLOGY_msg_generation}" \
        "payload_sha256=${TOPOLOGY_payload_sha}" \
        "rollback_performed=${router_topology_fail_rollback_performed}" \
        "rollback_result=${router_topology_fail_rollback_result}"
}

router_topology_snapshot_previous_file() {
    router_topology_snapshot_src="$1"
    router_topology_snapshot_dst="$2"
    router_topology_snapshot_flag="$3"
    if [ -f "$router_topology_snapshot_src" ]; then
        cp "$router_topology_snapshot_src" "$router_topology_snapshot_dst" || return 1
        eval "$router_topology_snapshot_flag=true"
    else
        : > "$router_topology_snapshot_dst"
        eval "$router_topology_snapshot_flag=false"
    fi
}

if [ "$TOPOLOGY_TXN_ACTIVE" != true ]; then
    router_topology_snapshot_previous_file "$TOPOLOGY_STATE_FILE" "$TOPOLOGY_TXN_DIR/state.before" TOPOLOGY_OLD_STATE_EXISTED || exit 76
    router_topology_snapshot_previous_file "$TOPOLOGY_PLAN_FILE" "$TOPOLOGY_TXN_DIR/plan.before" TOPOLOGY_OLD_PLAN_EXISTED || exit 76
    router_topology_snapshot_previous_file "$TOPOLOGY_ACK_FILE" "$TOPOLOGY_TXN_DIR/ack.before" TOPOLOGY_OLD_ACK_EXISTED || exit 76
    TOPOLOGY_TXN_ACTIVE=true
fi

TOPOLOGY_selector_sha_after="$TOPOLOGY_selector_sha"
TOPOLOGY_apply_performed=false
TOPOLOGY_exhausted_remaining="$TOPOLOGY_remaining"
TOPOLOGY_final_result=PASS

if [ "$TOPOLOGY_result" = DIRECT_REQUIRED ]; then
    [ -x "$TOPOLOGY_DIRECT_MODE_HELPER" ] || {
        router_topology_emit_failed_ack direct_helper_missing "$TOPOLOGY_DIRECT_MODE_HELPER" false NOT_REQUIRED
        exit 73
    }
    TOPOLOGY_DIRECT_LOG="$TOPOLOGY_TMP_ROOT/direct-mode.log"
    ROUTER_WGPAY_DIRECT_CONFIG="$TOPOLOGY_CONFIG" ROUTER_WGPAY_DIRECT_POLICY_ENABLED="$TOPOLOGY_DIRECT_POLICY_ENABLED" "$TOPOLOGY_DIRECT_MODE_HELPER" --request DIRECT_REQUIRED "$TOPOLOGY_msg_source_generation" "$TOPOLOGY_msg_generation" > "$TOPOLOGY_DIRECT_LOG" 2>&1
    TOPOLOGY_direct_rc=$?
    if [ "$TOPOLOGY_direct_rc" -ne 0 ]; then
        router_topology_emit_failed_ack direct_helper_failed "$TOPOLOGY_direct_rc" false NOT_REQUIRED
        cat "$TOPOLOGY_DIRECT_LOG" >&2
        exit 73
    fi
    TOPOLOGY_direct_result="$(awk -F= '$1=="RESULT"{print substr($0,index($0,"=")+1)}' "$TOPOLOGY_DIRECT_LOG" | tail -n1)"
    TOPOLOGY_direct_changed="$(awk -F= '$1=="DIRECT_MODE_CHANGED"{print substr($0,index($0,"=")+1)}' "$TOPOLOGY_DIRECT_LOG" | tail -n1)"
    case "$TOPOLOGY_direct_result" in NOOP_DIRECT_POLICY_DISABLED|NOOP_DIRECT_ALREADY_ACTIVE|PASS_DIRECT_MODE_ENABLED) ;; *)
        router_topology_emit_failed_ack direct_helper_result_invalid "$TOPOLOGY_direct_result" false NOT_REQUIRED
        exit 73
        ;;
    esac
    [ "$TOPOLOGY_direct_changed" = true ] && TOPOLOGY_DIRECT_CHANGED=true
    TOPOLOGY_final_result=DIRECT_REQUIRED
elif [ "$TOPOLOGY_msg_mode" = SLOT_EXHAUSTED ]; then
    router_topology_build_selector_candidate "$TOPOLOGY_SELECTOR_FILE" "$TOPOLOGY_MOVE_MAP" "$TOPOLOGY_CANDIDATE" || {
        router_topology_emit_failed_ack selector_candidate_build_failed candidate false NOT_REQUIRED
        exit 74
    }
    router_topology_selector_to_rows "$TOPOLOGY_CANDIDATE" "$TOPOLOGY_CANDIDATE_ROWS" || {
        router_topology_emit_failed_ack selector_candidate_parse_failed candidate false NOT_REQUIRED
        exit 74
    }
    TOPOLOGY_candidate_count="$(awk 'END{print NR+0}' "$TOPOLOGY_CANDIDATE_ROWS")"
    [ "$TOPOLOGY_candidate_count" -eq "$TOPOLOGY_peer_count" ] || {
        router_topology_emit_failed_ack selector_candidate_peer_count_mismatch "$TOPOLOGY_candidate_count" false NOT_REQUIRED
        exit 74
    }
    TOPOLOGY_exhausted_remaining="$(router_topology_count_exhausted_rows "$TOPOLOGY_CANDIDATE_ROWS" "$TOPOLOGY_msg_exhausted_selectors")"
    [ "$TOPOLOGY_exhausted_remaining" -eq 0 ] || {
        router_topology_emit_failed_ack selector_candidate_exhausted_rows_remaining "$TOPOLOGY_exhausted_remaining" false NOT_REQUIRED
        exit 74
    }
    TOPOLOGY_selector_sha_after="$(sha256sum "$TOPOLOGY_CANDIDATE" | awk '{print $1}')"

    cp "$TOPOLOGY_SELECTOR_FILE" "$TOPOLOGY_TXN_DIR/selector.before" || {
        router_topology_emit_failed_ack selector_backup_failed selector false NOT_REQUIRED
        exit 76
    }
    if [ "${ROUTER_TOPOLOGY_TEST_FAULT:-}" = selector_write ]; then
        router_topology_emit_failed_ack selector_write_failed injected false NOT_REQUIRED
        TOPOLOGY_TXN_ACTIVE=false
        exit 77
    fi
    router_topology_atomic_write "$TOPOLOGY_CANDIDATE" "$TOPOLOGY_SELECTOR_FILE" 600 || {
        router_topology_emit_failed_ack selector_write_failed atomic false NOT_REQUIRED
        TOPOLOGY_TXN_ACTIVE=false
        exit 77
    }
    TOPOLOGY_SELECTOR_CHANGED=true

    if [ "${ROUTER_TOPOLOGY_TEST_FAULT:-}" = selector_apply ]; then
        TOPOLOGY_apply_rc=91
    else
        "$TOPOLOGY_SELECTOR_APPLY" start > "$TOPOLOGY_APPLY_LOG" 2>&1
        TOPOLOGY_apply_rc=$?
    fi
    if [ "$TOPOLOGY_apply_rc" -ne 0 ]; then
        if router_topology_transaction_rollback; then TOPOLOGY_rb=PASS; else TOPOLOGY_rb=FAILED; fi
        router_topology_emit_failed_ack selector_apply_failed "$TOPOLOGY_apply_rc" true "$TOPOLOGY_rb"
        [ "$TOPOLOGY_rb" = PASS ] && exit 78 || exit 79
    fi
    TOPOLOGY_apply_performed=true

    if [ "${ROUTER_TOPOLOGY_TEST_FAULT:-}" = verify ]; then
        TOPOLOGY_verify_rc=92
    else
        mkdir -p "$TOPOLOGY_TMP_ROOT/verify"
        router_topology_verify_selector_runtime "$TOPOLOGY_SELECTOR_FILE" "$TOPOLOGY_SELECTOR_TABLE" "$TOPOLOGY_peer_count" "$TOPOLOGY_msg_exhausted_selectors" "$TOPOLOGY_TMP_ROOT/verify"
        TOPOLOGY_verify_rc=$?
    fi
    if [ "$TOPOLOGY_verify_rc" -ne 0 ]; then
        if router_topology_transaction_rollback; then TOPOLOGY_rb=PASS; else TOPOLOGY_rb=FAILED; fi
        router_topology_emit_failed_ack selector_verify_failed "$TOPOLOGY_verify_rc" true "$TOPOLOGY_rb"
        [ "$TOPOLOGY_rb" = PASS ] && exit 80 || exit 81
    fi
fi

{
    printf 'schema=%s\n' "$TOPOLOGY_STATE_SCHEMA"
    printf 'accepted_generation=%s\n' "$TOPOLOGY_msg_generation"
    printf 'applied_generation=%s\n' "$TOPOLOGY_msg_generation"
    printf 'payload_sha256=%s\n' "$TOPOLOGY_payload_sha"
    printf 'mode=%s\n' "$TOPOLOGY_msg_mode"
    printf 'source_vm101_generation=%s\n' "$TOPOLOGY_msg_source_generation"
    printf 'healthy_slots=%s\n' "$TOPOLOGY_msg_healthy_slots"
    printf 'exhausted_slots=%s\n' "$TOPOLOGY_msg_exhausted_slots"
    printf 'allowed_selectors=%s\n' "$TOPOLOGY_msg_healthy_selectors"
    printf 'exhausted_selectors=%s\n' "$TOPOLOGY_msg_exhausted_selectors"
    printf 'created_epoch=%s\n' "$TOPOLOGY_msg_created_epoch"
    printf 'received_epoch=%s\n' "$TOPOLOGY_NOW_EPOCH"
    printf 'apply_result=%s\n' "$TOPOLOGY_final_result"
    printf 'direct_policy_enabled=%s\n' "$TOPOLOGY_DIRECT_POLICY_ENABLED"
    printf 'direct_request_result=%s\n' "${TOPOLOGY_direct_result:-NOT_REQUESTED}"
    printf 'apply_performed=%s\n' "$TOPOLOGY_apply_performed"
    printf 'selector_sha256_before=%s\n' "$TOPOLOGY_selector_sha"
    printf 'selector_sha256=%s\n' "$TOPOLOGY_selector_sha_after"
    printf 'peer_count=%s\n' "$TOPOLOGY_peer_count"
    printf 'moved_peer_count=%s\n' "$TOPOLOGY_moved"
    printf 'exhausted_rows_remaining=%s\n' "$TOPOLOGY_exhausted_remaining"
    printf 'plan_sha256=%s\n' "$TOPOLOGY_plan_sha"
    for TOPOLOGY_cls in cs1 cs2 cs3 cs4 cs5; do
        printf 'counts.%s=%s\n' "$TOPOLOGY_cls" "$(router_topology_kv_get "counts.after.${TOPOLOGY_cls}" "$TOPOLOGY_COUNTS")"
    done
} > "$TOPOLOGY_STATE_TMP"

{
    printf 'schema=%s\n' "$TOPOLOGY_ACK_SCHEMA"
    printf 'result=%s\n' "$TOPOLOGY_final_result"
    printf 'direct_policy_enabled=%s\n' "$TOPOLOGY_DIRECT_POLICY_ENABLED"
    printf 'direct_request_result=%s\n' "${TOPOLOGY_direct_result:-NOT_REQUESTED}"
    printf 'accepted_generation=%s\n' "$TOPOLOGY_msg_generation"
    printf 'applied_generation=%s\n' "$TOPOLOGY_msg_generation"
    printf 'apply_performed=%s\n' "$TOPOLOGY_apply_performed"
    printf 'payload_sha256=%s\n' "$TOPOLOGY_payload_sha"
    printf 'selector_sha256_before=%s\n' "$TOPOLOGY_selector_sha"
    printf 'selector_sha256=%s\n' "$TOPOLOGY_selector_sha_after"
    printf 'plan_sha256=%s\n' "$TOPOLOGY_plan_sha"
    printf 'peer_count=%s\n' "$TOPOLOGY_peer_count"
    printf 'moved_peer_count=%s\n' "$TOPOLOGY_moved"
    printf 'exhausted_rows_remaining=%s\n' "$TOPOLOGY_exhausted_remaining"
    printf 'rollback_performed=false\n'
    printf 'rollback_result=NOT_REQUIRED\n'
    for TOPOLOGY_cls in cs1 cs2 cs3 cs4 cs5; do
        printf 'counts.%s=%s\n' "$TOPOLOGY_cls" "$(router_topology_kv_get "counts.after.${TOPOLOGY_cls}" "$TOPOLOGY_COUNTS")"
    done
} > "$TOPOLOGY_ACK_TMP"

router_topology_atomic_write "$TOPOLOGY_PLAN_TMP" "$TOPOLOGY_PLAN_FILE" 600 || TOPOLOGY_persist_rc=1
: "${TOPOLOGY_persist_rc:=0}"
[ "$TOPOLOGY_persist_rc" -ne 0 ] || router_topology_atomic_write "$TOPOLOGY_STATE_TMP" "$TOPOLOGY_STATE_FILE" 600 || TOPOLOGY_persist_rc=1
[ "$TOPOLOGY_persist_rc" -ne 0 ] || router_topology_atomic_write "$TOPOLOGY_ACK_TMP" "$TOPOLOGY_ACK_FILE" 600 || TOPOLOGY_persist_rc=1
if [ "$TOPOLOGY_persist_rc" -ne 0 ]; then
    if [ "$TOPOLOGY_TXN_ACTIVE" = true ]; then
        if router_topology_transaction_rollback; then TOPOLOGY_rb=PASS; else TOPOLOGY_rb=FAILED; fi
    else
        TOPOLOGY_rb=NOT_REQUIRED
    fi
    router_topology_emit_failed_ack topology_state_persist_failed persist "$TOPOLOGY_apply_performed" "$TOPOLOGY_rb"
    [ "$TOPOLOGY_rb" != FAILED ] && exit 82 || exit 83
fi

TOPOLOGY_TXN_COMMITTED=true
TOPOLOGY_TXN_ACTIVE=false
cat "$TOPOLOGY_ACK_FILE"
exit 0
