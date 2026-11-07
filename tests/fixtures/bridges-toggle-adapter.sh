#!/usr/bin/env bash
# Fake target adapter for the bridges-toggle dry run (bridges-toggle plan,
# Task 2.1): the operations live/bridges-toggle uses, with target.sh's report
# formats. Install state, snapshots and lifecycle reports go to
# tests/fixtures/command-recovery-adapter.sh (and on to lifecycle-adapter.sh).
# A fake mac's runtime stays in gui/<uid>, where target.sh reaches it through
# the gui session (OD-8): an install or a switch fails once anything moves it
# (BL-052; mac-runtime-ssh moves it, as on the real mac). Every operation is appended to
# $IL_FAKE_DIR/<alias>/oplog. One defect can be seeded by writing its name to
# $IL_FAKE_DIR/break:
#   resume-fails      resume-agents exits 1
#   install-fails     install-cell fails
#   cli-fails         nice-dns bridges exits 1
#   no-mode-change    a switch journals no mode-change row
#   no-ack            a switch journals no service acknowledged row
#   ack-other-id      the acknowledged row has another request id
#   still-bridges     after off the proxy still launches with bridges
#   still-direct      after on the proxy still launches direct
#   leak              the supervisor op returns a line that is not a spawn line
#   servfail          no fresh name answers after a switch
#   servfail-once     no fresh name answers after the off switch, until the next switch
#   refresh-runs      with bridges off the refresh still evaluates (journals unchanged)
#   refresh-fails     with bridges off the refresh exits 1
#   status-stale      status --tsv shows the mode before the last switch
#   status-stuck-off  status --tsv shows off after the on switch
# Nothing here touches the host.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
op="${1:-}"
alias_="${2:-}"
F="${IL_FAKE_DIR:-${ARTIFACT_DIR:?}/il-fake}"
case "$op" in
  validate|snapshot|lifecycle-report|set-tunables) ;;
  *) mkdir -p "$F/$alias_"; printf '%s\n' "$op" >>"$F/$alias_/oplog" ;;
esac
case "$op" in
  quiesce-agents|resume-agents|mac-runtime-ssh|mac-runtime-gui|install-cell|bridges-refresh|proxy-supervisor-lines|fresh-name|controller-report|command) ;;
  *) exec bash "$HERE/command-recovery-adapter.sh" "$@" ;;
esac
args=("$@")
shift 2
mode=""
while [ $# -gt 0 ]; do
  case "$1" in
    --mode) mode="$2"; shift 2 ;;
    --targets|--component|--cell|--source-sha) shift 2 ;;
    *) shift ;;
  esac
done
brk="$(cat "$F/break" 2>/dev/null || true)"
S="$F/$alias_"
case "$alias_" in lin1) plat=linux ;; *) plat=macos ;; esac
get() { cat "$S/$1" 2>/dev/null || printf '%s\n' "${2:-}"; }
put() { printf '%s\n' "$2" >"$S/$1"; }
now() { date +%s; }
identity() { printf 'machine_id\tfake-%s\nhostname\t%s\nplatform\t%s\n' "$alias_" "$alias_" "$plat"; }
# As target.sh: a change needs a snapshot of the target in this run.
case "$op" in
  quiesce-agents|resume-agents|mac-runtime-ssh|mac-runtime-gui|install-cell|bridges-refresh|command)
    [ -f "${ARTIFACT_DIR:?}/targets/$alias_/snapshot.tsv" ] || { echo "target.sh: no restore snapshot for $alias_ in this run" >&2; exit 2; } ;;
esac
case "$op" in
  mac-runtime-ssh|mac-runtime-gui) [ "$plat" = macos ] || { echo "target.sh: $op is macOS only" >&2; exit 2; } ;;
esac

# journal <id> <component> <phase> <detail>
journal() { printf '%s\t%s\t%s\t%s\t%s\n' "$(now)" "$1" "$2" "$3" "$4" >>"$S/journal"; }

# cmd_wrap <rc> <lines...>: the command op's report around the CLI's output.
cmd_wrap() {
  local rc="$1"
  shift
  printf 'command\t/home/t/.local/bin/nice-dns\t%s\nstarted_utc\t%s\n' "$mode" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  printf '%s\n' "$@"
  printf 'finished_utc\t%s\ncommand_exit\t%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$rc"
  [ "$rc" = 0 ] || exit 1
  exit 0
}

case "$op" in
  quiesce-agents)
    put quiesced yes
    if [ "$plat" = macos ]; then printf 'quiesced\torg.nice-dns.health\trc=0\nquiesced\torg.nice-dns.health-bridges\trc=0\n'
    else printf 'quiesced\tnice-dns-health.timer\trc=0\n'; fi ;;
  resume-agents)
    [ "$brk" != resume-fails ] || { echo "fake resume failed"; exit 1; }
    put quiesced no; printf 'resumed\tagents\trc=0\n' ;;
  mac-runtime-ssh)
    put domain ssh
    printf 'booted_out\tgui/501/com.apple.container.apiserver\trc=0\nsystem_start\trc=0\nsystem_status\trc=0\n' ;;
  mac-runtime-gui)
    put domain gui
    printf 'system_stop\trc=0\nkickstarted\tgui/501/org.nice-dns.start-container\trc=0\nstack\trunning\t3\nwaited_s\t4\n' ;;
  install-cell)
    if [ "$plat" = macos ] && [ "$(get domain gui)" != gui ]; then
      echo "the container runtime is not up after its restart (nd_install_macos_fresh_datapath)"; exit 1
    fi
    [ "$brk" != install-fails ] || { echo "fake install failed"; exit 1; }
    bash "$HERE/lifecycle-adapter.sh" "${args[@]}" || exit 1
    put sgen "$(( $(get sgen 0) + 1 ))" ;;
  fresh-name)
    identity
    st=NXDOMAIN
    [ "$(get dark no)" = yes ] && st=SERVFAIL
    printf 'fresh_name\tnd-cr-%s.example.com\t%s\n' "$(now)" "$st" ;;
  controller-report)
    identity
    printf 'now\t%s\nsection\tjournal-active\n' "$(now)"
    cat "$S/journal" 2>/dev/null
    printf 'section\tobserve\nobs\troute:cloudflare-onion\thealthy\nobs\tunbound\thealthy\nobs\truntime\thealthy\n' ;;
  proxy-supervisor-lines)
    identity
    printf 'section\tsupervisor\n'
    if [ "$(get installed)" = 1 ]; then
      g="$(get sgen 1)"
      how="$(get how 'with 3 bridge(s)')"
      printf 'supervisor_line\ttor-%s\ttor-supervisor: spawned tor pid=%s generation=%s %s\n' "$(get proxy)" "$((100 + g))" "$g" "$how"
      [ "$brk" != leak ] || printf 'supervisor_line\ttor-%s\ttor-supervisor: bridges: obfs4 192.0.2.1:443 cert=AAAAAAAAAAAAAAAAAAAAAAAA iat-mode=0\n' "$(get proxy)"
    fi ;;
  bridges-refresh)
    if [ "$(get mode on)" = off ] && [ "$brk" != refresh-runs ]; then
      journal "br-$(now)" bridges skipped "bridges off"
      printf 'result\tskipped\ndetail\tbridges off\n'
      [ "$brk" != refresh-fails ] || exit 1
    else
      journal "br-$(now)" bridges unchanged "the evaluated set equals the running one (abcd)"
      printf 'result\tunchanged\n'
    fi ;;
  command)
    case "$mode" in
      bridges-on|bridges-off)
        m="${mode#bridges-}"
        [ "$(get installed)" = 1 ] || cmd_wrap 1 "nice-dns: nice-dns is not installed."
        if [ "$plat" = macos ] && [ "$(get domain gui)" != gui ]; then
          cmd_wrap 1 "nice-dns: the proxy restart failed (exit 1: the start agent cannot see the runtime)"
        fi
        [ "$(get mode on)" != "$m" ] || cmd_wrap 0 "Bridges are already $m; nothing restarted."
        [ "$brk" != cli-fails ] || cmd_wrap 1 "nice-dns: the controller is still busy; the bridges mode is unchanged."
        put prevmode "$(get mode on)"
        put mode "$m"
        id="bridges-$m-$(now)"
        [ "$brk" = no-mode-change ] || journal "$id" bridges mode-change "$m"
        journal "$id" service requested "proxy restart for tor-$(get proxy); container before: g$(get sgen 1)"
        if [ "$brk" = ack-other-id ]; then journal "bridges-$m-1" service acknowledged "tor-$(get proxy) restarted"
        elif [ "$brk" != no-ack ]; then journal "$id" service acknowledged "tor-$(get proxy) restarted"; fi
        put sgen "$(( $(get sgen 1) + 1 ))"
        if [ "$m" = off ]; then
          if [ "$brk" = still-bridges ]; then put how 'with 3 bridge(s)'; else put how 'direct (no bridges)'; fi
        else
          if [ "$brk" = still-direct ]; then put how 'direct (no bridges)'; else put how 'with 3 bridge(s)'; fi
        fi
        put dark no
        [ "$brk" != servfail ] || put dark yes
        [ "$brk" != servfail-once ] || [ "$m" != off ] || put dark yes
        if [ "$m" = off ]; then
          cmd_wrap 0 "Bridges are off. Your ISP will see plain Tor guard connections instead of" \
            "obfs4 traffic: it can tell you use Tor, though still not what you look up." \
            "Restarting the proxy..." "Bridges are off; the proxy restarted and DNS is answering."
        fi
        cmd_wrap 0 "Restarting the proxy..." "Bridges are on; the proxy restarted and DNS is answering." ;;
      status)
        [ "$(get installed)" = 1 ] || cmd_wrap 1 "schema	nice-dns-status/1" "install	installed	no"
        m="$(get mode on)"
        [ "$brk" != status-stale ] || m="$(get prevmode on)"
        [ "$brk" != status-stuck-off ] || [ "$m" != on ] || [ "$(get prevmode on)" != off ] || m=off
        cmd_wrap 0 "schema	nice-dns-status/1" "install	installed	yes" "bridges	mode	$m" "bridges	count	3" "bridges	last_refresh	never" ;;
      *) exec bash "$HERE/command-recovery-adapter.sh" "${args[@]}" ;;
    esac ;;
esac
