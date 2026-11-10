# shellcheck shell=bash
# Group live/gui-mac (Sub-plan 7 Task 2.3). Run by `tests/run.sh live gui-mac
# --live --targets FILE --platforms macos`. One cell: mac, the proxy it runs
# now, standard Pi-hole, installed by the nice-dns command from this
# checkout's committed HEAD, whose release/assets.lock pins the macOS app.
#
# It proves that an install puts the menu-bar app on the Mac from the verified
# release asset and that the owner can run it:
#
#   gm_before       snapshot; the cell
#   gm_install      nice-dns install from a clone of HEAD (a git bundle):
#                   ~/Applications/nice-dns.app is there, signed, with no
#                   quarantine; its --check in the gui domain exits 0 and names
#                   the generation
#   gm_screenshot   in the gui domain, --screenshot writes a PNG; the run
#                   fetches it
#   gm_restart      --run-action restart --exit returns 0; DNS answers
#   gm_bridges      --run-action bridges-off --exit, then bridges-on, each
#                   returns 0 with DNS answering after; the target ends with
#                   the bridges mode it had
#   gm_open         open -a ~/Applications/nice-dns.app leaves a running
#                   process (as Finder starts it), which is then quit
#   gm_uninstall    nice-dns uninstall removes the app; host DNS given back
#   gm_final        nice-dns install again: the app and the stack are back
#
# Evidence: $ARTIFACT_DIR/gui-mac/<alias>/. The command's output stays in
# cmd-*.log and session-*.log, private to the run; only *.tsv and the PNG go
# into the receipt.
#
# Limits (in the receipt): no person clicked and the menu bar was not seen:
# over ssh there is no Screen Recording or Accessibility grant, so the hooks
# run the code a click runs, and the app is quit by SIGTERM (an Apple event
# needs an Automation grant).

gm_plan() {
  cat <<'EOF'
gm_before        snapshot the target, record its proxy as the cell
gm_install       nice-dns install from a clone of HEAD: ~/Applications/nice-dns.app is installed, signed, without quarantine; --check in the gui domain exits 0 naming the generation
gm_screenshot    NiceDNSGUI --screenshot in the gui domain writes a PNG; the run fetches it
gm_restart       NiceDNSGUI --run-action restart --exit in the gui domain returns 0; DNS answers
gm_bridges       --run-action bridges-off --exit then bridges-on, each returns 0 with DNS answering after
gm_open          open -a ~/Applications/nice-dns.app leaves a running NiceDNSGUI, which is then quit
gm_uninstall     nice-dns uninstall removes ~/Applications/nice-dns.app; host DNS given back
gm_final         nice-dns install from a clone of HEAD: the app and the stack are back
gm_privacy       no bridge material, session or hash in the evidence
gm_receipt       assemble and verify the gui-mac receipt
EOF
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  if [ "${1:-}" = --dry-run ]; then
    echo "dry run: no target is touched"
    gm_plan
    here="$(cd "$(dirname "$0")" && pwd)"
    ops="$(sed -n "s/^OPS='\(.*\)'$/\1/p" "$here/target.sh")"
    for o in snapshot lifecycle-report command gui-report gui-session; do
      case " $ops " in *" $o "*) ;; *) echo "dry run: target.sh has no operation $o" >&2; exit 1 ;; esac
    done
    for m in screenshot restart bridges-off bridges-on open launch running; do
      grep -q "gui-session needs --mode .*$m" "$here/target.sh" || { echo "dry run: gui-session has no mode $m" >&2; exit 1; }
    done
    grep -q '^    if \[ "\$plat" = macos \]; then$' "$here/target.sh" || { echo "dry run: target.sh has no macOS GUI branch" >&2; exit 1; }
    grep -q '^      install-git)' "$here/target.sh" || { echo "dry run: target.sh command has no mode install-git" >&2; exit 1; }
    grep -qx "live	gui-mac	tests/live/gui-mac.sh	live" "$here/../manifests/groups.tsv" || { echo "dry run: the group is not registered" >&2; exit 1; }
    [ -f "$here/../manifests/gui-mac.tsv" ] || { echo "dry run: no receipt manifest" >&2; exit 1; }
    grep -q "^RECEIPTS=.* gui-mac" "$here/../reports/verify.sh" || { echo "dry run: verify.sh does not know the receipt" >&2; exit 1; }
    awk -F '\t' '$1 == "asset" && $2 == "gui" && $3 == "macos" { n++ } END { exit !(n >= 1) }' "$here/../../release/assets.lock" \
      || { echo "dry run: release/assets.lock pins no macOS GUI asset" >&2; exit 1; }
    echo "dry run: the operations, modes, group, manifest and the pinned asset are in place"
    exit 0
  fi
  echo "usage: gui-mac.sh --dry-run (the run itself: tests/run.sh live gui-mac)" >&2
  exit 2
fi

# shellcheck disable=SC1091 # the group runner gives NICE_DNS_ROOT
. "$NICE_DNS_ROOT/tests/live/install-lifecycle.sh"
unset -f t_1_before t_2_upgrade_from_legacy t_3_state_survives t_4_uninstall_restores t_5_final_install t_6_evidence_is_private

GM_SIBS="${NICE_DNS_SIBLINGS_DIR:-$(dirname "$NICE_DNS_ROOT")}"
GM_STEPS='gm_before gm_install gm_screenshot gm_restart gm_bridges gm_open gm_uninstall gm_final'
GM_DNS_MAX="${GM_DNS_MAX:-300}"
# shellcheck disable=SC2034 # read by il_each
IL_FIRST_STEPS=gm_before

il_dir() { printf '%s\n' "$ARTIFACT_DIR/gui-mac/$1"; }
gm_kv() { awk -F '\t' -v k="$2" '$1 == k { print $2; exit }' "$1"; }
gm_require() { grep -qx "$2" "$(il_dir "$1")/passed.tsv" 2>/dev/null || fail "$2 did not pass on $1; this step does not run"; }
gm_command() {
  local a="$1" label="$2"
  shift 2
  il_t "$a" command --mode "$@" >"$(il_dir "$a")/cmd-$label.log" 2>&1
}
gm_gui_report() { il_t "$1" gui-report >"$(il_dir "$1")/gui-$2.tsv" 2>>"$(il_dir "$1")/ops.log"; }
# gm_session <alias> <mode>: the hook in the gui domain; its rows in
# session-<mode>.log (the PNG row is cut out before anything is kept as tsv).
gm_session() { il_t "$1" gui-session --mode "$2" >"$(il_dir "$1")/session-$2.log" 2>>"$(il_dir "$1")/ops.log"; }
gm_pane_last() { grep '^out	' "$1" | tail -n 1 | cut -f2- | tr '\t' ' '; }

# gm_pinned <alias>: the macOS app the lock pins, fetched here and checked
# against the lock; pinned.tsv names the release and the sha256 of the
# program inside it, which an install must put in ~/Applications.
gm_pinned() {
  local d row url sha rel z
  d="$(il_dir "$1")"
  rel="$(awk -F '\t' '$1 == "release" { print $2; exit }' "$NICE_DNS_ROOT/release/assets.lock")"
  row="$(awk -F '\t' '$1 == "asset" && $2 == "gui" && $3 == "macos" && $4 == "arm64" { print $5 "\t" $6; exit }' "$NICE_DNS_ROOT/release/assets.lock")"
  [ -n "$row" ] || fail "release/assets.lock pins no macOS app"
  url="${row%%	*}" sha="${row#*	}"; z="$d/pinned.zip"
  curl -fsSL --proto =https --max-time 300 "$url" -o "$z" || fail "cannot fetch the pinned app $url"
  assert_eq "$sha" "$(sha256sum "$z" | cut -d' ' -f1)" "the pinned zip is the lock's"
  printf 'release\t%s\nasset_sha256\t%s\nprogram_sha256\t%s\n' "$rel" "$sha" \
    "$(python3 -I -c 'import hashlib, sys, zipfile
z = zipfile.ZipFile(sys.argv[1])
n = [i for i in z.namelist() if i.endswith("nice-dns.app/Contents/MacOS/NiceDNSGUI")]
print(hashlib.sha256(z.read(n[0])).hexdigest() if len(n) == 1 else "none")' "$z")" >"$d/pinned.tsv"
  rm -f "$z"
  assert_match '^[0-9a-f]{64}$' "$(gm_kv "$d/pinned.tsv" program_sha256)" "the pinned zip holds one NiceDNSGUI"
}

# gm_started <alias> <label>: the proxy container's start time, which a
# restart of the proxy (on macOS, of the whole stack) changes.
gm_started() {
  local a="$1" d
  d="$(il_dir "$a")"
  il_t "$a" config >"$d/config-$2.tsv" 2>>"$d/ops.log" || fail "config: $(tail -n 3 "$d/ops.log")"
  awk -F '\t' -v c="tor-$(il_cell "$a" proxy)" '$1 == "started" && $2 == c { print $3; exit }' "$d/config-$2.tsv"
}

# gm_mode <alias> <label>: the bridges mode status --tsv reports.
gm_mode() {
  local a="$1" d
  d="$(il_dir "$a")"
  gm_command "$a" "status-$2" status || fail "nice-dns status --tsv: $(tail -n 5 "$d/cmd-status-$2.log")"
  awk -F '\t' '$1 == "bridges" && $2 == "mode" { print $3; exit }' "$d/cmd-status-$2.log"
}

# gm_dns <alias> <label>: DNS answers through the stack within GM_DNS_MAX s
# (a proxy restart bootstraps Tor again); after-<label>.tsv is the last report.
gm_dns() {
  local a="$1" label="$2" end
  end=$(( $(date +%s) + GM_DNS_MAX ))
  while :; do
    il_report "$a" "after-$label" || fail "lifecycle-report"
    [ "$(il_val "$(il_dir "$a")/after-$label.tsv" resolution resolves)" = yes ] && return 0
    [ "$(date +%s)" -lt "$end" ] || fail "$label: DNS did not answer within ${GM_DNS_MAX}s"
    sleep 15
  done
}

# gm_assert_gui <alias> <label>: the app as an install leaves it.
gm_assert_gui() {
  local a="$1" label="$2" r gen p
  r="$(il_dir "$a")/gui-$label.tsv"
  gen="$(il_val "$(il_dir "$a")/after-$label.tsv" generation current)"
  p="$(il_dir "$a")/pinned.tsv"
  assert_eq present "$(gm_kv "$r" gui_app)" "$label: ~/Applications/nice-dns.app is installed"
  assert_eq "nice-dns-gui $(gm_kv "$p" release | sed 's/^v//')" "$(gm_kv "$r" gui_version)" "$label: it is the pinned release"
  assert_eq "$(gm_kv "$p" program_sha256)" "$(gm_kv "$r" gui_program_sha256)" "$label: its program is the one in the pinned release asset"
  assert_eq 0 "$(gm_kv "$r" gui_quarantine)" "$label: no quarantine is left on the bundle"
  assert_eq 0 "$(gm_kv "$r" gui_codesign)" "$label: codesign --verify --deep accepts it"
  assert_eq 0 "$(gm_kv "$r" gui_check_exit)" "$label: --check exits 0: $(gm_kv "$r" gui_check)"
  assert_match "^installed: generation $gen;" "$(gm_kv "$r" gui_check)" "$label: --check names the generation"
}

# gm_action <alias> <action>: one action through the app's hook; the proxy
# restarted (its start time changed) and DNS answers after.
gm_action() {
  local a="$1" act="$2" d l s0 s1
  d="$(il_dir "$a")"; l="$d/session-$act.log"
  s0="$(gm_started "$a" "before-$act")"
  assert_ne "" "$s0" "$act: the proxy's start time is read before"
  gm_session "$a" "$act" || fail "gui-session $act: $(tail -n 5 "$d/ops.log")"
  assert_eq 0 "$(gm_kv "$l" gui_exit)" "--run-action $act exits 0: $(grep '^out	' "$l" | tail -n 5)"
  assert_match 'finished \(exit 0\)$' "$(gm_pane_last "$l")" "$act: the pane ends with the action's exit"
  gm_dns "$a" "$act"
  s1="$(gm_started "$a" "after-$act")"
  assert_ne "" "$s1" "$act: the proxy's start time is read after"
  assert_ne "$s0" "$s1" "$act: the proxy restarted (start time $s0, then $s1)"
  printf 'proxy_started_before\t%s\nproxy_started_after\t%s\n' "$s0" "$s1" >"$d/started-$act.tsv"
}

# ─────────────────────────── steps ───────────────────────────────────────────

gm_before() {
  local plat="$1" a="$2" d proxy dirty
  d="$(il_dir "$a")"
  [ "$plat" = macos ] || fail "gui-mac runs on macOS only"
  dirty="$(GIT_OPTIONAL_LOCKS=0 git -C "$NICE_DNS_ROOT" status --porcelain --untracked-files=no)"
  if [ "${NICE_DNS_IL_DRY_RUN:-0}" = 1 ]; then
    echo "dry run: the committed-checkout check is skipped"
  else
    assert_eq "" "$dirty" "the checkout is committed (the bundle is of HEAD)"
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
  gm_pinned "$a"
  gm_gui_report "$a" before || fail "gui-report: $(tail -n 5 "$d/ops.log")"
}

# gm_install_step <platform> <alias> <label>: nice-dns install from a bundle
# of HEAD; the stack and the app are what HEAD installs.
gm_install_step() {
  local plat="$1" a="$2" label="$3" d proxy
  d="$(il_dir "$a")"; proxy="$(il_cell "$a" proxy)"
  gm_command "$a" "$label" install-git --cell "$proxy/standard" --source-sha "$(il_cell "$a" source_sha)" \
    || fail "nice-dns install ($label) failed: $(tail -n 20 "$d/cmd-$label.log")"
  assert_eq "" "$(grep 'GUI not installed' "$d/cmd-$label.log")" "$label: the install installed the app"
  assert_match 'The nice-dns menu-bar app: open .*/Applications/nice-dns\.app' "$(cat "$d/cmd-$label.log")" "$label: the summary names the app"
  gm_dns "$a" "$label"
  il_check_deployed "$plat" "$d/after-$label.tsv" "$proxy"
  gm_gui_report "$a" "$label" || fail "gui-report: $(tail -n 5 "$d/ops.log")"
  gm_assert_gui "$a" "$label"
  { grep -v '^gui_check	' "$d/gui-$label.tsv"; printf 'gui_check_generation\t%s\ngui_program_pinned\tyes\npinned_release\t%s\nresolves\t%s\nresult\tpass\n' \
      "$(il_val "$d/after-$label.tsv" generation current)" "$(gm_kv "$d/pinned.tsv" release)" "$(il_val "$d/after-$label.tsv" resolution resolves)"; } >"$d/gm-$label.tsv"
}

gm_install() { gm_install_step "$1" "$2" install; }

gm_screenshot() {
  local a="$2" d l png
  d="$(il_dir "$a")"; l="$d/session-screenshot.log"
  gm_require "$a" gm_install
  gm_session "$a" screenshot || fail "gui-session screenshot: $(tail -n 5 "$d/ops.log")"
  assert_eq 0 "$(gm_kv "$l" gui_exit)" "--screenshot exits 0: $(grep '^out	' "$l" | tail -n 3)"
  png="$d/gui-mac.png"
  gm_kv "$l" png_base64 | base64 -d >"$png" || fail "the PNG did not decode"
  assert_eq "$(gm_kv "$l" png_sha256)" "$(sha256sum "$png" | cut -d' ' -f1)" "the fetched PNG is the one written"
  assert_match '^PNG image data' "$(file -b "$png")" "it is a PNG"
  [ "$(stat -c %s "$png")" -gt 10000 ] || fail "the PNG is only $(stat -c %s "$png") bytes"
  printf 'gui_exit\t%s\npng_size\t%s\npng_sha256\t%s\npng_file\tgui-mac.png\nresult\tpass\n' \
    "$(gm_kv "$l" gui_exit)" "$(gm_kv "$l" png_size)" "$(gm_kv "$l" png_sha256)" >"$d/gm-screenshot.tsv"
}

gm_restart() {
  local a="$2" d
  d="$(il_dir "$a")"
  gm_require "$a" gm_install
  gm_action "$a" restart
  printf 'gui_exit\t%s\npane_last\t%s\nproxy_restarted\tyes\nresolves\t%s\nresult\tpass\n' "$(gm_kv "$d/session-restart.log" gui_exit)" \
    "$(gm_pane_last "$d/session-restart.log")" "$(il_val "$d/after-restart.tsv" resolution resolves)" >"$d/gm-restart.tsv"
}

gm_bridges() {
  local a="$2" d m off on
  d="$(il_dir "$a")"
  gm_require "$a" gm_install
  m="$(gm_mode "$a" before-bridges)"
  assert_match '^(on|off)$' "$m" "status --tsv names the bridges mode"
  # Asking for the mode in force restarts nothing: start from on.
  if [ "$m" = off ]; then
    gm_command "$a" bridges-start bridges-on || fail "nice-dns bridges on (start): $(tail -n 5 "$d/cmd-bridges-start.log")"
    gm_dns "$a" bridges-start
  fi
  gm_action "$a" bridges-off
  off="$(gm_mode "$a" after-bridges-off)"
  assert_eq off "$off" "after bridges-off, status --tsv says off"
  gm_action "$a" bridges-on
  on="$(gm_mode "$a" after-bridges-on)"
  assert_eq on "$on" "after bridges-on, status --tsv says on"
  # The target ends as it was.
  if [ "$m" = off ]; then
    gm_command "$a" bridges-restore bridges-off || fail "nice-dns bridges off (restore): $(tail -n 5 "$d/cmd-bridges-restore.log")"
    gm_dns "$a" bridges-restore
  fi
  printf 'bridges_mode_before\t%s\noff_exit\t%s\noff_mode\t%s\noff_resolves\t%s\non_exit\t%s\non_mode\t%s\non_resolves\t%s\nproxy_restarted\tyes\nresult\tpass\n' "$m" \
    "$(gm_kv "$d/session-bridges-off.log" gui_exit)" "$off" "$(il_val "$d/after-bridges-off.tsv" resolution resolves)" \
    "$(gm_kv "$d/session-bridges-on.log" gui_exit)" "$on" "$(il_val "$d/after-bridges-on.tsv" resolution resolves)" >"$d/gm-bridges.tsv"
}

gm_open() {
  local a="$2" d l
  d="$(il_dir "$a")"; l="$d/session-open.log"
  gm_require "$a" gm_install
  gm_session "$a" open || fail "gui-session open: $(tail -n 5 "$d/ops.log")"
  assert_eq yes "$(gm_kv "$l" gui_running)" "open -a leaves NiceDNSGUI running: $(grep '^out	' "$l" | tail -n 3)"
  assert_eq yes "$(gm_kv "$l" gui_quit)" "and it quits"
  printf 'gui_running\t%s\ngui_quit\t%s\nresult\tpass\n' "$(gm_kv "$l" gui_running)" "$(gm_kv "$l" gui_quit)" >"$d/gm-open.tsv"
}

gm_uninstall() {
  local plat="$1" a="$2" d r n q
  d="$(il_dir "$a")"
  gm_require "$a" gm_install
  # The app open during the uninstall quits by itself once its bundle is gone.
  gm_session "$a" launch || fail "gui-session launch: $(tail -n 5 "$d/ops.log")"
  assert_eq yes "$(gm_kv "$d/session-launch.log" gui_running)" "the app runs before the uninstall"
  gm_command "$a" uninstall uninstall || fail "nice-dns uninstall failed: $(tail -n 20 "$d/cmd-uninstall.log")"
  n=0 q=no
  while [ "$n" -lt 8 ]; do
    gm_session "$a" running || fail "gui-session running: $(tail -n 5 "$d/ops.log")"
    [ "$(gm_kv "$d/session-running.log" gui_running)" = no ] && { q=yes; break; }
    sleep 5; n=$((n + 1))
  done
  assert_eq yes "$q" "the open app quit by itself after the uninstall removed it"
  il_report "$a" after-uninstall || fail "lifecycle-report"
  il_assert_uninstalled "$plat" "$d/before.tsv" "$d/after-uninstall.tsv"
  gm_gui_report "$a" uninstall || fail "gui-report"
  r="$d/gui-uninstall.tsv"
  assert_eq absent "$(gm_kv "$r" gui_app)" "nice-dns.app in ~/Applications is gone"
  { cat "$r"; printf 'app_quit_after_uninstall\t%s\nresolves\t%s\nresult\tpass\n' "$q" "$(il_val "$d/after-uninstall.tsv" resolution resolves)"; } >"$d/gm-uninstall.tsv"
}

# Runs whatever came before it: the target must end with a working stack.
gm_final() { gm_install_step "$1" "$2" final; }

gm_clean() { GIT_OPTIONAL_LOCKS=0 git -C "$1" status --porcelain | grep -v '^?? bridge-eval/bridge-eval$'; }

gm_receipt() {
  local root out r repo cd st d cell key gen a f id n=0 v s ok
  root="$(dirname "$(dirname "$ARTIFACT_DIR")")"
  out="$root/receipts/gui-mac/$RUN_ID"; r="$out/receipt.tsv"
  assert_no_path "$out" "this run has no gui-mac receipt yet"
  mkdir -p "$out/cells" || fail "cannot create $out"
  {
    printf '# schema\tnice-dns-receipt/1\n'
    printf 'receipt\tgui-mac\nrun_id\t%s\ncreated_utc\t%s\n' "$RUN_ID" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    for repo in nice-dns tor-haproxy tor-socat hardened-unbound pi-hole-hardened; do
      if [ "$repo" = nice-dns ]; then cd="$NICE_DNS_ROOT"; else cd="$GM_SIBS/$repo"; fi
      if [ -n "$(gm_clean "$cd")" ]; then st=dirty; else st=clean; fi
      printf 'source\t%s\t%s\t%s\n' "$repo" "$(git -C "$cd" rev-parse HEAD)" "$st"
    done
    for repo in tor-haproxy tor-socat hardened-unbound pi-hole-hardened; do
      printf 'arch\t%s\t%s\t%s\n' "$repo" "$(git -C "$GM_SIBS/$repo" rev-parse HEAD)" \
        "$(git -C "$GM_SIBS/$repo" show HEAD:.github/workflows/main.yml |
          awk '/^ *platform: *$/ { on = 1; next } on && /^ *- *linux\// { sub(/^ *- */, ""); print; next } on { on = 0 }' |
          sort | paste -sd, -)"
    done
    printf 'product\tnice-dns\t%s\n' "$(git -C "$NICE_DNS_ROOT" rev-parse HEAD)"
    printf 'limit\tno-person-clicked\t-\tscope=sub-plan-7\tthe hooks ran the code a click runs, in the gui domain over ssh; the menu bar was not seen (no Screen Recording or Accessibility grant over ssh); the opened app was quit by SIGTERM\n'
  } >"$r"
  for d in "$ARTIFACT_DIR"/gui-mac/*/; do
    [ -f "$d/cell.tsv" ] || continue
    d="${d%/}"
    cell="$(awk -F '\t' '$1 == "cell" { print $2; exit }' "$d/cell.tsv")"; key="$(printf '%s' "$cell" | tr / -)"
    a="$(awk -F '\t' '$1 == "target" { print $2; exit }' "$d/cell.tsv")"
    gen="generation=$(il_val "$d/after-final.tsv" generation current)"
    mkdir -p "$out/cells/$key"
    cp "$d/cell.tsv" "$out/cells/$key/"
    ok=1
    for s in $GM_STEPS; do grep -qx "$s" "$d/passed.tsv" 2>/dev/null || ok=0; done
    if [ "$ok" != 1 ]; then
      printf 'cell\t%s\t%s\t%s\t%s\t%s\tfailed\n' "${cell%%/*}" "$(printf '%s' "$cell" | cut -d/ -f2)" "${cell##*/}" "$a" "$gen" >>"$r"
      continue
    fi
    n=$((n + 1))
    printf 'cell\t%s\t%s\t%s\t%s\t%s\tobserved\n' "${cell%%/*}" "$(printf '%s' "$cell" | cut -d/ -f2)" "${cell##*/}" "$a" "$gen" >>"$r"
    cp "$d/gui-mac.png" "$out/cells/$key/gui-mac.png"
    for id in GM-INSTALL:gm-install.tsv GM-SCREENSHOT:gm-screenshot.tsv GM-RESTART:gm-restart.tsv GM-BRIDGES:gm-bridges.tsv GM-OPEN:gm-open.tsv GM-UNINSTALL:gm-uninstall.tsv GM-FINAL:gm-final.tsv; do
      f="${id#*:}"
      cp "$d/$f" "$out/cells/$key/$f"
      printf 'scenario\t%s\t%s\tpass\tcells/%s/%s\t%s\t%s\n' "${id%%:*}" "$cell" "$key" "$f" "$(sha256sum "$out/cells/$key/$f" | cut -d' ' -f1)" "$gen" >>"$r"
    done
  done
  assert_match '^[1-9]' "$n" "at least one fully passed cell"
  v="$(bash "$NICE_DNS_ROOT/tests/reports/verify.sh" check "$r" 2>&1)"
  assert_rc 0 "$?" "the gui-mac receipt verifies: $v"
  assert_eq "" "$(grep -rlE 'cert=[A-Za-z0-9+/]{20}|(^|[^0-9A-Fa-f])[0-9A-F]{40}([^0-9A-Fa-f]|$)|PRIVATE KEY|"sid":|pwhash|BRIDGE[0-9]+=' "$out" --include='*.tsv' 2>/dev/null)" \
    "no bridge line, certificate, fingerprint, key, session or password hash in the receipt"
}

t_01_before() { il_selection; il_each gm_before; }
t_02_install() { il_selection; il_each gm_install; }
t_03_screenshot() { il_selection; il_each gm_screenshot; }
t_04_restart() { il_selection; il_each gm_restart; }
t_05_bridges() { il_selection; il_each gm_bridges; }
t_06_open() { il_selection; il_each gm_open; }
t_07_uninstall() { il_selection; il_each gm_uninstall; }
t_08_final() { il_selection; il_each gm_final; }

t_09_privacy() {
  il_selection
  assert_eq "" "$(grep -rlE 'cert=[A-Za-z0-9+/]{20}|(^|[^0-9A-Fa-f])[0-9A-F]{40}([^0-9A-Fa-f]|$)|PRIVATE KEY|"sid":|pwhash|BRIDGE[0-9]+=' "$ARTIFACT_DIR/gui-mac" --include='*.tsv' 2>/dev/null)" \
    "no report, sample or step record holds bridge material, a session or a hash"
}

t_10_receipt() { il_selection; gm_receipt; }
