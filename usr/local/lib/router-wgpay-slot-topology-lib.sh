#!/bin/sh
# shellcheck shell=sh

router_topology_sanitize_detail() {
    printf '%s' "${1:-}" | tr -cd 'A-Za-z0-9_.:,/@+-' | cut -c1-160
}

router_topology_reject() {
    router_topology_reject_reason="$1"
    router_topology_reject_detail="$(router_topology_sanitize_detail "${2:-}")"
    printf '%s\n' \
        "schema=${TOPOLOGY_ACK_SCHEMA}" \
        'result=REJECTED' \
        "reason=${router_topology_reject_reason}" \
        "detail=${router_topology_reject_detail}"
    return "${3:-64}"
}

router_topology_kv_get() {
    router_topology_kv_key="$1"
    router_topology_kv_file="$2"
    [ -f "$router_topology_kv_file" ] || return 0
    awk -F= -v key="$router_topology_kv_key" '$1==key {print substr($0,index($0,"=")+1)}' "$router_topology_kv_file" | tail -n 1
}

router_topology_csv_contains() {
    router_topology_csv_list="$1"
    router_topology_csv_item="$2"
    [ -n "$router_topology_csv_list" ] || return 1
    printf '%s\n' "$router_topology_csv_list" | awk -F, -v item="$router_topology_csv_item" '{for(i=1;i<=NF;i++) if($i==item) found=1} END{exit found?0:1}'
}

router_topology_csv_validate_subsequence() {
    router_topology_csv_value="$1"
    router_topology_csv_canonical="$2"
    router_topology_csv_allow_empty="$3"
    [ -n "$router_topology_csv_value" ] || [ "$router_topology_csv_allow_empty" = true ]
    [ -n "$router_topology_csv_value" ] || return 0
    printf '%s\n' "$router_topology_csv_value" | awk -F, -v canonical="$router_topology_csv_canonical" '
        BEGIN {
            n=split(canonical,c,",");
            for(i=1;i<=n;i++) idx[c[i]]=i;
        }
        {
            last=0;
            for(i=1;i<=NF;i++) {
                if($i=="" || !($i in idx) || seen[$i] || idx[$i] <= last) exit 1;
                seen[$i]=1; last=idx[$i];
            }
        }
    '
}

router_topology_sets_complete_disjoint() {
    router_topology_set_a="$1"
    router_topology_set_b="$2"
    router_topology_set_canonical="$3"
    router_topology_old_ifs="$IFS"
    IFS=,
    for router_topology_set_item in $router_topology_set_canonical; do
        router_topology_set_hits=0
        router_topology_csv_contains "$router_topology_set_a" "$router_topology_set_item" && router_topology_set_hits=$((router_topology_set_hits + 1))
        router_topology_csv_contains "$router_topology_set_b" "$router_topology_set_item" && router_topology_set_hits=$((router_topology_set_hits + 1))
        if [ "$router_topology_set_hits" -ne 1 ]; then
            IFS="$router_topology_old_ifs"
            return 1
        fi
    done
    IFS="$router_topology_old_ifs"
    return 0
}

router_topology_selector_for_slot() {
    case "$1" in
        egress1) printf '%s\n' "$TOPOLOGY_SLOT_egress1_SELECTOR" ;;
        egress2) printf '%s\n' "$TOPOLOGY_SLOT_egress2_SELECTOR" ;;
        egress3) printf '%s\n' "$TOPOLOGY_SLOT_egress3_SELECTOR" ;;
        egress4) printf '%s\n' "$TOPOLOGY_SLOT_egress4_SELECTOR" ;;
        egress5) printf '%s\n' "$TOPOLOGY_SLOT_egress5_SELECTOR" ;;
        *) return 1 ;;
    esac
}

router_topology_target_for_selector() {
    case "$1" in
        cs1) printf '%s\n' "$TOPOLOGY_SLOT_egress3_TARGET" ;;
        cs2) printf '%s\n' "$TOPOLOGY_SLOT_egress4_TARGET" ;;
        cs3) printf '%s\n' "$TOPOLOGY_SLOT_egress5_TARGET" ;;
        cs4) printf '%s\n' "$TOPOLOGY_SLOT_egress1_TARGET" ;;
        cs5) printf '%s\n' "$TOPOLOGY_SLOT_egress2_TARGET" ;;
        *) return 1 ;;
    esac
}

router_topology_validate_slot_selector_alignment() {
    router_topology_align_healthy_slots="$1"
    router_topology_align_exhausted_slots="$2"
    router_topology_align_healthy_selectors="$3"
    router_topology_align_exhausted_selectors="$4"
    router_topology_align_old_ifs="$IFS"
    IFS=,
    for router_topology_align_slot in $TOPOLOGY_CANONICAL_SLOTS; do
        router_topology_align_selector="$(router_topology_selector_for_slot "$router_topology_align_slot")" || {
            IFS="$router_topology_align_old_ifs"
            return 1
        }
        if router_topology_csv_contains "$router_topology_align_healthy_slots" "$router_topology_align_slot"; then
            router_topology_csv_contains "$router_topology_align_healthy_selectors" "$router_topology_align_selector" || {
                IFS="$router_topology_align_old_ifs"
                return 1
            }
        else
            router_topology_csv_contains "$router_topology_align_exhausted_slots" "$router_topology_align_slot" || {
                IFS="$router_topology_align_old_ifs"
                return 1
            }
            router_topology_csv_contains "$router_topology_align_exhausted_selectors" "$router_topology_align_selector" || {
                IFS="$router_topology_align_old_ifs"
                return 1
            }
        fi
    done
    IFS="$router_topology_align_old_ifs"
    return 0
}

router_topology_generation_compare() {
    # Prints -1, 0 or 1. Generations are fixed-width decimal strings.
    router_topology_gen_a="$1"
    router_topology_gen_b="$2"
    if [ "$router_topology_gen_a" = "$router_topology_gen_b" ]; then
        printf '0\n'
    elif [ "$(printf '%s\n%s\n' "$router_topology_gen_a" "$router_topology_gen_b" | LC_ALL=C sort | head -n 1)" = "$router_topology_gen_a" ]; then
        printf '%s\n' '-1'
    else
        printf '1\n'
    fi
}

router_topology_atomic_write() {
    router_topology_atomic_src="$1"
    router_topology_atomic_dst="$2"
    router_topology_atomic_mode="${3:-600}"
    router_topology_atomic_dir="$(dirname "$router_topology_atomic_dst")"
    mkdir -p "$router_topology_atomic_dir" || return 1
    chmod 700 "$router_topology_atomic_dir" 2>/dev/null || true
    cp "$router_topology_atomic_src" "${router_topology_atomic_dst}.tmp.$$" || return 1
    chmod "$router_topology_atomic_mode" "${router_topology_atomic_dst}.tmp.$$" || return 1
    mv "${router_topology_atomic_dst}.tmp.$$" "$router_topology_atomic_dst"
}

router_topology_selector_to_rows() {
    router_topology_selector_file="$1"
    router_topology_rows_file="$2"
    awk '
        function ipkey(ip, a) {
            split(ip,a,".");
            return sprintf("%03d%03d%03d%03d",a[1],a[2],a[3],a[4]);
        }
        function validip(ip, a, i) {
            if (ip !~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/) return 0;
            split(ip,a,".");
            if (length(a)!=4) return 0;
            for(i=1;i<=4;i++) if(a[i] < 0 || a[i] > 255) return 0;
            return 1;
        }
        /^[[:space:]]*($|#)/ {next}
        NF != 3 {exit 41}
        !validip($1) {exit 42}
        $2 !~ /^cs[1-5]$/ {exit 43}
        seen[$1]++ {exit 44}
        {print ipkey($1) "\t" $1 "\t" $2 "\t" $3}
    ' "$router_topology_selector_file" | LC_ALL=C sort -k1,1 > "$router_topology_rows_file"
}

router_topology_count_class() {
    router_topology_count_rows="$1"
    router_topology_count_class_name="$2"
    awk -F '\t' -v cls="$router_topology_count_class_name" '$3==cls {n++} END{print n+0}' "$router_topology_count_rows"
}

router_topology_choose_min_selector() {
    router_topology_choose_allowed="$1"
    router_topology_choose_counts_file="$2"
    router_topology_choose_best=''
    router_topology_choose_best_count=''
    router_topology_choose_old_ifs="$IFS"
    IFS=,
    for router_topology_choose_cls in $TOPOLOGY_CANONICAL_SELECTORS; do
        router_topology_csv_contains "$router_topology_choose_allowed" "$router_topology_choose_cls" || continue
        router_topology_choose_count="$(router_topology_kv_get "counts.after.${router_topology_choose_cls}" "$router_topology_choose_counts_file")"
        [ -n "$router_topology_choose_count" ] || router_topology_choose_count=0
        if [ -z "$router_topology_choose_best" ] || [ "$router_topology_choose_count" -lt "$router_topology_choose_best_count" ]; then
            router_topology_choose_best="$router_topology_choose_cls"
            router_topology_choose_best_count="$router_topology_choose_count"
        fi
    done
    IFS="$router_topology_choose_old_ifs"
    [ -n "$router_topology_choose_best" ] || return 1
    printf '%s\n' "$router_topology_choose_best"
}

router_topology_decrement_count() {
    router_topology_dec_file="$1"
    router_topology_dec_key="$2"
    router_topology_dec_current="$(router_topology_kv_get "$router_topology_dec_key" "$router_topology_dec_file")"
    [ -n "$router_topology_dec_current" ] || return 1
    [ "$router_topology_dec_current" -gt 0 ] || return 1
    router_topology_dec_next=$((router_topology_dec_current - 1))
    awk -F= -v key="$router_topology_dec_key" -v value="$router_topology_dec_next" '
        BEGIN {OFS="="}
        $1==key {$0=key OFS value; changed=1}
        {print}
        END {if(!changed) exit 1}
    ' "$router_topology_dec_file" > "${router_topology_dec_file}.tmp.$$" && mv "${router_topology_dec_file}.tmp.$$" "$router_topology_dec_file"
}

router_topology_increment_count() {
    router_topology_inc_file="$1"
    router_topology_inc_key="$2"
    router_topology_inc_current="$(router_topology_kv_get "$router_topology_inc_key" "$router_topology_inc_file")"
    [ -n "$router_topology_inc_current" ] || router_topology_inc_current=0
    router_topology_inc_next=$((router_topology_inc_current + 1))
    awk -F= -v key="$router_topology_inc_key" -v value="$router_topology_inc_next" '
        BEGIN {OFS="="}
        $1==key {$0=key OFS value; changed=1}
        {print}
        END {if(!changed) print key OFS value}
    ' "$router_topology_inc_file" > "${router_topology_inc_file}.tmp.$$" && mv "${router_topology_inc_file}.tmp.$$" "$router_topology_inc_file"
}

router_topology_build_selector_candidate() {
    router_topology_candidate_selector="$1"
    router_topology_candidate_moves="$2"
    router_topology_candidate_output="$3"

    # POSIX awk NR==FNR is ambiguous when the first input file is empty:
    # the first selector row is then treated as a move-map row and END exits 52.
    # An empty move map is a valid idempotent topology transition, so copy the
    # selector byte-for-byte and let the caller's exhausted-row verification
    # decide whether the no-op candidate is semantically acceptable.
    if [ ! -s "$router_topology_candidate_moves" ]; then
        cp "$router_topology_candidate_selector" "$router_topology_candidate_output"
        return $?
    fi

    awk -F '\t' '
        NR==FNR {
            if (NF != 3 || seen[$1]++) exit 51;
            to_class[$1]=$2;
            to_target[$1]=$3;
            next;
        }
        /^[[:space:]]*($|#)/ {print; next}
        {
            split($0,fields,/[[:space:]]+/);
            ip=fields[1];
            if (ip in to_class) {
                print ip " " to_class[ip] " " to_target[ip];
                applied[ip]++;
            } else {
                print;
            }
        }
        END {
            for (ip in to_class) if (applied[ip] != 1) exit 52;
        }
    ' "$router_topology_candidate_moves" "$router_topology_candidate_selector" > "$router_topology_candidate_output"
}

router_topology_count_exhausted_rows() {
    router_topology_exhausted_rows_file="$1"
    router_topology_exhausted_csv="$2"
    awk -F '\t' -v exhausted="$router_topology_exhausted_csv" '
        function has(csv,item, a,n,i){
            if(csv=="") return 0;
            n=split(csv,a,",");
            for(i=1;i<=n;i++) if(a[i]==item) return 1;
            return 0;
        }
        has(exhausted,$3){n++}
        END{print n+0}
    ' "$router_topology_exhausted_rows_file"
}

router_topology_restore_file_state() {
    router_topology_restore_existed="$1"
    router_topology_restore_backup="$2"
    router_topology_restore_destination="$3"
    router_topology_restore_mode="${4:-600}"
    if [ "$router_topology_restore_existed" = true ]; then
        router_topology_atomic_write "$router_topology_restore_backup" "$router_topology_restore_destination" "$router_topology_restore_mode"
    else
        rm -f "$router_topology_restore_destination"
    fi
}

router_topology_verify_selector_runtime() {
    router_topology_verify_selector="$1"
    router_topology_verify_table="$2"
    router_topology_verify_expected_count="$3"
    router_topology_verify_exhausted_csv="$4"
    router_topology_verify_workdir="$5"
    router_topology_verify_rows="$router_topology_verify_workdir/verify-rows.tsv"
    router_topology_verify_dump="$router_topology_verify_workdir/nft-dump.txt"

    router_topology_selector_to_rows "$router_topology_verify_selector" "$router_topology_verify_rows" || return 1
    router_topology_verify_count="$(awk 'END{print NR+0}' "$router_topology_verify_rows")"
    [ "$router_topology_verify_count" -eq "$router_topology_verify_expected_count" ] || return 2
    router_topology_verify_remaining="$(router_topology_count_exhausted_rows "$router_topology_verify_rows" "$router_topology_verify_exhausted_csv")"
    [ "$router_topology_verify_remaining" -eq 0 ] || return 3

    if [ -n "${ROUTER_TOPOLOGY_VERIFY_COMMAND:-}" ]; then
        "$ROUTER_TOPOLOGY_VERIFY_COMMAND" "$router_topology_verify_selector" "$router_topology_verify_table" "$router_topology_verify_expected_count" || return 4
        return 0
    fi

    nft list table inet "$router_topology_verify_table" > "$router_topology_verify_dump" 2>&1 || return 5
    router_topology_verify_seen=0
    while IFS="$(printf '\t')" read -r router_topology_verify_sortkey router_topology_verify_ip router_topology_verify_class router_topology_verify_tag; do
        grep -F "ip saddr ${router_topology_verify_ip} ip dscp set ${router_topology_verify_class}" "$router_topology_verify_dump" >/dev/null 2>&1 || return 6
        router_topology_verify_seen=$((router_topology_verify_seen + 1))
    done < "$router_topology_verify_rows"
    [ "$router_topology_verify_seen" -eq "$router_topology_verify_expected_count" ] || return 7
    return 0
}
