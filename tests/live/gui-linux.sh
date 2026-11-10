# shellcheck shell=bash
# Group live/gui-linux (Sub-plan 6 Task 2.3). Run by `tests/run.sh live
# gui-linux --live --targets FILE --platforms linux`. One cell: mint, the proxy
# it runs now, standard Pi-hole, installed by the nice-dns command from this
# checkout's committed HEAD, whose release/assets.lock pins the GUI asset.
#
# It proves that an install puts the Linux GUI on the host from the verified
# release asset and that the owner can use it:
#
#   gl_before       snapshot; the cell
#   gl_install      nice-dns install from a clone of HEAD (a git bundle, so a
#                   clean commit is recorded): the program,
#                   the launcher (desktop-file-validate) and the icon are
#                   there; `nice-dns-gui --check` over ssh exits 0 and names
#                   the generation
#   gl_screenshot   in the user's graphical session, `nice-dns-gui
#                   --screenshot` writes a PNG; the run fetches it
#   gl_restart      in the session, `--run-action restart --exit` returns 0;
#                   DNS answers afterwards
#   gl_update_check in the session, `--run-action update-check --exit`
#                   returns 0 (current) or 10 (available)
#   gl_uninstall    nice-dns uninstall: the program, the launcher, the icon
#                   and the GUI's files are gone; host DNS given back
#   gl_final        nice-dns install again: the GUI and the stack are back
#
# Evidence: $ARTIFACT_DIR/gui-linux/<alias>/. The command's output stays in
# cmd-*.log and session-*.log, private to the run; only *.tsv and the PNG go
# into the receipt.
#
# Limits (in the receipt): no person clicked: the session hooks run the same
# code paths a click does (Ui::run), with no dialog; the restart needs no root,
# so no polkit prompt was shown.

gl_plan() {
  cat <<'EOF'
gl_before        snapshot the target, record its proxy as the cell
gl_install       nice-dns install from a clone of HEAD: nice-dns-gui, its launcher and icon are installed; --check exits 0 naming the generation
gl_screenshot    nice-dns-gui --screenshot in the user's graphical session writes a PNG; the run fetches it
gl_restart       nice-dns-gui --run-action restart --exit in the session returns 0; DNS answers
gl_update_check  nice-dns-gui --run-action update-check --exit in the session returns 0 or 10
gl_uninstall     nice-dns uninstall removes the program, the launcher, the icon and the files; host DNS given back
gl_final         nice-dns install from a clone of HEAD: the GUI and the stack are back
gl_privacy       no bridge material, session or hash in the evidence
gl_receipt       assemble and verify the gui-linux receipt
EOF
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  if [ "${1:-}" = --dry-run ]; then
    echo "dry run: no target is touched"
    gl_plan
    here="$(cd "$(dirname "$0")" && pwd)"
    ops="$(sed -n "s/^OPS='\(.*\)'$/\1/p" "$here/target.sh")"
    for o in snapshot lifecycle-report command gui-report gui-session; do
      case " $ops " in *" $o "*) ;; *) echo "dry run: target.sh has no operation $o" >&2; exit 1 ;; esac
    done
    for m in screenshot restart update-check; do
      grep -q "gui-session needs --mode .*$m" "$here/target.sh" || { echo "dry run: gui-session has no mode $m" >&2; exit 1; }
    done
    grep -q '^      install-git)' "$here/target.sh" || { echo "dry run: target.sh command has no mode install-git" >&2; exit 1; }
    grep -qx "live	gui-linux	tests/live/gui-linux.sh	live" "$here/../manifests/groups.tsv" || { echo "dry run: the group is not registered" >&2; exit 1; }
    [ -f "$here/../manifests/gui-linux.tsv" ] || { echo "dry run: no receipt manifest" >&2; exit 1; }
    grep -q "^RECEIPTS=.* gui-linux" "$here/../reports/verify.sh" || { echo "dry run: verify.sh does not know the receipt" >&2; exit 1; }
    awk -F '\t' '$1 == "asset" && $2 == "gui" && $3 == "linux" { n++ } END { exit !(n >= 1) }' "$here/../../release/assets.lock" \
      || { echo "dry run: release/assets.lock pins no Linux GUI asset" >&2; exit 1; }
    echo "dry run: the operations, modes, group, manifest and the pinned asset are in place"
    exit 0
  fi
  echo "usage: gui-linux.sh --dry-run (the run itself: tests/run.sh live gui-linux)" >&2
  exit 2
fi

# shellcheck disable=SC1091 # the group runner gives NICE_DNS_ROOT
. "$NICE_DNS_ROOT/tests/live/install-lifecycle.sh"
unset -f t_1_before t_2_upgrade_from_legacy t_3_state_survives t_4_uninstall_restores t_5_final_install t_6_evidence_is_private

GL_SIBS="${NICE_DNS_SIBLINGS_DIR:-$(dirname "$NICE_DNS_ROOT")}"
GL_STEPS='gl_before gl_install gl_screenshot gl_restart gl_update_check gl_uninstall gl_final'
# shellcheck disable=SC2034 # read by il_each
IL_FIRST_STEPS=gl_before

il_dir() { printf '%s\n' "$ARTIFACT_DIR/gui-linux/$1"; }
gl_kv() { awk -F '\t' -v k="$2" '$1 == k { print $2; exit }' "$1"; }
gl_require() { grep -qx "$2" "$(il_dir "$1")/passed.tsv" 2>/dev/null || fail "$2 did not pass on $1; this step does not run"; }
gl_command() {
  local a="$1" label="$2"
  shift 2
  il_t "$a" command --mode "$@" >"$(il_dir "$a")/cmd-$label.log" 2>&1
}
gl_gui_report() { il_t "$1" gui-report >"$(il_dir "$1")/gui-$2.tsv" 2>>"$(il_dir "$1")/ops.log"; }
# gl_session <alias> <mode>: the hook in the session; its rows in
# session-<mode>.log (the PNG row is cut out before anything is kept as tsv).
gl_session() { il_t "$1" gui-session --mode "$2" >"$(il_dir "$1")/session-$2.log" 2>>"$(il_dir "$1")/ops.log"; }

# gl_pinned <alias>: the Linux GUI tarballs the lock pins, fetched here and
# checked against the lock; pinned.tsv names the sha256 of the program inside
# each, one of which an install must publish (Sub-plan 7 Stage 2 gate).
gl_pinned() {
  local d row url sha t
  d="$(il_dir "$1")"; : >"$d/pinned.tsv"
  while IFS= read -r row; do
    url="${row%%	*}" sha="${row#*	}"; t="$d/pinned.tar.gz"
    curl -fsSL --proto =https --max-time 300 "$url" -o "$t" || fail "cannot fetch the pinned GUI $url"
    assert_eq "$sha" "$(sha256sum "$t" | cut -d' ' -f1)" "the pinned tarball ${url##*/} is the lock's"
    printf 'program_sha256\t%s\n' "$(tar -xzOf "$t" nice-dns-gui | sha256sum | cut -d' ' -f1)" >>"$d/pinned.tsv"
    rm -f "$t"
  done <<EOF
$(awk -F '\t' '$1 == "asset" && $2 == "gui" && $3 == "linux" { print $5 "\t" $6 }' "$NICE_DNS_ROOT/release/assets.lock")
EOF
  assert_match '^program_sha256	[0-9a-f]{64}$' "$(head -n 1 "$d/pinned.tsv")" "the lock pins a Linux GUI"
}

# gl_started <alias> <label>: the proxy container's start time, which a
# restart changes.
gl_started() {
  local a="$1" d
  d="$(il_dir "$a")"
  il_t "$a" config >"$d/config-$2.tsv" 2>>"$d/ops.log" || fail "config: $(tail -n 3 "$d/ops.log")"
  awk -F '\t' -v c="tor-$(il_cell "$a" proxy)" '$1 == "started" && $2 == c { print $3; exit }' "$d/config-$2.tsv"
}

# gl_assert_gui <alias> <label>: the GUI as an install leaves it.
gl_assert_gui() {
  local a="$1" label="$2" r gen
  r="$(il_dir "$a")/gui-$label.tsv"
  gen="$(il_val "$(il_dir "$a")/after-$label.tsv" generation current)"
  assert_eq present "$(gl_kv "$r" gui_bin)" "$label: nice-dns-gui is installed"
  grep -qx "program_sha256	$(gl_kv "$r" gui_program_sha256)" "$(il_dir "$a")/pinned.tsv" \
    || fail "$label: the installed program is not the one in a pinned release asset"
  assert_match '^nice-dns-gui [0-9]' "$(gl_kv "$r" gui_version)" "$label: it answers --version"
  assert_eq 0 "$(gl_kv "$r" gui_check_exit)" "$label: --check exits 0: $(gl_kv "$r" gui_check)"
  assert_match "^installed: generation $gen;" "$(gl_kv "$r" gui_check)" "$label: --check names the generation"
  assert_eq present "$(gl_kv "$r" gui_desktop)" "$label: the launcher is installed"
  assert_eq "$(gl_kv "$r" gui_bin_path)" "$(gl_kv "$r" gui_desktop_exec)" "$label: it runs the installed program"
  assert_eq 0 "$(gl_kv "$r" gui_desktop_valid)" "$label: desktop-file-validate accepts it"
  assert_eq present "$(gl_kv "$r" gui_icon)" "$label: the icon is installed"
  assert_eq present "$(gl_kv "$r" gui_dir)" "$label: the GUI's files are kept"
}

# ─────────────────────────── steps ───────────────────────────────────────────

gl_before() {
  local plat="$1" a="$2" d proxy dirty
  d="$(il_dir "$a")"
  [ "$plat" = linux ] || fail "gui-linux runs on Linux only"
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
  gl_pinned "$a"
}

# gl_install_step <platform> <alias> <label>: nice-dns install from an archive
# of HEAD; the stack and the GUI are what HEAD installs.
gl_install_step() {
  local plat="$1" a="$2" label="$3" d proxy
  d="$(il_dir "$a")"; proxy="$(il_cell "$a" proxy)"
  # From a clone of HEAD (a git bundle), so the install records a clean
  # commit and the update check can answer 0 or 10 (an archive records an
  # unknown commit, which the contract answers with 1).
  gl_command "$a" "$label" install-git --cell "$proxy/standard" --source-sha "$(il_cell "$a" source_sha)" \
    || fail "nice-dns install ($label) failed: $(tail -n 20 "$d/cmd-$label.log")"
  assert_eq "" "$(grep 'GUI not installed' "$d/cmd-$label.log")" "$label: the install installed the GUI"
  il_report "$a" "after-$label" || fail "lifecycle-report"
  il_check_deployed "$plat" "$d/after-$label.tsv" "$proxy"
  gl_gui_report "$a" "$label" || fail "gui-report: $(tail -n 5 "$d/ops.log")"
  gl_assert_gui "$a" "$label"
  { grep -v '^gui_check	' "$d/gui-$label.tsv"; printf 'gui_check_generation\t%s\ngui_program_pinned\tyes\nresolves\t%s\nresult\tpass\n' \
      "$(il_val "$d/after-$label.tsv" generation current)" "$(il_val "$d/after-$label.tsv" resolution resolves)"; } >"$d/gl-$label.tsv"
}

gl_install() { gl_install_step "$1" "$2" install; }

gl_screenshot() {
  local a="$2" d l png
  d="$(il_dir "$a")"; l="$d/session-screenshot.log"
  gl_require "$a" gl_install
  gl_session "$a" screenshot || fail "gui-session screenshot: $(tail -n 5 "$d/ops.log")"
  assert_eq 0 "$(gl_kv "$l" gui_exit)" "--screenshot exits 0: $(grep '^out	' "$l" | tail -n 3)"
  png="$d/gui-linux.png"
  gl_kv "$l" png_base64 | base64 -d >"$png" || fail "the PNG did not decode"
  assert_eq "$(gl_kv "$l" png_sha256)" "$(sha256sum "$png" | cut -d' ' -f1)" "the fetched PNG is the one written"
  assert_match '^PNG image data' "$(file -b "$png")" "it is a PNG"
  [ "$(stat -c %s "$png")" -gt 10000 ] || fail "the PNG is only $(stat -c %s "$png") bytes"
  printf 'gui_exit\t%s\npng_size\t%s\npng_sha256\t%s\npng_file\tgui-linux.png\nresult\tpass\n' \
    "$(gl_kv "$l" gui_exit)" "$(gl_kv "$l" png_size)" "$(gl_kv "$l" png_sha256)" >"$d/gl-screenshot.tsv"
}

gl_restart() {
  local plat="$1" a="$2" d l proxy s0 s1
  d="$(il_dir "$a")"; l="$d/session-restart.log"; proxy="$(il_cell "$a" proxy)"
  gl_require "$a" gl_install
  s0="$(gl_started "$a" before-restart)"
  assert_ne "" "$s0" "the proxy's start time is read before the restart"
  gl_session "$a" restart || fail "gui-session restart: $(tail -n 5 "$d/ops.log")"
  assert_eq 0 "$(gl_kv "$l" gui_exit)" "--run-action restart exits 0: $(grep '^out	' "$l" | tail -n 5)"
  assert_match 'finished \(exit 0\)$' "$(grep '^out	' "$l" | tail -n 1)" "the pane ends with the action's exit"
  il_report "$a" after-restart || fail "lifecycle-report"
  il_check_deployed "$plat" "$d/after-restart.tsv" "$proxy"
  s1="$(gl_started "$a" after-restart)"
  assert_ne "$s0" "$s1" "the proxy restarted (start time $s0, then $s1)"
  printf 'gui_exit\t%s\nproxy_restarted\tyes\npane_last\t%s\nresolves\t%s\nresult\tpass\n' "$(gl_kv "$l" gui_exit)" \
    "$(grep '^out	' "$l" | tail -n 1 | cut -f2- | tr '\t' ' ')" "$(il_val "$d/after-restart.tsv" resolution resolves)" >"$d/gl-restart.tsv"
}

gl_update_check() {
  local a="$2" d l rc
  d="$(il_dir "$a")"; l="$d/session-update-check.log"
  gl_require "$a" gl_install
  gl_session "$a" update-check || fail "gui-session update-check: $(tail -n 5 "$d/ops.log")"
  rc="$(gl_kv "$l" gui_exit)"
  assert_match '^(0|10)$' "$rc" "--run-action update-check exits 0 or 10: $(grep '^out	' "$l" | tail -n 5)"
  printf 'gui_exit\t%s\npane_last\t%s\nresult\tpass\n' "$rc" "$(grep '^out	' "$l" | tail -n 1 | cut -f2- | tr '\t' ' ')" >"$d/gl-update-check.tsv"
}

gl_uninstall() {
  local plat="$1" a="$2" d r
  d="$(il_dir "$a")"
  gl_require "$a" gl_install
  gl_command "$a" uninstall uninstall || fail "nice-dns uninstall failed: $(tail -n 20 "$d/cmd-uninstall.log")"
  il_report "$a" after-uninstall || fail "lifecycle-report"
  il_assert_uninstalled "$plat" "$d/before.tsv" "$d/after-uninstall.tsv"
  gl_gui_report "$a" uninstall || fail "gui-report"
  r="$d/gui-uninstall.tsv"
  assert_eq absent "$(gl_kv "$r" gui_bin)" "the program is gone"
  assert_eq absent "$(gl_kv "$r" gui_desktop)" "the launcher is gone"
  assert_eq absent "$(gl_kv "$r" gui_icon)" "the icon is gone"
  assert_eq absent "$(gl_kv "$r" gui_dir)" "the GUI's files are gone"
  { cat "$r"; printf 'resolves\t%s\nresult\tpass\n' "$(il_val "$d/after-uninstall.tsv" resolution resolves)"; } >"$d/gl-uninstall.tsv"
}

# Runs whatever came before it: the target must end with a working stack.
gl_final() { gl_install_step "$1" "$2" final; }

gl_clean() { GIT_OPTIONAL_LOCKS=0 git -C "$1" status --porcelain | grep -v '^?? bridge-eval/bridge-eval$'; }

gl_receipt() {
  local root out r repo cd st d cell key gen a f id n=0 v s ok
  root="$(dirname "$(dirname "$ARTIFACT_DIR")")"
  out="$root/receipts/gui-linux/$RUN_ID"; r="$out/receipt.tsv"
  assert_no_path "$out" "this run has no gui-linux receipt yet"
  mkdir -p "$out/cells" || fail "cannot create $out"
  {
    printf '# schema\tnice-dns-receipt/1\n'
    printf 'receipt\tgui-linux\nrun_id\t%s\ncreated_utc\t%s\n' "$RUN_ID" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    for repo in nice-dns tor-haproxy tor-socat hardened-unbound pi-hole-hardened; do
      if [ "$repo" = nice-dns ]; then cd="$NICE_DNS_ROOT"; else cd="$GL_SIBS/$repo"; fi
      if [ -n "$(gl_clean "$cd")" ]; then st=dirty; else st=clean; fi
      printf 'source\t%s\t%s\t%s\n' "$repo" "$(git -C "$cd" rev-parse HEAD)" "$st"
    done
    for repo in tor-haproxy tor-socat hardened-unbound pi-hole-hardened; do
      printf 'arch\t%s\t%s\t%s\n' "$repo" "$(git -C "$GL_SIBS/$repo" rev-parse HEAD)" \
        "$(git -C "$GL_SIBS/$repo" show HEAD:.github/workflows/main.yml |
          awk '/^ *platform: *$/ { on = 1; next } on && /^ *- *linux\// { sub(/^ *- */, ""); print; next } on { on = 0 }' |
          sort | paste -sd, -)"
    done
    printf 'product\tnice-dns\t%s\n' "$(git -C "$NICE_DNS_ROOT" rev-parse HEAD)"
    printf 'limit\tno-person-clicked\t-\tscope=sub-plan-6\tthe session hooks ran the code a click runs (Ui::run) with no dialog; the restart needs no root, so no polkit prompt was shown\n'
  } >"$r"
  for d in "$ARTIFACT_DIR"/gui-linux/*/; do
    [ -f "$d/cell.tsv" ] || continue
    d="${d%/}"
    cell="$(awk -F '\t' '$1 == "cell" { print $2; exit }' "$d/cell.tsv")"; key="$(printf '%s' "$cell" | tr / -)"
    a="$(awk -F '\t' '$1 == "target" { print $2; exit }' "$d/cell.tsv")"
    gen="generation=$(il_val "$d/after-final.tsv" generation current)"
    mkdir -p "$out/cells/$key"
    cp "$d/cell.tsv" "$out/cells/$key/"
    ok=1
    for s in $GL_STEPS; do grep -qx "$s" "$d/passed.tsv" 2>/dev/null || ok=0; done
    if [ "$ok" != 1 ]; then
      printf 'cell\t%s\t%s\t%s\t%s\t%s\tfailed\n' "${cell%%/*}" "$(printf '%s' "$cell" | cut -d/ -f2)" "${cell##*/}" "$a" "$gen" >>"$r"
      continue
    fi
    n=$((n + 1))
    printf 'cell\t%s\t%s\t%s\t%s\t%s\tobserved\n' "${cell%%/*}" "$(printf '%s' "$cell" | cut -d/ -f2)" "${cell##*/}" "$a" "$gen" >>"$r"
    cp "$d/gui-linux.png" "$out/cells/$key/gui-linux.png"
    for id in GL-INSTALL:gl-install.tsv GL-SCREENSHOT:gl-screenshot.tsv GL-RESTART:gl-restart.tsv GL-UPDATE-CHECK:gl-update-check.tsv GL-UNINSTALL:gl-uninstall.tsv GL-FINAL:gl-final.tsv; do
      f="${id#*:}"
      cp "$d/$f" "$out/cells/$key/$f"
      printf 'scenario\t%s\t%s\tpass\tcells/%s/%s\t%s\t%s\n' "${id%%:*}" "$cell" "$key" "$f" "$(sha256sum "$out/cells/$key/$f" | cut -d' ' -f1)" "$gen" >>"$r"
    done
  done
  assert_match '^[1-9]' "$n" "at least one fully passed cell"
  v="$(bash "$NICE_DNS_ROOT/tests/reports/verify.sh" check "$r" 2>&1)"
  assert_rc 0 "$?" "the gui-linux receipt verifies: $v"
  assert_eq "" "$(grep -rlE 'cert=[A-Za-z0-9+/]{20}|(^|[^0-9A-Fa-f])[0-9A-F]{40}([^0-9A-Fa-f]|$)|PRIVATE KEY|"sid":|pwhash|BRIDGE[0-9]+=' "$out" --include='*.tsv' 2>/dev/null)" \
    "no bridge line, certificate, fingerprint, key, session or password hash in the receipt"
}

t_01_before() { il_selection; il_each gl_before; }
t_02_install() { il_selection; il_each gl_install; }
t_03_screenshot() { il_selection; il_each gl_screenshot; }
t_04_restart() { il_selection; il_each gl_restart; }
t_05_update_check() { il_selection; il_each gl_update_check; }
t_06_uninstall() { il_selection; il_each gl_uninstall; }
t_07_final() { il_selection; il_each gl_final; }

t_08_privacy() {
  il_selection
  assert_eq "" "$(grep -rlE 'cert=[A-Za-z0-9+/]{20}|(^|[^0-9A-Fa-f])[0-9A-F]{40}([^0-9A-Fa-f]|$)|PRIVATE KEY|"sid":|pwhash|BRIDGE[0-9]+=' "$ARTIFACT_DIR/gui-linux" --include='*.tsv' 2>/dev/null)" \
    "no report, sample or step record holds bridge material, a session or a hash"
}

t_09_receipt() { il_selection; gl_receipt; }
