# shellcheck shell=bash
# Group unit/baseline (sub-plan 01, Task 2.3; ARCH-09).
#
# Drives tests/live/baseline.sh against a fake target adapter (canned
# config/health/collect output; freeze state in a file), so the observation
# rules are proven on this host without touching a real target: a complete
# observation passes, a target left frozen or with changed containers fails
# BL-RESTORED, a failed freeze is not a severed observation, an interrupt
# while frozen still thaws, health findings are judged against the pre-fault
# verdict, and the receipt assembled from two cells verifies.

BT_BASELINE="$NICE_DNS_ROOT/tests/live/baseline.sh"
BT_HEX="0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"

bt_setup() {
  mkdir -p "$CASE_DIR/bin"
  cat >"$CASE_DIR/bin/target.sh" <<'FAKE'
#!/usr/bin/env bash
# Fake tests/live/target.sh. Behaviour: FAKE_* variables; freeze state in
# $FAKE_STATE/frozen-ALIAS; every call logged to $FAKE_LOG.
op="$1" alias_="${2:-}"
printf '%s %s\n' "$op" "$*" >>"$FAKE_LOG"
plat="${FAKE_PLATFORM:-linux}"
[ "$alias_" = fakemac ] && plat=macos
frozen=no; [ -f "$FAKE_STATE/frozen-$alias_" ] && frozen=yes
hex=0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef
containers() {
  printf 'section\tcontainers\n'
  printf 'pi-hole\trunning\t172.31.240.250\nunbound\trunning\t172.31.240.251\n'
  printf 'tor-socat\trunning\t%s\n' "${1:-172.31.240.252}"
}
case "$op" in
  validate) printf 'fakelin\tlinux\tssh-l\t2026-09-22\nfakemac\tmacos\tssh-m\t2026-09-22\n' ;;
  snapshot)
    mkdir -p "$ARTIFACT_DIR/targets/$alias_"
    { printf 'machine_id\tm-%s\nplatform\t%s\n' "$alias_" "$plat"; containers; } >"$ARTIFACT_DIR/targets/$alias_/snapshot.tsv" ;;
  config)
    addr=''; [ -f "$FAKE_STATE/thawed-$alias_" ] && addr="${FAKE_AFTER_ADDR:-}"
    printf 'machine_id\tm-%s\nplatform\t%s\n' "$alias_" "$plat"
    containers "$addr"
    printf 'section\timages\n'
    printf 'image\tpi-hole\tpi-hole:latest\tsha256:%s\n' "$hex"
    printf 'image\tunbound\tunbound:latest\tsha256:%s\n' "$hex"
    [ -n "${FAKE_TWO_DIGESTS:-}" ] || printf 'image\ttor-socat\ttor-socat:latest\tsha256:%s\n' "$hex"
    printf 'started\tunbound\t2026-09-23T00:00:00Z\n'
    printf 'pihole_variant\tstandard\npihole_upstream\tserver=172.31.240.251#5335\n'
    printf 'unbound_conf\tforward-zone:\nproxy_component\ttor-socat\n'
    if [ "$frozen" = yes ]; then printf 'tor_state\tT\n'; else printf 'tor_state\tS\n'; fi ;;
  health)
    printf 'machine_id\tm-%s\nsection\thealth\n' "$alias_"
    v="${FAKE_HEALTH:-healthy}"
    [ "$frozen" = no ] && [ -n "${FAKE_HEALTH_BEFORE:-}" ] && v="$FAKE_HEALTH_BEFORE"
    printf 'health\tpodman:unbound\t%s\tstate=running streak=0\n' "$v" ;;
  collect)
    shift 2
    while [ $# -gt 0 ]; do case "$1" in --workload) w="$2" ;; --count) n="$2" ;; esac; shift 2; done
    printf '# schema\tnice-dns-sample/1\n'
    printf 'run_id\tsample_id\tutc_start\telapsed_us\tworkload\tcache_class\ttarget_id\tplatform\tproxy\tpihole\tsource_rev\timages\tresolver\ttransport\tqname\tqtype\toutcome\trcode\ttimeout_ms\n'
    rc=0 i=1
    while [ "$i" -le "$n" ]; do
      o=ok r=NOERROR e=1500
      if [ "$frozen" = yes ] && [ "$w" = cold ] && [ -z "${FAKE_ANSWERS_WHILE_FROZEN:-}" ]; then o=timeout r=- e=5000000 rc=3; fi
      printf '%s\t%s\t2026-09-23T00:00:00Z\t%s\t%s\tmiss\t%s\t%s\tsocat\tstandard\tx\ti\t127.0.0.1#53\tudp\tq.example.com\tA\t%s\t%s\t5000\n' \
        "$RUN_ID" "$i" "$e" "$w" "$alias_" "$plat" "$o" "$r"
      i=$((i + 1))
    done
    exit "$rc" ;;
  freeze-upstream)
    [ -n "${FAKE_FREEZE_FAIL:-}" ] && { echo "freeze failed" >&2; exit 1; }
    : >"$FAKE_STATE/frozen-$alias_"; printf 'tor_state\tT\n' ;;
  thaw-upstream)
    [ -n "${FAKE_THAW_BROKEN:-}" ] || rm -f "$FAKE_STATE/frozen-$alias_"
    : >"$FAKE_STATE/thawed-$alias_"; printf 'tor_state\tS\n' ;;
  restore) : ;;
  *) echo "fake: unknown op $op" >&2; exit 2 ;;
esac
FAKE
  chmod 755 "$CASE_DIR/bin/target.sh"
  : >"$CASE_DIR/targets.env"
  # Fresh state and artifact dirs per setup: one characterization per alias.
  NICE_DNS_TARGET_ADAPTER="$CASE_DIR/bin/target.sh" FAKE_STATE="$(mktemp -d "$CASE_DIR/state.XXXX")"
  FAKE_LOG="$CASE_DIR/fake.log" ARTIFACT_DIR="$(mktemp -d "$CASE_DIR/art.XXXX")" RUN_ID=run-unit-1
  NICE_DNS_BASELINE_COLD=3 NICE_DNS_BASELINE_WARM=4 NICE_DNS_BASELINE_SEVER_SECS=1
  NICE_DNS_BASELINE_SEVERED_COUNT=2 NICE_DNS_BASELINE_RECOVERY_COUNT=2
  export NICE_DNS_TARGET_ADAPTER FAKE_STATE FAKE_LOG ARTIFACT_DIR RUN_ID NICE_DNS_BASELINE_COLD \
    NICE_DNS_BASELINE_WARM NICE_DNS_BASELINE_SEVER_SECS NICE_DNS_BASELINE_SEVERED_COUNT NICE_DNS_BASELINE_RECOVERY_COUNT
  : >"$FAKE_LOG"
}

bt_run() {
  # bt_run ALIAS: characterize; sets BT_RC, BT_OBS, BT_FIND.
  bash "$BT_BASELINE" characterize "$1" --targets "$CASE_DIR/targets.env" >"$CASE_DIR/run.log" 2>&1
  BT_RC=$?
  BT_OBS="$(cat "$ARTIFACT_DIR/baseline/$1/observations.tsv" 2>/dev/null)"
  BT_FIND="$(cat "$ARTIFACT_DIR/baseline/$1/findings.tsv" 2>/dev/null)"
}

t_complete_observation_passes_and_records_false_green() {
  local s
  bt_setup
  bt_run fakelin
  assert_rc 0 "$BT_RC" "complete observation: $(cat "$CASE_DIR/run.log")"
  for s in BL-CONFIG BL-COLD BL-WARM BL-SEVERED BL-RESTORED; do
    assert_match "^$s	pass	" "$BT_OBS" "$s pass"
  done
  assert_match '^health-false-green	podman:unbound stayed healthy while 0/2 uncached' "$BT_FIND" "green health with dead upstream is a finding"
  assert_match '^cache-masks-outage	2/2 cached' "$BT_FIND" "cached answers while severed recorded"
  assert_eq 3 "$(grep -vc '^#' "$ARTIFACT_DIR/baseline/fakelin/samples-cold.tsv" | awk '{ print $1 - 1 }')" "every cold attempt kept"
  assert_file "$ARTIFACT_DIR/baseline/fakelin/samples-cold.stats.tsv" "cold aggregate written"
  assert_match '^cell	linux/socat/standard$' "$(cat "$ARTIFACT_DIR/baseline/fakelin/cell.tsv")" "cell identity"
  assert_match "^image_gen	pi-hole=sha256:$BT_HEX,unbound=sha256:$BT_HEX,tor-socat=sha256:$BT_HEX$" \
    "$(cat "$ARTIFACT_DIR/baseline/fakelin/cell.tsv")" "image generation from the three digests"
  assert_match '^thaw-upstream ' "$(cat "$FAKE_LOG")" "upstream thawed"
}

t_target_left_frozen_fails_restored() {
  bt_setup
  FAKE_THAW_BROKEN=1; export FAKE_THAW_BROKEN
  bt_run fakelin
  assert_rc 1 "$BT_RC" "a target left frozen is not restored"
  assert_match '^BL-RESTORED	fail	' "$BT_OBS" "BL-RESTORED fails"
}

t_stopped_tor_fails_restored_even_if_queries_answer() {
  # The snapshot state includes a running tor; an answer from elsewhere does
  # not make a target left with tor stopped "restored".
  bt_setup
  FAKE_THAW_BROKEN=1 FAKE_ANSWERS_WHILE_FROZEN=1; export FAKE_THAW_BROKEN FAKE_ANSWERS_WHILE_FROZEN
  bt_run fakelin
  assert_rc 1 "$BT_RC" "tor still stopped after restore"
  assert_match '^BL-RESTORED	fail	' "$BT_OBS" "BL-RESTORED fails on tor state alone"
}

t_changed_container_address_fails_restored() {
  bt_setup
  FAKE_AFTER_ADDR=172.31.240.253; export FAKE_AFTER_ADDR
  bt_run fakelin
  assert_rc 1 "$BT_RC" "a container on another address is not the snapshot state"
  assert_match '^BL-RESTORED	fail	' "$BT_OBS" "BL-RESTORED fails"
}

t_failed_freeze_is_not_a_severed_observation() {
  bt_setup
  FAKE_FREEZE_FAIL=1; export FAKE_FREEZE_FAIL
  bt_run fakelin
  assert_rc 1 "$BT_RC" "no severed observation without a freeze"
  assert_match '^BL-SEVERED	fail	' "$BT_OBS" "BL-SEVERED fails"
  assert_match '^thaw-upstream ' "$(cat "$FAKE_LOG")" "a thaw is still attempted"
}

t_incomplete_config_fails_before_any_fault() {
  bt_setup
  FAKE_TWO_DIGESTS=1; export FAKE_TWO_DIGESTS
  bt_run fakelin
  assert_rc 1 "$BT_RC" "two of three image digests is incomplete"
  assert_match '^BL-CONFIG	fail	.*digests=2 of 3' "$BT_OBS" "BL-CONFIG fails with the reason"
  assert_not_match '^freeze-upstream ' "$(cat "$FAKE_LOG")" "no fault injected on an unidentified cell"
}

t_interrupt_while_frozen_still_thaws() {
  local pid i
  bt_setup
  NICE_DNS_BASELINE_SEVER_SECS=30; export NICE_DNS_BASELINE_SEVER_SECS
  bash "$BT_BASELINE" characterize fakelin --targets "$CASE_DIR/targets.env" >"$CASE_DIR/run.log" 2>&1 &
  pid=$!
  i=0
  while ! grep -q '^freeze-upstream ' "$FAKE_LOG" && [ "$i" -lt 100 ]; do sleep 0.1; i=$((i + 1)); done
  assert_match '^freeze-upstream ' "$(cat "$FAKE_LOG")" "reached the frozen window"
  sleep 0.5
  kill -TERM "$pid"
  wait "$pid"
  assert_nonzero $? "interrupted run is not a pass"
  assert_match '^thaw-upstream ' "$(sed -n '/^freeze-upstream /,$p' "$FAKE_LOG")" "thawed after the interrupt"
  assert_no_path "$FAKE_STATE/frozen-fakelin" "target not left frozen"
}

t_health_red_before_the_fault_is_not_detection() {
  bt_setup
  FAKE_HEALTH=unhealthy FAKE_HEALTH_BEFORE=unhealthy; export FAKE_HEALTH FAKE_HEALTH_BEFORE
  bt_run fakelin
  assert_rc 0 "$BT_RC" "observation complete"
  assert_match '^health-not-discriminating	podman:unbound was already unhealthy' "$BT_FIND" "always-red health recorded as such"
  assert_not_match '^health-detects' "$BT_FIND" "always-red health is not detection"
  FAKE_HEALTH=unhealthy FAKE_HEALTH_BEFORE=healthy
  bt_setup
  bt_run fakelin
  assert_match '^health-detects	podman:unbound went healthy -> unhealthy' "$BT_FIND" "green-to-red is detection"
}

t_receipt_from_two_cells_verifies_and_detects_tampering() {
  local g r
  bt_setup
  bt_run fakelin
  assert_rc 0 "$BT_RC" "linux cell"
  bt_run fakemac
  assert_rc 0 "$BT_RC" "macos cell"
  g="$CASE_DIR/global"; mkdir -p "$g"
  printf 'stage evidence\n' >"$g/BL-STAGE.txt"; printf 'inventory evidence\n' >"$g/BL-INVENTORY.txt"
  r="$(NICE_DNS_BASELINE_GLOBAL_DIR="$g" bash "$BT_BASELINE" receipt --out "$CASE_DIR/receipt" \
    "$ARTIFACT_DIR/baseline/fakelin" "$ARTIFACT_DIR/baseline/fakemac" 2>"$CASE_DIR/receipt.err")"
  assert_rc 0 $? "receipt assembled: $(cat "$CASE_DIR/receipt.err")"
  bash "$NICE_DNS_ROOT/tests/reports/verify.sh" check "$r" --require-matrix representative >"$CASE_DIR/verify.log" 2>&1
  assert_rc 0 $? "representative receipt verifies: $(cat "$CASE_DIR/verify.log")"
  bash "$NICE_DNS_ROOT/tests/reports/verify.sh" check "$r" --require-matrix all >/dev/null 2>&1
  assert_rc 1 $? "two cells never satisfy the eight-cell matrix"
  printf 'x\n' >>"$CASE_DIR/receipt/cells/linux-socat-standard/samples-cold.tsv"
  bash "$NICE_DNS_ROOT/tests/reports/verify.sh" check "$r" --require-matrix representative >/dev/null 2>&1
  assert_rc 1 $? "a tampered sample file fails verification"
}
