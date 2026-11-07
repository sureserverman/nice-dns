# shellcheck shell=bash
# Group live/bridges-toggle (bridges-toggle plan, Task 2.1). Run by
# `tests/run.sh live bridges-toggle --live --targets FILE --platforms
# linux,macos` (OD-3: mint and the mac, never this machine). One cell per
# platform: the proxy the target runs now, standard Pi-hole, installed from
# this checkout's HEAD; the installed proxy launcher must know TOR_BRIDGES
# before `nice-dns bridges on|off` accepts a switch (Stage 1).
#
# macOS (OD-8, BL-052): the mac's container runtime runs in launchd
# gui/<uid>, which plain ssh cannot see. target.sh then runs the mac's
# container calls and its installer inside the gui session (launchctl
# asuser); the runtime is never moved (OD-7's move broke vmnet, 2026-11-07).
# The install step quiesces the controller agents, installs, and always
# resumes them.
#
# A failed step stops that platform's later steps, but bt_after still runs,
# so the target ends with bridges on and a settled stack. Every wait is
# bounded (a fresh name: BT_FRESH_MAX, 600 s; settling: CR_SETTLE_MAX), and
# no step starts past BT_RUN_MAX from the run's first step.
# NICE_DNS_CELL_REUSE_RUNS names earlier run directories: a platform whose
# cell passed every step there, at a commit with the same product files and
# the same scenario, is not run again (DEC-009).
#
# Evidence: $ARTIFACT_DIR/bridges-toggle/<alias>/. Only *.tsv is checked and
# copied into the receipt. The proxy's log is never read here: target.sh
# proxy-supervisor-lines returns only the supervisor's `spawned tor` lines,
# cut after their launch words, and this file keeps a line only when it is
# exactly that shape. The command's and installer's output stay in *.log.
#
# NICE_DNS_TARGET_ADAPTER replaces target.sh only for the dry run
# (integration/bridges-toggle-dryrun, NICE_DNS_IL_DRY_RUN=1).

bt_plan() {
  local p
  echo "dry run: no target is touched"
  for p in linux macos; do
    printf '%s %-13s %s\n' "$p" bt_before "snapshot the target, record its proxy as the cell ($p/<proxy>/standard)"
    if [ "$p" = macos ]; then
      printf '%s %-13s %s\n' "$p" bt_install "quiesce-agents; install-cell --cell <proxy>/standard --source-sha HEAD, inside the gui session when ssh cannot see the runtime (launchctl asuser); then always resume-agents; the runtime is never moved (OD-8)"
    else
      printf '%s %-13s %s\n' "$p" bt_install "install-cell --cell <proxy>/standard --source-sha HEAD; the deployment checked; real timers"
    fi
    printf '%s %-13s %s\n' "$p" bt_off "settle; nice-dns bridges off (exit 0, last line); one request id journals bridges mode-change off and service acknowledged; proxy-supervisor-lines: the latest spawn is direct (no bridges); a fresh name answers within 600 s"
    printf '%s %-13s %s\n' "$p" bt_refresh "nice-dns-health bridges-refresh exits 0 and journals bridges skipped bridges off, nothing else"
    printf '%s %-13s %s\n' "$p" bt_status_off "nice-dns status --tsv shows bridges<TAB>mode<TAB>off"
    printf '%s %-13s %s\n' "$p" bt_on "nice-dns bridges on (exit 0, last line); one request id journals bridges mode-change on and service acknowledged; the latest spawn is with N bridge(s); a fresh name answers within 600 s"
    printf '%s %-13s %s\n' "$p" bt_status_on "nice-dns status --tsv shows bridges<TAB>mode<TAB>on"
    printf '%s %-13s %s\n' "$p" bt_after "runs whatever came before: bridges on again if a step stopped while off; the stack settles"
  done
  printf '%s %-13s %s\n' all bt_privacy "no bridge material, session or hash in the evidence"
  printf '%s %-13s %s\n' all bt_receipt "assemble and verify the bridges-toggle receipt (a passed cell of an earlier run is reused, DEC-009)"
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  if [ "${1:-}" = --dry-run ]; then
    bt_plan
    exit 0
  fi
  echo "usage: bridges-toggle.sh --dry-run (the run itself: tests/run.sh live bridges-toggle --live --targets FILE)" >&2
  exit 2
fi

# The helpers of live/command-recovery (settle, fresh name, journal, cell),
# with this group's own directory.
# shellcheck source=tests/live/command-recovery.sh
. "$NICE_DNS_ROOT/tests/live/command-recovery.sh"
unset -f t_01_before t_02_install t_03_fault_unbound t_04_fault_proxy t_05_restart t_06_reinstall t_07_uninstall t_08_final t_09_privacy t_10_receipt
il_dir() { printf '%s\n' "$ARTIFACT_DIR/bridges-toggle/$1"; }

BT_STEPS='bt_before bt_install bt_off bt_refresh bt_status_off bt_on bt_status_on bt_after'
# A fresh name after each switch (the Outcomes' 10 minutes).
BT_FRESH_MAX="${BT_FRESH_MAX:-600}"
# The supervisor's spawn line after a switch the CLI already acknowledged.
BT_LINE_MAX="${BT_LINE_MAX:-120}"
# The whole run: no step starts later than this after the first.
BT_RUN_MAX="${BT_RUN_MAX:-10800}"
BT_LINE_RE='^tor-supervisor: spawned tor pid=[0-9]+ generation=[0-9]+ (direct \(no bridges\)|with [0-9]+ bridge\(s\))$'
# shellcheck disable=SC2034 # read by il_each
IL_FIRST_STEPS=bt_before

bt_require() {
  grep -qx "$2" "$(il_dir "$1")/passed.tsv" 2>/dev/null || fail "$2 did not pass on $1; this step does not run"
}

# bt_budget_start: the run's first step stamps its start (once; the two
# platforms' first steps may race to it, a second or so apart).
bt_budget_start() {
  mkdir -p "$ARTIFACT_DIR/bridges-toggle"
  [ -f "$ARTIFACT_DIR/bridges-toggle/started" ] || date +%s >"$ARTIFACT_DIR/bridges-toggle/started"
}

# bt_budget: refuse to start a step past BT_RUN_MAX.
bt_budget() {
  local s
  bt_budget_start
  s="$(cat "$ARTIFACT_DIR/bridges-toggle/started" 2>/dev/null)"
  case "$s" in ''|*[!0-9]*) fail "no run start stamp; the run budget cannot be checked" ;; esac
  [ $(( $(date +%s) - s )) -le "$BT_RUN_MAX" ] || fail "past the run budget (BT_RUN_MAX=${BT_RUN_MAX}s since $s); $1 does not start"
}

# bt_cli <alias> <label> <mode>: the installed nice-dns through target.sh
# command (bridges-on, bridges-off, status). Output in cmd-<label>.log.
bt_cli() { il_t "$1" command --mode "$3" >"$(il_dir "$1")/cmd-$2.log" 2>&1; }
# bt_cli_exit / bt_cli_last <log>: the command's exit and its last line.
bt_cli_exit() { awk -F '\t' '$1 == "command_exit" { v = $2 } END { print (v == "" ? "-" : v) }' "$1"; }
bt_cli_last() { awk -F '\t' '$1 == "started_utc" { on = 1; next } $1 == "finished_utc" { on = 0 } on && NF { l = $0 } END { print l }' "$1"; }

# bt_ids <alias> <file>: the request ids the active journal holds now, and
# prints the target's clock. A row of this step is one at or after it whose
# id is not in the list.
bt_ids() {
  local r
  r="$(il_dir "$1")/ids.report"
  il_t "$1" controller-report >"$r" 2>>"$(il_dir "$1")/ops.log" || fail "controller-report"
  il_sec "$r" journal-active | awk -F '\t' '$1 ~ /^[0-9]+$/ { print $2 }' | LC_ALL=C sort -u >"$2"
  cr_now "$r"
}

# bt_rows <report> <since> <ids file>: this step's journal rows.
bt_rows() {
  cr_jrows "$1" "$2" | awk -F '\t' -v f="$3" 'BEGIN { while ((getline l < f) > 0) old[l] = 1 } !($2 in old)'
}

# bt_spawn <alias> <report>: "<container> TAB <line>" of the latest spawn,
# or nothing.
bt_spawn() {
  il_t "$1" proxy-supervisor-lines >"$2" 2>>"$(il_dir "$1")/ops.log" || return 1
  awk -F '\t' '$1 == "supervisor_line" { c = $2; l = $3 } END { if (l != "") print c "\t" l }' "$2"
}

# bt_switch <platform> <alias> <on|off>: the switch and everything it must
# show, in switch-<mode>.tsv.
bt_switch() {
  local a="$2" m="$3" d out ids r t0 tl rows rid spawn line c how hre end row rc=0 el ex last
  d="$(il_dir "$a")"; out="$d/switch-$m.tsv"; ids="$d/switch-$m.ids"; r="$d/switch-$m.report"
  if [ "$m" = off ]; then how='direct (no bridges)' hre='direct \(no bridges\)$'
  else how='with N bridge(s)' hre='with [0-9]+ bridge\(s\)$'; fi
  cr_settled "$a"
  t0="$(bt_ids "$a" "$ids")"
  tl="$(date +%s)"
  bt_cli "$a" "bridges-$m" "bridges-$m" || rc=1
  ex="$(bt_cli_exit "$d/cmd-bridges-$m.log")"; last="$(bt_cli_last "$d/cmd-bridges-$m.log")"
  il_t "$a" controller-report >"$r" 2>>"$d/ops.log" || fail "controller-report"
  rows="$(bt_rows "$r" "$t0" "$ids")"
  rid="$(printf '%s\n' "$rows" | awk -F '\t' -v m="$m" '$3 == "bridges" && $4 == "mode-change" && $5 == m { i = $2 } END { print i }')"
  # The spawn line: the CLI waited for the new start, so it is there or
  # comes within BT_LINE_MAX.
  end=$(( $(date +%s) + BT_LINE_MAX ))
  while :; do
    spawn="$(bt_spawn "$a" "$d/supervisor-$m.report")"
    line="${spawn#*	}"; c="${spawn%%	*}"
    printf '%s\n' "$line" | grep -Eq -- "$BT_LINE_RE" && printf '%s\n' "$line" | grep -Eq -- "$hre" && break
    [ "$(date +%s)" -lt "$end" ] || break
    sleep "$CR_POLL"
  done
  # Only a line of exactly the spawn shape is kept; anything else is named.
  if ! printf '%s\n' "$line" | grep -Eq -- "$BT_LINE_RE"; then
    if [ -n "$spawn" ]; then line=unexpected; else line=none; c=-; fi
  fi
  row="$(cr_fresh "$a" $(( tl + BT_FRESH_MAX )))" || rc=1
  el=$(( $(date +%s) - tl ))
  {
    printf 'mode\t%s\ncli_exit\t%s\ncli_last\t%s\nrequest_id\t%s\n' "$m" "$ex" "$last" "${rid:--}"
    [ -z "$rid" ] || printf '%s\n' "$rows" | awk -F '\t' -v i="$rid" '$2 == i' | sed 's/^/journal	/'
    printf 'supervisor\t%s\t%s\n' "${c:--}" "$line"
    printf '%s\n' "$row"
    printf 'elapsed_s\t%s\n' "$el"
  } >"$out"
  assert_eq 0 "$ex" "nice-dns bridges $m exited 0: $(tail -n 5 "$d/cmd-bridges-$m.log" | tr '\n' ' ')"
  assert_eq "Bridges are $m; the proxy restarted and DNS is answering." "$last" "nice-dns bridges $m acknowledged the restart"
  assert_ne "" "$rid" "the journal has a bridges mode-change $m row: $(printf '%s\n' "$rows" | cut -f2-4 | tr '\n' ' ')"
  assert_match "^bridges-$m-[0-9]+\$" "$rid" "the request id is the switch's own"
  printf '%s\n' "$rows" | awk -F '\t' -v i="$rid" '$2 == i && $3 == "service" && $4 == "acknowledged" { f = 1 } END { exit !f }' \
    || fail "no service acknowledged row for $rid: $(printf '%s\n' "$rows" | cut -f2-4 | tr '\n' ' ')"
  assert_ne unexpected "$line" "the supervisor op returned only spawn lines"
  printf '%s\n' "$line" | grep -Eq -- "$hre" || fail "the latest spawn is not '$how': $line"
  assert_eq 0 "$rc" "a fresh name answered within ${BT_FRESH_MAX}s of bridges $m: $row"
  [ "$el" -le "$BT_FRESH_MAX" ] || fail "bridges $m to a fresh name took ${el}s, over ${BT_FRESH_MAX}s"
}

# bt_status <alias> <on|off>: status --tsv's bridges rows, in status-<mode>.tsv.
bt_status() {
  local a="$1" m="$2" d
  d="$(il_dir "$a")"
  bt_cli "$a" "status-$m" status
  {
    awk -F '\t' '$1 == "bridges" && NF == 3' "$d/cmd-status-$m.log" | sed 's/^/status	/'
    printf 'status_exit\t%s\n' "$(bt_cli_exit "$d/cmd-status-$m.log")"
  } >"$d/status-$m.tsv"
  grep -qx "status	bridges	mode	$m" "$d/status-$m.tsv" \
    || fail "status --tsv does not show bridges mode $m: $(grep '^status	' "$d/status-$m.tsv" | tr '\n' ' ')"
  assert_eq 0 "$(awk -F '\t' '$1 == "status_exit" { print $2 }' "$d/status-$m.tsv")" "status --tsv exited 0 (installed, every file readable)"
}

# ─────────────────────────── steps ───────────────────────────────────────────

bt_before() { bt_budget bt_before; cr_before "$@"; }

# On macOS the agents are resumed whatever the install did (OD-8).
bt_install() {
  local plat="$1" a="$2" d proxy rc=0 back=0
  d="$(il_dir "$a")"; proxy="$(il_cell "$a" proxy)"
  bt_budget bt_install
  if [ "$plat" = macos ]; then
    il_t "$a" quiesce-agents >"$d/runtime-quiesce.log" 2>&1 || rc=1
  fi
  [ "$rc" != 0 ] || il_t "$a" install-cell --cell "$proxy/standard" --source-sha "$(il_cell "$a" source_sha)" >"$d/install.log" 2>&1 || rc=3
  if [ "$plat" = macos ]; then
    il_t "$a" resume-agents >"$d/runtime-resume.log" 2>&1 || back=2
    {
      awk -F '\t' '$1 == "quiesced" || $1 == "absent" { print "quiesce\t" $2 "\t" $1 }' "$d/runtime-quiesce.log"
      printf 'restored\t%s\n' "$([ "$back" = 0 ] && echo yes || echo no)"
    } >"$d/runtime.tsv"
  fi
  case "$rc" in
    1) fail "quiesce-agents failed: $(tail -n 5 "$d/runtime-quiesce.log" | tr '\n' ' ')" ;;
    3) fail "install-cell $proxy/standard failed: $(tail -n 20 "$d/install.log")" ;;
  esac
  [ "$back" = 0 ] || fail "the agents were not resumed: $(tail -n 3 "$d/runtime-resume.log" | tr '\n' ' ')"
  il_report "$a" after-install || fail "lifecycle-report"
  il_check_deployed "$plat" "$d/after-install.tsv" "$proxy"
  il_t "$a" set-tunables --mode default >>"$d/ops.log" 2>&1 || fail "set-tunables: $(tail -n 5 "$d/ops.log")"
  printf 'cell\t%s/standard\ngeneration\t%s\n' "$proxy" "$(il_val "$d/after-install.tsv" generation current)" >"$d/install.tsv"
}

bt_off() { bt_require "$2" bt_install; bt_budget bt_off; bt_switch "$1" "$2" off; }

bt_refresh() {
  local a="$2" d ids r t0 rc=0 rows
  d="$(il_dir "$a")"; ids="$d/refresh.ids"; r="$d/refresh.report"
  bt_require "$a" bt_off
  bt_budget bt_refresh
  t0="$(bt_ids "$a" "$ids")"
  il_t "$a" bridges-refresh >"$d/refresh.log" 2>&1 || rc=$?
  il_t "$a" controller-report >"$r" 2>>"$d/ops.log" || fail "controller-report"
  rows="$(bt_rows "$r" "$t0" "$ids" | awk -F '\t' '$3 == "bridges"')"
  {
    printf 'refresh_exit\t%s\n' "$rc"
    printf 'refresh_result\t%s\n' "$(awk -F '\t' '$1 == "result" { v = $2 } END { print (v == "" ? "-" : v) }' "$d/refresh.log")"
    [ -z "$rows" ] || printf '%s\n' "$rows" | sed 's/^/journal	/'
  } >"$d/refresh-off.tsv"
  assert_eq 0 "$rc" "nice-dns-health bridges-refresh exited 0 with bridges off: $(tail -n 3 "$d/refresh.log" | tr '\n' ' ')"
  assert_eq skipped "$(awk -F '\t' '$1 == "refresh_result" { print $2 }' "$d/refresh-off.tsv")" "the refresh says skipped"
  printf '%s\n' "$rows" | awk -F '\t' '$4 == "skipped" && $5 == "bridges off" { f = 1 } END { exit !f }' \
    || fail "no journal row bridges skipped bridges off: $(printf '%s\n' "$rows" | cut -f3-5 | tr '\n' ' ')"
  assert_eq "" "$(printf '%s\n' "$rows" | awk -F '\t' 'NF && !($4 == "skipped" && $5 == "bridges off")')" "the refresh changed nothing (no other bridges row)"
}

bt_status_off() { bt_require "$2" bt_refresh; bt_budget bt_status_off; bt_status "$2" off; }
bt_on() { bt_require "$2" bt_status_off; bt_budget bt_on; bt_switch "$1" "$2" on; }
bt_status_on() { bt_require "$2" bt_on; bt_budget bt_status_on; bt_status "$2" on; }

# Runs whatever came before it: the target ends with bridges on, settled.
bt_after() {
  local a="$2" d m
  d="$(il_dir "$a")"
  bt_cli "$a" status-after status
  m="$(awk -F '\t' '$1 == "bridges" && $2 == "mode" { print $3; exit }' "$d/cmd-status-after.log")"
  if [ "$m" = off ]; then
    bt_cli "$a" after-on bridges-on || fail "nice-dns bridges on (after): $(tail -n 5 "$d/cmd-after-on.log" | tr '\n' ' ')"
    bt_cli "$a" status-after-on status
    m="$(awk -F '\t' '$1 == "bridges" && $2 == "mode" { print $3; exit }' "$d/cmd-status-after-on.log")"
  fi
  # The step's promise: the target ends with bridges on. No mode read is no pass.
  [ "$m" = on ] || fail "the target does not end with bridges on (status --tsv mode: ${m:-none})"
  cr_settled "$a"
  printf 'settled\tyes\nbridges_mode\t%s\n' "${m:--}" >"$d/after.tsv"
}

# bt_reuse_dir <platform>: that platform's cell in a run listed in
# NICE_DNS_CELL_REUSE_RUNS, passed in every step, at the same product (DEC-009).
bt_reuse_dir() {
  local r d s ok
  for r in ${NICE_DNS_CELL_REUSE_RUNS:-}; do
    case "$r" in /*) ;; *) fail "NICE_DNS_CELL_REUSE_RUNS: $r is not an absolute run directory" ;; esac
    [ -d "$r" ] || fail "NICE_DNS_CELL_REUSE_RUNS: no run directory $r"
    for d in "$r"/bridges-toggle/*/; do
      [ -f "$d/cell.tsv" ] || continue
      [ "$(il_cell_of "$d" cell | cut -d/ -f1)" = "$1" ] || continue
      [ "$(il_cell_of "$d" adapter)" = "$(cr_adapter)" ] || continue
      ok=1
      for s in $BT_STEPS; do grep -qx "$s" "$d/passed.tsv" 2>/dev/null || ok=0; done
      [ "$ok" = 1 ] || continue
      il_same_product "$(il_cell_of "$d" source_sha)" "$1" || continue
      # A cell proven under a looser scenario does not prove this one.
      git -C "$NICE_DNS_ROOT" diff --quiet "$(il_cell_of "$d" source_sha)" HEAD -- \
        tests/live/bridges-toggle.sh tests/live/target.sh tests/manifests/bridges-toggle.tsv tests/reports/verify.sh 2>/dev/null || continue
      printf '%s\n' "${d%/}"
      return 0
    done
  done
  return 0
}

BT_SCENARIOS='BT-OFF:switch-off.tsv BT-REFRESH:refresh-off.tsv BT-STATUS-OFF:status-off.tsv BT-ON:switch-on.tsv BT-STATUS-ON:status-on.tsv'
BT_SECRETS='cert=[A-Za-z0-9+/]{20}|(^|[^0-9A-Fa-f])[0-9A-F]{40}([^0-9A-Fa-f]|$)|PRIVATE KEY|"sid":|pwhash|BRIDGE[0-9]+=|obfs4 [0-9]'

bt_receipt() {
  local root out r repo cd st d from cell key gen a f id n=0 v s ok p selected rd
  root="$(dirname "$(dirname "$ARTIFACT_DIR")")"
  out="$root/receipts/bridges-toggle/$RUN_ID"; r="$out/receipt.tsv"
  assert_no_path "$out" "this run has no bridges-toggle receipt yet"
  mkdir -p "$out/cells" || fail "cannot create $out"
  {
    printf '# schema\tnice-dns-receipt/1\n'
    printf 'receipt\tbridges-toggle\nrun_id\t%s\ncreated_utc\t%s\n' "$RUN_ID" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
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
    # What the run did not prove.
    printf 'limit\tmac-runtime-domain\t-\tscope=BL-052\tthe macOS install ran over ssh inside the gui session (launchctl asuser, OD-8), not from a login at the Mac\n'
    printf 'limit\tmac-gui-context\t-\tscope=BL-052\tmacOS nice-dns commands ran in the GUI context (launchctl asuser), not from plain ssh or Terminal\n'
  } >"$r"
  selected=" $(il_platforms) "
  : >"$CASE_DIR/cell-dirs.tsv"
  for d in "$ARTIFACT_DIR"/bridges-toggle/*/; do
    [ -f "$d/cell.tsv" ] || continue
    printf '%s\t-\n' "${d%/}" >>"$CASE_DIR/cell-dirs.tsv"
  done
  for p in linux macos; do
    case "$selected" in *" $p "*) continue ;; esac
    rd="$(bt_reuse_dir "$p")"
    [ -z "$rd" ] || printf '%s\t%s\n' "$rd" "$(basename "$(dirname "$(dirname "$rd")")")" >>"$CASE_DIR/cell-dirs.tsv"
  done
  while IFS="$(printf '\t')" read -r d from; do
    cell="$(il_cell_of "$d" cell)"; key="$(printf '%s' "$cell" | tr / -)"
    a="$(il_cell_of "$d" target)"
    gen="generation=$(il_val "$d/after-install.tsv" generation current)"
    mkdir -p "$out/cells/$key"
    cp "$d/cell.tsv" "$out/cells/$key/"
    ok=1
    for s in $BT_STEPS; do grep -qx "$s" "$d/passed.tsv" 2>/dev/null || ok=0; done
    if [ "$ok" != 1 ]; then
      printf 'cell\t%s\t%s\t%s\t%s\t%s\tfailed\n' "${cell%%/*}" "$(printf '%s' "$cell" | cut -d/ -f2)" "${cell##*/}" "$a" "$gen" >>"$r"
      continue
    fi
    n=$((n + 1))
    printf 'cell\t%s\t%s\t%s\t%s\t%s\tobserved\n' "${cell%%/*}" "$(printf '%s' "$cell" | cut -d/ -f2)" "${cell##*/}" "$a" "$gen" >>"$r"
    [ "$from" = - ] || printf 'reuse\t%s\t%s\t%s\n' "$cell" "$from" "$(il_cell_of "$d" source_sha)" >>"$r"
    for id in $BT_SCENARIOS; do
      f="${id#*:}"
      cp "$d/$f" "$out/cells/$key/$f"
      printf 'scenario\t%s\t%s\tpass\tcells/%s/%s\t%s\t%s\n' "${id%%:*}" "$cell" "$key" "$f" "$(sha256sum "$out/cells/$key/$f" | cut -d' ' -f1)" "$gen" >>"$r"
    done
  done <"$CASE_DIR/cell-dirs.tsv"
  assert_match '^[1-9]' "$n" "at least one fully passed cell"
  v="$(bash "$NICE_DNS_ROOT/tests/reports/verify.sh" check "$r" 2>&1)"
  assert_rc 0 "$?" "the bridges-toggle receipt verifies: $v"
  assert_eq "" "$(grep -rlE "$BT_SECRETS" "$out" 2>/dev/null)" \
    "no bridge line, certificate, fingerprint, key, session or password hash in the receipt"
  printf 'receipt\t%s\n' "$r" >"$CASE_DIR/receipt-path.tsv"
}

t_01_before() { il_selection; il_each bt_before; }
t_02_install() { il_selection; il_each bt_install; }
t_03_off() { il_selection; il_each bt_off; }
t_04_refresh() { il_selection; il_each bt_refresh; }
t_05_status_off() { il_selection; il_each bt_status_off; }
t_06_on() { il_selection; il_each bt_on; }
t_07_status_on() { il_selection; il_each bt_status_on; }
t_08_after() { il_selection; il_each bt_after; }

t_09_privacy() {
  il_selection
  assert_eq "" "$(grep -rlE "$BT_SECRETS" "$ARTIFACT_DIR/bridges-toggle" --include='*.tsv' 2>/dev/null)" \
    "no report, sample or step record holds bridge material, a session or a hash"
}

t_10_receipt() { il_selection; bt_receipt; }
