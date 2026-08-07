#!/bin/sh
set -u

MODE="${1:---dry-run}"
LIFECYCLE_CONFIG="${ROUTER_WGPAY_PEER_CONFIG:-/etc/router-wgpay-peer-lifecycle.conf}"
[ -r "$LIFECYCLE_CONFIG" ] && . "$LIFECYCLE_CONFIG"
SEL="${ROUTER_EGRESS_SELECTOR_FILE:-${PEER_ACTIVE_SELECTOR_FILE:-/etc/router-wgpay-selector.d/peers.conf}}"
APPLY="${ROUTER_EGRESS_SELECTOR_APPLY:-${PEER_SELECTOR_APPLY:-/usr/local/sbin/router-wgpay-canary-apply.sh}}"
REGISTRY_FILE="${ROUTER_EGRESS_REGISTRY_FILE:-${PEER_REGISTRY_FILE:-/etc/router-wgpay-peer-state/registry.tsv}}"
REGISTRY_SYNC="${ROUTER_EGRESS_REGISTRY_SYNC:-/usr/local/sbin/router-wgpay-peer-lifecycle.sh}"
STATE_DIR="${ROUTER_EGRESS_STATE_DIR:-/var/lib/router-wgpay-egress}"
STATE_FILE="${ROUTER_EGRESS_STATE_FILE:-${STATE_DIR}/state.kv}"
SELECTOR_LOCK="${ROUTER_EGRESS_SELECTOR_LOCK:-/var/run/router-wgpay-selector.lock}"
TOPOLOGY_STATE_FILE="${ROUTER_EGRESS_TOPOLOGY_STATE_FILE:-/var/lib/router-wgpay-topology/state.kv}"
SYN_ACTIVE_IPS="$(echo "${ROUTER_EGRESS_SYNTHETIC_ACTIVE_IPS:-}" | tr ',' ' ')"

ACTIVE_MIN_PACKETS="${ROUTER_EGRESS_ACTIVE_MIN_PACKETS:-10}"
ACTIVE_MIN_BYTES="${ROUTER_EGRESS_ACTIVE_MIN_BYTES:-16384}"
IDLE_SECONDS="${ROUTER_EGRESS_IDLE_SECONDS:-900}"
REASSIGN_COOLDOWN_SECONDS="${ROUTER_EGRESS_REASSIGN_COOLDOWN_SECONDS:-900}"

ALLOCATOR_ENABLED="${ROUTER_EGRESS_ALLOCATOR_ENABLED:-1}"
REBALANCE_PAUSED="${ROUTER_EGRESS_REBALANCE_PAUSED:-0}"
FORCE_MODE="${ROUTER_EGRESS_FORCE_MODE:-off}"
FORCE_CLASS="${ROUTER_EGRESS_FORCE_CLASS:-}"
MAINTENANCE_OVERRIDE="${ROUTER_EGRESS_MAINTENANCE_OVERRIDE:-0}"

CLASSES="cs1 cs2 cs3 cs4 cs5"
CANONICAL_CSV="cs1,cs2,cs3,cs4,cs5"
NOW="$(date +%s)"

csv_contains() {
  list="$1"
  item="$2"
  [ -n "$list" ] || return 1
  printf '%s\n' "$list" | awk -F, -v item="$item" '{for(i=1;i<=NF;i++) if($i==item) found=1} END{exit found?0:1}'
}

csv_to_words() {
  printf '%s\n' "$1" | tr ',' ' '
}

csv_validate_subsequence() {
  value="$1"
  allow_empty="$2"
  [ -n "$value" ] || [ "$allow_empty" = true ]
  [ -n "$value" ] || return 0
  printf '%s\n' "$value" | awk -F, -v canonical="$CANONICAL_CSV" '
    BEGIN {n=split(canonical,c,","); for(i=1;i<=n;i++) idx[c[i]]=i}
    {last=0; for(i=1;i<=NF;i++){if($i=="" || !($i in idx) || seen[$i] || idx[$i]<=last) exit 1; seen[$i]=1; last=idx[$i]}}
  '
}

sets_complete_disjoint() {
  allowed="$1"
  exhausted="$2"
  for cls in $CLASSES; do
    hits=0
    csv_contains "$allowed" "$cls" && hits=$((hits + 1))
    csv_contains "$exhausted" "$cls" && hits=$((hits + 1))
    [ "$hits" -eq 1 ] || return 1
  done
  return 0
}

kv_get_file() {
  key="$1"
  file="$2"
  [ -f "$file" ] || { echo ""; return 0; }
  awk -F= -v key="$key" '$1==key {print substr($0,index($0,"=")+1)}' "$file" | tail -n 1
}

target_for_class() {
  case "$1" in
    cs1) echo "canary_vpn3" ;;
    cs2) echo "canary_vpn4" ;;
    cs3) echo "canary_vpn5" ;;
    cs4) echo "canary_vpn1" ;;
    cs5) echo "canary_vpn2" ;;
    *) echo "" ;;
  esac
}

state_get() {
  key="$1"
  kv_get_file "$key" "$STATE_FILE"
}

counter_snapshot() {
  ip="$1"
  safe_ip="$(echo "$ip" | tr '.' '_')"
  nft list table inet router_egress_activity 2>/dev/null | awk -v safe="$safe_ip" '
    BEGIN {op=0; ob=0; ipk=0; ib=0}
    $0 ~ "peer_" safe "_out_vpn" {for(i=1;i<=NF;i++){if($i=="packets")op=$(i+1); if($i=="bytes")ob=$(i+1)}}
    $0 ~ "peer_" safe "_in_vpn" {for(i=1;i<=NF;i++){if($i=="packets")ipk=$(i+1); if($i=="bytes")ib=$(i+1)}}
    END {print op, ob, ipk, ib}
  '
}

is_synthetic_active() {
  ip="$1"
  for a in $SYN_ACTIVE_IPS; do
    [ "$a" = "$ip" ] && return 0
  done
  return 1
}

safe_delta() {
  cur="$1"
  prev="$2"
  [ -n "$prev" ] || prev=0
  if [ "$cur" -ge "$prev" ] 2>/dev/null; then
    echo $((cur - prev))
  else
    echo "$cur"
  fi
}

if [ "$MODE" != "--dry-run" ] && [ "$MODE" != "--apply-preview" ] && [ "$MODE" != "--state-preview" ] && [ "$MODE" != "--state-write" ] && [ "$MODE" != "--commit" ]; then
  echo "Usage: $0 --dry-run|--apply-preview|--state-preview|--state-write|--commit" >&2
  exit 64
fi

if [ "$MODE" = "--state-write" ] || [ "$MODE" = "--commit" ]; then
  mkdir -p "$(dirname "$SELECTOR_LOCK")" || exit 70
  exec 9>"$SELECTOR_LOCK"
  if ! flock -n 9; then
    printf '%s\n' \
      '{' \
      '  "schema": "router-wgpay-egress-local-v8",' \
      "  \"mode\": \"$MODE\"," \
      '  "summary": {' \
      '    "blocked": true,' \
      '    "block_reason": "selector_operation_locked",' \
      '    "action_count": 0,' \
      '    "noop": true' \
      '  }' \
      '}'
    exit 75
  fi
fi

TOPOLOGY_STATE_SOURCE=default_normal
TOPOLOGY_STATE_VALID=true
TOPOLOGY_STATE_ERROR=""
TOPOLOGY_SCHEMA=""
TOPOLOGY_MODE=NORMAL
TOPOLOGY_GENERATION=""
ALLOWED_CLASSES="$CANONICAL_CSV"
EXHAUSTED_CLASSES=""

if [ -f "$TOPOLOGY_STATE_FILE" ]; then
  TOPOLOGY_STATE_SOURCE=durable_state
  TOPOLOGY_SCHEMA="$(kv_get_file schema "$TOPOLOGY_STATE_FILE")"
  TOPOLOGY_MODE="$(kv_get_file mode "$TOPOLOGY_STATE_FILE")"
  TOPOLOGY_GENERATION="$(kv_get_file accepted_generation "$TOPOLOGY_STATE_FILE")"
  ALLOWED_CLASSES="$(kv_get_file allowed_selectors "$TOPOLOGY_STATE_FILE")"
  EXHAUSTED_CLASSES="$(kv_get_file exhausted_selectors "$TOPOLOGY_STATE_FILE")"
  [ "$TOPOLOGY_SCHEMA" = router-wgpay-slot-topology-state-v2 ] || { TOPOLOGY_STATE_VALID=false; TOPOLOGY_STATE_ERROR=schema_invalid; }
  case "$TOPOLOGY_MODE" in NORMAL|SLOT_EXHAUSTED) ;; *) TOPOLOGY_STATE_VALID=false; TOPOLOGY_STATE_ERROR=mode_invalid ;; esac
  printf '%s' "$TOPOLOGY_GENERATION" | grep -Eq '^[0-9]{12}$' || { TOPOLOGY_STATE_VALID=false; TOPOLOGY_STATE_ERROR=generation_invalid; }
  csv_validate_subsequence "$ALLOWED_CLASSES" true || { TOPOLOGY_STATE_VALID=false; TOPOLOGY_STATE_ERROR=allowed_selectors_invalid; }
  csv_validate_subsequence "$EXHAUSTED_CLASSES" true || { TOPOLOGY_STATE_VALID=false; TOPOLOGY_STATE_ERROR=exhausted_selectors_invalid; }
  sets_complete_disjoint "$ALLOWED_CLASSES" "$EXHAUSTED_CLASSES" || { TOPOLOGY_STATE_VALID=false; TOPOLOGY_STATE_ERROR=selector_sets_invalid; }
  if [ "$TOPOLOGY_MODE" = NORMAL ]; then
    [ "$ALLOWED_CLASSES" = "$CANONICAL_CSV" ] && [ -z "$EXHAUSTED_CLASSES" ] || { TOPOLOGY_STATE_VALID=false; TOPOLOGY_STATE_ERROR=normal_sets_invalid; }
  fi
fi

if [ "$TOPOLOGY_STATE_VALID" != true ]; then
  TOPOLOGY_MODE=INVALID
  TOPOLOGY_GENERATION=""
  ALLOWED_CLASSES=""
  EXHAUSTED_CLASSES=""
fi

TMP="/tmp/router-wgpay-egress-local-rows.$$"
STATE_TMP="/tmp/router-wgpay-egress-local-state.$$"
SEL_TMP="/tmp/router-wgpay-egress-local-selector.$$"
APPLY_LOG="/tmp/router-wgpay-egress-local-apply.$$.log"
REGISTRY_SYNC_LOG="/tmp/router-wgpay-egress-local-registry-sync.$$.log"
trap 'rm -f "$TMP" "$STATE_TMP" "$SEL_TMP" "$SEL_TMP.before" "$APPLY_LOG" "$REGISTRY_SYNC_LOG" "${STATE_FILE}.tmp.$$"' EXIT
: > "$TMP"

grep -Ev '^[[:space:]]*(#|$)' "$SEL" 2>/dev/null | while read -r ip cls tag rest; do
  [ -n "$ip" ] || continue

  vals="$(counter_snapshot "$ip")"
  set -- $vals
  outp="${1:-0}"
  outb="${2:-0}"
  inp="${3:-0}"
  inb="${4:-0}"

  prev_outp="$(state_get "peer.${ip}.out_packets")"
  prev_outb="$(state_get "peer.${ip}.out_bytes")"
  prev_inp="$(state_get "peer.${ip}.in_packets")"
  prev_inb="$(state_get "peer.${ip}.in_bytes")"
  prev_last_active="$(state_get "peer.${ip}.last_active_epoch")"
  prev_last_reassign="$(state_get "peer.${ip}.last_reassign_epoch")"

  [ -n "$prev_last_active" ] || prev_last_active=0
  [ -n "$prev_last_reassign" ] || prev_last_reassign=0

  delta_outp="$(safe_delta "$outp" "$prev_outp")"
  delta_outb="$(safe_delta "$outb" "$prev_outb")"
  delta_inp="$(safe_delta "$inp" "$prev_inp")"
  delta_inb="$(safe_delta "$inb" "$prev_inb")"
  delta_packets=$((delta_outp + delta_inp))
  delta_bytes=$((delta_outb + delta_inb))

  active_now=false
  active_state=false
  last_active="$prev_last_active"

  if is_synthetic_active "$ip"; then
    active_now=true
  elif [ "$delta_packets" -ge "$ACTIVE_MIN_PACKETS" ] || [ "$delta_bytes" -ge "$ACTIVE_MIN_BYTES" ]; then
    active_now=true
  fi

  if [ "$active_now" = true ]; then
    last_active="$NOW"
    active_state=true
  elif [ "$prev_last_active" -gt 0 ] 2>/dev/null && [ $((NOW - prev_last_active)) -lt "$IDLE_SECONDS" ]; then
    active_state=true
  fi

  cooldown_ok=true
  if [ "$prev_last_reassign" -gt 0 ] 2>/dev/null && [ $((NOW - prev_last_reassign)) -lt "$REASSIGN_COOLDOWN_SECONDS" ]; then
    cooldown_ok=false
  fi

  printf '%s %s %s %s %s %s %s %s %s %s %s %s %s %s\n' \
    "$ip" "$cls" "$tag" "$active_now" "$active_state" "$cooldown_ok" \
    "$outp" "$outb" "$inp" "$inb" "$delta_packets" "$delta_bytes" "$last_active" "$prev_last_reassign" >> "$TMP"
done

blocked=false
block_reason=""
fatal_topology_state=false
if [ "$TOPOLOGY_STATE_VALID" != true ]; then
  blocked=true
  fatal_topology_state=true
  block_reason="topology_state_invalid_${TOPOLOGY_STATE_ERROR}"
elif [ "$ALLOCATOR_ENABLED" != 1 ]; then
  blocked=true
  block_reason=allocator_disabled
elif [ "$FORCE_MODE" != off ]; then
  blocked=true
  if [ -n "$FORCE_CLASS" ] && ! csv_contains "$ALLOWED_CLASSES" "$FORCE_CLASS" && [ "$MAINTENANCE_OVERRIDE" != 1 ]; then
    block_reason=force_target_exhausted
  else
    block_reason=force_mode_active
  fi
elif [ "$REBALANCE_PAUSED" != 0 ]; then
  blocked=true
  block_reason=rebalance_paused
elif [ -z "$ALLOWED_CLASSES" ]; then
  blocked=true
  block_reason=no_allowed_selectors
fi

rows="$(wc -l < "$TMP" | tr -d ' ')"
active_now_count="$(awk '$4=="true"{c++} END{print c+0}' "$TMP")"
active_state_count="$(awk '$5=="true"{c++} END{print c+0}' "$TMP")"
idle_count="$(awk '$5!="true"{c++} END{print c+0}' "$TMP")"
exhausted_row_count="$(awk -v exhausted="$EXHAUSTED_CLASSES" '
  function has(csv,item,a,n,i){if(csv=="")return 0;n=split(csv,a,",");for(i=1;i<=n;i++)if(a[i]==item)return 1;return 0}
  has(exhausted,$2){n++} END{print n+0}
' "$TMP")"

min_class=""
max_class=""
min_count=999
max_count=-1
for cls in $CLASSES; do
  csv_contains "$ALLOWED_CLASSES" "$cls" || continue
  c="$(awk -v cls="$cls" '$2==cls{n++} END{print n+0}' "$TMP")"
  if [ "$c" -lt "$min_count" ]; then min_count="$c"; min_class="$cls"; fi
  if [ "$c" -gt "$max_count" ]; then max_count="$c"; max_class="$cls"; fi
done
[ -n "$min_class" ] || min_count=0
[ -n "$max_class" ] || max_count=0

action_count=0
action_ip=""
action_from_class=""
action_from_target=""
action_to_class=""
action_to_target=""
action_reason=""

if [ "$blocked" = false ]; then
  if [ "$exhausted_row_count" -gt 0 ]; then
    movable="$(awk -v exhausted="$EXHAUSTED_CLASSES" '
      function has(csv,item,a,n,i){if(csv=="")return 0;n=split(csv,a,",");for(i=1;i<=n;i++)if(a[i]==item)return 1;return 0}
      function ipkey(ip,a){split(ip,a,".");return sprintf("%03d%03d%03d%03d",a[1],a[2],a[3],a[4])}
      has(exhausted,$2){print ipkey($1) " " $0}
    ' "$TMP" | LC_ALL=C sort | head -n 1 | sed 's/^[^ ]* //')"
    if [ -n "$movable" ]; then
      set -- $movable
      action_ip="$1"
      action_from_class="$2"
      action_from_target="$3"
      action_to_class="$min_class"
      action_to_target="$(target_for_class "$min_class")"
      action_reason=exhausted_selector_reconciliation
      action_count=1
    else
      action_reason=exhausted_row_selection_failed
    fi
  else
    diff=$((max_count - min_count))
    if [ "$diff" -gt 1 ]; then
      movable="$(awk -v cls="$max_class" '$2==cls && $5!="true" && $6=="true"{print; exit}' "$TMP")"
      if [ -n "$movable" ]; then
        set -- $movable
        action_ip="$1"
        action_from_class="$2"
        action_from_target="$3"
        action_to_class="$min_class"
        action_to_target="$(target_for_class "$min_class")"
        action_reason=idle_state_rebalance_most_loaded_to_least_loaded
        action_count=1
      else
        action_reason=no_idle_cooldown_ok_peer_on_most_loaded_class
      fi
    else
      action_reason=already_balanced
    fi
  fi
else
  action_reason="$block_reason"
fi

noop=true
[ "$action_count" -gt 0 ] && noop=false

selector_would_change=false
selector_apply_would_run=false
state_file_would_write=false
if { [ "$MODE" = --state-write ] || [ "$MODE" = --commit ]; } && [ "$fatal_topology_state" != true ]; then
  state_file_would_write=true
fi
if [ "$MODE" = --apply-preview ] || [ "$MODE" = --state-preview ] || [ "$MODE" = --state-write ] || [ "$MODE" = --commit ]; then
  if [ "$action_count" -gt 0 ]; then
    selector_would_change=true
    selector_apply_would_run=true
  fi
fi

{
  echo schema=router-wgpay-egress-local-state-v3
  echo "generated_epoch=$NOW"
  echo "selector_file=$SEL"
  echo "state_file=$STATE_FILE"
  echo "topology_state_file=$TOPOLOGY_STATE_FILE"
  echo "topology_state_source=$TOPOLOGY_STATE_SOURCE"
  echo "topology_state_valid=$TOPOLOGY_STATE_VALID"
  echo "topology_state_error=$TOPOLOGY_STATE_ERROR"
  echo "topology_mode=$TOPOLOGY_MODE"
  echo "topology_generation=$TOPOLOGY_GENERATION"
  echo "allowed_selectors=$ALLOWED_CLASSES"
  echo "exhausted_selectors=$EXHAUSTED_CLASSES"
  echo "mode=$MODE"
  echo "rows=$rows"
  echo "exhausted_row_count=$exhausted_row_count"
  echo "active_now_count=$active_now_count"
  echo "active_state_count=$active_state_count"
  echo "idle_count=$idle_count"
  echo "idle_seconds=$IDLE_SECONDS"
  echo "reassign_cooldown_seconds=$REASSIGN_COOLDOWN_SECONDS"
  echo "active_min_packets=$ACTIVE_MIN_PACKETS"
  echo "active_min_bytes=$ACTIVE_MIN_BYTES"
  echo "min_class=$min_class"
  echo "min_count=$min_count"
  echo "max_class=$max_class"
  echo "max_count=$max_count"
  echo "blocked=$blocked"
  echo "block_reason=$block_reason"
  echo "action_count=$action_count"
  echo "action_ip=$action_ip"
  echo "action_from_class=$action_from_class"
  echo "action_from_target=$action_from_target"
  echo "action_to_class=$action_to_class"
  echo "action_to_target=$action_to_target"
  echo "action_reason=$action_reason"
  echo "selector_would_change=$selector_would_change"
  echo "selector_apply_would_run=$selector_apply_would_run"
  echo "state_file_would_write=$state_file_would_write"

  while read -r ip cls tag active_now active_state cooldown_ok outp outb inp inb delta_packets delta_bytes last_active last_reassign; do
    next_last_reassign="$last_reassign"
    if [ "$action_count" -gt 0 ] && [ "$ip" = "$action_ip" ]; then next_last_reassign="$NOW"; fi
    echo "peer.${ip}.class=$cls"
    echo "peer.${ip}.target=$tag"
    echo "peer.${ip}.active_now=$active_now"
    echo "peer.${ip}.active_state=$active_state"
    echo "peer.${ip}.cooldown_ok=$cooldown_ok"
    echo "peer.${ip}.out_packets=$outp"
    echo "peer.${ip}.out_bytes=$outb"
    echo "peer.${ip}.in_packets=$inp"
    echo "peer.${ip}.in_bytes=$inb"
    echo "peer.${ip}.delta_packets=$delta_packets"
    echo "peer.${ip}.delta_bytes=$delta_bytes"
    echo "peer.${ip}.last_active_epoch=$last_active"
    echo "peer.${ip}.last_reassign_epoch=$next_last_reassign"
  done < "$TMP"
} > "$STATE_TMP"

state_preview_sha="$(sha256sum "$STATE_TMP" | awk '{print $1}')"
selector_update_performed=false
selector_update_rc=not_attempted
selector_apply_performed=false
selector_apply_rc=not_attempted
selector_new_sha=""
state_file_write_performed=false
state_file_write_rc=not_attempted
commit_rc=0
[ "$fatal_topology_state" = true ] && commit_rc=74

if [ "$MODE" = --state-write ] && [ "$fatal_topology_state" != true ]; then
  mkdir -p "$STATE_DIR"
  cp "$STATE_TMP" "${STATE_FILE}.tmp.$$" && mv "${STATE_FILE}.tmp.$$" "$STATE_FILE"
  state_file_write_rc=$?
  [ "$state_file_write_rc" = 0 ] && state_file_write_performed=true
  [ "$state_file_write_rc" = 0 ] || commit_rc="$state_file_write_rc"
fi

if [ "$MODE" = --commit ] && [ "$fatal_topology_state" != true ]; then
  if [ "$action_count" -gt 0 ]; then
    awk -v ip="$action_ip" -v cls="$action_to_class" -v tag="$action_to_target" '
      $1==ip {print ip " " cls " " tag; changed=1; next}
      {print}
      END {if(changed!=1) exit 42}
    ' "$SEL" > "$SEL_TMP"
    selector_update_rc=$?

    if [ "$selector_update_rc" = 0 ]; then
      cp "$SEL" "$SEL_TMP.before" || selector_update_rc=$?
    fi

    if [ "$selector_update_rc" = 0 ]; then
      selector_new_sha="$(sha256sum "$SEL_TMP" | awk '{print $1}')"
      mv "$SEL_TMP" "$SEL"
      selector_update_rc=$?
      [ "$selector_update_rc" = 0 ] && selector_update_performed=true
    fi

    if [ "$selector_update_rc" = 0 ] && [ -x "$APPLY" ]; then
      "$APPLY" start > "$APPLY_LOG" 2>&1
      selector_apply_rc=$?
      selector_apply_performed=true
      if [ "$selector_apply_rc" = 0 ] && [ -s "$REGISTRY_FILE" ] && [ -x "$REGISTRY_SYNC" ]; then
        "$REGISTRY_SYNC" --sync-from-selectors-unlocked > "$REGISTRY_SYNC_LOG" 2>&1
        registry_sync_rc=$?
        if [ "$registry_sync_rc" -ne 0 ]; then
          cp "$SEL_TMP.before" "$SEL" >/dev/null 2>&1 || true
          "$APPLY" start >> "$APPLY_LOG" 2>&1 || true
          selector_apply_rc=71
        fi
      fi
    else
      [ -x "$APPLY" ] || selector_apply_rc=apply_script_missing
    fi
  else
    selector_update_rc=noop
    selector_apply_rc=noop
  fi

  if [ "$action_count" = 0 ] || { [ "$selector_update_rc" = 0 ] && [ "$selector_apply_rc" = 0 ]; }; then
    mkdir -p "$STATE_DIR"
    cp "$STATE_TMP" "${STATE_FILE}.tmp.$$" && mv "${STATE_FILE}.tmp.$$" "$STATE_FILE"
    state_file_write_rc=$?
    [ "$state_file_write_rc" = 0 ] && state_file_write_performed=true
  fi

  if [ "$action_count" -gt 0 ]; then
    if [ "$selector_update_rc" != 0 ]; then commit_rc="$selector_update_rc"
    elif [ "$selector_apply_rc" != 0 ]; then commit_rc=70
    elif [ "$state_file_write_rc" != 0 ]; then commit_rc="$state_file_write_rc"
    fi
  elif [ "$state_file_write_rc" != 0 ]; then
    commit_rc="$state_file_write_rc"
  fi
fi

apply_log_sanitized="$(cat "$APPLY_LOG" 2>/dev/null | sed 's/[A-Za-z0-9+\/=]\{20,\}/KEYMASK/g' | tr '\n' '|')"

echo '{'
echo '  "schema": "router-wgpay-egress-local-v8",'
echo "  \"mode\": \"$MODE\","
echo "  \"now_epoch\": $NOW,"
echo "  \"selector_file\": \"$SEL\","
echo "  \"selector_apply\": \"$APPLY\","
echo "  \"state_file\": \"$STATE_FILE\","
echo '  "topology": {'
echo "    \"state_file\": \"$TOPOLOGY_STATE_FILE\","
echo "    \"state_source\": \"$TOPOLOGY_STATE_SOURCE\","
echo "    \"state_valid\": $TOPOLOGY_STATE_VALID,"
echo "    \"state_error\": \"$TOPOLOGY_STATE_ERROR\","
echo "    \"mode\": \"$TOPOLOGY_MODE\","
echo "    \"generation\": \"$TOPOLOGY_GENERATION\","
echo "    \"allowed_selectors\": \"$ALLOWED_CLASSES\","
echo "    \"exhausted_selectors\": \"$EXHAUSTED_CLASSES\","
echo "    \"exhausted_row_count\": $exhausted_row_count"
echo '  },'
echo "  \"idle_seconds\": $IDLE_SECONDS,"
echo "  \"reassign_cooldown_seconds\": $REASSIGN_COOLDOWN_SECONDS,"
echo '  "rows": ['

first=1
while read -r ip cls tag active_now active_state cooldown_ok outp outb inp inb delta_packets delta_bytes last_active last_reassign; do
  expected="$(target_for_class "$cls")"
  match=false
  [ "$tag" = "$expected" ] && match=true
  allowed=false
  csv_contains "$ALLOWED_CLASSES" "$cls" && allowed=true
  exhausted=false
  csv_contains "$EXHAUSTED_CLASSES" "$cls" && exhausted=true
  [ "$first" = 0 ] && echo ','
  first=0
  printf '    {"tunnel_ip":"%s","egress_class":"%s","target_id":"%s","expected_target_id":"%s","selector_target_match":%s,"selector_allowed":%s,"selector_exhausted":%s,"active_now":%s,"active_state":%s,"cooldown_ok":%s,"out_packets":%s,"in_packets":%s,"delta_packets":%s,"delta_bytes":%s,"last_active_epoch":%s,"last_reassign_epoch":%s}' \
    "$ip" "$cls" "$tag" "$expected" "$match" "$allowed" "$exhausted" "$active_now" "$active_state" "$cooldown_ok" "$outp" "$inp" "$delta_packets" "$delta_bytes" "$last_active" "$last_reassign"
done < "$TMP"

echo
echo '  ],'
echo '  "actions": ['
if [ "$action_count" -gt 0 ]; then
  printf '    {"tunnel_ip":"%s","from_class":"%s","from_target_id":"%s","to_class":"%s","to_target_id":"%s","reason":"%s"}\n' \
    "$action_ip" "$action_from_class" "$action_from_target" "$action_to_class" "$action_to_target" "$action_reason"
fi
echo '  ],'
echo '  "commit": {'
echo "    \"commit_rc\": \"$commit_rc\","
echo "    \"selector_update_performed\": $selector_update_performed,"
echo "    \"selector_update_rc\": \"$selector_update_rc\","
echo "    \"selector_apply_performed\": $selector_apply_performed,"
echo "    \"selector_apply_rc\": \"$selector_apply_rc\","
echo "    \"selector_new_sha256\": \"$selector_new_sha\","
echo "    \"state_file_write_performed\": $state_file_write_performed,"
echo "    \"state_file_write_rc\": \"$state_file_write_rc\","
echo "    \"apply_log_sanitized\": \"$apply_log_sanitized\""
echo '  },'
echo '  "state_preview": {'
echo "    \"state_file\": \"$STATE_FILE\","
echo "    \"would_write_state_file\": $state_file_would_write,"
echo "    \"state_file_write_performed\": $state_file_write_performed,"
echo "    \"state_file_write_rc\": \"$state_file_write_rc\","
echo "    \"state_preview_sha256\": \"$state_preview_sha\","
echo '    "format": "key_value_v3"'
echo '  },'
echo '  "summary": {'
echo "    \"rows\": $rows,"
echo "    \"active_now_count\": $active_now_count,"
echo "    \"active_state_count\": $active_state_count,"
echo "    \"idle_count\": $idle_count,"
echo "    \"exhausted_row_count\": $exhausted_row_count,"
echo "    \"min_class\": \"$min_class\","
echo "    \"min_count\": $min_count,"
echo "    \"max_class\": \"$max_class\","
echo "    \"max_count\": $max_count,"
echo "    \"blocked\": $blocked,"
echo "    \"block_reason\": \"$block_reason\","
echo "    \"action_count\": $action_count,"
echo "    \"noop\": $noop,"
echo "    \"action_reason\": \"$action_reason\","
echo "    \"selector_file_would_change\": $selector_would_change,"
echo "    \"selector_apply_would_run\": $selector_apply_would_run,"
echo "    \"state_file_would_write\": $state_file_would_write"
echo '  }'
echo '}'

exit "$commit_rc"
