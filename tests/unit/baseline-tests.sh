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
cell="$(cat "$FAKE_STATE/cell-$alias_" 2>/dev/null || echo "${FAKE_ORIGINAL_CELL:-socat/standard}")"
proxy="${cell%/*}" pihole="${cell#*/}"
hex=0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef
containers() {
  printf 'section\tcontainers\n'
  printf 'pi-hole\trunning\t172.31.240.250\nunbound\trunning\t172.31.240.251\n'
  printf 'tor-%s\trunning\t%s\n' "$proxy" "${1:-172.31.240.252}"
}
case "$op" in
  validate) printf 'fakelin\tlinux\tssh-l\t2026-09-22\nfakemac\tmacos\tssh-m\t2026-09-22\n' ;;
  snapshot)
    mkdir -p "$ARTIFACT_DIR/targets/$alias_"
    { printf 'machine_id\tm-%s\nplatform\t%s\n' "$alias_" "$plat"; containers
      if [ -n "${FAKE_TRANSIENT:-}" ]; then printf 'db004885-a77b\trunning\t172.31.240.253/29\n'; fi; } >"$ARTIFACT_DIR/targets/$alias_/snapshot.tsv" ;;
  config)
    addr=''; [ -f "$FAKE_STATE/thawed-$alias_" ] && addr="${FAKE_AFTER_ADDR:-}"
    printf 'machine_id\tm-%s\nplatform\t%s\n' "$alias_" "$plat"
    containers "$addr"
    printf 'section\timages\n'
    printf 'image\tpi-hole\tpi-hole:latest\tsha256:%s\n' "$hex"
    printf 'image\tunbound\tunbound:latest\tsha256:%s\n' "$hex"
    [ -n "${FAKE_TWO_DIGESTS:-}" ] || printf 'image\ttor-%s\ttor-%s:latest\tsha256:%s\n' "$proxy" "$proxy" "$hex"
    printf 'started\tunbound\t2026-09-23T00:00:00Z\n'
    printf 'pihole_variant\t%s\npihole_upstream\tserver=172.31.240.251#5335\n' "$pihole"
    printf 'unbound_conf\tforward-zone:\nproxy_component\ttor-%s\n' "$proxy"
    if [ "$frozen" = yes ]; then printf 'tor_state\tT\n'; else printf 'tor_state\tS\n'; fi ;;
  health)
    printf 'machine_id\tm-%s\nsection\thealth\n' "$alias_"
    v="${FAKE_HEALTH:-healthy}"
    [ "$frozen" = no ] && [ -n "${FAKE_HEALTH_BEFORE:-}" ] && v="$FAKE_HEALTH_BEFORE"
    printf 'health\tpodman:unbound\t%s\tstate=running streak=0\n' "$v"
    [ "$frozen" = yes ] && [ -n "${FAKE_EXTRA_SEVERED_SOURCE:-}" ] && printf 'health\tpodman:newcomer\thealthy\t-\n'
    : ;;
  collect)
    shift 2
    while [ $# -gt 0 ]; do case "$1" in --workload) w="$2" ;; --count) n="$2" ;; --identity) idf="$2" ;; esac; shift 2; done
    rev="$(awk -F '\t' '$1 == "source_rev" { print $2 }' "$idf")"; imgs="$(awk -F '\t' '$1 == "images" { print $2 }' "$idf")"
    printf '# schema\tnice-dns-sample/1\n'
    printf 'run_id\tsample_id\tutc_start\telapsed_us\tworkload\tcache_class\ttarget_id\tplatform\tproxy\tpihole\tsource_rev\timages\tresolver\ttransport\tqname\tqtype\toutcome\trcode\ttimeout_ms\n'
    if [ -n "${FAKE_COLD_BROKEN:-}" ] && [ "$w" = cold ] && [ "$n" = 3 ]; then exit 2; fi
    rc=0 i=1
    while [ "$i" -le "$n" ]; do
      o=ok r=NOERROR e=1500
      if [ "$frozen" = yes ] && [ "$w" = cold ] && [ -z "${FAKE_ANSWERS_WHILE_FROZEN:-}" ]; then o=timeout r=- e=5000000 rc=3; fi
      if [ -f "$FAKE_STATE/thawed-$alias_" ] && [ "$w" = cold ] && [ "$n" = 5 ] && [ -n "${FAKE_POST_RESTORE_MISS:-}" ]; then o=timeout r=- e=5000000 rc=3; fi
      if [ -f "$FAKE_STATE/thawed-$alias_" ] && [ "$w" = cold ] && [ -n "${FAKE_NEVER_AFTER_THAW:-}" ]; then o=timeout r=- e=5000000 rc=3; fi
      if [ "$cell" = "${FAKE_DEAD_CELL:-}" ]; then o=timeout r=- e=5000000 rc=3; fi
      printf '%s\t%s\t2026-09-23T00:00:00Z\t%s\t%s\tmiss\t%s\t%s\t%s\t%s\t%s\t%s\t127.0.0.1#53\tudp\tq.example.com\tA\t%s\t%s\t5000\n' \
        "$RUN_ID" "$i" "$e" "$w" "$alias_" "$plat" "$proxy" "$pihole" "$rev" "$imgs" "$o" "$r"
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
  install-cell)
    shift 2
    hsha=-
    while [ $# -gt 0 ]; do case "$1" in --cell) want="$2" ;; --source-sha) sha="$2" ;; --hardened-sha) hsha="$2" ;; esac; shift 2; done
    printf 'install %s %s\n' "$want" "$sha" >>"$FAKE_STATE/installs"
    printf '%s %s\n' "$want" "$hsha" >>"$FAKE_STATE/hardened-pins"
    [ "$want" = "${FAKE_INSTALL_FAIL:-}" ] && { echo "installer failed" >&2; exit 1; }
    [ -n "${FAKE_INSTALL_IGNORES_CELL:-}" ] || printf '%s\n' "$want" >"$FAKE_STATE/cell-$alias_"
    printf 'installer_exit\t0\n' ;;
  *) echo "fake: unknown op $op" >&2; exit 2 ;;
esac
FAKE
  chmod 755 "$CASE_DIR/bin/target.sh"
  : >"$CASE_DIR/targets.env"
  # Fresh state and artifact dirs per setup: one characterization per alias.
  NICE_DNS_TARGET_ADAPTER="$CASE_DIR/bin/target.sh" FAKE_STATE="$(mktemp -d "$CASE_DIR/state.XXXX")"
  FAKE_LOG="$CASE_DIR/fake.log" ARTIFACT_DIR="$(mktemp -d "$CASE_DIR/art.XXXX")" RUN_ID=run-unit-1
  NICE_DNS_BASELINE_COLD=3 NICE_DNS_BASELINE_WARM=4 NICE_DNS_BASELINE_SEVER_SECS=1
  NICE_DNS_BASELINE_SEVERED_COUNT=2 NICE_DNS_BASELINE_RECOVERY_COUNT=2 NICE_DNS_BASELINE_READY_SECS=1
  export NICE_DNS_TARGET_ADAPTER FAKE_STATE FAKE_LOG ARTIFACT_DIR RUN_ID NICE_DNS_BASELINE_COLD \
    NICE_DNS_BASELINE_WARM NICE_DNS_BASELINE_SEVER_SECS NICE_DNS_BASELINE_SEVERED_COUNT NICE_DNS_BASELINE_RECOVERY_COUNT \
    NICE_DNS_BASELINE_READY_SECS
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

t_transient_product_container_is_not_restore_state() {
  # bridge-eval's anonymous probe container runs at snapshot time and is gone
  # afterwards; the stack itself is unchanged, so the target is restored.
  bt_setup
  FAKE_TRANSIENT=1; export FAKE_TRANSIENT
  bt_run fakelin
  assert_rc 0 "$BT_RC" "transient container ignored: $(cat "$CASE_DIR/run.log")"
  assert_match '^BL-RESTORED	pass	' "$BT_OBS" "BL-RESTORED passes"
  assert_not_match 'db004885' "$(cat "$ARTIFACT_DIR/baseline/fakelin/containers-before.tsv")" "only stack containers compared"
}

t_recovered_chain_with_unlucky_post_restore_samples_is_restored() {
  # Recovery after the thaw answered; the 5 later attempts all missed, as a
  # target that answered 10/30 cold before the fault can. That is restored.
  bt_setup
  FAKE_POST_RESTORE_MISS=1; export FAKE_POST_RESTORE_MISS
  bt_run fakelin
  assert_rc 0 "$BT_RC" "restored on the recovery answers: $(cat "$CASE_DIR/run.log")"
  assert_match '^BL-RESTORED	pass	.*post-restore cold answered=0/5' "$BT_OBS" "BL-RESTORED passes and says the post-restore samples missed"
}

t_chain_that_never_answers_after_thaw_is_not_restored() {
  bt_setup
  FAKE_NEVER_AFTER_THAW=1; export FAKE_NEVER_AFTER_THAW
  bt_run fakelin
  assert_rc 1 "$BT_RC" "no answer after the thaw is not restored"
  assert_match '^BL-RESTORED	fail	' "$BT_OBS" "BL-RESTORED fails"
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
  # The baseline manifest's floors: 30 cold, 1000 warm.
  NICE_DNS_BASELINE_COLD=30 NICE_DNS_BASELINE_WARM=1000; export NICE_DNS_BASELINE_COLD NICE_DNS_BASELINE_WARM
  bt_run fakelin
  assert_rc 0 "$BT_RC" "linux cell"
  bt_run fakemac
  assert_rc 0 "$BT_RC" "macos cell"
  g="$CASE_DIR/global"; mkdir -p "$g"
  printf 'git_head\t%s\ncollected=1 passed=1 failed=0\nresult=pass run_id=x\n' "$(git -C "$NICE_DNS_ROOT" rev-parse HEAD)" >"$g/BL-STAGE.txt"
  printf 'repo\tnice-dns\n' >"$g/BL-INVENTORY.txt"
  r="$(NICE_DNS_BASELINE_GLOBAL_DIR="$g" bash "$BT_BASELINE" receipt --out "$CASE_DIR/receipt" \
    "$ARTIFACT_DIR/baseline/fakelin" "$ARTIFACT_DIR/baseline/fakemac" 2>"$CASE_DIR/receipt.err")"
  assert_rc 0 $? "receipt assembled: $(cat "$CASE_DIR/receipt.err")"
  bash "$NICE_DNS_ROOT/tests/reports/verify.sh" check "$r" --require-matrix representative >"$CASE_DIR/verify.log" 2>&1
  assert_rc 0 $? "representative receipt verifies: $(cat "$CASE_DIR/verify.log")"
  bash "$NICE_DNS_ROOT/tests/reports/verify.sh" check "$r" --require-matrix all >/dev/null 2>&1
  assert_rc 1 $? "two cells never satisfy the eight-cell matrix"
  assert_match '^coverage	2 cells$' "$(cat "$CASE_DIR/receipt/BL-TARGETS.txt")" "targets name their coverage"
  assert_match '^target	linux	cold	timeout_rate_max=0\.0000	p95_all_us_max=1500$' "$(cat "$CASE_DIR/receipt/BL-TARGETS.txt")" "linux cold target frozen from the cell's stats"
  assert_match '^scenario	BL-TARGETS	-	pass	BL-TARGETS.txt	' "$(cat "$r")" "targets are a receipt scenario"
  printf 'x\n' >>"$CASE_DIR/receipt/cells/linux-socat-standard/samples-cold.tsv"
  bash "$NICE_DNS_ROOT/tests/reports/verify.sh" check "$r" --require-matrix representative >/dev/null 2>&1
  assert_rc 1 $? "a tampered sample file fails verification"
}


SHA40=0123456789abcdef0123456789abcdef01234567

t_matrix_installs_every_platform_cell_and_ends_on_the_original() {
  bt_setup
  bash "$BT_BASELINE" matrix fakelin --targets "$CASE_DIR/targets.env" --source-sha "$SHA40" >"$CASE_DIR/m.log" 2>&1
  assert_rc 0 $? "matrix: $(tail -n 20 "$CASE_DIR/m.log")"
  assert_eq 4 "$(grep -c "^install .* $SHA40$" "$FAKE_STATE/installs")" "four installs at the pinned commit"
  assert_eq "install socat/standard $SHA40" "$(tail -n 1 "$FAKE_STATE/installs")" "the original cell is installed last"
  assert_eq 4 "$(grep -c '	observed	' "$ARTIFACT_DIR/baseline-matrix/fakelin/cells.tsv")" "four cells observed"
  for c in haproxy-standard haproxy-hardened socat-standard socat-hardened; do
    assert_match "^cell	linux/${c%-*}/${c#*-}$" "$(cat "$ARTIFACT_DIR/baseline/fakelin-$c/cell.tsv")" "cell $c characterized as itself"
  done
  assert_eq "socat/standard" "$(cat "$FAKE_STATE/cell-fakelin")" "target ends on its original cell"
  h="$(git -C "$NICE_DNS_ROOT/../pi-hole-hardened" rev-parse HEAD)"
  assert_eq "haproxy/hardened $h|socat/hardened $h" "$(grep hardened "$FAKE_STATE/hardened-pins" | sort | paste -sd'|' -)" "hardened cells pinned to the sibling HEAD"
  assert_eq 2 "$(grep -c ' -$' "$FAKE_STATE/hardened-pins")" "standard cells carry no sibling pin"
}

t_matrix_failed_install_fails_and_other_cells_still_run() {
  bt_setup
  FAKE_INSTALL_FAIL=haproxy/hardened; export FAKE_INSTALL_FAIL
  bash "$BT_BASELINE" matrix fakelin --targets "$CASE_DIR/targets.env" --source-sha "$SHA40" >"$CASE_DIR/m.log" 2>&1
  assert_rc 1 $? "a cell that did not install fails the matrix"
  assert_match '^haproxy/hardened	install-failed	' "$(cat "$ARTIFACT_DIR/baseline-matrix/fakelin/cells.tsv")" "the failed cell is named"
  assert_eq 3 "$(grep -c '	observed	' "$ARTIFACT_DIR/baseline-matrix/fakelin/cells.tsv")" "the other three still observed"
}

t_matrix_wrong_installed_cell_is_not_observed() {
  bt_setup
  FAKE_INSTALL_IGNORES_CELL=1; export FAKE_INSTALL_IGNORES_CELL
  bash "$BT_BASELINE" matrix fakelin --targets "$CASE_DIR/targets.env" --source-sha "$SHA40" >"$CASE_DIR/m.log" 2>&1
  assert_rc 1 $? "an installer that installed another cell fails"
  assert_eq 3 "$(grep -c '	wrong-cell-installed	' "$ARTIFACT_DIR/baseline-matrix/fakelin/cells.tsv")" "each mismatched cell named"
}

t_matrix_refuses_unpinned_source_and_unknown_original() {
  bt_setup
  bash "$BT_BASELINE" matrix fakelin --targets "$CASE_DIR/targets.env" --source-sha main >/dev/null 2>&1
  assert_rc 2 $? "a branch name is not a pinned commit"
  FAKE_TWO_DIGESTS=1; export FAKE_TWO_DIGESTS
  bash "$BT_BASELINE" matrix fakelin --targets "$CASE_DIR/targets.env" --source-sha "$SHA40" >/dev/null 2>&1
  assert_rc 2 $? "an unidentifiable current cell cannot be returned to"
  assert_no_path "$FAKE_STATE/installs" "nothing installed"
}

t_matrix_cell_that_never_answers_is_observed_as_such() {
  # A stack whose Tor never bootstraps is the product as it is: it is
  # characterized (every attempt a failure), not skipped.
  bt_setup
  FAKE_DEAD_CELL=haproxy/hardened; export FAKE_DEAD_CELL
  bash "$BT_BASELINE" matrix fakelin --targets "$CASE_DIR/targets.env" --source-sha "$SHA40" >"$CASE_DIR/m.log" 2>&1
  assert_rc 0 $? "matrix with a dead cell: $(tail -n 20 "$CASE_DIR/m.log")"
  assert_match '^haproxy/hardened	observed-never-ready	' "$(cat "$ARTIFACT_DIR/baseline-matrix/fakelin/cells.tsv")" "dead cell observed and marked"
  assert_match '^never-ready	' "$(cat "$ARTIFACT_DIR/baseline/fakelin-haproxy-hardened/findings.tsv")" "finding recorded in the cell"
  assert_match '^BL-COLD	pass	samples-cold.tsv	attempted=3 answered=0$' "$(cat "$ARTIFACT_DIR/baseline/fakelin-haproxy-hardened/observations.tsv")" "failures observed, not dropped"
  assert_match '^BL-RESTORED	pass	.*cold answered before the fault=0/3' "$(cat "$ARTIFACT_DIR/baseline/fakelin-haproxy-hardened/observations.tsv")" "restored to its pre-fault (non-answering) state"
  assert_eq 3 "$(grep -c '	observed	' "$ARTIFACT_DIR/baseline-matrix/fakelin/cells.tsv")" "the other cells are ordinary observations"
}

t_matrix_records_the_installed_product_in_each_cell() {
  local h
  bt_setup
  bash "$BT_BASELINE" matrix fakelin --targets "$CASE_DIR/targets.env" --source-sha "$SHA40" >"$CASE_DIR/m.log" 2>&1
  assert_rc 0 $? "matrix: $(tail -n 5 "$CASE_DIR/m.log")"
  h="$(git -C "$NICE_DNS_ROOT/../pi-hole-hardened" rev-parse HEAD)"
  assert_match "^product_sha	$SHA40$" "$(cat "$ARTIFACT_DIR/baseline/fakelin-socat-standard/cell.tsv")" "product pin in the cell"
  assert_match '^install_source	inline-archive$' "$(cat "$ARTIFACT_DIR/baseline/fakelin-socat-standard/cell.tsv")" "linux cells install the inline archive"
  assert_match "^hardened_sha	$h$" "$(cat "$ARTIFACT_DIR/baseline/fakelin-socat-hardened/cell.tsv")" "hardened sibling pin in the cell"
  assert_match '^hardened_sha	-$' "$(cat "$ARTIFACT_DIR/baseline/fakelin-socat-standard/cell.tsv")" "standard cells carry no sibling pin"
  assert_match "^source_rev	$SHA40$" "$(cat "$ARTIFACT_DIR/baseline/fakelin-socat-standard/identity.tsv")" "samples name the installed product"
}

t_unknown_pre_fault_state_still_requires_an_answer() {
  # With no complete pre-fault cold sample, "answered nothing before" is not
  # known; a target that answers nothing after the thaw is not restored.
  bt_setup
  FAKE_COLD_BROKEN=1 FAKE_NEVER_AFTER_THAW=1; export FAKE_COLD_BROKEN FAKE_NEVER_AFTER_THAW
  bt_run fakelin
  assert_rc 1 "$BT_RC" "incomplete observation"
  assert_match '^BL-COLD	fail	' "$BT_OBS" "BL-COLD fails"
  assert_match '^BL-RESTORED	fail	' "$BT_OBS" "BL-RESTORED is not waved through on missing data"
}

t_never_ready_cells_are_named_in_the_frozen_targets() {
  local g r cells=""
  bt_setup
  FAKE_DEAD_CELL=haproxy/hardened; export FAKE_DEAD_CELL
  bash "$BT_BASELINE" matrix fakelin --targets "$CASE_DIR/targets.env" --source-sha "$SHA40" >"$CASE_DIR/m.log" 2>&1
  for d in "$ARTIFACT_DIR"/baseline/*/cell.tsv; do cells="$cells $(dirname "$d")"; done
  g="$CASE_DIR/global"; mkdir -p "$g"; : >"$g/BL-STAGE.txt"; : >"$g/BL-INVENTORY.txt"
  # shellcheck disable=SC2086
  r="$(NICE_DNS_BASELINE_GLOBAL_DIR="$g" bash "$BT_BASELINE" receipt --out "$CASE_DIR/receipt" $cells 2>"$CASE_DIR/r.err")"
  assert_rc 0 $? "receipt: $(cat "$CASE_DIR/r.err")"
  assert_match '^never-ready	linux/haproxy/hardened$' "$(cat "$CASE_DIR/receipt/BL-TARGETS.txt")" "dead cell named in the frozen targets"
  assert_eq 1 "$(grep -c '^never-ready	' "$CASE_DIR/receipt/BL-TARGETS.txt")" "only the dead cell"
  assert_match "^product	nice-dns	$SHA40$" "$(cat "$r")" "receipt names the installed product"
  assert_match "^product	pi-hole-hardened	$(git -C "$NICE_DNS_ROOT/../pi-hole-hardened" rev-parse HEAD)$" "$(cat "$r")" "receipt names the hardened sibling"
}

t_health_source_seen_only_while_severed_is_a_finding() {
  bt_setup
  FAKE_EXTRA_SEVERED_SOURCE=1; export FAKE_EXTRA_SEVERED_SOURCE
  bt_run fakelin
  assert_rc 0 "$BT_RC" "observation complete"
  assert_match '^health-source-appeared	podman:newcomer' "$BT_FIND" "no health source is silently dropped"
}

t_uninterpreted_health_verdict_is_a_finding() {
  # launchd reports last_exit=N, which is neither healthy nor unhealthy.
  bt_setup
  FAKE_HEALTH=last_exit=1; export FAKE_HEALTH
  bt_run fakelin
  assert_rc 0 "$BT_RC" "observation complete"
  assert_match "^health-uninterpreted	podman:unbound: before the fault 'last_exit=1', severed 'last_exit=1'" "$BT_FIND" "recorded, not dropped"
}
