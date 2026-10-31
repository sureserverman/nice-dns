#!/usr/bin/env bash
# Fake target adapter for the command-recovery dry run (Task 3.1): the operations
# live/command-recovery adds, with their report format. Everything else goes to
# tests/fixtures/lifecycle-adapter.sh, which keeps the install state. One defect
# can be seeded by writing its name to $IL_FAKE_DIR/break:
#   no-ready          a fault's journal has no ready row
#   no-ack            a fault's journal has no acknowledged row
#   not-felt          a fresh name still answers during a fault
#   gen-unchanged     a fault leaves the container's start unchanged
#   servfail          a fresh name never answers after a fault
#   restart-partial   nice-dns restart leaves Pi-hole's start unchanged
#   secret-changed    a reinstall changes the admin password
#   monitor-left      uninstall leaves the debug monitor's agent
#   command-left      uninstall leaves the command
#   source-left       uninstall leaves the kept source
#   image-left        uninstall leaves an image of the stack
#   images-empty      the image list cannot be read after the uninstall
#   sbin-left         uninstall leaves a root script (macOS)
#   probe-broken      fresh-name cannot run during a fault
#   digest-left       uninstall leaves a pulled digest with no name
#   harness-tags      a versioned proxy tag stays, as the tuning harness leaves (no defect)
#   quadlet-left      uninstall leaves a quadlet
#   unit-left         uninstall leaves a not-found failed unit
# Nothing here touches the host.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
op="${1:-}"
case "$op" in
  freeze-unbound|thaw-unbound|stop-proxy|fresh-name|command|command-report|controller-report|set-tunables) ;;
  *) exec bash "$HERE/lifecycle-adapter.sh" "$@" ;;
esac
alias_="${2:-}"
shift 2
mode="" cell="" sha=""
while [ $# -gt 0 ]; do
  case "$1" in
    --mode) mode="$2"; shift 2 ;;
    --cell) cell="$2"; shift 2 ;;
    --source-sha) sha="$2"; shift 2 ;;
    --targets|--component) shift 2 ;;
    *) shift ;;
  esac
done
F="${IL_FAKE_DIR:-${ARTIFACT_DIR:?}/il-fake}"
brk="$(cat "$F/break" 2>/dev/null || true)"
S="$F/$alias_"
mkdir -p "$S"
case "$alias_" in lin1) plat=linux ;; *) plat=macos ;; esac
get() { cat "$S/$1" 2>/dev/null || printf '%s\n' "${2:-}"; }
put() { printf '%s\n' "$2" >"$S/$1"; }
now() { date +%s; }
tick() { put clock "$(( $(get clock 0) + 1 ))"; }

# fault_rows <component>: what the controller journals for a fault.
fault_rows() {
  local t id
  id="req-$(get clock 0)"
  t="$(now)"
  printf '%s\t%s\t%s\trequested\tx\n' "$t" "$id" "$1" >>"$S/journal"
  [ "$brk" = no-ack ] || printf '%s\t%s\t%s\tacknowledged\tx\n' "$t" "$id" "$1" >>"$S/journal"
  [ "$brk" = no-ready ] || printf '%s\t%s\t%s\tready\tx\n' "$t" "$id" "$1" >>"$S/journal"
  [ "$brk" = gen-unchanged ] || tick
  [ "$brk" != servfail ] || put answering no
  [ "$brk" = not-felt ] || put felt yes
}

case "$op" in
  freeze-unbound) fault_rows unbound; printf 'unbound_state\tT\n' ;;
  thaw-unbound) printf 'thawed\n' ;;
  stop-proxy) fault_rows runtime ;;
  set-tunables) printf 'tunables\t%s\n' "$mode" ;;
  fresh-name)
    if [ "$(get felt no)" = yes ] && [ "$brk" = probe-broken ]; then rm -f "$S/felt"; echo "target.sh: target reported no machine id" >&2; exit 2; fi
    if [ "$(get felt no)" = yes ]; then st=SERVFAIL; rm -f "$S/felt"
    elif [ "$(get answering yes)" = yes ]; then st=NXDOMAIN; else st=SERVFAIL; fi
    printf 'fresh_name\tnd-cr-%s.example.com\t%s\n' "$(now)" "$st" ;;
  controller-report)
    printf 'now\t%s\nsection\tjournal-active\n' "$(now)"
    cat "$S/journal" 2>/dev/null
    printf 'section\tobserve\nobs\troute:cloudflare-onion\thealthy\nobs\tunbound\thealthy\nobs\truntime\thealthy\n' ;;
  command-report)
    inst="$(cat "$S/installed" 2>/dev/null)"
    printf 'now\t%s\nsection\tstarts\n' "$(now)"
    if [ "$inst" = 1 ]; then
      for c in unbound "tor-$(cat "$S/proxy")"; do printf 'start\t%s\ts-%s\n' "$c" "$(get clock 0)"; done
      printf 'start\tpi-hole\ts-%s\n' "$(get piclock 0)"
    fi
    printf 'section\tcommand\n'
    if [ "$(get cmd absent)" = present ]; then printf 'command\tpresent\nsource\tpresent\n'
    else
      printf 'command\t%s\n' "$([ "$brk" = command-left ] && echo present || echo absent)"
      printf 'source\t%s\n' "$([ "$brk" = source-left ] && echo present || echo absent)"
    fi
    printf 'section\timages\n'
    empty=0
    if [ "$inst" != 1 ] && [ "$brk" = images-empty ]; then empty=1; else printf 'image\tpihole/pihole:<none>\n'; fi
    if [ "$inst" = 1 ] || [ "$brk" = image-left ]; then printf 'image\tlocalhost/unbound:latest\n'; fi
    if [ "$brk" = digest-left ]; then
      if [ "$plat" = linux ]; then printf 'image\t<none>:<none>\tsha256:abc\n'
      else printf 'image\tsureserver/tor-%s:<none>\n' "$(cat "$S/proxy")"; fi
    fi
    if [ "$brk" = harness-tags ]; then printf 'image\tdocker.io/sureserver/tor-haproxy:v2.13\tsha256:def\n'; fi
    printf 'section\tquadlets\n'
    if [ "$plat" = linux ] && { [ "$inst" = 1 ] || [ "$brk" = quadlet-left ]; }; then printf 'quadlet\tunbound.container\n'; fi
    printf 'section\tagents\n'
    if [ "$plat" = macos ] && [ "$brk" = monitor-left ]; then printf 'agent_file\torg.nice-dns.debug-monitor.plist\n'; fi
    printf 'section\tunits\n'
    if [ "$plat" = linux ] && [ "$brk" = unit-left ]; then printf 'unit\tunbound.service\tfailed\tfailed\n'; fi
    printf 'section\tlisting\nlisting\timages\t%s\nlisting\tschedules\t0\n' "$empty"
    printf 'section\tsbin\n'
    if [ "$plat" = macos ] && [ "$brk" = sbin-left ]; then printf 'sbin\tnice-dns-fetch-bridges.sh\n'; fi ;;
  command)
    case "$mode" in
      install)
        bash "$HERE/lifecycle-adapter.sh" install-cell "$alias_" --targets x --cell "$cell" --source-sha "$sha" || exit 1
        put cmd present ;;
      reinstall)
        bash "$HERE/lifecycle-adapter.sh" install-cell "$alias_" --targets x --cell "$(cat "$S/proxy")/standard" --source-sha x || exit 1
        [ "$brk" != secret-changed ] || put secret bbbb ;;
      uninstall)
        bash "$HERE/lifecycle-adapter.sh" uninstall-cell "$alias_" --targets x --cell x/standard --source-sha x || exit 1
        put cmd absent ;;
      restart)
        tick
        [ "$brk" = restart-partial ] || put piclock "$(( $(get piclock 0) + 1 ))"
        echo "nice-dns restarted; DNS is answering." ;;
    esac ;;
esac
