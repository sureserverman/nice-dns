# shellcheck shell=bash
# Group live/command-recovery (command-and-unbound-recovery plan, Task 3.1). Run
# by `tests/run.sh live command-recovery --live --targets FILE --platforms
# linux,macos`. One cell per platform: the proxy the target runs now, standard
# Pi-hole. The controller runs on its real timers. Both platforms run at once.
#
# A failed step stops that platform's later steps, but cr_final still runs, so
# the target ends with a working stack. NICE_DNS_CELL_REUSE_RUNS names earlier
# run directories: a platform whose cell passed every step there, at a commit
# with the same product files, is not run again (DEC-009).
#
# Evidence: $ARTIFACT_DIR/command-recovery/<alias>/. The command's output may
# hold bridge lines: it stays in cmd-*.log and ops.log, private to the run, and
# is never copied into a receipt. Only *.tsv is checked and copied.
#
# NICE_DNS_TARGET_ADAPTER replaces target.sh only for the dry run
# (integration/command-recovery-dryrun, NICE_DNS_IL_DRY_RUN=1).

cr_plan() {
  cat <<'EOF'
cr_before         snapshot the target, record its proxy as the cell
cr_install        nice-dns install from a checkout of HEAD, over the running stack; real timers
cr_fault_unbound  SIGSTOP unbound; expect requested, acknowledged, ready, a new start and a fresh name within 10 minutes; thaw
cr_fault_proxy    stop the proxy's unit, Pi-hole running; expect the same from the runtime repair; no human action
cr_restart        nice-dns restart by full path: every container starts anew, a fresh name answers
cr_reinstall      mark the state, nice-dns reinstall --local by full path: admin password, lists, Tor data and anchor kept
cr_uninstall      nice-dns uninstall by full path: images, quadlets, every org.nice-dns.* agent, the command and its source gone; host DNS given back
cr_final          nice-dns install from a checkout of HEAD: the target ends on this branch's stack
cr_privacy        no bridge material, session or hash in the evidence
cr_receipt        assemble and verify the command-recovery receipt
EOF
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  if [ "${1:-}" = --dry-run ]; then
    echo "dry run: no target is touched"
    cr_plan
    exit 0
  fi
  echo "usage: command-recovery.sh --dry-run (the run itself: tests/run.sh live command-recovery)" >&2
  exit 2
fi

# shellcheck disable=SC1091 # the group runner gives NICE_DNS_ROOT
. "$NICE_DNS_ROOT/tests/live/install-lifecycle.sh"
unset -f t_1_before t_2_upgrade_from_legacy t_3_state_survives t_4_uninstall_restores t_5_final_install t_6_evidence_is_private

CR_SIBS="${NICE_DNS_SIBLINGS_DIR:-$(dirname "$NICE_DNS_ROOT")}"
CR_STEPS='cr_before cr_install cr_fault_unbound cr_fault_proxy cr_restart cr_reinstall cr_uninstall cr_final'
CR_RECOVER_MAX="${CR_RECOVER_MAX:-600}"
CR_ELAPSED_MAX="${CR_ELAPSED_MAX:-600}"
CR_SETTLE_MAX="${CR_SETTLE_MAX:-900}"
CR_POLL="${CR_POLL:-30}"
# ND_POLICY_COOLDOWN_S (300): a fault is not injected inside the last action's
# cooldown, or the wait below would measure the cooldown.
CR_QUIET="${CR_QUIET:-310}"
# The installer's own tags, named as each runtime lists them. Not a versioned
# proxy tag or nd-arm-*: the tuning harness pulled those (arm-prepare; mint
# 2026-10-31), and the install pulls by digest (cr_pulled_left checks those).
CR_STACK_IMAGES='^(localhost/)?(pi-hole|unbound|pi-hole-hardened-base|pihole-base|unbound-base|tor-haproxy|tor-socat):|^(docker\.io/)?sureserver/(tor-haproxy|tor-socat|pi-hole-hardened):latest$'
# shellcheck disable=SC2034 # read by il_each
IL_FIRST_STEPS=cr_before

il_dir() { printf '%s\n' "$ARTIFACT_DIR/command-recovery/$1"; }

cr_report() { il_t "$1" command-report >"$(il_dir "$1")/$2.tsv" 2>>"$(il_dir "$1")/ops.log"; }
cr_ctl_report() { il_t "$1" controller-report >"$(il_dir "$1")/$2.tsv" 2>>"$(il_dir "$1")/ops.log"; }
cr_now() { awk -F '\t' '$1 == "now" { print $2; exit }' "$1"; }
cr_start() { il_sec "$1" starts | awk -F '\t' -v c="$2" '$1 == "start" && $2 == c { print $3; exit }'; }
cr_obs() { il_sec "$1" observe | awk -F '\t' -v n="$2" '$1 == "obs" && $2 == n { print $3; exit }'; }
cr_route_up() { il_sec "$1" observe | awk -F '\t' '$1 == "obs" && $2 ~ /^route:/ && $3 == "healthy" { f = 1 } END { exit !f }'; }
cr_jrows() { il_sec "$1" journal-active | awk -F '\t' -v s="$2" '$1 ~ /^[0-9]+$/ && $1 >= s'; }

# cr_require <step>: the step before this one passed on this platform.
cr_require() {
  grep -qx "$2" "$(il_dir "$1")/passed.tsv" 2>/dev/null || fail "$2 did not pass on $1; this step does not run"
}

# cr_fresh <alias> <deadline epoch, this machine's clock>: prints a fresh_name
# row once the status is an answer; the last row and exit 1 at the deadline.
cr_fresh() {
  local a="$1" end="$2" row="" st
  while :; do
    row="$(il_t "$a" fresh-name 2>>"$(il_dir "$a")/ops.log" | awk -F '\t' '$1 == "fresh_name"')"
    st="$(printf '%s\n' "$row" | cut -f3)"
    case "$st" in NOERROR|NXDOMAIN) printf '%s\n' "$row"; return 0 ;; esac
    [ "$(date +%s)" -lt "$end" ] || { printf '%s\n' "${row:-fresh_name	-	no-answer}"; return 1; }
    sleep "$CR_POLL"
  done
}

# cr_settled <alias>: a route, Unbound and the runtime are healthy, and a fresh
# name answers.
cr_settled() {
  local a="$1" r end
  r="$(il_dir "$a")/settle.tsv"
  end=$(( $(date +%s) + CR_SETTLE_MAX ))
  while :; do
    if cr_ctl_report "$a" settle && cr_route_up "$r" && [ "$(cr_obs "$r" unbound)" = healthy ] \
      && [ "$(cr_obs "$r" runtime)" = healthy ] && cr_fresh "$a" "$(date +%s)" >/dev/null; then
      return 0
    fi
    [ "$(date +%s)" -lt "$end" ] || fail "$a did not settle within ${CR_SETTLE_MAX}s: $(il_sec "$r" observe | cut -f2,3 | tr '\n' ' '); last op: $(grep -v level=warning "$(il_dir "$a")/ops.log" | tail -n 2 | tr '\n' ' ')"
    sleep "$CR_POLL"
  done
}

# cr_quiet <alias>: past the cooldown of the journal's last row.
cr_quiet() {
  local a="$1" r last now end
  r="$(il_dir "$a")/settle.tsv"
  end=$(( $(date +%s) + CR_SETTLE_MAX ))
  while :; do
    cr_ctl_report "$a" settle || fail "controller-report"
    now="$(cr_now "$r")"
    last="$(cr_jrows "$r" 0 | tail -n 1 | cut -f1)"
    [ -z "$last" ] || [ $(( now - last )) -ge "$CR_QUIET" ] && return 0
    [ "$(date +%s)" -lt "$end" ] || fail "$a: the controller kept acting for ${CR_SETTLE_MAX}s: $(cr_jrows "$r" 0 | tail -n 3 | cut -f3,4 | tr '\n' ' ')"
    sleep "$CR_POLL"
  done
}

# cr_recovered <controller report> <since> <component>: one request of that
# component has requested, acknowledged and ready rows.
cr_recovered() {
  cr_jrows "$1" "$2" | awk -F '\t' -v c="$3" '$3 == c { s[$2] = s[$2] " " $4 }
    END { for (i in s) if (s[i] ~ / requested/ && s[i] ~ / acknowledged/ && s[i] ~ / ready/) f = 1; exit !f }'
}

# cr_fault <alias> <evidence> <component in the journal> <container> <inject op>
# [inject args]: inject, wait, and record what the controller did by itself.
cr_fault() {
  local a="$1" out="$2" comp="$3" c="$4" op="$5" d r t0 g0 g1 end row rc=0 t1 during
  shift 5
  d="$(il_dir "$a")"; r="$d/fault-$comp.tsv.report"
  cr_report "$a" fault-before || fail "command-report"
  g0="$(cr_start "$d/fault-before.tsv" "$c")"
  assert_ne "" "$g0" "$c runs before the fault"
  t0="$(cr_now "$d/fault-before.tsv")"
  il_t "$a" "$op" "$@" >>"$d/ops.log" 2>&1 || fail "$op: $(tail -n 5 "$d/ops.log")"
  # The control: while the fault holds, a fresh name does not answer. Without it
  # the answered name at the end would prove nothing.
  during="$(il_t "$a" fresh-name 2>>"$d/ops.log" | awk -F '\t' '$1 == "fresh_name" { print $3 }')"
  end=$(( $(date +%s) + CR_RECOVER_MAX ))
  while :; do
    if il_t "$a" controller-report >"$r" 2>>"$d/ops.log" && cr_recovered "$r" "$t0" "$comp"; then break; fi
    [ "$(date +%s)" -lt "$end" ] || { rc=1; break; }
    sleep "$CR_POLL"
  done
  if [ "$op" = freeze-unbound ]; then il_t "$a" thaw-unbound >>"$d/ops.log" 2>&1 || rc=1; fi
  row="$(cr_fresh "$a" "$end")" || rc=1
  cr_report "$a" fault-after || fail "command-report"
  g1="$(cr_start "$d/fault-after.tsv" "$c")"
  t1="$(cr_now "$d/fault-after.tsv")"
  {
    printf 'fault\t%s\ninjected\t%s\nelapsed_s\t%s\nfresh_during_fault\t%s\ngeneration_before\t%s\ngeneration_after\t%s\n' "$op" "$t0" "$(( t1 - t0 ))" "$during" "$g0" "$g1"
    if [ -n "$g1" ] && [ "$g1" != "$g0" ]; then printf 'generation_changed\tyes\n'; else printf 'generation_changed\tno\n'; fi
    cr_jrows "$r" "$t0" | sed 's/^/journal	/'
    printf '%s\n' "$row"
  } >"$d/$out"
  assert_ne "" "$during" "the control ran: fresh-name gave a row during the fault ($(grep -v level=warning "$d/ops.log" | tail -n 2 | tr '\n' ' '))"
  case "$during" in NOERROR|NXDOMAIN) fail "a fresh name answered ($during) right after $op: the fault did not take hold" ;; esac
  assert_eq 0 "$rc" "the controller recovered from $op within ${CR_RECOVER_MAX}s: $(cr_jrows "$r" "$t0" | cut -f3,4 | tr '\n' ' '); $row"
  [ -n "$g1" ] && [ "$g1" != "$g0" ] || fail "$c has no new start after $op ($g0 -> $g1)"
  [ $(( t1 - t0 )) -le "$CR_ELAPSED_MAX" ] || fail "recovery from $op took $(( t1 - t0 ))s, over ${CR_ELAPSED_MAX}s"
}

# cr_command <alias> <label> <mode> [args]: the nice-dns command on the target.
cr_command() {
  local a="$1" label="$2"
  shift 2
  il_t "$a" command --mode "$@" >"$(il_dir "$a")/cmd-$label.log" 2>&1
}

# cr_pulled_left <report with the generation> <report after the uninstall>: the
# digests that generation pulled and that are still there with no name. One that
# another tag also holds is not the install's to remove (the receipt lists every
# image left, so it stays visible). Podman lists an unnamed digest as
# <none>:<none>, or repo:<none> when the digest was pulled by name; Apple's
# runtime as repo:<none>.
cr_pulled_left() {
  local ref repo
  for ref in $(il_sec "$1" generation | awk -F '\t' '$1 == "pulled" { print $3 }'); do
    repo="${ref%@*}"
    il_sec "$2" images | awk -F '\t' -v r="${repo#docker.io/}" -v dg="${ref#*@}" -v ref="$ref" '
      { n = $2; sub(/^docker\.io\//, "", n) }
      n == r ":<none>" || ($2 == "<none>:<none>" && $3 == dg) { print ref }'
  done
}

# ─────────────────────────── steps ───────────────────────────────────────────

cr_before() {
  local plat="$1" a="$2" d proxy dirty
  d="$(il_dir "$a")"
  dirty="$(GIT_OPTIONAL_LOCKS=0 git -C "$NICE_DNS_ROOT" status --porcelain --untracked-files=no)"
  if [ "${NICE_DNS_IL_DRY_RUN:-0}" = 1 ]; then
    echo "dry run: the committed-checkout check is skipped"
  else
    assert_eq "" "$dirty" "the checkout is committed (the archive is of HEAD)"
  fi
  il_t "$a" snapshot >>"$d/ops.log" 2>&1 || fail "could not reach $a to snapshot it: $(grep -v level=warning "$d/ops.log" | tail -n 2 | tr '\n' ' ')"
  il_report "$a" before || fail "lifecycle-report $a: $(tail -n 5 "$d/ops.log")"
  proxy="$(il_proxy "$d/before.tsv")"
  if [ -z "$proxy" ]; then
    case "${NICE_DNS_OPT_PROXIES:-}" in haproxy|socat) proxy="$NICE_DNS_OPT_PROXIES" ;; esac
  fi
  assert_match '^(haproxy|socat)$' "$proxy" "$a runs a proxy now, or --proxies names one"
  printf 'cell\t%s/%s/standard\nproxy\t%s\nsource_sha\t%s\nadapter\t%s\ntarget\t%s\n' "$plat" "$proxy" "$proxy" "$(il_sha)" \
    "$( [ -n "${NICE_DNS_TARGET_ADAPTER:-}" ] && echo fake || echo real)" "$a" >"$d/cell.tsv"
}

# cr_install_step <platform> <alias> <label>: install from a checkout of HEAD;
# the command and its source are published, the deployment is what was asked.
cr_install_step() {
  local plat="$1" a="$2" label="$3" d proxy r
  d="$(il_dir "$a")"; proxy="$(il_cell "$a" proxy)"
  cr_command "$a" "$label" install --cell "$proxy/standard" --source-sha "$(il_cell "$a" source_sha)" \
    || fail "nice-dns install ($label) failed: $(tail -n 20 "$d/cmd-$label.log")"
  il_report "$a" "after-$label" || fail "lifecycle-report"
  il_check_deployed "$plat" "$d/after-$label.tsv" "$proxy"
  cr_report "$a" "report-$label" || fail "command-report"
  r="$d/report-$label.tsv"
  assert_eq present "$(il_val "$r" command command)" "the install published the command"
  assert_eq present "$(il_val "$r" command source)" "and kept the source"
}

cr_install() {
  local plat="$1" a="$2" d over
  d="$(il_dir "$a")"
  cr_install_step "$plat" "$a" install
  il_t "$a" set-tunables --mode default >>"$d/ops.log" 2>&1 || fail "set-tunables: $(tail -n 5 "$d/ops.log")"
  if [ -n "$(il_proxy "$d/before.tsv")" ]; then over=yes; else over=no; fi
  printf 'over_running_stack\t%s\ninstall_over_stack\t%s\n' "$over" "$(il_val "$d/after-install.tsv" generation current)" >"$d/cmd-install.tsv"
}

cr_fault_unbound() {
  local a="$2"
  cr_require "$a" cr_install
  cr_settled "$a"
  cr_quiet "$a"
  cr_fault "$a" fault-unbound.tsv unbound unbound freeze-unbound
}

cr_fault_proxy() {
  local a="$2" c
  cr_require "$a" cr_fault_unbound
  cr_settled "$a"
  cr_quiet "$a"
  c="tor-$(il_cell "$a" proxy)"
  cr_fault "$a" fault-proxy.tsv runtime "$c" stop-proxy --component "$c"
}

cr_restart() {
  local a="$2" d c g0 g1 row end out
  d="$(il_dir "$a")"
  cr_require "$a" cr_fault_proxy
  cr_settled "$a"
  cr_report "$a" restart-before || fail "command-report"
  cr_command "$a" restart restart || fail "nice-dns restart failed: $(tail -n 20 "$d/cmd-restart.log")"
  assert_match 'nice-dns restarted; DNS is answering' "$(cat "$d/cmd-restart.log")" "the command reports the answer"
  cr_report "$a" restart-after || fail "command-report"
  out="$d/cmd-restart.tsv"; : >"$out"
  for c in pi-hole unbound "tor-$(il_cell "$a" proxy)"; do
    g0="$(cr_start "$d/restart-before.tsv" "$c")"; g1="$(cr_start "$d/restart-after.tsv" "$c")"
    printf 'start\t%s\t%s\t%s\n' "$c" "$g0" "$g1" >>"$out"
    assert_ne "" "$g1" "$c runs after the restart"
    assert_ne "$g0" "$g1" "$c started anew"
  done
  end=$(( $(date +%s) + 60 ))
  row="$(cr_fresh "$a" "$end")" || fail "no fresh name after the restart: $row"
  printf 'all_new_start\tyes\n%s\nresult\tpass\n' "$row" >>"$out"
}

cr_kept() { if [ -n "$1" ] && [ "$1" = "$2" ]; then echo kept; else echo lost; fi; }

cr_reinstall() {
  local plat="$1" a="$2" d m r proxy id0 id1 g0 g1
  d="$(il_dir "$a")"; proxy="$(il_cell "$a" proxy)"
  cr_require "$a" cr_restart
  m="nd-live-$RUN_ID"
  il_t "$a" mark-state >>"$d/ops.log" 2>&1 || fail "mark-state: $(tail -n 5 "$d/ops.log")"
  il_report "$a" marked || fail "lifecycle-report"
  assert_eq "$m" "$(il_val "$d/marked.tsv" state anchor_marker)" "the anchor volume holds the mark"
  g0="$(il_val "$d/marked.tsv" generation current)"
  id0="$(il_val "$d/marked.tsv" admin admin_secret_id)"
  assert_ne "" "$id0" "an admin password exists"
  cr_command "$a" reinstall reinstall || fail "nice-dns reinstall failed: $(tail -n 20 "$d/cmd-reinstall.log")"
  il_report "$a" after-reinstall || fail "lifecycle-report"
  r="$d/after-reinstall.tsv"
  il_check_deployed "$plat" "$r" "$proxy"
  g1="$(il_val "$r" generation current)"
  id1="$(il_val "$r" admin admin_secret_id)"
  {
    printf 'generation\t%s\t%s\n' "$g0" "$g1"
    printf 'admin_secret\t%s\n' "$(cr_kept "$id0" "$id1")"
    printf 'anchor\t%s\n' "$(cr_kept "$m" "$(il_val "$r" state anchor_marker)")"
    printf 'tor_data\t%s\n' "$(cr_kept "$m" "$(il_val3 "$r" state tor_marker "tor-$proxy")")"
    case "$(il_val "$r" state lists_marker_rules)" in
      *"$(printf '%s' "$m" | tr '[:upper:]' '[:lower:]').example"*) printf 'lists\tkept\n' ;;
      *) printf 'lists\tlost\n' ;;
    esac
  } >"$d/cmd-reinstall.tsv"
  assert_ne "$g0" "$g1" "the reinstall made a new generation"
  assert_eq "$id0" "$id1" "the admin password survived the reinstall"
  assert_eq "$m" "$(il_val "$r" state anchor_marker)" "the anchor state survived the reinstall"
  assert_eq "$m" "$(il_val3 "$r" state tor_marker "tor-$proxy")" "the Tor data survived the reinstall"
  # Pi-hole stores domains in lower case.
  assert_match "$(printf '%s' "$m" | tr '[:upper:]' '[:lower:]')\\.example" "$(il_val "$r" state lists_marker_rules)" "the Pi-hole lists survived the reinstall"
  printf 'result\tpass\n' >>"$d/cmd-reinstall.tsv"
}

cr_uninstall() {
  local plat="$1" a="$2" d r out images quadlets agents units sbin pulled before x
  d="$(il_dir "$a")"
  cr_require "$a" cr_reinstall
  cr_command "$a" uninstall uninstall || fail "nice-dns uninstall failed: $(tail -n 20 "$d/cmd-uninstall.log")"
  il_report "$a" after-uninstall || fail "lifecycle-report"
  cr_report "$a" report-uninstall || fail "command-report"
  r="$d/report-uninstall.tsv"; out="$d/cmd-uninstall.tsv"
  images="$(il_sec "$r" images | cut -f2 | grep -E "$CR_STACK_IMAGES")"
  before="$(il_sec "$d/report-install.tsv" images | cut -f2 | grep -Ec "$CR_STACK_IMAGES")"
  pulled="$(cr_pulled_left "$d/after-reinstall.tsv" "$r")"
  quadlets="$(il_sec "$r" quadlets | cut -f2 | grep -E '^(nice-dns\.|pi-hole\.|unbound\.|tor-haproxy\.|tor-socat\.)')"
  agents="$(il_sec "$r" agents)"; units="$(il_sec "$r" units)"; sbin="$(il_sec "$r" sbin)"
  {
    il_sec "$r" command
    il_sec "$r" listing
    printf 'resolves\t%s\n' "$(il_val "$d/after-uninstall.tsv" resolution resolves)"
    printf 'stack_images_before\t%s\n' "$before"
    for x in images pulled quadlets agents units sbin; do
      printf '%s_left\t%s\n' "$x" "$(eval "printf '%s' \"\$$x\"" | grep -c .)"
    done
    il_sec "$r" images | sed 's/^image/left_image/'
    printf '%s\n' "$quadlets$agents$units$sbin" | grep . | sed 's/^/left\t/'
  } >"$out"
  il_assert_uninstalled "$plat" "$d/before.tsv" "$d/after-uninstall.tsv"
  assert_eq absent "$(il_val "$r" command command)" "the command is gone"
  assert_eq absent "$(il_val "$r" command source)" "the kept source is gone"
  # The positive controls: an empty list below means something only if the list
  # was read, and the same match found the stack's images before the uninstall.
  assert_eq 0 "$(il_val3 "$r" listing listing images)" "the image list could be read"
  assert_eq 0 "$(il_val3 "$r" listing listing schedules)" "the agent or unit list could be read"
  assert_match '^[1-9]' "$before" "the image check found the stack's images before the uninstall"
  assert_eq "" "$images" "no image of the stack is left"
  assert_ne "" "$(il_sec "$d/after-reinstall.tsv" generation | awk -F '\t' '$1 == "pulled"')" "the generation names the digests it pulled"
  assert_eq "" "$pulled" "no digest the install pulled is left unnamed"
  assert_eq "" "$quadlets" "no quadlet is left"
  assert_eq "" "$agents" "no org.nice-dns.* agent is left, the debug monitor included"
  assert_eq "" "$units" "no unit is left listed, not even as not-found failed"
  assert_eq "" "$sbin" "no root script is left"
  printf 'result\tpass\n' >>"$out"
}

# Runs whatever came before it: the target must end with a working stack.
cr_final() {
  local plat="$1" a="$2" d
  d="$(il_dir "$a")"
  cr_install_step "$plat" "$a" final
  printf 'install_after_uninstall\t%s\nresult\tpass\n' "$(il_val "$d/after-final.tsv" generation current)" >>"$d/cmd-install.tsv"
}

# cr_reuse_dir <platform>: the directory of that platform's cell in a run listed
# in NICE_DNS_CELL_REUSE_RUNS, passed in every step, at the same product (DEC-009).
cr_reuse_dir() {
  local r d s ok
  for r in ${NICE_DNS_CELL_REUSE_RUNS:-}; do
    case "$r" in /*) ;; *) fail "NICE_DNS_CELL_REUSE_RUNS: $r is not an absolute run directory" ;; esac
    [ -d "$r" ] || fail "NICE_DNS_CELL_REUSE_RUNS: no run directory $r"
    for d in "$r"/command-recovery/*/; do
      [ -f "$d/cell.tsv" ] || continue
      [ "$(il_cell_of "$d" cell | cut -d/ -f1)" = "$1" ] || continue
      [ "$(il_cell_of "$d" adapter)" = "$(cr_adapter)" ] || continue
      ok=1
      for s in $CR_STEPS; do grep -qx "$s" "$d/passed.tsv" 2>/dev/null || ok=0; done
      [ "$ok" = 1 ] || continue
      il_same_product "$(il_cell_of "$d" source_sha)" "$1" || continue
      # A cell proven under a looser scenario does not prove this one.
      git -C "$NICE_DNS_ROOT" diff --quiet "$(il_cell_of "$d" source_sha)" HEAD -- \
        tests/live/command-recovery.sh tests/live/target.sh tests/manifests/command-recovery.tsv tests/reports/verify.sh 2>/dev/null || continue
      printf '%s\n' "${d%/}"
      return 0
    done
  done
  return 0
}

cr_adapter() { if [ -n "${NICE_DNS_TARGET_ADAPTER:-}" ]; then echo fake; else echo real; fi; }
il_cell_of() { awk -F '\t' -v k="$2" '$1 == k { print $2; exit }' "$1/cell.tsv"; }
cr_clean() { GIT_OPTIONAL_LOCKS=0 git -C "$1" status --porcelain | grep -v '^?? bridge-eval/bridge-eval$'; }

cr_receipt() {
  local root out r repo cd st d from cell key gen a f id n=0 v s ok p selected rd
  root="$(dirname "$(dirname "$ARTIFACT_DIR")")"
  out="$root/receipts/command-recovery/$RUN_ID"; r="$out/receipt.tsv"
  assert_no_path "$out" "this run has no command-recovery receipt yet"
  mkdir -p "$out/cells" || fail "cannot create $out"
  {
    printf '# schema\tnice-dns-receipt/1\n'
    printf 'receipt\tcommand-recovery\nrun_id\t%s\ncreated_utc\t%s\n' "$RUN_ID" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
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
    printf 'limit\tmac-gui-context\t-\tscope=BL-052\tmacOS commands ran in the GUI context (launchctl asuser), not from plain ssh or Terminal\n'
    printf 'limit\treinstall-clone\t-\tscope=BL-055\treinstall ran with --local, the branch being unpublished; a clone is not proven here\n'
  } >"$r"
  selected=" $(il_platforms) "
  : >"$CASE_DIR/cell-dirs.tsv"
  for d in "$ARTIFACT_DIR"/command-recovery/*/; do
    [ -f "$d/cell.tsv" ] || continue
    printf '%s\t-\n' "${d%/}" >>"$CASE_DIR/cell-dirs.tsv"
  done
  for p in linux macos; do
    case "$selected" in *" $p "*) continue ;; esac
    rd="$(cr_reuse_dir "$p")"
    [ -z "$rd" ] || printf '%s\t%s\n' "$rd" "$(basename "$(dirname "$(dirname "$rd")")")" >>"$CASE_DIR/cell-dirs.tsv"
  done
  while IFS="$(printf '\t')" read -r d from; do
    cell="$(il_cell_of "$d" cell)"; key="$(printf '%s' "$cell" | tr / -)"
    a="$(il_cell_of "$d" target)"
    gen="generation=$(il_val "$d/after-final.tsv" generation current)"
    mkdir -p "$out/cells/$key"
    cp "$d/cell.tsv" "$out/cells/$key/"
    ok=1
    for s in $CR_STEPS; do grep -qx "$s" "$d/passed.tsv" 2>/dev/null || ok=0; done
    if [ "$ok" != 1 ]; then
      printf 'cell\t%s\t%s\t%s\t%s\t%s\tfailed\n' "${cell%%/*}" "$(printf '%s' "$cell" | cut -d/ -f2)" "${cell##*/}" "$a" "$gen" >>"$r"
      continue
    fi
    n=$((n + 1))
    printf 'cell\t%s\t%s\t%s\t%s\t%s\tobserved\n' "${cell%%/*}" "$(printf '%s' "$cell" | cut -d/ -f2)" "${cell##*/}" "$a" "$gen" >>"$r"
    [ "$from" = - ] || printf 'reuse\t%s\t%s\t%s\n' "$cell" "$from" "$(il_cell_of "$d" source_sha)" >>"$r"
    for id in CR-UNBOUND:fault-unbound.tsv CR-PROXY:fault-proxy.tsv CR-RESTART:cmd-restart.tsv CR-REINSTALL:cmd-reinstall.tsv CR-UNINSTALL:cmd-uninstall.tsv CR-INSTALL:cmd-install.tsv; do
      f="${id#*:}"
      cp "$d/$f" "$out/cells/$key/$f"
      printf 'scenario\t%s\t%s\tpass\tcells/%s/%s\t%s\t%s\n' "${id%%:*}" "$cell" "$key" "$f" "$(sha256sum "$out/cells/$key/$f" | cut -d' ' -f1)" "$gen" >>"$r"
    done
  done <"$CASE_DIR/cell-dirs.tsv"
  assert_match '^[1-9]' "$n" "at least one fully passed cell"
  v="$(bash "$NICE_DNS_ROOT/tests/reports/verify.sh" check "$r" 2>&1)"
  assert_rc 0 "$?" "the command-recovery receipt verifies: $v"
  assert_eq "" "$(grep -rlE 'cert=[A-Za-z0-9+/]{20}|(^|[^0-9A-Fa-f])[0-9A-F]{40}([^0-9A-Fa-f]|$)|PRIVATE KEY|"sid":|pwhash|BRIDGE[0-9]+=' "$out" 2>/dev/null)" \
    "no bridge line, certificate, fingerprint, key, session or password hash in the receipt"
  printf 'receipt\t%s\n' "$r" >"$CASE_DIR/receipt-path.tsv"
}

t_01_before() { il_selection; il_each cr_before; }
t_02_install() { il_selection; il_each cr_install; }
t_03_fault_unbound() { il_selection; il_each cr_fault_unbound; }
t_04_fault_proxy() { il_selection; il_each cr_fault_proxy; }
t_05_restart() { il_selection; il_each cr_restart; }
t_06_reinstall() { il_selection; il_each cr_reinstall; }
t_07_uninstall() { il_selection; il_each cr_uninstall; }
t_08_final() { il_selection; il_each cr_final; }

t_09_privacy() {
  il_selection
  assert_eq "" "$(grep -rlE 'cert=[A-Za-z0-9+/]{20}|(^|[^0-9A-Fa-f])[0-9A-F]{40}([^0-9A-Fa-f]|$)|PRIVATE KEY|"sid":|pwhash|BRIDGE[0-9]+=' "$ARTIFACT_DIR/command-recovery" --include='*.tsv' 2>/dev/null)" \
    "no report, sample or step record holds bridge material, a session or a hash"
}

t_10_receipt() { il_selection; cr_receipt; }
