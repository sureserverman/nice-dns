# shellcheck shell=bash
# Group unit/measurement (sub-plan 01, Task 1.3; ARCH-09).
#
# Sourced by tests/run.sh (assert_* helpers; NICE_DNS_ROOT, ARTIFACT_DIR,
# CASE_DIR exported). Covers the raw sample schema, the collector
# (tests/live/collect.sh) against the local fixture, and the percentile /
# denominator report (tests/reports/stats.sh) against known vectors.

# shellcheck source=tests/fixtures/fixture.sh
. "$NICE_DNS_ROOT/tests/fixtures/fixture.sh"

MT_COLLECT="$NICE_DNS_ROOT/tests/live/collect.sh"
MT_STATS="$NICE_DNS_ROOT/tests/reports/stats.sh"

mt_identity() {
  printf 'target_id\tfixture-local\nplatform\tlinux\nproxy\thaproxy\npihole\tstandard\nsource_rev\t%s\nimages\tnone:fixture\n' \
    "$(git -C "$NICE_DNS_ROOT" rev-parse HEAD)" >"$CASE_DIR/identity.tsv"
}

mt_workloads() {
  printf '# test workloads over the local fixture\n' >"$CASE_DIR/workloads.tsv"
  printf 'fx-warm\thit\tsigned.fixture.test\tA\n' >>"$CASE_DIR/workloads.tsv"
  printf 'fx-cold\tmiss\t{nonce}.fixture.test\tA\n' >>"$CASE_DIR/workloads.tsv"
  printf 'fx-drop\tmiss\tdrop.fixture.test\tA\n' >>"$CASE_DIR/workloads.tsv"
  printf 'fx-servfail\tmiss\tservfail.fixture.test\tA\n' >>"$CASE_DIR/workloads.tsv"
}

mt_start() {
  fx_start "$CASE_DIR/fx" || fail "fixture did not start"
  trap 'fx_stop "$CASE_DIR/fx"' EXIT
  mt_identity
  mt_workloads
  MT_RESOLVER="127.0.0.1#$(fx_port "$CASE_DIR/fx" dns)"
}

mt_collect() {
  # mt_collect <workload> <count> [extra args...]
  local w="$1" n="$2"
  shift 2
  MT_OUT="$(bash "$MT_COLLECT" --resolver "$MT_RESOLVER" --workload "$w" --count "$n" \
    --workloads "$CASE_DIR/workloads.tsv" --identity "$CASE_DIR/identity.tsv" \
    --out "$CASE_DIR/samples.tsv" "$@" 2>&1)"
  MT_RC=$?
}

mt_rows() { grep -v '^#' "$CASE_DIR/samples.tsv" | tail -n +2; }

mt_col() {
  # mt_col <column-name>: prints that column for every data row.
  awk -F '\t' -v c="$1" '/^#/ { next } !h { for (i = 1; i <= NF; i++) if ($i == c) k = i; h = 1; next } { print $k }' \
    "$CASE_DIR/samples.tsv"
}

mt_vector() {
  # mt_vector <file> <ok-values...>: build a synthetic sample file from values
  # in microseconds; the word FAIL:<outcome> adds a failed attempt.
  local f="$1" v i=0
  shift
  printf '# schema\tnice-dns-sample/1\n' >"$f"
  printf 'run_id\tsample_id\tutc_start\telapsed_us\tworkload\tcache_class\ttarget_id\tplatform\tproxy\tpihole\tsource_rev\timages\tresolver\ttransport\tqname\tqtype\toutcome\trcode\ttimeout_ms\n' >>"$f"
  for v in "$@"; do
    i=$((i + 1))
    case "$v" in
      FAIL:*) printf 'r\t%d\t2026-01-01T00:00:00Z\t3000000\tw\tmiss\tt\tlinux\thaproxy\tstandard\tx\ti\t127.0.0.1#53\tudp\tq.fixture.test\tA\t%s\t-\t3000\n' "$i" "${v#FAIL:}" >>"$f" ;;
      *) printf 'r\t%d\t2026-01-01T00:00:00Z\t%s\tw\tmiss\tt\tlinux\thaproxy\tstandard\tx\ti\t127.0.0.1#53\tudp\tq.fixture.test\tA\tok\tNOERROR\t3000\n' "$i" "$v" >>"$f" ;;
    esac
  done
}

mt_stat() {
  # mt_stat <file> <field>: one field from the stats.sh TSV for workload w.
  bash "$MT_STATS" "$1" | awk -F '\t' -v f="$2" 'NR == 1 { for (i = 1; i <= NF; i++) if ($i == f) k = i; next } $1 == "w" { print $k }'
}

# ─────────────── collector ───────────────

t_collect_records_every_attempt_with_identity() {
  mt_start
  mt_collect fx-warm 5
  assert_rc 0 "$MT_RC" "collect warm: $MT_OUT"
  assert_eq 5 "$(mt_rows | wc -l | tr -d ' ')" "one row per attempted query"
  assert_match '^# schema	nice-dns-sample/1$' "$(head -1 "$CASE_DIR/samples.tsv")" "schema header"
  assert_eq "fixture-local" "$(mt_col target_id | sort -u)" "target identity on every row"
  assert_eq "$(git -C "$NICE_DNS_ROOT" rev-parse HEAD)" "$(mt_col source_rev | sort -u)" "source identity on every row"
  assert_eq "none:fixture" "$(mt_col images | sort -u)" "image identity on every row"
  assert_eq "hit" "$(mt_col cache_class | sort -u)" "declared cache class"
  assert_eq "ok" "$(mt_col outcome | sort -u)" "all answered"
}

t_collect_times_with_monotonic_microseconds_and_utc() {
  mt_start
  mt_collect fx-warm 3
  assert_rc 0 "$MT_RC" "collect"
  assert_eq "" "$(mt_col elapsed_us | grep -Ev '^[1-9][0-9]*$')" "elapsed is a positive integer in microseconds"
  assert_eq "" "$(mt_col utc_start | grep -Ev '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(\.[0-9]+)?Z$')" "UTC start stamp"
  assert_eq "1 2 3" "$(mt_col sample_id | tr '\n' ' ' | sed 's/ $//')" "sample ids are sequential per file"
}

t_collect_counts_timeouts_in_denominator() {
  local e
  mt_start
  mt_collect fx-drop 2 --timeout-ms 1000
  assert_nonzero "$MT_RC" "a workload with failed queries is not a clean run"
  assert_eq 2 "$(mt_rows | wc -l | tr -d ' ')" "failed attempts are still recorded"
  assert_eq "timeout" "$(mt_col outcome | sort -u)" "outcome timeout"
  for e in $(mt_col elapsed_us); do
    [ "$e" -ge 900000 ] || fail "timeout elapsed $e us is shorter than the 1000 ms budget"
  done
  assert_eq "1000" "$(mt_col timeout_ms | sort -u)" "timeout budget recorded"
}

t_collect_servfail_is_failure_and_nxdomain_is_answer() {
  mt_start
  mt_collect fx-servfail 1
  assert_nonzero "$MT_RC" "SERVFAIL is a failure"
  assert_eq "servfail	SERVFAIL" "$(mt_col outcome)	$(mt_col rcode)" "servfail row"
  rm -f "$CASE_DIR/samples.tsv"
  mt_collect fx-cold 2
  assert_rc 0 "$MT_RC" "NXDOMAIN is a valid negative answer, not a transport failure"
  assert_eq "nxdomain" "$(mt_col outcome | sort -u)" "nxdomain outcome"
}

t_collect_cold_names_are_unique_nonces() {
  mt_start
  mt_collect fx-cold 4
  assert_rc 0 "$MT_RC" "collect cold"
  assert_eq 4 "$(mt_col qname | sort -u | wc -l | tr -d ' ')" "every cold query uses a fresh name"
  assert_eq "" "$(mt_col qname | grep -Ev '^[0-9a-f]{16}\.fixture\.test$')" "nonce names match the template"
}

t_collect_refuses_names_outside_workloads() {
  assert_file "$MT_COLLECT" "collector exists"
  mt_start
  MT_OUT="$(bash "$MT_COLLECT" --resolver "$MT_RESOLVER" --workload no-such --count 1 \
    --workloads "$CASE_DIR/workloads.tsv" --identity "$CASE_DIR/identity.tsv" --out "$CASE_DIR/samples.tsv" 2>&1)"
  assert_nonzero $? "unknown workload refused"
  assert_match 'unknown workload' "$MT_OUT" "refusal names the cause"
  assert_no_path "$CASE_DIR/samples.tsv" "nothing written for a refused workload"
  MT_OUT="$(bash "$MT_COLLECT" --resolver "$MT_RESOLVER" --qname example.org --count 1 \
    --workloads "$CASE_DIR/workloads.tsv" --identity "$CASE_DIR/identity.tsv" --out "$CASE_DIR/samples.tsv" 2>&1)"
  assert_nonzero $? "free-form query names are not accepted (no client query history)"
  assert_match 'unknown option' "$MT_OUT" "--qname is not an option"
  assert_no_path "$CASE_DIR/samples.tsv" "nothing written for a free-form name"
}

t_collect_refuses_incomplete_identity() {
  local k
  mt_start
  for k in target_id platform proxy pihole source_rev images; do
    grep -v "^$k	" "$CASE_DIR/identity.tsv" >"$CASE_DIR/identity-missing.tsv"
    MT_OUT="$(bash "$MT_COLLECT" --resolver "$MT_RESOLVER" --workload fx-warm --count 1 \
      --workloads "$CASE_DIR/workloads.tsv" --identity "$CASE_DIR/identity-missing.tsv" --out "$CASE_DIR/s-$k.tsv" 2>&1)"
    assert_nonzero $? "identity without $k refused"
    assert_match "$k" "$MT_OUT" "refusal names the missing key $k"
    assert_no_path "$CASE_DIR/s-$k.tsv" "no samples without $k"
  done
}

t_collect_appends_without_rewriting_header() {
  mt_start
  mt_collect fx-warm 2
  mt_collect fx-warm 2
  assert_rc 0 "$MT_RC" "second collect"
  assert_eq 1 "$(grep -c '^# schema' "$CASE_DIR/samples.tsv")" "one schema line"
  assert_eq 4 "$(mt_rows | wc -l | tr -d ' ')" "rows appended"
  assert_eq "1 2 3 4" "$(mt_col sample_id | tr '\n' ' ' | sed 's/ $//')" "ids continue"
}

t_default_workloads_are_controlled_names() {
  local f="$NICE_DNS_ROOT/tests/manifests/workloads.tsv" w
  assert_file "$f" "default workload manifest"
  for w in cold warm idle wake; do
    assert_match "^$w	" "$(grep -v '^#' "$f")" "workload $w defined"
  done
  assert_eq "" "$(grep -v '^#' "$f" | awk -F '\t' 'NF != 4 { print }')" "four columns per workload row"
}

# ─────────────── statistics ───────────────

t_stats_nearest_rank_known_vector_1_to_100() {
  local f="$CASE_DIR/v.tsv"
  # shellcheck disable=SC2046
  mt_vector "$f" $(seq 1 100)
  assert_eq 100 "$(mt_stat "$f" attempted)" "attempted"
  assert_eq 50 "$(mt_stat "$f" p50_ok_us)" "p50 nearest rank"
  assert_eq 95 "$(mt_stat "$f" p95_ok_us)" "p95 nearest rank"
  assert_eq 99 "$(mt_stat "$f" p99_ok_us)" "p99 nearest rank"
  assert_eq 0.0000 "$(mt_stat "$f" failure_rate)" "no failures"
}

t_stats_small_vectors() {
  local f="$CASE_DIR/v.tsv"
  mt_vector "$f" 7
  assert_eq "7 7 7" "$(mt_stat "$f" p50_ok_us) $(mt_stat "$f" p95_ok_us) $(mt_stat "$f" p99_ok_us)" "single sample"
  # shellcheck disable=SC2046
  mt_vector "$f" $(seq 10 -1 1)
  assert_eq "5 10 10" "$(mt_stat "$f" p50_ok_us) $(mt_stat "$f" p95_ok_us) $(mt_stat "$f" p99_ok_us)" "unsorted 1..10"
}

t_stats_failures_stay_in_denominator() {
  local f="$CASE_DIR/v.tsv"
  # shellcheck disable=SC2046
  mt_vector "$f" $(seq 1 98) FAIL:timeout FAIL:servfail
  assert_eq 100 "$(mt_stat "$f" attempted)" "attempted includes failures"
  assert_eq 98 "$(mt_stat "$f" ok)" "ok count"
  assert_eq 2 "$(mt_stat "$f" failed)" "failed count"
  assert_eq 1 "$(mt_stat "$f" timeouts)" "timeouts count"
  assert_eq 0.0200 "$(mt_stat "$f" failure_rate)" "failure rate over all attempts"
  assert_eq 0.0100 "$(mt_stat "$f" timeout_rate)" "timeout rate over all attempts"
  assert_eq 50 "$(mt_stat "$f" p50_all_us)" "all-attempt p50 (failures = +inf)"
  assert_eq 95 "$(mt_stat "$f" p95_all_us)" "all-attempt p95"
  assert_eq inf "$(mt_stat "$f" p99_all_us)" "all-attempt p99 lands on a failure"
  assert_eq 98 "$(mt_stat "$f" p99_ok_us)" "success-only p99 is reported separately"
}

t_stats_nxdomain_counts_as_answer() {
  local f="$CASE_DIR/v.tsv"
  mt_vector "$f" 10 20
  sed 's/	ok	NOERROR	/	nxdomain	NXDOMAIN	/' "$f" >"$f.nx"
  assert_eq 2 "$(mt_stat "$f.nx" ok)" "NXDOMAIN answers are successes"
  assert_eq 0 "$(mt_stat "$f.nx" failed)" "and not failures"
}

t_stats_all_failed_has_no_success_percentiles() {
  local f="$CASE_DIR/v.tsv"
  mt_vector "$f" FAIL:timeout FAIL:timeout
  assert_eq "n/a inf 1.0000" "$(mt_stat "$f" p50_ok_us) $(mt_stat "$f" p50_all_us) $(mt_stat "$f" failure_rate)" "no fabricated latency"
}

t_stats_labels_weak_tail_support() {
  local f="$CASE_DIR/v.tsv"
  # shellcheck disable=SC2046
  mt_vector "$f" $(seq 1 100)
  assert_eq "supported exploratory exploratory" \
    "$(mt_stat "$f" p50_support) $(mt_stat "$f" p95_support) $(mt_stat "$f" p99_support)" "100 samples"
  # shellcheck disable=SC2046
  mt_vector "$f" $(seq 1 1000)
  assert_eq "supported supported supported" \
    "$(mt_stat "$f" p50_support) $(mt_stat "$f" p95_support) $(mt_stat "$f" p99_support)" "1000 samples"
}

t_stats_rejects_bad_input() {
  local f="$CASE_DIR/v.tsv" out
  assert_file "$MT_STATS" "stats script exists"
  : >"$f"
  out="$(bash "$MT_STATS" "$f" 2>&1)"
  assert_nonzero $? "empty file"
  assert_match 'schema' "$out" "empty file refused for missing schema"
  mt_vector "$f" 1 2
  sed '1s/nice-dns-sample\/1/nice-dns-sample\/9/' "$f" >"$f.bad"
  out="$(bash "$MT_STATS" "$f.bad" 2>&1)"
  assert_nonzero $? "unknown schema version"
  assert_match 'schema' "$out" "refusal names the schema"
  mt_vector "$f" 1 2
  printf 'short\trow\n' >>"$f"
  out="$(bash "$MT_STATS" "$f" 2>&1)"
  assert_nonzero $? "row with wrong column count"
  assert_match 'column' "$out" "refusal names the column count"
  mt_vector "$f"
  out="$(bash "$MT_STATS" "$f" 2>&1)"
  assert_nonzero $? "header only: zero samples is never a result"
  assert_match 'no samples' "$out" "refusal says there are no samples"
}

t_stats_groups_by_workload() {
  local f="$CASE_DIR/v.tsv" out
  mt_vector "$f" 1 2 3
  sed 's/	w	miss	/	other	hit	/' "$f" | tail -n +3 >>"$f"
  out="$(bash "$MT_STATS" "$f")"
  assert_match '^w	' "$out" "row for workload w"
  assert_match '^other	' "$out" "row for workload other"
  assert_eq 2 "$(printf '%s\n' "$out" | tail -n +2 | wc -l | tr -d ' ')" "one row per workload"
}
