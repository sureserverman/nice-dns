# shellcheck shell=bash
# Group live/helper-install (Sub-plan 5 Task 2.6). Run by `tests/run.sh live
# helper-install --live --targets FILE --platforms linux,macos`. One cell per
# platform: the proxy the target runs now, standard Pi-hole, installed by the
# nice-dns command from this checkout's committed HEAD. Both platforms at once.
#
# It proves that a caller with no terminal (the GUI) gets an install, a
# reinstall and an uninstall done through nice-dns-helper, never sudo:
#
#   hi_before     snapshot; on mint, the temporary polkit rule that lets the
#                 target user run org.nice-dns.helper with no password (no one
#                 is at the screen to answer the dialog; never shipped)
#   hi_install    nice-dns install from an archive of HEAD, sudo available
#                 (the terminal path): the helper lands as a side effect,
#                 root-owned, 0755 (Linux) or 4755 (macOS), the version root-ops
#                 expects, running HEAD's root-ops; DNS answers
#   hi_reinstall  nice-dns reinstall --local with a sudo that only fails: it
#                 succeeds, no root step asked sudo, and on Linux pkexec's
#                 journal shows the helper run for each verb; DNS answers
#   hi_uninstall  nice-dns uninstall with the same sudo: it succeeds, nothing
#                 asked sudo for a root step, the helper, its root-ops copy and
#                 (Linux) the polkit action are gone; host DNS given back
#   hi_final      nice-dns install again, sudo available: everything is back
#   cleanup       the polkit test rule is removed whatever happened
#
# Evidence: $ARTIFACT_DIR/helper-install/<alias>/. The command's output may
# hold bridge lines: it stays in cmd-*.log and ops.log, private to the run;
# only *.tsv is checked and copied into the receipt.
#
# Limits (in the receipt): the terminal path ran with passwordless sudo and no
# tty, so neither a sudo nor a polkit password dialog was answered by a
# person; on Linux the polkit rule stands in for the administrator, so
# auth_admin_keep's prompt and the one runner process (OD-11) are shown by
# the fixture tests only; macOS commands ran in the GUI context (launchctl
# asuser, DEC-024).

hi_plan() {
  cat <<'EOF'
hi_before     snapshot the target, record its proxy as the cell; Linux: add the polkit test rule
hi_install    nice-dns install from an archive of HEAD, sudo available: the helper lands, root-owned, the expected mode and version, HEAD's root-ops; DNS answers
hi_reinstall  nice-dns reinstall --local with a failing sudo: succeeds through the helper (Linux: pkexec's journal names it per verb); DNS answers
hi_uninstall  nice-dns uninstall with a failing sudo: succeeds through the helper; the helper, its root-ops and the polkit action are gone; host DNS given back
hi_final      nice-dns install from an archive of HEAD, sudo available: the helper and the stack are back
hi_cleanup    Linux: the polkit test rule removed, whatever happened before
hi_privacy    no bridge material, session or hash in the evidence
hi_receipt    assemble and verify the helper-install receipt
EOF
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  if [ "${1:-}" = --dry-run ]; then
    echo "dry run: no target is touched"
    hi_plan
    here="$(cd "$(dirname "$0")" && pwd)"
    # Every adapter operation and command mode the run uses must exist.
    ops="$(sed -n "s/^OPS='\(.*\)'$/\1/p" "$here/target.sh")"
    for o in snapshot lifecycle-report command helper-report polkit-test-rule; do
      case " $ops " in *" $o "*) ;; *) echo "dry run: target.sh has no operation $o" >&2; exit 1 ;; esac
    done
    for m in install reinstall-helper uninstall-helper; do
      grep -q "^      [a-z|-]*${m}[a-z|-]*) " "$here/target.sh" || { echo "dry run: target.sh command has no mode $m" >&2; exit 1; }
    done
    grep -qx "live	helper-install	tests/live/helper-install.sh	live" "$here/../manifests/groups.tsv" || { echo "dry run: the group is not registered" >&2; exit 1; }
    [ -f "$here/../manifests/helper-install.tsv" ] || { echo "dry run: no receipt manifest" >&2; exit 1; }
    echo "dry run: the operations, modes, group and manifest are in place"
    exit 0
  fi
  echo "usage: helper-install.sh --dry-run (the run itself: tests/run.sh live helper-install)" >&2
  exit 2
fi

# shellcheck disable=SC1091 # the group runner gives NICE_DNS_ROOT
. "$NICE_DNS_ROOT/tests/live/install-lifecycle.sh"
unset -f t_1_before t_2_upgrade_from_legacy t_3_state_survives t_4_uninstall_restores t_5_final_install t_6_evidence_is_private

HI_SIBS="${NICE_DNS_SIBLINGS_DIR:-$(dirname "$NICE_DNS_ROOT")}"
HI_STEPS='hi_before hi_install hi_reinstall hi_uninstall hi_final hi_cleanup'
# shellcheck disable=SC2034 # read by il_each
IL_FIRST_STEPS=hi_before

il_dir() { printf '%s\n' "$ARTIFACT_DIR/helper-install/$1"; }
hi_kv() { awk -F '\t' -v k="$2" '$1 == k { print $2; exit }' "$1"; }
hi_os() { if [ "$1" = linux ]; then echo deb; else echo mac; fi; }
hi_require() { grep -qx "$2" "$(il_dir "$1")/passed.tsv" 2>/dev/null || fail "$2 did not pass on $1; this step does not run"; }
hi_command() {
  local a="$1" label="$2"
  shift 2
  il_t "$a" command --mode "$@" >"$(il_dir "$a")/cmd-$label.log" 2>&1
}
hi_helper_report() { il_t "$1" helper-report >"$(il_dir "$1")/helper-$2.tsv" 2>>"$(il_dir "$1")/ops.log"; }

# hi_assert_helper <platform> <alias> <label>: the helper as an install leaves
# it, recorded in helper-<label>.tsv.
hi_assert_helper() {
  local plat="$1" a="$2" label="$3" r sha want mode os
  r="$(il_dir "$a")/helper-$label.tsv"; os="$(hi_os "$plat")"
  sha="$(il_cell "$a" source_sha)"
  want="$(git -C "$NICE_DNS_ROOT" show "$sha:$os/root-ops" | sed -n 's/^ND_HELPER_VERSION=//p')"
  if [ "$plat" = linux ]; then mode=755; else mode=4755; fi
  assert_eq present "$(hi_kv "$r" helper)" "$label: the helper is installed"
  assert_eq 0 "$(hi_kv "$r" helper_owner)" "$label: root owns it"
  assert_eq "$mode" "$(hi_kv "$r" helper_mode)" "$label: its mode is $mode"
  assert_eq "$want" "$(hi_kv "$r" helper_version)" "$label: it is the version root-ops expects"
  assert_eq "$(git -C "$NICE_DNS_ROOT" show "$sha:$os/root-ops" | sha256sum | cut -d' ' -f1)" "$(hi_kv "$r" held_root_ops_sha)" "$label: it runs HEAD's root-ops"
  if [ "$plat" = linux ]; then
    assert_eq present "$(hi_kv "$r" policy)" "$label: the polkit action is installed"
  else
    assert_eq "$(hi_kv "$r" user_uid)" "$(hi_kv "$r" owner_file)" "$label: its owner file names the installing user"
  fi
}

# hi_assert_no_sudo <alias> <label>: the command, run with a failing sudo,
# succeeded and asked sudo for no root step; on Linux pkexec ran the helper.
hi_assert_no_sudo() {
  local a="$1" label="$2" plat="$3" l n
  l="$(il_dir "$a")/cmd-$label.log"
  assert_eq 0 "$(hi_kv "$l" command_exit)" "$label: the command succeeded with no sudo to fall back on"
  assert_eq 0 "$(hi_kv "$l" sudo_root_ops)" "$label: no root step asked sudo"
  if [ "$plat" = linux ]; then
    n="$(grep -c '^pkexec	/usr/libexec/nice-dns-helper --tree ' "$l")"
    assert_match '^[1-9]' "$n" "$label: pkexec's journal shows the helper run"
    assert_eq "" "$(grep '^pkexec	' "$l" | grep -v '^pkexec	/usr/libexec/nice-dns-helper --tree ')" "$label: pkexec ran nothing but the helper"
  fi
}

# ─────────────────────────── steps ───────────────────────────────────────────

hi_before() {
  local plat="$1" a="$2" d proxy dirty r
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
  if [ "$plat" = linux ]; then
    r="$d/polkit-add.tsv"
    il_t "$a" polkit-test-rule --mode add >"$r" 2>>"$d/ops.log" || fail "polkit-test-rule add: $(tail -n 5 "$d/ops.log")"
    assert_eq present "$(hi_kv "$r" polkit_test_rule)" "the polkit test rule is in place"
  fi
}

# hi_install_step <platform> <alias> <label>: nice-dns install from an archive
# of HEAD with sudo available; the helper and the stack are what HEAD installs.
hi_install_step() {
  local plat="$1" a="$2" label="$3" d proxy
  d="$(il_dir "$a")"; proxy="$(il_cell "$a" proxy)"
  hi_command "$a" "$label" install --cell "$proxy/standard" --source-sha "$(il_cell "$a" source_sha)" \
    || fail "nice-dns install ($label) failed: $(tail -n 20 "$d/cmd-$label.log")"
  il_report "$a" "after-$label" || fail "lifecycle-report"
  il_check_deployed "$plat" "$d/after-$label.tsv" "$proxy"
  hi_helper_report "$a" "$label" || fail "helper-report: $(tail -n 5 "$d/ops.log")"
  hi_assert_helper "$plat" "$a" "$label"
  { cat "$d/helper-$label.tsv"; printf 'resolves\t%s\nresult\tpass\n' "$(il_val "$d/after-$label.tsv" resolution resolves)"; } >"$d/hi-$label.tsv"
}

hi_install() { hi_install_step "$1" "$2" install; }

hi_reinstall() {
  local plat="$1" a="$2" d proxy
  d="$(il_dir "$a")"; proxy="$(il_cell "$a" proxy)"
  hi_require "$a" hi_install
  hi_command "$a" reinstall reinstall-helper || fail "nice-dns reinstall without sudo failed: $(tail -n 20 "$d/cmd-reinstall.log")"
  hi_assert_no_sudo "$a" reinstall "$plat"
  il_report "$a" after-reinstall || fail "lifecycle-report"
  il_check_deployed "$plat" "$d/after-reinstall.tsv" "$proxy"
  hi_helper_report "$a" reinstall || fail "helper-report"
  hi_assert_helper "$plat" "$a" reinstall
  {
    printf 'command_exit\t%s\nsudo_root_ops\t%s\n' "$(hi_kv "$d/cmd-reinstall.log" command_exit)" "$(hi_kv "$d/cmd-reinstall.log" sudo_root_ops)"
    printf 'pkexec_helper_runs\t%s\n' "$(grep -c '^pkexec	/usr/libexec/nice-dns-helper --tree ' "$d/cmd-reinstall.log")"
    grep '^pkexec	' "$d/cmd-reinstall.log" | awk -F ' ' '{ print "verb\t" $NF }' | sort -u
    printf 'resolves\t%s\nresult\tpass\n' "$(il_val "$d/after-reinstall.tsv" resolution resolves)"
  } >"$d/hi-reinstall.tsv"
}

hi_uninstall() {
  local plat="$1" a="$2" d r
  d="$(il_dir "$a")"
  hi_require "$a" hi_reinstall
  hi_command "$a" uninstall uninstall-helper || fail "nice-dns uninstall without sudo failed: $(tail -n 20 "$d/cmd-uninstall.log")"
  hi_assert_no_sudo "$a" uninstall "$plat"
  il_report "$a" after-uninstall || fail "lifecycle-report"
  il_assert_uninstalled "$plat" "$d/before.tsv" "$d/after-uninstall.tsv"
  hi_helper_report "$a" uninstall || fail "helper-report"
  r="$d/helper-uninstall.tsv"
  assert_eq absent "$(hi_kv "$r" helper)" "the helper is gone"
  assert_eq absent "$(hi_kv "$r" helper_dir)" "its root-ops copy and directory are gone"
  [ "$plat" != linux ] || assert_eq absent "$(hi_kv "$r" policy)" "the polkit action is gone"
  {
    printf 'command_exit\t%s\nsudo_root_ops\t%s\n' "$(hi_kv "$d/cmd-uninstall.log" command_exit)" "$(hi_kv "$d/cmd-uninstall.log" sudo_root_ops)"
    printf 'pkexec_helper_runs\t%s\n' "$(grep -c '^pkexec	/usr/libexec/nice-dns-helper --tree ' "$d/cmd-uninstall.log")"
    printf 'helper\t%s\nhelper_dir\t%s\n' "$(hi_kv "$r" helper)" "$(hi_kv "$r" helper_dir)"
    [ "$plat" != linux ] || printf 'policy\t%s\n' "$(hi_kv "$r" policy)"
    printf 'resolves\t%s\nresult\tpass\n' "$(il_val "$d/after-uninstall.tsv" resolution resolves)"
  } >"$d/hi-uninstall.tsv"
}

# Runs whatever came before it: the target must end with a working stack.
hi_final() { hi_install_step "$1" "$2" final; }

# Whatever came before: the polkit test rule never stays on the target.
hi_cleanup() {
  local plat="$1" a="$2" d r
  d="$(il_dir "$a")"
  [ "$plat" = linux ] || return 0
  r="$d/polkit-remove.tsv"
  il_t "$a" polkit-test-rule --mode remove >"$r" 2>>"$d/ops.log" || fail "polkit-test-rule remove: $(tail -n 5 "$d/ops.log")"
  assert_eq absent "$(hi_kv "$r" polkit_test_rule)" "the polkit test rule is gone"
}

hi_clean() { GIT_OPTIONAL_LOCKS=0 git -C "$1" status --porcelain | grep -v '^?? bridge-eval/bridge-eval$'; }

hi_receipt() {
  local root out r repo cd st d cell key gen a f id n=0 v s ok
  root="$(dirname "$(dirname "$ARTIFACT_DIR")")"
  out="$root/receipts/helper-install/$RUN_ID"; r="$out/receipt.tsv"
  assert_no_path "$out" "this run has no helper-install receipt yet"
  mkdir -p "$out/cells" || fail "cannot create $out"
  {
    printf '# schema\tnice-dns-receipt/1\n'
    printf 'receipt\thelper-install\nrun_id\t%s\ncreated_utc\t%s\n' "$RUN_ID" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    for repo in nice-dns tor-haproxy tor-socat hardened-unbound pi-hole-hardened; do
      if [ "$repo" = nice-dns ]; then cd="$NICE_DNS_ROOT"; else cd="$HI_SIBS/$repo"; fi
      if [ -n "$(hi_clean "$cd")" ]; then st=dirty; else st=clean; fi
      printf 'source\t%s\t%s\t%s\n' "$repo" "$(git -C "$cd" rev-parse HEAD)" "$st"
    done
    for repo in tor-haproxy tor-socat hardened-unbound pi-hole-hardened; do
      printf 'arch\t%s\t%s\t%s\n' "$repo" "$(git -C "$HI_SIBS/$repo" rev-parse HEAD)" \
        "$(git -C "$HI_SIBS/$repo" show HEAD:.github/workflows/main.yml |
          awk '/^ *platform: *$/ { on = 1; next } on && /^ *- *linux\// { sub(/^ *- */, ""); print; next } on { on = 0 }' |
          sort | paste -sd, -)"
    done
    printf 'product\tnice-dns\t%s\n' "$(git -C "$NICE_DNS_ROOT" rev-parse HEAD)"
    printf 'limit\tno-person-prompted\t-\tscope=sub-plan-5\tthe terminal path ran with passwordless sudo and no tty; on Linux a temporary polkit rule stood in for the administrator, so the prompt and the one-runner rule (OD-11) rest on the fixture tests\n'
    printf 'limit\tmac-gui-context\t-\tscope=BL-052\tmacOS commands ran in the GUI context (launchctl asuser), not from plain ssh or Terminal\n'
  } >"$r"
  for d in "$ARTIFACT_DIR"/helper-install/*/; do
    [ -f "$d/cell.tsv" ] || continue
    d="${d%/}"
    cell="$(awk -F '\t' '$1 == "cell" { print $2; exit }' "$d/cell.tsv")"; key="$(printf '%s' "$cell" | tr / -)"
    a="$(awk -F '\t' '$1 == "target" { print $2; exit }' "$d/cell.tsv")"
    gen="generation=$(il_val "$d/after-final.tsv" generation current)"
    mkdir -p "$out/cells/$key"
    cp "$d/cell.tsv" "$out/cells/$key/"
    ok=1
    for s in $HI_STEPS; do grep -qx "$s" "$d/passed.tsv" 2>/dev/null || ok=0; done
    if [ "$ok" != 1 ]; then
      printf 'cell\t%s\t%s\t%s\t%s\t%s\tfailed\n' "${cell%%/*}" "$(printf '%s' "$cell" | cut -d/ -f2)" "${cell##*/}" "$a" "$gen" >>"$r"
      continue
    fi
    n=$((n + 1))
    printf 'cell\t%s\t%s\t%s\t%s\t%s\tobserved\n' "${cell%%/*}" "$(printf '%s' "$cell" | cut -d/ -f2)" "${cell##*/}" "$a" "$gen" >>"$r"
    for id in HI-INSTALL:hi-install.tsv HI-REINSTALL:hi-reinstall.tsv HI-UNINSTALL:hi-uninstall.tsv HI-FINAL:hi-final.tsv; do
      f="${id#*:}"
      cp "$d/$f" "$out/cells/$key/$f"
      printf 'scenario\t%s\t%s\tpass\tcells/%s/%s\t%s\t%s\n' "${id%%:*}" "$cell" "$key" "$f" "$(sha256sum "$out/cells/$key/$f" | cut -d' ' -f1)" "$gen" >>"$r"
    done
  done
  assert_match '^[1-9]' "$n" "at least one fully passed cell"
  v="$(bash "$NICE_DNS_ROOT/tests/reports/verify.sh" check "$r" 2>&1)"
  assert_rc 0 "$?" "the helper-install receipt verifies: $v"
  assert_eq "" "$(grep -rlE 'cert=[A-Za-z0-9+/]{20}|(^|[^0-9A-Fa-f])[0-9A-F]{40}([^0-9A-Fa-f]|$)|PRIVATE KEY|"sid":|pwhash|BRIDGE[0-9]+=' "$out" 2>/dev/null)" \
    "no bridge line, certificate, fingerprint, key, session or password hash in the receipt"
}

t_01_before() { il_selection; il_each hi_before; }
t_02_install() { il_selection; il_each hi_install; }
t_03_reinstall() { il_selection; il_each hi_reinstall; }
t_04_uninstall() { il_selection; il_each hi_uninstall; }
t_05_final() { il_selection; il_each hi_final; }
t_06_cleanup() { il_selection; il_each hi_cleanup; }

t_07_privacy() {
  il_selection
  assert_eq "" "$(grep -rlE 'cert=[A-Za-z0-9+/]{20}|(^|[^0-9A-Fa-f])[0-9A-F]{40}([^0-9A-Fa-f]|$)|PRIVATE KEY|"sid":|pwhash|BRIDGE[0-9]+=' "$ARTIFACT_DIR/helper-install" --include='*.tsv' 2>/dev/null)" \
    "no report, sample or step record holds bridge material, a session or a hash"
}

t_08_receipt() { il_selection; hi_receipt; }
