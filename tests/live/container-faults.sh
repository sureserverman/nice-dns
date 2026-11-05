# shellcheck shell=bash
# Group live/container-faults (restart-policy plan, Task 3.1). Run by
# `tests/run.sh live container-faults --live --targets FILE --platforms
# linux,macos`. One cell per platform: the proxy the target runs now, standard
# Pi-hole, installed from this checkout. The controller runs on its real
# timers and default tunables; nothing here repairs anything: every recovery
# the steps wait for is the controller's own.
#
# A failed step stops that platform's later fault steps, but cf_after still
# runs, so the target ends with a working stack. NICE_DNS_CELL_REUSE_RUNS
# names earlier run directories: a platform whose cell passed every step
# there, at a commit with the same product files, is not run again (DEC-009).
#
# Evidence: $ARTIFACT_DIR/container-faults/<alias>/. Only *.tsv is checked and
# copied into the receipt; the command's output stays in cmd-*.log.
#
# NICE_DNS_TARGET_ADAPTER replaces target.sh only for the dry run
# (integration/container-faults-dryrun, NICE_DNS_IL_DRY_RUN=1).

cf_plan() {
  cat <<'EOF'
cf_before   snapshot the target, record its proxy as the cell
cf_install  nice-dns install from a checkout of HEAD, over the running stack; real timers, default tunables
cf_pihole   SIGSTOP pihole-FTL; expect pi-hole requested, acknowledged, ready, a new start and a fresh name within 10 minutes; thaw
cf_pause    Linux: pause unbound; expect the runtime repair of containers-paused (requested, acknowledged, ready) and a fresh name within 4 minutes. macOS: not run (no pause)
cf_crash    Linux: crash the proxy 4 times, 20 s apart; expect one crash-loop escalation, no controller restart of the proxy, NRestarts up by 4 with growing delays, a fresh name within 10 minutes. macOS: not run
cf_stop     macOS: stop unbound; expect the containers-missing repair (requested, acknowledged, ready), a new start and a fresh name within 10 minutes. Linux: not run
cf_after    thaw, unpause, end the crash sequence: the target ends with a settled stack
cf_privacy  no bridge material, session or hash in the evidence
cf_receipt  assemble and verify the container-faults receipt
EOF
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  if [ "${1:-}" = --dry-run ]; then
    echo "dry run: no target is touched"
    cf_plan
    exit 0
  fi
  echo "usage: container-faults.sh --dry-run (the run itself: tests/run.sh live container-faults)" >&2
  exit 2
fi

# The helpers of live/command-recovery (settle, quiet, fresh name, journal),
# with this group's own directory.
# shellcheck source=tests/live/command-recovery.sh
. "$NICE_DNS_ROOT/tests/live/command-recovery.sh"
unset -f t_01_before t_02_install t_03_fault_unbound t_04_fault_proxy t_05_restart t_06_reinstall t_07_uninstall t_08_final t_09_privacy t_10_receipt
il_dir() { printf '%s\n' "$ARTIFACT_DIR/container-faults/$1"; }

CF_STEPS='cf_before cf_install cf_pihole cf_pause cf_crash cf_stop cf_after'
CF_RECOVER_MAX="${CF_RECOVER_MAX:-600}"
CF_PAUSE_MAX="${CF_PAUSE_MAX:-240}"
CF_CRASH_TIMES="${CF_CRASH_TIMES:-4}"
CF_CRASH_EVERY="${CF_CRASH_EVERY:-20}"
# ND_POLICY_CRASH_WINDOW_S (600): the hold is watched for the whole window.
CF_CRASH_OBSERVE="${CF_CRASH_OBSERVE:-600}"
# shellcheck disable=SC2034 # read by il_each
IL_FIRST_STEPS=cf_before

# cf_require <alias> <step>: the step before this one passed on this platform.
cf_require() {
  grep -qx "$2" "$(il_dir "$1")/passed.tsv" 2>/dev/null || fail "$2 did not pass on $1; this step does not run"
}

# cf_not_here <alias> <step> <why>: a step that has no meaning on this platform.
cf_not_here() { printf 'step\t%s\nnot_run\t%s\n' "$2" "$3" >"$(il_dir "$1")/$2.not-run.tsv"; }

# cf_ids <alias> <file>: the request ids the active journal holds now. A row
# of the fault is one at or after its injection whose id is not in this list:
# the epoch alone also takes an earlier action's row from the same second.
cf_ids() {
  local r
  r="$(il_dir "$1")/ids.report"
  il_t "$1" controller-report >"$r" 2>>"$(il_dir "$1")/ops.log" || fail "controller-report"
  il_sec "$r" journal-active | awk -F '\t' '$1 ~ /^[0-9]+$/ { print $2 }' | LC_ALL=C sort -u >"$2"
}

# cf_rows <report> <since> <ids file>: the journal rows of this fault.
cf_rows() {
  cr_jrows "$1" "$2" | awk -F '\t' -v f="$3" 'BEGIN { while ((getline l < f) > 0) old[l] = 1 } !($2 in old)'
}

# cf_done <report> <since> <ids file> <component> <kind>: the controller
# recovered: one request has requested, acknowledged and ready rows; for kind
# pause it is a runtime repair of containers-paused, else any of <component>.
cf_done() {
  cf_rows "$1" "$2" "$3" | awk -F '\t' -v c="$4" -v k="$5" '
    $3 != c { next }
    $4 == "requested" && k == "pause" && $5 !~ /^repair of containers-paused/ { bad[$2] = 1 }
    { s[$2] = s[$2] " " $4 }
    END { for (i in s) if (!(i in bad) && s[i] ~ / requested/ && s[i] ~ / acknowledged/ && s[i] ~ / ready/) f = 1; exit !f }'
}

# cf_fault <alias> <evidence> <component in the journal> <container> <kind>
# <max s> <inject op> [args]: inject, wait, and record what the controller did
# by itself. kind: restart (a new start is required) or pause (unpaused).
cf_fault() {
  local a="$1" out="$2" comp="$3" c="$4" kind="$5" max="$6" op="$7" d r t0 g0 g1 end row rc=0 t1 during ids
  shift 7
  d="$(il_dir "$a")"; r="$d/${out%.tsv}.report"; ids="$d/${out%.tsv}.ids"
  cf_ids "$a" "$ids"
  cr_report "$a" fault-before || fail "command-report"
  g0="$(cr_start "$d/fault-before.tsv" "$c")"
  assert_ne "" "$g0" "$c runs before the fault"
  t0="$(cr_now "$d/fault-before.tsv")"
  il_t "$a" "$op" "$@" >>"$d/ops.log" 2>&1 || fail "$op: $(tail -n 5 "$d/ops.log")"
  # The control: while the fault holds, a fresh name does not answer.
  during="$(il_t "$a" fresh-name 2>>"$d/ops.log" | awk -F '\t' '$1 == "fresh_name" { print $3 }')"
  end=$(( $(date +%s) + max ))
  while :; do
    if il_t "$a" controller-report >"$r" 2>>"$d/ops.log" && cf_done "$r" "$t0" "$ids" "$comp" "$kind"; then break; fi
    [ "$(date +%s)" -lt "$end" ] || { rc=1; break; }
    sleep "$CR_POLL"
  done
  case "$op" in
    freeze-service) il_t "$a" thaw-service --component "$c" >>"$d/ops.log" 2>&1 || rc=1 ;;
    pause-container) il_t "$a" unpause-container --component "$c" >>"$d/ops.log" 2>&1 || rc=1 ;;
  esac
  row="$(cr_fresh "$a" "$end")" || rc=1
  cr_report "$a" fault-after || fail "command-report"
  g1="$(cr_start "$d/fault-after.tsv" "$c")"
  t1="$(cr_now "$d/fault-after.tsv")"
  {
    printf 'fault\t%s\ninjected\t%s\nelapsed_s\t%s\nfresh_during_fault\t%s\ngeneration_before\t%s\ngeneration_after\t%s\n' "$op" "$t0" "$(( t1 - t0 ))" "$during" "$g0" "$g1"
    if [ -n "$g1" ] && [ "$g1" != "$g0" ]; then printf 'generation_changed\tyes\n'; else printf 'generation_changed\tno\n'; fi
    if [ -n "$g1" ]; then printf 'running_after\tyes\n'; else printf 'running_after\tno\n'; fi
    cf_rows "$r" "$t0" "$ids" | sed 's/^/journal	/'
    printf '%s\n' "$row"
  } >"$d/$out"
  assert_ne "" "$during" "the control ran: fresh-name gave a row during the fault ($(grep -v level=warning "$d/ops.log" | tail -n 2 | tr '\n' ' '))"
  case "$during" in NOERROR|NXDOMAIN) fail "a fresh name answered ($during) right after $op: the fault did not take hold" ;; esac
  assert_eq 0 "$rc" "the controller recovered from $op within ${max}s: $(cf_rows "$r" "$t0" "$ids" | cut -f3,4 | tr '\n' ' '); $row"
  assert_ne "" "$g1" "$c runs after $op"
  if [ "$kind" = restart ]; then
    [ "$g1" != "$g0" ] || fail "$c has no new start after $op ($g0 -> $g1)"
  fi
  [ $(( t1 - t0 )) -le "$max" ] || fail "recovery from $op took $(( t1 - t0 ))s, over ${max}s"
}

# ─────────────────────────── steps ───────────────────────────────────────────

cf_before() { cr_before "$@"; }
cf_install() { cr_install "$@"; }

cf_pihole() {
  local a="$2"
  cf_require "$a" cf_install
  cr_settled "$a"
  cr_quiet "$a"
  cf_fault "$a" fault-pihole.tsv pi-hole pi-hole restart "$CF_RECOVER_MAX" freeze-service --component pi-hole
}

cf_pause() {
  local plat="$1" a="$2"
  cf_require "$a" cf_pihole
  if [ "$plat" = macos ]; then cf_not_here "$a" cf_pause "Apple container has no pause"; return 0; fi
  cr_settled "$a"
  cr_quiet "$a"
  cf_fault "$a" fault-pause.tsv runtime unbound pause "$CF_PAUSE_MAX" pause-container --component unbound
}

# cf_delays <crash report>: one exit-to-restart delay per crash, in order.
cf_delays() {
  il_sec "$1" unit | awk -F '\t' '$1 == "exit" { e = $2; next } $1 == "restart" && e != "" { print $2 - e; e = "" }'
}

cf_crash() {
  local plat="$1" a="$2" d c r cr t0 tl end row rc=0 st kills rise esc held delays grow n0 n1 elapsed ids
  d="$(il_dir "$a")"; ids="$d/crash.ids"
  cf_require "$a" cf_pause
  if [ "$plat" = macos ]; then cf_not_here "$a" cf_crash "Apple container restarts nothing by itself; the controller is the only restart owner (no crash loop to hold)"; return 0; fi
  c="tor-$(il_cell "$a" proxy)"
  cr_settled "$a"
  cr_quiet "$a"
  cf_ids "$a" "$ids"
  cr_report "$a" crash-before || fail "command-report"
  t0="$(cr_now "$d/crash-before.tsv")"; tl="$(date +%s)"
  il_t "$a" crash-container --component "$c" --times "$CF_CRASH_TIMES" --every "$CF_CRASH_EVERY" >>"$d/ops.log" 2>&1 \
    || fail "crash-container: $(tail -n 5 "$d/ops.log")"
  cr="$d/crash.report"
  # The sequence ends by itself (NICE_DNS_FREEZE_MAX); wait for it.
  end=$(( tl + CF_RECOVER_MAX ))
  while :; do
    il_t "$a" crash-report >"$cr" 2>>"$d/ops.log" || fail "crash-report"
    [ "$(il_val "$cr" sequence running)" = no ] && break
    [ "$(date +%s)" -lt "$end" ] || { il_t "$a" stop-crash >>"$d/ops.log" 2>&1; fail "the crash sequence did not end within ${CF_RECOVER_MAX}s"; }
    sleep "$CR_POLL"
  done
  row="$(cr_fresh "$a" "$end")" || rc=1
  elapsed=$(( $(date +%s) - tl ))
  # Watch the hold for the whole crash window before reading the journal.
  while [ "$(date +%s)" -lt $(( tl + CF_CRASH_OBSERVE )) ]; do sleep "$CR_POLL"; done
  r="$d/crash-controller.report"
  il_t "$a" controller-report >"$r" 2>>"$d/ops.log" || fail "controller-report"
  il_t "$a" crash-report >"$cr" 2>>"$d/ops.log" || fail "crash-report"
  kills="$(il_sec "$cr" sequence | awk -F '\t' '$1 == "kill" && $3 == 0' | grep -c .)"
  n0="$(il_val "$cr" sequence nrestarts_before)"; n1="$(il_val "$cr" unit nrestarts)"
  rise=$(( ${n1:-0} - ${n0:-0} ))
  delays="$(cf_delays "$cr" | paste -sd' ' -)"
  grow="$(printf '%s\n' "$delays" | awk '{ ok = (NF >= 3); for (i = 2; i <= NF; i++) if ($i <= $(i - 1)) ok = 0; print (ok ? "yes" : "no") }')"
  esc="$(cf_rows "$r" "$t0" "$ids" | awk -F '\t' -v c="$c" '$3 == "controller" && $4 == "escalated" && index($5, "crash-loop: " c " ") == 1' | grep -c .)"
  held="$(cf_rows "$r" "$t0" "$ids" | awk -F '\t' '$4 == "requested" && ($3 == "proxy" || $3 == "tor" || $3 == "stack" || $3 == "runtime")' | grep -c .)"
  st="$(il_val "$cr" unit state)"
  {
    printf 'fault\tcrash-container\ncomponent\t%s\ninjected\t%s\ntimes\t%s\nevery_s\t%s\n' "$c" "$t0" "$CF_CRASH_TIMES" "$CF_CRASH_EVERY"
    printf 'kills\t%s\nnrestarts_before\t%s\nnrestarts_after\t%s\nnrestarts_rise\t%s\n' "$kills" "$n0" "$n1" "$rise"
    printf 'delays_s\t%s\nbackoff_growing\t%s\n' "$delays" "$grow"
    printf 'crash_escalations\t%s\ncontroller_proxy_restarts\t%s\nunit_state_after\t%s\nelapsed_s\t%s\n' "$esc" "$held" "$st" "$elapsed"
    cf_rows "$r" "$t0" "$ids" | sed 's/^/journal	/'
    printf '%s\n' "$row"
  } >"$d/fault-crash.tsv"
  assert_eq "$CF_CRASH_TIMES" "$kills" "every crash of the sequence was sent"
  [ "$rise" -ge "$CF_CRASH_TIMES" ] || fail "NRestarts rose by $rise, not by the $CF_CRASH_TIMES crashes ($n0 -> $n1)"
  assert_eq yes "$grow" "the unit's delay before each restart grows (back-off): $delays"
  assert_eq 1 "$esc" "exactly one crash-loop escalation of $c: $(cf_rows "$r" "$t0" "$ids" | cut -f3,4 | tr '\n' ' ')"
  assert_eq 0 "$held" "the controller restarted nothing of the proxy during the loop"
  assert_eq 0 "$rc" "a fresh name answered within ${CF_RECOVER_MAX}s of the first crash: $row"
  assert_eq active "$st" "the proxy's unit is active at the end"
}

cf_stop() {
  local plat="$1" a="$2"
  cf_require "$a" cf_crash
  if [ "$plat" = linux ]; then cf_not_here "$a" cf_stop "Linux restarts a stopped unit's container through the runtime repair already proven by command-recovery CR-PROXY"; return 0; fi
  cr_settled "$a"
  cr_quiet "$a"
  cf_fault "$a" fault-stop.tsv runtime unbound restart "$CF_RECOVER_MAX" stop-container --component unbound
}

# Runs whatever came before it: the target must end with a settled stack.
cf_after() {
  local plat="$1" a="$2" d
  d="$(il_dir "$a")"
  il_t "$a" thaw-service --component pi-hole >>"$d/ops.log" 2>&1
  if [ "$plat" = linux ]; then
    il_t "$a" unpause-container --component unbound >>"$d/ops.log" 2>&1
    il_t "$a" stop-crash >>"$d/ops.log" 2>&1
  fi
  cr_settled "$a"
  printf 'settled\tyes\n' >"$d/after.tsv"
}

# cf_reuse_dir <platform>: that platform's cell in a run listed in
# NICE_DNS_CELL_REUSE_RUNS, passed in every step, at the same product (DEC-009).
cf_reuse_dir() {
  local r d s ok
  for r in ${NICE_DNS_CELL_REUSE_RUNS:-}; do
    case "$r" in /*) ;; *) fail "NICE_DNS_CELL_REUSE_RUNS: $r is not an absolute run directory" ;; esac
    [ -d "$r" ] || fail "NICE_DNS_CELL_REUSE_RUNS: no run directory $r"
    for d in "$r"/container-faults/*/; do
      [ -f "$d/cell.tsv" ] || continue
      [ "$(il_cell_of "$d" cell | cut -d/ -f1)" = "$1" ] || continue
      [ "$(il_cell_of "$d" adapter)" = "$(cr_adapter)" ] || continue
      ok=1
      for s in $CF_STEPS; do grep -qx "$s" "$d/passed.tsv" 2>/dev/null || ok=0; done
      [ "$ok" = 1 ] || continue
      il_same_product "$(il_cell_of "$d" source_sha)" "$1" || continue
      # A cell proven under a looser scenario does not prove this one.
      git -C "$NICE_DNS_ROOT" diff --quiet "$(il_cell_of "$d" source_sha)" HEAD -- \
        tests/live/container-faults.sh tests/live/target.sh tests/manifests/container-faults.tsv tests/reports/verify.sh 2>/dev/null || continue
      printf '%s\n' "${d%/}"
      return 0
    done
  done
  return 0
}

# cf_scenarios <platform>: ID:artifact per scenario of that platform.
cf_scenarios() {
  case "$1" in
    linux) echo CF-PIHOLE:fault-pihole.tsv CF-PAUSE:fault-pause.tsv CF-CRASH:fault-crash.tsv ;;
    macos) echo CF-PIHOLE:fault-pihole.tsv CF-STOP:fault-stop.tsv ;;
  esac
}

cf_receipt() {
  local root out r repo cd st d from cell key gen a f id n=0 v s ok p selected rd
  root="$(dirname "$(dirname "$ARTIFACT_DIR")")"
  out="$root/receipts/container-faults/$RUN_ID"; r="$out/receipt.tsv"
  assert_no_path "$out" "this run has no container-faults receipt yet"
  mkdir -p "$out/cells" || fail "cannot create $out"
  {
    printf '# schema\tnice-dns-receipt/1\n'
    printf 'receipt\tcontainer-faults\nrun_id\t%s\ncreated_utc\t%s\n' "$RUN_ID" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
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
    printf 'limit\tmac-gui-context\t-\tscope=BL-052\tthe macOS install ran in the GUI context (launchctl asuser), not from plain ssh or Terminal\n'
  } >"$r"
  selected=" $(il_platforms) "
  : >"$CASE_DIR/cell-dirs.tsv"
  for d in "$ARTIFACT_DIR"/container-faults/*/; do
    [ -f "$d/cell.tsv" ] || continue
    printf '%s\t-\n' "${d%/}" >>"$CASE_DIR/cell-dirs.tsv"
  done
  for p in linux macos; do
    case "$selected" in *" $p "*) continue ;; esac
    rd="$(cf_reuse_dir "$p")"
    [ -z "$rd" ] || printf '%s\t%s\n' "$rd" "$(basename "$(dirname "$(dirname "$rd")")")" >>"$CASE_DIR/cell-dirs.tsv"
  done
  while IFS="$(printf '\t')" read -r d from; do
    cell="$(il_cell_of "$d" cell)"; key="$(printf '%s' "$cell" | tr / -)"
    a="$(il_cell_of "$d" target)"
    gen="generation=$(il_val "$d/after-install.tsv" generation current)"
    mkdir -p "$out/cells/$key"
    cp "$d/cell.tsv" "$out/cells/$key/"
    ok=1
    for s in $CF_STEPS; do grep -qx "$s" "$d/passed.tsv" 2>/dev/null || ok=0; done
    if [ "$ok" != 1 ]; then
      printf 'cell\t%s\t%s\t%s\t%s\t%s\tfailed\n' "${cell%%/*}" "$(printf '%s' "$cell" | cut -d/ -f2)" "${cell##*/}" "$a" "$gen" >>"$r"
      continue
    fi
    n=$((n + 1))
    printf 'cell\t%s\t%s\t%s\t%s\t%s\tobserved\n' "${cell%%/*}" "$(printf '%s' "$cell" | cut -d/ -f2)" "${cell##*/}" "$a" "$gen" >>"$r"
    [ "$from" = - ] || printf 'reuse\t%s\t%s\t%s\n' "$cell" "$from" "$(il_cell_of "$d" source_sha)" >>"$r"
    for id in $(cf_scenarios "${cell%%/*}"); do
      f="${id#*:}"
      cp "$d/$f" "$out/cells/$key/$f"
      printf 'scenario\t%s\t%s\tpass\tcells/%s/%s\t%s\t%s\n' "${id%%:*}" "$cell" "$key" "$f" "$(sha256sum "$out/cells/$key/$f" | cut -d' ' -f1)" "$gen" >>"$r"
    done
  done <"$CASE_DIR/cell-dirs.tsv"
  assert_match '^[1-9]' "$n" "at least one fully passed cell"
  v="$(bash "$NICE_DNS_ROOT/tests/reports/verify.sh" check "$r" 2>&1)"
  assert_rc 0 "$?" "the container-faults receipt verifies: $v"
  assert_eq "" "$(grep -rlE 'cert=[A-Za-z0-9+/]{20}|(^|[^0-9A-Fa-f])[0-9A-F]{40}([^0-9A-Fa-f]|$)|PRIVATE KEY|"sid":|pwhash|BRIDGE[0-9]+=' "$out" 2>/dev/null)" \
    "no bridge line, certificate, fingerprint, key, session or password hash in the receipt"
  printf 'receipt\t%s\n' "$r" >"$CASE_DIR/receipt-path.tsv"
}

t_01_before() { il_selection; il_each cf_before; }
t_02_install() { il_selection; il_each cf_install; }
t_03_pihole() { il_selection; il_each cf_pihole; }
t_04_pause() { il_selection; il_each cf_pause; }
t_05_crash() { il_selection; il_each cf_crash; }
t_06_stop() { il_selection; il_each cf_stop; }
t_07_after() { il_selection; il_each cf_after; }

t_08_privacy() {
  il_selection
  assert_eq "" "$(grep -rlE 'cert=[A-Za-z0-9+/]{20}|(^|[^0-9A-Fa-f])[0-9A-F]{40}([^0-9A-Fa-f]|$)|PRIVATE KEY|"sid":|pwhash|BRIDGE[0-9]+=' "$ARTIFACT_DIR/container-faults" --include='*.tsv' 2>/dev/null)" \
    "no report, sample or step record holds bridge material, a session or a hash"
}

t_09_receipt() { il_selection; cf_receipt; }
