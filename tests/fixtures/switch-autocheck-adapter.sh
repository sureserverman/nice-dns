#!/usr/bin/env bash
# Fake target adapter for the switch-autocheck dry run (app-switches-autocheck
# plan, Task 3.1): the operations live/switch-autocheck uses, with target.sh's
# report formats. Install state, snapshots and lifecycle reports go to
# tests/fixtures/lifecycle-adapter.sh (which also reads the break file, so its
# own old-proxy-left works here). Every operation is appended to
# $IL_FAKE_DIR/<alias>/oplog. One defect can be seeded by writing its name to
# $IL_FAKE_DIR/break:
#   checkout-present   a pi-hole-hardened checkout sits in the home directory
#   polkit-fails       polkit-test-rule add leaves no rule
#   install-fails      the install exits 1
#   no-gui             the install says the GUI was not installed
#   auto-stopped       status says update auto stopped
#   gui-fails          the app's proxy action exits 1
#   pane-other         the app's pane ends with another line than its exit
#   proxy-unchanged    the app's proxy action exits 0 and changes nothing
#   commit-changed     a switch records another source_commit
#   switch-fails       nice-dns switch pihole hardened exits 3
#   last-line-other    the switch exits 0 with another last line
#   hardened-standard  the Pi-hole that runs after the hardened switch is the standard one
#   base-missing       the kept source has no pihole-hardened/base
#   checkout-appears   after the hardened switch a checkout is on the host
#   servfail-hardened  the host does not resolve once the hardened Pi-hole runs
#   schedule-fails     update-schedule exits 1
#   schedule-stale     the scheduled check leaves checked_at where it was
#   restore-wrong      the restoring reinstall leaves the other proxy running
#   polkit-left        polkit-test-rule remove leaves the rule
#   polkit-unconfirmed polkit-test-rule add puts the rule in place but reports it absent
#   restore-fails      the restoring reinstall exits 1
#   schedule-unknown   the scheduled check moves checked_at but could not reach GitHub
#   offline-lin1       lin1 does not answer (probe times out); mac1 does
# Nothing here touches the host.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
op="${1:-}"
alias_="${2:-}"
F="${IL_FAKE_DIR:-${ARTIFACT_DIR:?}/il-fake}"
case "$op" in
  validate) exec bash "$HERE/lifecycle-adapter.sh" "$@" ;;
  snapshot|probe) ;;
  *) mkdir -p "$F/$alias_"; printf '%s\n' "$op" >>"$F/$alias_/oplog" ;;
esac
args=("$@")
shift 2
mode="" cell="" sha=""
while [ $# -gt 0 ]; do
  case "$1" in
    --mode) mode="$2"; shift 2 ;;
    --cell) cell="$2"; shift 2 ;;
    --source-sha) sha="$2"; shift 2 ;;
    --targets) shift 2 ;;
    *) shift ;;
  esac
done
brk="$(cat "$F/break" 2>/dev/null || true)"
S="$F/$alias_"
mkdir -p "$S"
case "$alias_" in lin1) plat=linux home=/home/t ;; *) plat=macos home=/Users/t ;; esac
get() { cat "$S/$1" 2>/dev/null || printf '%s\n' "${2:-}"; }
put() { printf '%s\n' "$2" >"$S/$1"; }
identity() { printf 'machine_id\tfake-%s\nhostname\t%s\nplatform\t%s\n' "$alias_" "$alias_" "$plat"; }
# As target.sh: anything but a read of the targets needs a snapshot.
case "$op" in
  snapshot|probe) ;;
  *) [ -f "${ARTIFACT_DIR:?}/targets/$alias_/snapshot.tsv" ] || { echo "target.sh: no restore snapshot for $alias_ in this run" >&2; exit 2; } ;;
esac
# lif <op> [args]: the install state's own adapter.
lif() { bash "$HERE/lifecycle-adapter.sh" "$@"; }
# The lifecycle state is created on its first call.
case "$op" in snapshot|probe) ;; *) lif lifecycle-report "$alias_" --targets x >/dev/null ;; esac
proxy() { get proxy; }
pihole() { get pihole standard; }
# reinstall <proxy> <pihole>: the install transaction with those choices.
reinstall() { lif install-cell "$alias_" --targets x --cell "$1/$2" --source-sha x >/dev/null || exit 1; }

cmd_wrap() {
  local rc="$1"
  shift
  printf 'command\t%s/.local/bin/nice-dns\t%s\nstarted_utc\t%s\n' "$home" "$mode" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  printf '%s\n' "$@"
  printf 'finished_utc\t%s\ncommand_exit\t%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$rc"
  [ "$rc" = 0 ] || exit 1
  exit 0
}

case "$op" in
  probe)
    if [ "$brk" = offline-lin1 ] && [ "$alias_" = lin1 ]; then
      echo "ssh: connect to host lin1-ssh port 22: Connection timed out" >&2; exit 1
    fi
    identity ;;
  snapshot|lifecycle-report)
    if [ "$brk" = offline-lin1 ] && [ "$alias_" = lin1 ]; then echo "fake adapter: lin1 is offline" >&2; exit 1; fi
    if [ "$op" = lifecycle-report ] && [ "$brk" = servfail-hardened ] && [ "$(get pihole standard)" = hardened ]; then
      lif "${args[@]}" | sed 's/^resolves	yes$/resolves	no/'
    else
      exec bash "$HERE/lifecycle-adapter.sh" "${args[@]}"
    fi ;;
  polkit-test-rule)
    case "$mode" in
      add) [ "$brk" = polkit-fails ] || put polkit present
        [ "$brk" != polkit-unconfirmed ] || { printf 'polkit_test_rule\tabsent\n'; exit 0; } ;;
      remove) [ "$brk" = polkit-left ] || put polkit absent ;;
    esac
    printf 'polkit_test_rule\t%s\n' "$(get polkit absent)" ;;
  switch-report)
    identity
    printf 'section\tcheckouts\n'
    for c in "$home/.local/share/nice-dns/pi-hole-hardened" "$home/pi-hole-hardened" "$home/dev/pi-hole-hardened" "$home/nice-dns-gui-build/pi-hole-hardened"; do
      st=absent
      [ "$brk" = checkout-present ] && [ "$c" = "$home/pi-hole-hardened" ] && st=present
      [ "$brk" = checkout-appears ] && [ "$(pihole)" = hardened ] && [ "$c" = "$home/.local/share/nice-dns/pi-hole-hardened" ] && st=present
      printf 'hardened_checkout\t%s\t%s\n' "$c" "$st"
    done
    printf 'section\tsource\n'
    if [ "$(get installed)" = 1 ] && [ "$brk" != base-missing ]; then printf 'kept_base\tpresent\n'; else printf 'kept_base\tabsent\n'; fi
    printf 'section\tpihole\n'
    ph="$(pihole)"
    [ "$brk" != hardened-standard ] || ph=standard
    printf 'pihole_running\t%s\n' "$ph" ;;
  update-schedule)
    printf 'schedule\tupdate\nstarted_utc\t%s\nschedule_loaded\tyes\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    [ "$brk" != schedule-fails ] || { printf 'start_exit\t1\n'; exit 1; }
    [ "$brk" = schedule-stale ] || put checked "$(date +%s)"
    [ "$brk" != schedule-unknown ] || put upresult unknown
    printf 'start_exit\t0\nschedule_done\tyes\nschedule_last_exit\t0\nwaited_s\t0\nfinished_utc\t%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" ;;
  gui-report)
    if [ "$plat" = linux ]; then printf 'gui_bin\tpresent\ngui_bin_path\t%s/.local/bin/nice-dns-gui\ngui_version\tnice-dns-gui 0.2.0\n' "$home"
    else printf 'gui_app\tpresent\ngui_bin_path\t%s/Applications/nice-dns.app/Contents/MacOS/NiceDNSGUI\ngui_version\tnice-dns.app 1.4.0\n' "$home"; fi
    printf 'gui_program_sha256\t%064d\n' 7 ;;
  gui-session)
    printf 'gui_session\t%s\nstarted_utc\t%s\n' "$mode" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    case "$mode" in
      proxy-haproxy|proxy-socat)
        want="${mode#proxy-}"
        printf 'out\t$ nice-dns switch proxy %s\n' "$want"
        if [ "$brk" = gui-fails ]; then
          printf 'out\tnice-dns: the switch did not happen (installer exit 1); the installer keeps or restores the running stack, so %s still runs.\nout\tfailed (exit 3)\n' "$(proxy)"
          printf 'finished_utc\t%s\ngui_exit\t1\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
          exit 0
        fi
        [ "$brk" = proxy-unchanged ] || reinstall "$want" "$(pihole)"
        [ "$brk" != commit-changed ] || put commit 1111111111111111111111111111111111111111
        printf 'out\tSwitched: the proxy is now tor-%s, and DNS is answering.\n' "$want"
        if [ "$brk" = pane-other ]; then printf 'out\tstill running\n'; else printf 'out\tfinished (exit 0)\n'; fi
        printf 'finished_utc\t%s\ngui_exit\t0\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" ;;
      *) echo "fake adapter: gui-session mode $mode is not used here" >&2; exit 2 ;;
    esac ;;
  command)
    case "$mode" in
      install-git)
        [ "$brk" != install-fails ] || cmd_wrap 1 "nice-dns: the install failed; the running stack was restored."
        reinstall "${cell%/*}" "${cell#*/}"
        put commit "$sha"; put checked "$(( $(date +%s) - 3600 ))"
        if [ "$brk" = no-gui ]; then cmd_wrap 0 "warning: GUI not installed (the release asset could not be fetched)" "nice-dns is installed; DNS is answering."
        else cmd_wrap 0 "nice-dns is installed; DNS is answering."; fi ;;
      status)
        auto=loaded; [ "$brk" != auto-stopped ] || auto=stopped
        inst=yes; [ "$(get installed)" = 0 ] && inst=no
        cmd_wrap 0 "schema	nice-dns-status/1" "install	installed	$inst" "install	source_commit	$(get commit 671d95031d6b4e5475b2682aa600f204268aa854)" \
          "install	variant	$(proxy)" "install	pihole	$(pihole)" "install	platform	$plat" \
          "update	result	$(get upresult current)" "update	checked_at	$(get checked 1794345355)" "update	auto	$auto" "bridges	mode	on" ;;
      switch-pihole-hardened|switch-pihole-standard)
        want="${mode#switch-pihole-}"
        [ "$(pihole)" != "$want" ] || cmd_wrap 0 "Already $want; nothing changed."
        [ "$brk" != switch-fails ] || cmd_wrap 3 "nice-dns: the switch did not happen (installer exit 1); the installer keeps or restores the running stack, so $(pihole) still runs."
        reinstall "$(proxy)" "$want"
        [ "$brk" != commit-changed ] || put commit 1111111111111111111111111111111111111111
        if [ "$brk" = last-line-other ]; then cmd_wrap 0 "Switched."; fi
        cmd_wrap 0 "Switched: Pi-hole is now the $want one, and DNS is answering." ;;
      reinstall-cell)
        [ "$brk" != restore-fails ] || cmd_wrap 1 "nice-dns: the install failed; the running stack was restored."
        if [ "$brk" = restore-wrong ]; then reinstall "$(proxy)" "${cell#*/}"; else reinstall "${cell%/*}" "${cell#*/}"; fi
        cmd_wrap 0 "nice-dns is reinstalled; DNS is answering." ;;
      *) echo "fake adapter: command mode $mode is not used here" >&2; exit 2 ;;
    esac ;;
  *) echo "fake adapter: unsupported op $op" >&2; exit 2 ;;
esac
