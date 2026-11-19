# shellcheck shell=bash
# Group live/transport-live (Sub-plan 4 Task 2.3; BL-042). Run by
# `tests/run.sh live transport-live --live --targets FILE --platforms
# linux,macos` (mint and the mac, never this machine). One cell per platform:
# the stack as the target runs it now (nothing is installed). Three scenarios,
# read through target.sh:
#   TL-DNSSEC        through the client resolver (Pi-hole) a signed name and an
#                    unsigned one answer and dnssec-failed.org is SERVFAIL; at
#                    Unbound's own listener the signed name carries `ad` and
#                    the unsigned one does not (Pi-hole never passes `ad` on,
#                    so validation is read there), and with checking disabled
#                    (+cd) dnssec-failed.org's data arrives, so its SERVFAIL is
#                    validation, not an outage.
#   TL-CONTROL       nothing listens on TCP 8953 in the Unbound container, its
#                    control interface is a Unix socket, and it answers.
#   TL-TLS-NEGATIVE  a fresh name answers first (TL_PRE_MAX, 120 s), so a later
#                    SERVFAIL is not a cold or dead upstream; fault-route --mode
#                    tls-control sets the route's own TLS name by the runtime
#                    path the fault uses and a fresh name must still answer;
#                    --mode tls-name then gives it a wrong name (same address
#                    and port) and a fresh name must be SERVFAIL, never
#                    answered; heal-route brings answers back within
#                    TL_HEAL_MAX (600 s). The minute controller is not paused:
#                    a tick that heals the route mid-fault makes a name
#                    answer, a false FAIL, never a false PASS.
# The TLS step heals whatever happens; a fault cut off in place leaves
# fault-left, which tl_after heals. target.sh's own timer heals it after
# NICE_DNS_FREEZE_MAX_SECS in any case.
#
# macOS (DEC-024): target.sh reaches the mac's gui container runtime through
# launchctl asuser; the runtime is never moved.
# NICE_DNS_CELL_REUSE_RUNS names earlier run directories: a platform whose
# cell passed every step there, at a commit with the same product files and
# the same scenario, is carried into the receipt, not run again (DEC-009).
#
# Evidence: $ARTIFACT_DIR/transport-live/<alias>/; only *.tsv is checked and
# copied into the receipt.
#
# NICE_DNS_TARGET_ADAPTER replaces target.sh only for the dry run
# (integration/transport-live-dryrun, NICE_DNS_IL_DRY_RUN=1).

TL_STEPS='tl_before tl_dnssec tl_control tl_tls_negative tl_after'

tl_plan() {
  local p
  echo "dry run: no target is touched"
  for p in linux macos; do
    printf '%s %-15s %s\n' "$p" tl_before "snapshot the target, record the proxy it runs as the cell ($p/<proxy>/standard); nothing is installed"
    printf '%s %-15s %s\n' "$p" tl_dnssec "TL-DNSSEC: transport-report; through the client resolver a signed and an unsigned name answer, dnssec-failed.org is SERVFAIL; at Unbound the signed name has \`ad\`, the unsigned one not"
    printf '%s %-15s %s\n' "$p" tl_control "TL-CONTROL: no TCP 8953 listener in the Unbound container; the control interface is a Unix socket and answers"
    printf '%s %-15s %s\n' "$p" tl_tls_negative "TL-TLS-NEGATIVE: a fresh name answers; fault-route --component unbound --route <running> --mode tls-control and a fresh name still answers; --mode tls-name and a fresh name is SERVFAIL (${TL_FAULT_TRIES:-3} tries), never answered; heal-route; a fresh name answers within ${TL_HEAL_MAX:-600} s"
    if [ "$p" = macos ]; then
      printf '%s %-15s %s\n' "$p" tl_after "heal a fault left in place; a fresh name answers (target.sh reaches the runtime in the gui session, DEC-024)"
    else
      printf '%s %-15s %s\n' "$p" tl_after "heal a fault left in place; a fresh name answers"
    fi
  done
  printf '%s %-15s %s\n' all tl_privacy "no bridge material, session or hash in the evidence"
  printf '%s %-15s %s\n' all tl_receipt "assemble and verify the transport-live receipt (a passed cell of an earlier run is reused, DEC-009)"
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  if [ "${1:-}" = --dry-run ]; then
    tl_plan
    exit 0
  fi
  echo "usage: transport-live.sh --dry-run (the run itself: tests/run.sh live transport-live --live --targets FILE)" >&2
  exit 2
fi

# The helpers of live/command-recovery (cell, fresh name, sources), with this
# group's own directory.
# shellcheck source=tests/live/command-recovery.sh
. "$NICE_DNS_ROOT/tests/live/command-recovery.sh"
unset -f t_01_before t_02_install t_03_fault_unbound t_04_fault_proxy t_05_restart t_06_reinstall t_07_uninstall t_08_final t_09_privacy t_10_receipt
il_dir() { printf '%s\n' "$ARTIFACT_DIR/transport-live/$1"; }
# shellcheck disable=SC2034 # read by il_each
IL_FIRST_STEPS=tl_before

TL_FAULT_TRIES="${TL_FAULT_TRIES:-3}"
TL_HEAL_MAX="${TL_HEAL_MAX:-600}"
TL_PRE_MAX="${TL_PRE_MAX:-120}"
TL_SECRETS='cert=[A-Za-z0-9+/]{20}|(^|[^0-9A-Fa-f])[0-9A-F]{40}([^0-9A-Fa-f]|$)|PRIVATE KEY|"sid":|pwhash|BRIDGE[0-9]+=|obfs4 [0-9]'

# tl_row <file> <k1> <k2> <k3>: the rest of the first row starting k1 k2 k3.
tl_row() { awk -F '\t' -v a="$2" -v b="$3" -v c="$4" '$1 == a && $2 == b && $3 == c { sub(/^[^\t]*\t[^\t]*\t[^\t]*\t/, ""); print; exit }' "$1"; }

tl_before() { cr_before "$@"; }

tl_dnssec() {
  local a="$2" d r f
  d="$(il_dir "$a")"; r="$d/transport.tsv"; f="$d/dnssec.tsv"
  il_t "$a" transport-report >"$r" 2>>"$d/ops.log" || fail "$a: transport-report: $(tail -n 3 "$d/ops.log")"
  assert_match '^NOERROR	' "$(tl_row "$r" dnssec client signed | cut -f2-)" "$a: a signed name answers through the client resolver"
  assert_match '^NOERROR	' "$(tl_row "$r" dnssec client unsigned | cut -f2-)" "$a: an unsigned name answers through the client resolver"
  assert_match '^SERVFAIL	' "$(tl_row "$r" dnssec client bogus | cut -f2-)" "$a: dnssec-failed.org is SERVFAIL through the client resolver"
  assert_match '^NOERROR	ad$' "$(tl_row "$r" dnssec unbound signed | cut -f2-)" "$a: the signed name validates at Unbound (ad)"
  assert_match '^NOERROR	noad$' "$(tl_row "$r" dnssec unbound unsigned | cut -f2-)" "$a: the unsigned name answers without ad (it is unsigned)"
  assert_match '^NOERROR	' "$(tl_row "$r" dnssec unbound bogus-cd | cut -f2-)" "$a: with checking disabled the bogus name's data arrives (its SERVFAIL is validation)"
  { awk -F '\t' '$1 == "dnssec"' "$r"; printf 'result\tpass\n'; } >"$f"
}

tl_control() {
  local a="$2" d r f
  d="$(il_dir "$a")"; r="$d/transport.tsv"; f="$d/control.tsv"
  cr_require "$a" tl_dnssec
  assert_eq none "$(awk -F '\t' '$1 == "control" && $2 == "tcp_8953" { print $3; exit }' "$r")" "$a: nothing listens on TCP 8953"
  assert_match '^/' "$(awk -F '\t' '$1 == "control" && $2 == "interface" { print $3; exit }' "$r")" "$a: the control interface is a path"
  assert_eq unix "$(awk -F '\t' '$1 == "control" && $2 == "socket" { print $3; exit }' "$r")" "$a: and a Unix socket"
  assert_eq yes "$(awk -F '\t' '$1 == "control" && $2 == "answers" { print $3; exit }' "$r")" "$a: which answers"
  { awk -F '\t' '$1 == "control"' "$r"; printf 'result\tpass\n'; } >"$f"
}

# tl_heal <alias> <route>: heal-route, then drop the marker.
tl_heal() {
  local d
  d="$(il_dir "$1")"
  il_t "$1" heal-route --component unbound --route "$2" --mode tls-name >"$d/heal.tsv" 2>>"$d/ops.log" || return 1
  rm -f "$d/fault-left"
}

tl_tls_negative() {
  local a="$2" d f route row st i=0 bad=0 sf=0 rc=0 before="" control=""
  d="$(il_dir "$a")"; f="$d/tls-negative.tsv"
  cr_require "$a" tl_dnssec
  route="$(awk -F '\t' '$1 == "route" && $2 == "running" { print $3; exit }' "$d/transport.tsv")"
  assert_match '^[a-z0-9-]+$' "$route" "$a: the running route is known"
  # A SERVFAIL under the fault means something only if names answer now.
  before="$(cr_fresh "$a" "$(( $(date +%s) + TL_PRE_MAX ))")" \
    || fail "$a: no fresh name answers before the fault within ${TL_PRE_MAX}s ($before); a SERVFAIL under it would prove nothing"
  printf '%s\n' "$route" >"$d/fault-left"
  : >"$d/faulted.tsv"
  # The positive control: the route's own name, set by the fault's own path.
  if il_t "$a" fault-route --component unbound --route "$route" --mode tls-control >"$d/tls-control.out" 2>>"$d/ops.log" \
    && control="$(cr_fresh "$a" "$(( $(date +%s) + TL_PRE_MAX ))")" \
    && il_t "$a" fault-route --component unbound --route "$route" --mode tls-name >"$d/fault.tsv" 2>>"$d/ops.log"; then
    while [ "$i" -lt "$TL_FAULT_TRIES" ]; do
      row="$(il_t "$a" fresh-name 2>>"$d/ops.log" | awk -F '\t' '$1 == "fresh_name"')"
      st="$(printf '%s\n' "$row" | cut -f3)"
      printf 'faulted\t%s\t%s\n' "$(printf '%s\n' "$row" | cut -f2)" "${st:-timeout}" >>"$d/faulted.tsv"
      case "$st" in NOERROR|NXDOMAIN) bad=$((bad + 1)) ;; SERVFAIL) sf=$((sf + 1)) ;; esac
      i=$((i + 1))
    done
  else
    rc=1
  fi
  # Healed whatever happened above.
  tl_heal "$a" "$route" || fail "$a: heal-route failed; the route keeps its changed TLS name until target.sh's timer: $(tail -n 3 "$d/ops.log")"
  [ "$rc" = 0 ] || fail "$a: the control (--mode tls-control, then a fresh name: ${control:-none}) or the fault (--mode tls-name) failed: $(tail -n 3 "$d/ops.log")"
  assert_eq 0 "$bad" "$a: no fresh name is answered under the wrong TLS name"
  assert_ne 0 "$sf" "$a: a fresh name is SERVFAIL under the wrong TLS name"
  row="$(cr_fresh "$a" "$(( $(date +%s) + TL_HEAL_MAX ))")" || fail "$a: no answer within ${TL_HEAL_MAX}s of heal-route: $row"
  {
    printf 'route\t%s\n' "$route"
    printf 'before\t%s\t%s\n' "$(printf '%s\n' "$before" | cut -f2)" "$(printf '%s\n' "$before" | cut -f3)"
    awk -F '\t' '$1 == "forwarder" { print "control_forwarder\t" $2 }' "$d/tls-control.out"
    printf 'control\t%s\t%s\n' "$(printf '%s\n' "$control" | cut -f2)" "$(printf '%s\n' "$control" | cut -f3)"
    awk -F '\t' '$1 == "forwarder"' "$d/fault.tsv"
    cat "$d/faulted.tsv"
    printf 'healed\t%s\t%s\n' "$(printf '%s\n' "$row" | cut -f2)" "$(printf '%s\n' "$row" | cut -f3)"
    printf 'result\tpass\n'
  } >"$f"
}

tl_after() {
  local a="$2" d row
  d="$(il_dir "$a")"
  if [ -f "$d/fault-left" ]; then
    tl_heal "$a" "$(cat "$d/fault-left")" || fail "$a: heal-route of the fault left in place failed: $(tail -n 3 "$d/ops.log")"
  fi
  row="$(cr_fresh "$a" "$(( $(date +%s) + TL_HEAL_MAX ))")" || fail "$a: no answer within ${TL_HEAL_MAX}s: $row"
}

# tl_reuse_dir <platform>: that platform's cell in a run listed in
# NICE_DNS_CELL_REUSE_RUNS that passed every step at the same product (DEC-009).
tl_reuse_dir() {
  local r d s ok
  for r in ${NICE_DNS_CELL_REUSE_RUNS:-}; do
    case "$r" in /*) ;; *) fail "NICE_DNS_CELL_REUSE_RUNS: $r is not an absolute run directory" ;; esac
    [ -d "$r" ] || fail "NICE_DNS_CELL_REUSE_RUNS: no run directory $r"
    for d in "$r"/transport-live/*/; do
      [ -f "$d/cell.tsv" ] || continue
      [ "$(il_cell_of "$d" cell | cut -d/ -f1)" = "$1" ] || continue
      [ "$(il_cell_of "$d" adapter)" = "$(cr_adapter)" ] || continue
      ok=1
      for s in $TL_STEPS; do grep -qx "$s" "$d/passed.tsv" 2>/dev/null || ok=0; done
      [ "$ok" = 1 ] || continue
      il_same_product "$(il_cell_of "$d" source_sha)" "$1" || continue
      git -C "$NICE_DNS_ROOT" diff --quiet "$(il_cell_of "$d" source_sha)" HEAD -- \
        tests/live/transport-live.sh tests/live/command-recovery.sh tests/live/install-lifecycle.sh tests/live/fault-lib.sh \
        tests/live/target.sh tests/manifests/transport-live.tsv tests/reports/verify.sh 2>/dev/null || continue
      printf '%s\n' "${d%/}"
      return 0
    done
  done
  return 0
}

TL_SCENARIOS='TL-DNSSEC:dnssec.tsv TL-CONTROL:control.tsv TL-TLS-NEGATIVE:tls-negative.tsv'

tl_receipt() {
  local root out r repo cd st d from cell key gen a f id n=0 v ok p selected rd s
  root="$(dirname "$(dirname "$ARTIFACT_DIR")")"
  out="$root/receipts/transport-live/$RUN_ID"; r="$out/receipt.tsv"
  assert_no_path "$out" "this run has no transport-live receipt yet"
  mkdir -p "$out/cells" || fail "cannot create $out"
  {
    printf '# schema\tnice-dns-receipt/1\n'
    printf 'receipt\ttransport-live\nrun_id\t%s\ncreated_utc\t%s\n' "$RUN_ID" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    for repo in nice-dns tor-haproxy tor-socat hardened-unbound pi-hole-hardened; do
      if [ "$repo" = nice-dns ]; then cd="$NICE_DNS_ROOT"; else cd="$CR_SIBS/$repo"; fi
      if [ -n "$(cr_clean "$cd")" ]; then st=dirty; else st=clean; fi
      printf 'source\t%s\t%s\t%s\n' "$repo" "$(git -C "$cd" rev-parse HEAD)" "$st"
    done
    for repo in tor-haproxy tor-socat hardened-unbound pi-hole-hardened; do
      printf 'arch\t%s\t%s\t%s\n' "$repo" "$(git -C "$CR_SIBS/$repo" rev-parse HEAD)" \
        "$(git -C "$CR_SIBS/$repo" show HEAD:.github/workflows/main.yml |
          awk '/^ *platform: *$/ { on = 1; next } on && /^ *- *linux\// { sub(/^ *- */, ""); print; next } on { on = 0 }' |
          sort | paste -sd, -)"
    done
    printf 'product\tnice-dns\t%s\n' "$(git -C "$NICE_DNS_ROOT" rev-parse HEAD)"
    printf 'limit\tinstalled-as-found\t-\tscope=BL-042\tthe stack was read as each target runs it; this group installs nothing\n'
  } >"$r"
  selected=" $(il_platforms) "
  : >"$CASE_DIR/cell-dirs.tsv"
  for d in "$ARTIFACT_DIR"/transport-live/*/; do
    [ -f "$d/cell.tsv" ] || continue
    printf '%s\t-\n' "${d%/}" >>"$CASE_DIR/cell-dirs.tsv"
  done
  for p in linux macos; do
    case "$selected" in *" $p "*) continue ;; esac
    rd="$(tl_reuse_dir "$p")"
    [ -z "$rd" ] || printf '%s\t%s\n' "$rd" "$(basename "$(dirname "$(dirname "$rd")")")" >>"$CASE_DIR/cell-dirs.tsv"
  done
  while IFS="$(printf '\t')" read -r d from; do
    cell="$(il_cell_of "$d" cell)"; key="$(printf '%s' "$cell" | tr / -)"
    a="$(il_cell_of "$d" target)"
    gen="generation=$(awk -F '\t' '$1 == "route" && $2 == "running" { print $4; exit }' "$d/transport.tsv" 2>/dev/null)"
    mkdir -p "$out/cells/$key"
    cp "$d/cell.tsv" "$out/cells/$key/"
    ok=1
    for s in $TL_STEPS; do grep -qx "$s" "$d/passed.tsv" 2>/dev/null || ok=0; done
    if [ "$ok" != 1 ]; then
      printf 'cell\t%s\t%s\t%s\t%s\t%s\tfailed\n' "${cell%%/*}" "$(printf '%s' "$cell" | cut -d/ -f2)" "${cell##*/}" "$a" "$gen" >>"$r"
      continue
    fi
    n=$((n + 1))
    printf 'cell\t%s\t%s\t%s\t%s\t%s\tobserved\n' "${cell%%/*}" "$(printf '%s' "$cell" | cut -d/ -f2)" "${cell##*/}" "$a" "$gen" >>"$r"
    [ "$from" = - ] || printf 'reuse\t%s\t%s\t%s\n' "$cell" "$from" "$(il_cell_of "$d" source_sha)" >>"$r"
    for id in $TL_SCENARIOS; do
      f="${id#*:}"
      cp "$d/$f" "$out/cells/$key/$f"
      printf 'scenario\t%s\t%s\tpass\tcells/%s/%s\t%s\t%s\n' "${id%%:*}" "$cell" "$key" "$f" "$(sha256sum "$out/cells/$key/$f" | cut -d' ' -f1)" "$gen" >>"$r"
    done
  done <"$CASE_DIR/cell-dirs.tsv"
  assert_match '^[1-9]' "$n" "at least one fully passed cell"
  v="$(bash "$NICE_DNS_ROOT/tests/reports/verify.sh" check "$r" 2>&1)"
  assert_rc 0 "$?" "the transport-live receipt verifies: $v"
  assert_eq "" "$(grep -rlE "$TL_SECRETS" "$out" 2>/dev/null)" "no bridge line, certificate, fingerprint, key, session or password hash in the receipt"
  printf 'receipt\t%s\n' "$r" >"$CASE_DIR/receipt-path.tsv"
}

t_1_before() { il_selection; il_each tl_before; }
t_2_dnssec() { il_selection; il_each tl_dnssec; }
t_3_control() { il_selection; il_each tl_control; }
t_4_tls_negative() { il_selection; il_each tl_tls_negative; }
t_5_after() { il_selection; il_each tl_after; }

t_6_privacy() {
  il_selection
  nd_reports_present "$ARTIFACT_DIR/transport-live"
  assert_eq "" "$(grep -rlE "$TL_SECRETS" "$ARTIFACT_DIR/transport-live" --include='*.tsv' 2>/dev/null)" \
    "no report or step record holds bridge material, a session or a hash"
}

t_7_receipt() { il_selection; tl_receipt; }
