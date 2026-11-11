# shellcheck shell=bash
# Group live/switch-autocheck (app-switches-autocheck plan, Task 3.1). Run by
# `tests/run.sh live switch-autocheck --live --targets FILE` (OD-4: mint and
# the mac, never this machine). One cell per platform: the proxy the target
# runs now, standard Pi-hole, installed by the nice-dns command from a clone
# of this checkout's committed HEAD (a git bundle), whose release/assets.lock
# pins the apps with the selectors.
#
#   sa_before    snapshot; the recorded choices (status variant and pihole);
#                no pi-hole-hardened checkout anywhere on the host; Linux:
#                the polkit test rule, so the helper's pkexec needs nobody
#   sa_install   nice-dns install from the bundle: the stack, the app, and
#                `update auto loaded`
#   sa_proxy     in the user's session the app's own action `--run-action
#                proxy-<the other> --exit` returns 0; status shows the other
#                variant and the same source_commit; the other proxy runs and
#                the old one does not; DNS answers
#   sa_hardened  nice-dns switch pihole hardened: exit 0 and its last line;
#                status shows hardened and the same source_commit; the
#                running Pi-hole is the hardened one, built from the kept
#                source's pihole-hardened/base with still no checkout on the
#                host; DNS answers
#   sa_update    the update schedule started by hand (Linux: its service;
#                macOS: launchctl kickstart): status's update checked_at
#                moves past the value read before
#   sa_restore   runs whatever came before: the target ends on its recorded
#                choices (one `nice-dns reinstall --local <proxy> --<pihole>`
#                when it is not on them), DNS answers, and the polkit test
#                rule is gone
#
# macOS (DEC-024, BL-052): target.sh runs the command and the app inside the
# gui session (launchctl asuser). mint: the app draws with GSK_RENDERER=cairo
# (DEC-027).
#
# A failed step stops that platform's later steps, but sa_restore still runs
# (it alone takes no run budget, so a late failure is still put back), and on
# Linux the polkit test rule is removed whatever the restore found. The
# restore puts back the recorded proxy and Pi-hole choices, not the version:
# the target keeps this checkout's HEAD and its apps (`nice-dns reinstall
# --branch main` returns it to main). No other step starts past SA_RUN_MAX
# from the run's first step; every DNS wait is bounded by SA_DNS_MAX. A
# target that does not answer is not run: sa_before says it is offline and
# asks for it to be woken, and the receipt names it. A failed cell's receipt
# row names the first step it did not pass. NICE_DNS_CELL_REUSE_RUNS names earlier run
# directories: a platform whose cell passed every step there, at a commit with
# the same product files and the same scenario, is not run again (DEC-009).
#
# Evidence: $ARTIFACT_DIR/switch-autocheck/<alias>/. Only *.tsv is checked
# and copied into the receipt; the command's, installer's and app's output
# stay in *.log.
#
# NICE_DNS_TARGET_ADAPTER replaces target.sh only for the dry run
# (integration/switch-autocheck-dryrun, NICE_DNS_IL_DRY_RUN=1).

SA_STEPS='sa_before sa_install sa_proxy sa_hardened sa_update sa_restore'

sa_plan() {
  local p
  echo "dry run: no target is touched"
  for p in linux macos; do
    if [ "$p" = linux ]; then
      printf '%s %-12s %s\n' "$p" sa_before "snapshot; record status variant and pihole as the cell ($p/<proxy>/standard); switch-report: no pi-hole-hardened checkout on the host; polkit-test-rule add"
    else
      printf '%s %-12s %s\n' "$p" sa_before "snapshot; record status variant and pihole as the cell ($p/<proxy>/standard); switch-report: no pi-hole-hardened checkout on the host"
    fi
    printf '%s %-12s %s\n' "$p" sa_install "command install-git --cell <proxy>/standard --source-sha HEAD (the bundle); the deployment checked; the app installed; status update auto loaded"
    if [ "$p" = linux ]; then
      printf '%s %-12s %s\n' "$p" sa_proxy "gui-session --mode proxy-<other>: nice-dns-gui --run-action proxy-<other> --exit with GSK_RENDERER=cairo returns 0; status variant <other>, same source_commit; tor-<other> runs, tor-<proxy> does not; DNS answers"
    else
      printf '%s %-12s %s\n' "$p" sa_proxy "gui-session --mode proxy-<other>: the app's --run-action proxy-<other> --exit in the gui session (launchctl asuser) returns 0; status variant <other>, same source_commit; tor-<other> runs, tor-<proxy> does not; DNS answers"
    fi
    printf '%s %-12s %s\n' "$p" sa_hardened "command switch-pihole-hardened: nice-dns switch pihole hardened exits 0 with its last line; status pihole hardened, same source_commit; switch-report: the running Pi-hole is hardened, kept base present, no checkout; DNS answers"
    if [ "$p" = linux ]; then
      printf '%s %-12s %s\n' "$p" sa_update "status checked_at; update-schedule: systemctl --user start nice-dns-health-update.service; status checked_at moved"
    else
      printf '%s %-12s %s\n' "$p" sa_update "status checked_at; update-schedule: launchctl kickstart gui/<uid>/org.nice-dns.health-update, waited until done; status checked_at moved"
    fi
    if [ "$p" = linux ]; then
      printf '%s %-12s %s\n' "$p" sa_restore "runs whatever came before: command reinstall-cell --cell <recorded proxy>/<recorded pihole> when status is not on them; status on the recorded choices; DNS answers; polkit-test-rule remove"
    else
      printf '%s %-12s %s\n' "$p" sa_restore "runs whatever came before: command reinstall-cell --cell <recorded proxy>/<recorded pihole> when status is not on them; status on the recorded choices; DNS answers"
    fi
  done
  printf '%s %-12s %s\n' all sa_privacy "no bridge material, session or hash in the evidence"
  printf '%s %-12s %s\n' all sa_receipt "assemble and verify the switch-autocheck receipt (a passed cell of an earlier run is reused, DEC-009)"
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  if [ "${1:-}" = --dry-run ]; then
    sa_plan
    exit 0
  fi
  echo "usage: switch-autocheck.sh --dry-run (the run itself: tests/run.sh live switch-autocheck --live --targets FILE)" >&2
  exit 2
fi

# The helpers of live/command-recovery (and through it install-lifecycle),
# with this group's own directory.
# shellcheck source=tests/live/command-recovery.sh
. "$NICE_DNS_ROOT/tests/live/command-recovery.sh"
unset -f t_01_before t_02_install t_03_fault_unbound t_04_fault_proxy t_05_restart t_06_reinstall t_07_uninstall t_08_final t_09_privacy t_10_receipt
il_dir() { printf '%s\n' "$ARTIFACT_DIR/switch-autocheck/$1"; }

# The whole run: no step starts later than this after the first (six
# reinstalls per run, a hardened build among them).
SA_RUN_MAX="${SA_RUN_MAX:-14400}"
# DNS after an install or a switch.
SA_DNS_MAX="${SA_DNS_MAX:-600}"
SA_POLL="${SA_POLL:-15}"
# shellcheck disable=SC2034 # read by il_each
IL_FIRST_STEPS=sa_before

sa_require() {
  grep -qx "$2" "$(il_dir "$1")/passed.tsv" 2>/dev/null || fail "$2 did not pass on $1; this step does not run"
}

sa_budget_start() {
  mkdir -p "$ARTIFACT_DIR/switch-autocheck"
  [ -f "$ARTIFACT_DIR/switch-autocheck/started" ] || date +%s >"$ARTIFACT_DIR/switch-autocheck/started"
}

sa_budget() {
  local s
  sa_budget_start
  s="$(cat "$ARTIFACT_DIR/switch-autocheck/started" 2>/dev/null)"
  case "$s" in ''|*[!0-9]*) fail "no run start stamp; the run budget cannot be checked" ;; esac
  [ $(( $(date +%s) - s )) -le "$SA_RUN_MAX" ] || fail "past the run budget (SA_RUN_MAX=${SA_RUN_MAX}s since $s); $1 does not start"
}

# sa_cli <alias> <label> <mode> [args]: the installed nice-dns through
# target.sh command. Output in cmd-<label>.log.
sa_cli() {
  local a="$1" label="$2"
  shift 2
  il_t "$a" command --mode "$@" >"$(il_dir "$a")/cmd-$label.log" 2>&1
}
sa_exit() { awk -F '\t' '$1 == "command_exit" { v = $2 } END { print (v == "" ? "-" : v) }' "$1"; }
sa_last() { awk -F '\t' '$1 == "started_utc" { on = 1; next } $1 == "finished_utc" { on = 0 } on && NF { l = $0 } END { print l }' "$1"; }
sa_kv() { awk -F '\t' -v k="$2" '$1 == k { print $2; exit }' "$1"; }

# sa_status <alias> <label>: status --tsv's install and update rows, in
# status-<label>.tsv (`status <group> <key> <value>`).
sa_status() {
  local a="$1" label="$2" d
  d="$(il_dir "$a")"
  sa_cli "$a" "status-$label" status
  {
    awk -F '\t' '($1 == "install" || $1 == "update") && NF == 3' "$d/cmd-status-$label.log" | sed 's/^/status	/'
    printf 'status_exit\t%s\n' "$(sa_exit "$d/cmd-status-$label.log")"
  } >"$d/status-$label.tsv"
  assert_eq 0 "$(sa_kv "$d/status-$label.tsv" status_exit)" "$label: status --tsv exited 0"
}
# sa_st <alias> <label> <group> <key>: one status value.
sa_st() { awk -F '\t' -v g="$3" -v k="$4" '$1 == "status" && $2 == g && $3 == k { print $4; exit }' "$(il_dir "$1")/status-$2.tsv"; }

# sa_switch_report <alias> <label>: switch-<label>.tsv.
sa_switch_report() {
  il_t "$1" switch-report >"$(il_dir "$1")/switch-$2.tsv" 2>>"$(il_dir "$1")/ops.log" || fail "switch-report: $(tail -n 5 "$(il_dir "$1")/ops.log")"
}
# sa_no_checkout <alias> <label>: every path the report looked at is absent.
sa_no_checkout() {
  local r
  r="$(il_dir "$1")/switch-$2.tsv"
  assert_match '^[1-9]' "$(awk -F '\t' '$1 == "hardened_checkout"' "$r" | grep -c .)" "$2: the report looked for a pi-hole-hardened checkout"
  assert_eq "" "$(awk -F '\t' '$1 == "hardened_checkout" && $3 != "absent" { print $2 }' "$r")" \
    "$2: no pi-hole-hardened checkout on the host the old sibling lookup could use"
}

# sa_dns <alias> <label>: lifecycle-report after-<label>.tsv, until the host
# resolves through the stack (bounded by SA_DNS_MAX).
sa_dns() {
  local a="$1" label="$2" end
  end=$(( $(date +%s) + SA_DNS_MAX ))
  while :; do
    il_report "$a" "after-$label" || fail "lifecycle-report"
    [ "$(il_val "$(il_dir "$a")/after-$label.tsv" resolution resolves)" = yes ] && return 0
    [ "$(date +%s)" -lt "$end" ] || fail "$label: DNS did not answer within ${SA_DNS_MAX}s"
    sleep "$SA_POLL"
  done
}
# sa_running <alias> <label>: the proxy containers running, space separated.
sa_running() { il_sec "$(il_dir "$1")/after-$2.tsv" running | awk -F '\t' '$1 == "running" && $2 ~ /^tor-/ { print $2 }' | LC_ALL=C sort -u | tr '\n' ' ' | sed 's/ $//'; }

# ─────────────────────────── steps ───────────────────────────────────────────

sa_before() {
  local plat="$1" a="$2" d proxy ph r why
  d="$(il_dir "$a")"
  sa_budget sa_before
  rm -f "$d/offline.tsv"
  printf 'platform\t%s\n' "$plat" >"$d/started.tsv"
  if ! il_t "$a" probe >"$d/probe.log" 2>&1; then
    why="$(grep -v -e 'level=warning' -e '^[[:space:]]*$' "$d/probe.log" | tail -n 1 | tr '\t' ' ')"
    printf 'offline\t%s\t%s\n' "$plat" "${why:-no answer}" >"$d/offline.tsv"
    fail "OFFLINE: $a does not answer ($(cut -f3 "$d/offline.tsv")). The cell is not run. Ask the owner to wake $a (mint: its Wi-Fi after a suspend), then rerun only this platform: --platforms $plat"
  fi
  cr_before "$@"
  proxy="$(il_cell "$a" proxy)"
  sa_status "$a" before
  assert_eq "$proxy" "$(sa_st "$a" before install variant)" "status names the proxy that runs"
  ph="$(sa_st "$a" before install pihole)"
  # Recorded before any check here can fail, so sa_restore always has them.
  printf 'other\t%s\nrecorded_proxy\t%s\nrecorded_pihole\t%s\n' "$([ "$proxy" = haproxy ] && echo socat || echo haproxy)" "$proxy" "$ph" >>"$d/cell.tsv"
  assert_eq standard "$ph" "the cell starts from the standard Pi-hole (status pihole)"
  sa_switch_report "$a" before
  sa_no_checkout "$a" before
  if [ "$plat" = linux ]; then
    r="$d/polkit-add.tsv"
    il_t "$a" polkit-test-rule --mode add >"$r" 2>>"$d/ops.log" || fail "polkit-test-rule add: $(tail -n 5 "$d/ops.log")"
    assert_eq present "$(sa_kv "$r" polkit_test_rule)" "the polkit test rule is in place"
  fi
  {
    printf 'recorded_proxy\t%s\nrecorded_pihole\t%s\n' "$proxy" "$ph"
    awk -F '\t' '$1 == "hardened_checkout"' "$d/switch-before.tsv"
    [ "$plat" != linux ] || printf 'polkit_test_rule\tpresent\n'
    printf 'result\tpass\n'
  } >"$d/sa-before.tsv"
}

sa_install() {
  local plat="$1" a="$2" d proxy sha g
  d="$(il_dir "$a")"; proxy="$(il_cell "$a" proxy)"; sha="$(il_cell "$a" source_sha)"
  sa_require "$a" sa_before
  sa_budget sa_install
  sa_cli "$a" install install-git --cell "$proxy/standard" --source-sha "$sha" \
    || fail "nice-dns install failed: $(tail -n 20 "$d/cmd-install.log")"
  assert_eq "" "$(grep 'GUI not installed' "$d/cmd-install.log")" "the install installed the app"
  sa_dns "$a" install
  il_check_deployed "$plat" "$d/after-install.tsv" "$proxy"
  sa_status "$a" install
  assert_eq "$sha" "$(sa_st "$a" install install source_commit)" "status names HEAD as the installed commit"
  assert_eq "$proxy" "$(sa_st "$a" install install variant)" "status variant $proxy"
  assert_eq standard "$(sa_st "$a" install install pihole)" "status pihole standard"
  assert_eq loaded "$(sa_st "$a" install update auto)" "status: the automatic update check is scheduled (update auto loaded)"
  il_t "$a" gui-report >"$d/gui-install.log" 2>>"$d/ops.log" || fail "gui-report: $(tail -n 5 "$d/ops.log")"
  if [ "$plat" = linux ]; then g="$(sa_kv "$d/gui-install.log" gui_bin)"; else g="$(sa_kv "$d/gui-install.log" gui_app)"; fi
  assert_eq present "$g" "the app is installed"
  printf 'source_commit\t%s\nvariant\t%s\npihole\tstandard\nupdate_auto\tloaded\ngui\tpresent\ngui_version\t%s\ngui_program_sha256\t%s\nresolves\t%s\nresult\tpass\n' \
    "$sha" "$proxy" "$(sa_kv "$d/gui-install.log" gui_version)" "$(sa_kv "$d/gui-install.log" gui_program_sha256)" \
    "$(il_val "$d/after-install.tsv" resolution resolves)" >"$d/sa-install.tsv"
}

sa_proxy() {
  local plat="$1" a="$2" d proxy other l sha rc run
  d="$(il_dir "$a")"; proxy="$(il_cell "$a" proxy)"; other="$(il_cell "$a" other)"; l="$d/session-proxy-$other.log"
  sa_require "$a" sa_install
  sa_budget sa_proxy
  sha="$(sa_st "$a" install install source_commit)"
  il_t "$a" gui-session --mode "proxy-$other" >"$l" 2>>"$d/ops.log" || fail "gui-session proxy-$other: $(tail -n 5 "$d/ops.log")"
  rc="$(sa_kv "$l" gui_exit)"
  assert_eq 0 "$rc" "the app's --run-action proxy-$other exits 0: $(grep '^out	' "$l" | tail -n 5 | tr '\n' ' ')"
  assert_match 'finished \(exit 0\)$' "$(grep '^out	' "$l" | tail -n 1)" "the app's pane ends with the action's exit"
  sa_dns "$a" proxy
  il_check_deployed "$plat" "$d/after-proxy.tsv" "$other"
  run="$(sa_running "$a" proxy)"
  assert_eq "tor-$other" "$run" "tor-$other runs and tor-$proxy does not (running: $run)"
  sa_status "$a" proxy
  assert_eq "$other" "$(sa_st "$a" proxy install variant)" "status variant $other"
  assert_eq "$sha" "$(sa_st "$a" proxy install source_commit)" "the switch kept the installed commit"
  printf 'action\tproxy-%s\ngui_exit\t%s\npane_last\t%s\nvariant_before\t%s\nvariant_after\t%s\nsource_commit_before\t%s\nsource_commit_after\t%s\nrunning_proxy\t%s\nresolves\t%s\nresult\tpass\n' \
    "$other" "$rc" "$(grep '^out	' "$l" | tail -n 1 | cut -f2- | tr '\t' ' ')" "$proxy" "$other" "$sha" "$(sa_st "$a" proxy install source_commit)" \
    "$run" "$(il_val "$d/after-proxy.tsv" resolution resolves)" >"$d/sa-proxy.tsv"
}

sa_hardened() {
  local plat="$1" a="$2" d other sha ex last r
  d="$(il_dir "$a")"; other="$(il_cell "$a" other)"
  sa_require "$a" sa_proxy
  sa_budget sa_hardened
  sha="$(sa_st "$a" proxy install source_commit)"
  sa_cli "$a" hardened switch-pihole-hardened || true
  ex="$(sa_exit "$d/cmd-hardened.log")"; last="$(sa_last "$d/cmd-hardened.log")"
  assert_eq 0 "$ex" "nice-dns switch pihole hardened exits 0: $(tail -n 8 "$d/cmd-hardened.log" | tr '\n' ' ')"
  assert_eq "Switched: Pi-hole is now the hardened one, and DNS is answering." "$last" "its last line"
  sa_dns "$a" hardened
  il_check_deployed "$plat" "$d/after-hardened.tsv" "$other"
  sa_status "$a" hardened
  assert_eq hardened "$(sa_st "$a" hardened install pihole)" "status pihole hardened"
  assert_eq "$other" "$(sa_st "$a" hardened install variant)" "the proxy stayed $other"
  assert_eq "$sha" "$(sa_st "$a" hardened install source_commit)" "the switch kept the installed commit"
  sa_switch_report "$a" hardened
  r="$d/switch-hardened.tsv"
  assert_eq hardened "$(sa_kv "$r" pihole_running)" "the running Pi-hole is the hardened one"
  assert_eq present "$(sa_kv "$r" kept_base)" "the kept source carries pihole-hardened/base"
  sa_no_checkout "$a" hardened
  {
    printf 'cli_exit\t%s\ncli_last\t%s\npihole_after\thardened\npihole_running\t%s\nkept_base\t%s\nsource_commit_before\t%s\nsource_commit_after\t%s\n' \
      "$ex" "$last" "$(sa_kv "$r" pihole_running)" "$(sa_kv "$r" kept_base)" "$sha" "$(sa_st "$a" hardened install source_commit)"
    awk -F '\t' '$1 == "hardened_checkout"' "$r"
    printf 'resolves\t%s\nresult\tpass\n' "$(il_val "$d/after-hardened.tsv" resolution resolves)"
  } >"$d/sa-hardened.tsv"
}

sa_update() {
  local a="$2" d c0 c1 r
  d="$(il_dir "$a")"; r="$d/schedule.log"
  sa_require "$a" sa_hardened
  sa_budget sa_update
  sa_status "$a" update-before
  c0="$(sa_st "$a" update-before update checked_at)"
  assert_eq loaded "$(sa_st "$a" update-before update auto)" "the automatic check is scheduled (update auto loaded)"
  # A checked_at in the same second as the one read before would not move.
  sleep 1
  il_t "$a" update-schedule >"$r" 2>>"$d/ops.log" || fail "update-schedule: $(tail -n 5 "$r" | tr '\n' ' ') $(tail -n 3 "$d/ops.log" | tr '\n' ' ')"
  assert_eq yes "$(sa_kv "$r" schedule_done)" "the scheduled check ran to its end"
  sa_status "$a" update-after
  c1="$(sa_st "$a" update-after update checked_at)"
  assert_match '^[0-9]+$' "$c1" "the check left a checked_at"
  [ "$c1" -gt "${c0:-0}" ] 2>/dev/null || fail "checked_at did not move: ${c0:-none} before, $c1 after"
  # An unreachable GitHub also moves checked_at (result unknown): the check
  # must have got an answer.
  assert_match '^(current|available)$' "$(sa_st "$a" update-after update result)" "the scheduled check reached GitHub (result current or available)"
  printf 'update_auto\tloaded\nchecked_at_before\t%s\nchecked_at_after\t%s\nresult_after\t%s\nschedule_done\tyes\nschedule_last_exit\t%s\nresult\tpass\n' \
    "${c0:--}" "$c1" "$(sa_st "$a" update-after update result)" "$(sa_kv "$r" schedule_last_exit)" >"$d/sa-update.tsv"
}

# Runs whatever came before it: the target ends on its recorded choices. The
# choices are restored in a subshell, so that on Linux the polkit test rule is
# removed after it on every path: a failed reinstall, DNS not coming back, or
# sa_before stopping right after it added the rule.
sa_restore_choices() {
  local a="$1" d rp rh v h re=no
  d="$(il_dir "$a")"; rp="$(il_cell "$a" recorded_proxy)"; rh="$(il_cell "$a" recorded_pihole)"
  [ -n "$rp" ] && [ -n "$rh" ] || fail "no recorded choices (sa_before did not finish)"
  sa_status "$a" restore-before
  v="$(sa_st "$a" restore-before install variant)"; h="$(sa_st "$a" restore-before install pihole)"
  if [ "$v" != "$rp" ] || [ "$h" != "$rh" ]; then
    re=yes
    sa_cli "$a" restore reinstall-cell --cell "$rp/$rh" || fail "nice-dns reinstall --local $rp --$rh: $(tail -n 8 "$d/cmd-restore.log" | tr '\n' ' ')"
  fi
  sa_dns "$a" restore
  sa_status "$a" restore
  assert_eq "$rp" "$(sa_st "$a" restore install variant)" "the target is back on tor-$rp"
  assert_eq "$rh" "$(sa_st "$a" restore install pihole)" "and on the $rh Pi-hole"
  assert_eq "tor-$rp" "$(sa_running "$a" restore)" "tor-$rp is the proxy that runs"
  printf 'reinstalled\t%s\nvariant\t%s\npihole\t%s\nresolves\t%s\n' "$re" "$rp" "$rh" "$(il_val "$d/after-restore.tsv" resolution resolves)" >"$d/restore-choices.tsv"
}

sa_restore() {
  local plat="$1" a="$2" d rc=0 r gone=-
  d="$(il_dir "$a")"
  rm -f "$d/restore-choices.tsv"
  ( sa_restore_choices "$a" ) || rc=1
  # The rule exists only under this run's snapshot (sa_before adds it after
  # taking one); remove it whatever the restore found.
  if [ "$plat" = linux ] && [ -f "$ARTIFACT_DIR/targets/$a/snapshot.tsv" ]; then
    r="$d/polkit-remove.tsv"
    if il_t "$a" polkit-test-rule --mode remove >"$r" 2>>"$d/ops.log"; then gone="$(sa_kv "$r" polkit_test_rule)"; else gone=error; fi
  fi
  [ "$plat" != linux ] || [ "$gone" = absent ] || [ "$gone" = - ] || fail "the polkit test rule may still be on $a ($gone): remove /etc/polkit-1/rules.d/90-nice-dns-test.rules by hand"
  [ "$rc" = 0 ] || fail "$a is not back on its recorded choices (above); polkit test rule: $gone"
  {
    cat "$d/restore-choices.tsv"
    [ "$plat" != linux ] || printf 'polkit_test_rule\t%s\n' "$gone"
    printf 'result\tpass\n'
  } >"$d/sa-restore.tsv"
}

# sa_reuse_dir <platform>: that platform's cell in a run listed in
# NICE_DNS_CELL_REUSE_RUNS, passed in every step, at the same product (DEC-009).
# Each candidate it refuses is written, with why, to $CASE_DIR/reuse-refused.tsv
# (DEC-009: a reuse, or its refusal, is visible, never silent).
SA_REUSE_FILES='tests/live/switch-autocheck.sh tests/live/command-recovery.sh tests/live/install-lifecycle.sh tests/live/target.sh tests/manifests/switch-autocheck.tsv tests/reports/verify.sh'
sa_reuse_dir() {
  local r d s ok sha miss found
  for r in ${NICE_DNS_CELL_REUSE_RUNS:-}; do
    case "$r" in /*) ;; *) fail "NICE_DNS_CELL_REUSE_RUNS: $r is not an absolute run directory" ;; esac
    [ -d "$r" ] || fail "NICE_DNS_CELL_REUSE_RUNS: no run directory $r"
    found=0
    for d in "$r"/switch-autocheck/*/; do
      [ -f "$d/cell.tsv" ] || continue
      [ "$(il_cell_of "$d" cell | cut -d/ -f1)" = "$1" ] || continue
      found=1
      sha="$(il_cell_of "$d" source_sha)"
      if [ "$(il_cell_of "$d" adapter)" != "$(cr_adapter)" ]; then
        printf '%s\t%s\tran against the %s adapter, this run uses the %s one\n' "$1" "${d%/}" "$(il_cell_of "$d" adapter)" "$(cr_adapter)" >>"$CASE_DIR/reuse-refused.tsv"; continue
      fi
      ok=1 miss=""
      for s in $SA_STEPS; do grep -qx "$s" "$d/passed.tsv" 2>/dev/null || { ok=0; miss="$miss $s"; }; done
      if [ "$ok" != 1 ]; then
        printf '%s\t%s\tthe cell did not pass:%s\n' "$1" "${d%/}" "$miss" >>"$CASE_DIR/reuse-refused.tsv"; continue
      fi
      if ! il_same_product "$sha" "$1"; then
        printf '%s\t%s\tthe product files changed since %s (%s)\n' "$1" "${d%/}" "${sha:0:12}" \
          "$(git -C "$NICE_DNS_ROOT" diff --name-only "$sha" HEAD -- . ':(exclude)tests' ':(exclude)docs' ':(exclude)proof' ':(exclude,glob)**/*.md' ":(exclude)$([ "$1" = linux ] && echo mac || echo deb)" 2>/dev/null | head -n 3 | tr '\n' ' ')" >>"$CASE_DIR/reuse-refused.tsv"; continue
      fi
      # A cell proven under a looser scenario does not prove this one.
      # shellcheck disable=SC2086 # the file list is words
      if ! git -C "$NICE_DNS_ROOT" diff --quiet "$sha" HEAD -- $SA_REUSE_FILES 2>/dev/null; then
        # shellcheck disable=SC2086 # the file list is words
        printf '%s\t%s\tthe scenario changed since %s (%s)\n' "$1" "${d%/}" "${sha:0:12}" \
          "$(git -C "$NICE_DNS_ROOT" diff --name-only "$sha" HEAD -- $SA_REUSE_FILES 2>/dev/null | tr '\n' ' ')" >>"$CASE_DIR/reuse-refused.tsv"; continue
      fi
      printf '%s\n' "${d%/}"
      return 0
    done
    [ "$found" = 1 ] || printf '%s\t%s\tthe run has no %s cell of this group\n' "$1" "$r" "$1" >>"$CASE_DIR/reuse-refused.tsv"
  done
  return 0
}

SA_SCENARIOS='SA-BEFORE:sa-before.tsv SA-INSTALL:sa-install.tsv SA-PROXY:sa-proxy.tsv SA-HARDENED:sa-hardened.tsv SA-UPDATE:sa-update.tsv SA-RESTORE:sa-restore.tsv'
SA_SECRETS='cert=[A-Za-z0-9+/]{20}|(^|[^0-9A-Fa-f])[0-9A-F]{40}([^0-9A-Fa-f]|$)|PRIVATE KEY|"sid":|pwhash|BRIDGE[0-9]+=|obfs4 [0-9]'

sa_receipt() {
  local root out r repo cd st d from cell key gen a f id n=0 v s ok p selected rd off nore failed why
  root="$(dirname "$(dirname "$ARTIFACT_DIR")")"
  out="$root/receipts/switch-autocheck/$RUN_ID"; r="$out/receipt.tsv"
  assert_no_path "$out" "this run has no switch-autocheck receipt yet"
  mkdir -p "$out/cells" || fail "cannot create $out"
  {
    printf '# schema\tnice-dns-receipt/1\n'
    printf 'receipt\tswitch-autocheck\nrun_id\t%s\ncreated_utc\t%s\n' "$RUN_ID" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
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
    printf 'limit\tno-person-clicked\t-\tscope=sub-plan-6\tthe app ran its own action through --run-action (the code a click runs) with no dialog shown\n'
    printf 'limit\tpolkit-test-rule\t-\tscope=sub-plan-5\ton Linux the helper was authorised by a temporary polkit rule, not by a person typing a password\n'
    printf 'limit\tmac-gui-context\t-\tscope=BL-052\tmacOS nice-dns commands and the app ran in the GUI context (launchctl asuser), not from a login at the Mac\n'
    printf 'limit\tschedule-by-hand\t-\tscope=BL-066\tthe update schedule was started by hand; its 12-hour calendar firing was not waited for (the calendar itself: integration/scheduling)\n'
  } >"$r"
  selected=" $(il_platforms) "
  : >"$CASE_DIR/cell-dirs.tsv"; : >"$CASE_DIR/reuse-refused.tsv"; nore="" failed=""
  for d in "$ARTIFACT_DIR"/switch-autocheck/*/; do
    if [ ! -f "$d/cell.tsv" ]; then
      # Started but stopped before the cell was recorded, and not offline:
      # that platform failed in sa_before (e.g. the snapshot).
      [ -f "$d/started.tsv" ] && [ ! -f "$d/offline.tsv" ] && failed="$failed $(cut -f2 "$d/started.tsv")"
      continue
    fi
    printf '%s\t-\n' "${d%/}" >>"$CASE_DIR/cell-dirs.tsv"
  done
  for p in linux macos; do
    case "$selected" in *" $p "*) continue ;; esac
    rd="$(sa_reuse_dir "$p")"
    if [ -n "$rd" ]; then
      printf '%s\t%s\n' "$rd" "$(basename "$(dirname "$(dirname "$rd")")")" >>"$CASE_DIR/cell-dirs.tsv"
      printf 'carried: the %s cell from run %s (DEC-009)\n' "$p" "$(basename "$(dirname "$(dirname "$rd")")")"
    else nore="$nore $p"; fi
  done
  while IFS="$(printf '\t')" read -r d from; do
    cell="$(il_cell_of "$d" cell)"; key="$(printf '%s' "$cell" | tr / -)"
    a="$(il_cell_of "$d" target)"
    gen="generation=$(il_val "$d/after-install.tsv" generation current 2>/dev/null)"
    mkdir -p "$out/cells/$key"
    cp "$d/cell.tsv" "$out/cells/$key/"
    ok=1
    for s in $SA_STEPS; do grep -qx "$s" "$d/passed.tsv" 2>/dev/null || ok=0; done
    for id in $SA_SCENARIOS; do [ -f "$d/${id#*:}" ] || ok=0; done
    if [ "$ok" != 1 ]; then
      printf 'cell\t%s\t%s\t%s\t%s\t%s\tfailed\n' "${cell%%/*}" "$(printf '%s' "$cell" | cut -d/ -f2)" "${cell##*/}" "$a" "$gen" >>"$r"
      failed="$failed ${cell%%/*}"
      # The first step this cell did not pass, as a failed scenario row:
      # the verifier names the cell and the step.
      for s in $SA_STEPS; do
        grep -qx "$s" "$d/passed.tsv" 2>/dev/null && continue
        printf 'scenario\t%s\t%s\tfail\t-\t-\t%s\n' "$(printf '%s' "$s" | tr '[:lower:]_' '[:upper:]-')" "$cell" "$gen" >>"$r"
        break
      done
      continue
    fi
    n=$((n + 1))
    printf 'cell\t%s\t%s\t%s\t%s\t%s\tobserved\n' "${cell%%/*}" "$(printf '%s' "$cell" | cut -d/ -f2)" "${cell##*/}" "$a" "$gen" >>"$r"
    [ "$from" = - ] || printf 'reuse\t%s\t%s\t%s\n' "$cell" "$from" "$(il_cell_of "$d" source_sha)" >>"$r"
    for id in $SA_SCENARIOS; do
      f="${id#*:}"
      cp "$d/$f" "$out/cells/$key/$f"
      printf 'scenario\t%s\t%s\tpass\tcells/%s/%s\t%s\t%s\n' "${id%%:*}" "$cell" "$key" "$f" "$(sha256sum "$out/cells/$key/$f" | cut -d' ' -f1)" "$gen" >>"$r"
    done
  done <"$CASE_DIR/cell-dirs.tsv"
  # A target that did not answer is named, with what to do.
  off="$(cat "$ARTIFACT_DIR"/switch-autocheck/*/offline.tsv 2>/dev/null | cut -f2 | tr '\n' ' ')"
  [ -z "$off" ] || printf 'offline\t%s\n' "$off" >"$CASE_DIR/offline.tsv"
  # Every problem is named at once, each with what to do: one found first
  # must not hide another (an offline target and a refused carry together).
  why=""
  [ -z "$off" ] || why="${why}offline: ${off}ask the owner to wake it, then rerun only that platform. "
  [ -z "$failed" ] || why="${why}cell(s) failed on:$failed (the receipt or the step's output names the step). Rerun only those: --platforms $(printf '%s' "${failed# }" | tr ' ' ',') with NICE_DNS_CELL_REUSE_RUNS=$ARTIFACT_DIR. "
  [ -z "$nore" ] || why="${why}no cell for:$nore. NICE_DNS_CELL_REUSE_RUNS=${NICE_DNS_CELL_REUSE_RUNS:-(unset)} carried none: $(awk -F '\t' '{ printf "%s: %s; ", $1, $3 }' "$CASE_DIR/reuse-refused.tsv")run that platform too, or name a run whose cell passed at this product and scenario. "
  [ -z "$why" ] || fail "$why"
  assert_match '^[1-9]' "$n" "at least one fully passed cell"
  v="$(bash "$NICE_DNS_ROOT/tests/reports/verify.sh" check "$r" 2>&1)"
  assert_rc 0 "$?" "the switch-autocheck receipt verifies: $v"
  assert_eq "" "$(grep -rlE "$SA_SECRETS" "$out" 2>/dev/null)" \
    "no bridge line, certificate, fingerprint, key, session or password hash in the receipt"
  printf 'receipt\t%s\n' "$r" >"$CASE_DIR/receipt-path.tsv"
}

t_01_before() { il_selection; il_each sa_before; }
t_02_install() { il_selection; il_each sa_install; }
t_03_proxy() { il_selection; il_each sa_proxy; }
t_04_hardened() { il_selection; il_each sa_hardened; }
t_05_update() { il_selection; il_each sa_update; }
t_06_restore() { il_selection; il_each sa_restore; }

t_07_privacy() {
  il_selection
  assert_eq "" "$(grep -rlE "$SA_SECRETS" "$ARTIFACT_DIR/switch-autocheck" --include='*.tsv' 2>/dev/null)" \
    "no report, sample or step record holds bridge material, a session or a hash"
}

t_08_receipt() { il_selection; sa_receipt; }
