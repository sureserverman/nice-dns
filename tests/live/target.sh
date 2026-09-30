#!/usr/bin/env bash
# Disposable test-target adapter (sub-plan 01, Task 2.1; ARCH-03, ARCH-09).
#
# Usage:
#   bash tests/live/target.sh validate --targets FILE
#   bash tests/live/target.sh <operation> ALIAS --targets FILE [--component NAME]
#
# Operations (a fixed allow-list; there is no free-form remote command):
#   probe            read-only identity (machine id, hostname, platform, versions)
#   snapshot         read-only capture of containers, images and DNS ownership
#                    into $ARTIFACT_DIR/targets/ALIAS/ (required before any
#                    mutation, and bound to the machine it was taken from)
#   sever-upstream   stop the Tor proxy container (--component tor-haproxy|tor-socat)
#                    while Pi-hole and Unbound keep listening
#   heal-upstream    start that container again
#   restore          start every allow-listed container the snapshot saw running
#   config           read-only effective configuration: image references and
#                    digests, Pi-hole variant and upstreams, Unbound config,
#                    proxy listeners/backends, health tooling, DNS owner.
#                    Filtered at the source: never process arguments, env,
#                    torrc or pihole.toml secrets (bridge lines, the web-login hash).
#   health           the verdict of the target's existing health mechanisms:
#                    runtime healthcheck state (observed, never invoked) and
#                    the installed nice-dns-health, run with its recovery
#                    grace forced out of reach so it can only log
#   collect          run tests/live/collect.sh on the target against its
#                    client resolver (Pi-hole): --workload W --count N
#                    [--timeout-ms MS] [--pause-ms MS] --identity FILE;
#                    samples on stdout
#   freeze-upstream  SIGSTOP the tor process inside --component, so every
#                    listener (Pi-hole, Unbound, the proxy) stays up while
#                    upstream is dead; a detached remote timer thaws it after
#                    NICE_DNS_FREEZE_MAX_SECS (default 900) whatever happens here
#   thaw-upstream    SIGCONT that tor process
#   install-cell     reinstall the stack as --cell PROXY/PIHOLE with the
#                    product's own installer (install-{deb,mac}{,-hardened}.sh)
#                    run from this checkout's `git archive` of --source-sha
#                    SHA, sent inline (the target's own DNS may be the broken
#                    stack being replaced, so nothing is fetched there). Every
#                    entrypoint installs the tree it sits in (Sub-plan 4 Task
#                    1.1), so no platform depends on GitHub main any more. The
#                    installer's output is streamed back; it may carry bridge
#                    lines, so keep it out of portable evidence.
#   uninstall-cell   the same entrypoint and archive, run with `uninstall`
#                    (--cell names the entrypoint; the proxy is ignored).
#   lifecycle-report read-only (Sub-plan 4 Task 2.3): the installed generation
#                    and the images the containers run, the controller's
#                    install record, the nice-dns volumes, the state markers,
#                    DNS ownership, schedules, the macOS sudoers rule, Linux
#                    :53 listeners, and the Pi-hole admin API asked
#                    anonymously, with a wrong password and with the
#                    deployment's (read on the target from its file, never
#                    printed; the session is closed again).
#   watch-dns        read-only: one row per 2 s of the host's resolver
#                    settings for NICE_DNS_WATCH_SECS (10..3600, default 1800)
#                    or until the caller hangs up; streamed.
#   mark-state       write the run's marker into each state the deployment
#                    must keep (the Tor data volume, the anchor volume) and
#                    one operator allow rule through the admin API. Hardened
#                    cells also need the pi-hole-hardened sibling, which has
#                    no public source (no GitHub repo, no Docker Hub image):
#                    --hardened-sha SHA must equal this checkout's sibling
#                    ../pi-hole-hardened HEAD, whose `git archive` is sent
#                    inline and unpacked next to the clone.
#   quiesce-agents   stop the schedules that could mutate the stack beside the
#                    controller under test: macOS org.nice-dns.health (the old
#                    30-minute run), org.nice-dns.bridge-eval and
#                    org.nice-dns.health-bridges (launchctl bootout; the
#                    plists stay); Linux nice-dns-health.timer and
#                    nice-dns-health-bridges.timer (stopped). The stack's own
#                    starter and the read-only debug monitor keep running.
#   build-proxy      build --component's image on the target from the sibling
#                    checkout's `git archive` of --source-sha (sent inline) as
#                    nice-dns-candidate/<component>:<sha12> and tag it as the
#                    published docker.io/sureserver/<component>:latest the
#                    stack runs; prints the previous and the candidate image
#   recreate-proxy   recreate --component through the stack's own path (Linux
#                    its quadlet service; macOS the start-container agent,
#                    which rebuilds the whole stack) and wait for a new start
#   install-controller
#                    install health/nice-dns-health from this checkout's
#                    `git archive` of --source-sha, --mode shadow|active
#   fault-route      make one identity route (--route cloudflare-onion|
#                    cloudflare-exit|quad9-exit) of --component fail while
#                    every other route works: tor-haproxy puts its servers in
#                    maintenance, tor-socat SIGSTOPs its listener; a detached
#                    timer heals it after NICE_DNS_FREEZE_MAX_SECS
#   heal-route       undo fault-route
#   route-report     read-only (Sub-plan 5 Task 1.2): Unbound's route as the
#                    host holds it (the directory's mode, the include's
#                    marker and forwarder, desired.tsv), whether the
#                    container reads the host's include at /etc/unbound/route
#                    (desired.tsv is 0600, unreadable to Unbound's user), the
#                    running route read back over the control socket, the
#                    image's probe-route verdict, and one fresh name
#                    through Pi-hole. Run with the installed controller's
#                    own bundle (lib/recovery.sh).
#   route-apply      switch Unbound to --route (an identity route) with the
#                    installed bundle's apply_route, under the controller's
#                    state lock, at the next generation; prints its result
#   route-onion      Sub-plan 5 Task 1.4: leave a persisted cloudflare-onion
#                    include at the next generation, files only, under the
#                    controller's state lock (what the controller leaves once
#                    it has promoted the onion). The running Unbound is not
#                    reloaded: the include is what the next start reads, so a
#                    restart after it shows whether the start demotes the
#                    onion (lib/recovery.sh start_route)
#   arm-prepare      Sub-plan 5 Task 1.3 (DEC-012): the two arms of an
#                    interleaved comparison, as local image tags nd-arm-*.
#                    candidate: the images the stack runs now. baseline:
#                    Unbound and Pi-hole built from this checkout's `git
#                    archive` of --source-sha (b85bc9b; macOS with that
#                    commit's installer rewrites), the proxy --component
#                    pulled at --proxy-tag. macOS builds in a stack-down
#                    window (the builder wedges dnsnet otherwise), then
#                    restarts the runtime and the stack's agent.
#   arm-set          point the stack's image names at --mode baseline|
#                    candidate, restart the stack through its own path (Linux
#                    the pod service; macOS the start-container agent, after
#                    removing the three containers) and wait until Pi-hole
#                    answers; prints the resolver, the time from the restart
#                    command to the first answer (DEC-014: `first_answer`, up
#                    to 600 s) and the images that run, and fails unless
#                    they are the arm's
#   thaw-on-request  wait (up to NICE_DNS_FREEZE_MAX_SECS) until the image
#                    claims the controller's restart request, then SIGCONT
#                    the frozen tor of --component: its pending TERM ends it
#                    and the image respawns it (the in-image acknowledged
#                    restart); after the wait it thaws anyway and fails
#   wedge-runtime    macOS: start a container on the default network (the
#                    observed trigger of the dnsnet wedge); Linux: stop
#                    pi-hole.service (the stack's containers go missing)
#   heal-runtime     remove the macOS wedge container (Linux: nothing to undo)
#   bridges-refresh  run the installed controller's bridges-refresh now
#   install-agent    macOS: replace the LaunchAgent's root-owned
#                    /usr/local/sbin/start-container.sh with this checkout's
#                    `git archive` of --source-sha (sudo -n: the disposable
#                    Mac's sudo asks for no credential; nothing prompts). A cell
#                    installed from origin/main otherwise keeps its old agent
#   set-tunables     --mode fast writes the installed controller's
#                    tunables.tsv (30 s startup allowance, grace and cooldown:
#                    the live gate's extra configurations, user decision
#                    2026-09-26); --mode default removes it (the real timers).
#                    The ladder hold keeps its real 660 s: a shorter one
#                    recreates the proxy mid-bootstrap (live, mint haproxy,
#                    run 20260927T082335Z-3babdc89: 70 s after the first)
#   hold-bridge-refresh
#                    stamp the controller's outage-refresh rate limit
#                    (bridges.last = now), so an outage in the next hour does
#                    not re-evaluate bridges (test-only: keeps the in-image
#                    restart path deterministic)
#   controller-report
#                    read-only: the controller's install receipt, tick lines,
#                    state and journals (active and shadow), the bridge set's
#                    hash (never its lines), the proxy generation, the HAProxy
#                    summary lines and one `observe`; redacted at the source
#
# Targets file: TSV data, never sourced; owned by the user, not a symlink and
# not group/world-writable. One row per target:
#   alias  platform(linux|macos)  ssh-alias  SHA256:<host key>  disposable  YYYY-MM-DD
# "disposable" is the explicit designation that the target may lose DNS
# during tests; the date records when it was designated.
#
# Guards, all enforced before any remote command is sent:
#   - ssh runs with BatchMode, StrictHostKeyChecking=yes and no forwarding;
#     the pinned SHA256 key must already be in known_hosts (no trust on first
#     use) and match the targets file.
#   - the ssh hostname must not be this machine (loopback, local names or
#     addresses); the remote machine id must differ from this machine's and
#     the remote platform must match the row.
#   - mutations require a snapshot of the same machine id in this run.
#   - state paths under $ARTIFACT_DIR must not be symlinks.
# No credentials live here: authentication is the user's ssh agent/config.
# ProxyCommand/ProxyJump from the user's own ssh config are inside that trust
# boundary and are not overridden; the remote machine-id check, not the
# ssh -G hostname, is the authoritative "not this machine" guard.
#
# Exit: 0 done; 1 the remote operation failed; 2 refused (nothing mutating sent);
#   3 collect wrote samples but at least one attempt failed (data, not an error).
# Portability: Bash 3.2, BSD/GNU userland; remote side is /bin/sh.

set -u
# State, receipts and payloads are owner-only even when run standalone
# (tests/run.sh sets the same umask for the harness).
umask 077

die() { printf 'target.sh: %s\n' "$*" >&2; exit 2; }

TAB="$(printf '\t')"
OPS='validate probe snapshot sever-upstream heal-upstream restore config health collect freeze-upstream thaw-upstream install-cell uninstall-cell quiesce-agents build-proxy recreate-proxy install-controller fault-route heal-route controller-report thaw-on-request wedge-runtime heal-runtime bridges-refresh hold-bridge-refresh install-agent set-tunables lifecycle-report watch-dns mark-state route-report route-apply route-onion arm-prepare arm-set'
FAULT_ROUTES='cloudflare-onion cloudflare-exit quad9-exit'
COMPONENTS='pi-hole unbound tor-haproxy tor-socat'
UPSTREAM_COMPONENTS='tor-haproxy tor-socat'
ND_CHECKOUT="$(cd "$(dirname "$0")/../.." && pwd -P)"

op="${1:-}"
[ $# -gt 0 ] && shift
case " $OPS " in *" $op "*) ;; *) die "unknown operation '$op' (allowed: $OPS)" ;; esac
alias_=''
if [ "$op" != validate ]; then
  alias_="${1:-}"
  [ $# -gt 0 ] && shift
  case "$alias_" in ''|-*) die "usage: target.sh $op ALIAS --targets FILE" ;; esac
fi
targets='' component='' c_workload='' c_count='' c_timeout=5000 c_pause=0 c_identity='' i_cell='' i_sha='' i_hsha='' i_route='' i_mode='' i_ptag=''
while [ $# -gt 0 ]; do
  case "$1" in
    --targets|--component|--workload|--count|--timeout-ms|--pause-ms|--identity|--cell|--source-sha|--hardened-sha|--route|--mode|--proxy-tag)
      [ $# -ge 2 ] || die "option $1 needs a value"
      case "$1" in
        --targets) targets="$2" ;;
        --component) component="$2" ;;
        --workload) c_workload="$2" ;;
        --count) c_count="$2" ;;
        --timeout-ms) c_timeout="$2" ;;
        --pause-ms) c_pause="$2" ;;
        --identity) c_identity="$2" ;;
        --cell) i_cell="$2" ;;
        --hardened-sha) i_hsha="$2" ;;
        --source-sha) i_sha="$2" ;;
        --route) i_route="$2" ;;
        --mode) i_mode="$2" ;;
        --proxy-tag) i_ptag="$2" ;;
      esac
      shift 2 ;;
    *) die "unknown option '$1'" ;;
  esac
done
[ -n "$targets" ] || die "missing --targets FILE"
if [ "$op" != collect ] && [ -n "$c_workload$c_count$c_identity" ]; then
  die "--workload/--count/--identity are only valid for collect"
fi
case "$op" in install-cell|uninstall-cell) ;; *) [ -z "$i_cell$i_hsha" ] || die "--cell/--hardened-sha are only valid for install-cell and uninstall-cell" ;; esac
case "$op" in install-cell|uninstall-cell|build-proxy|install-controller|install-agent|arm-prepare) ;; *) [ -z "$i_sha" ] || die "--source-sha is only valid for install-cell, uninstall-cell, build-proxy, install-controller, install-agent and arm-prepare" ;; esac
case "$op" in fault-route|heal-route|route-apply) ;; *) [ -z "$i_route" ] || die "--route is only valid for fault-route, heal-route and route-apply" ;; esac
case "$op" in install-controller|set-tunables|arm-set) ;; *) [ -z "$i_mode" ] || die "--mode is only valid for install-controller, set-tunables and arm-set" ;; esac
case "$op" in arm-prepare) [[ "$i_ptag" =~ ^v[0-9]+(\.[0-9]+)*$ ]] || die "arm-prepare needs --proxy-tag vN[.N]" ;; *) [ -z "$i_ptag" ] || die "--proxy-tag is only valid for arm-prepare" ;; esac
if [ "$op" = arm-set ]; then case "$i_mode" in baseline|candidate) ;; *) die "arm-set needs --mode baseline|candidate" ;; esac; fi
if [ "$op" = arm-prepare ]; then
  [[ "$i_sha" =~ ^[0-9a-f]{40}$ ]] || die "arm-prepare needs --source-sha <40-hex commit>"
  [ "$(git -C "$ND_CHECKOUT" cat-file -t "$i_sha" 2>/dev/null)" = commit ] || die "--source-sha $i_sha is not a commit in $ND_CHECKOUT"
fi
if [ "$op" = set-tunables ]; then case "$i_mode" in fast|default) ;; *) die "set-tunables needs --mode fast|default" ;; esac; fi

# ─── targets file (data only) ────────────────────────────────────────────────

file_mode() { stat -c %a "$1" 2>/dev/null || stat -f %Lp "$1"; }
file_uid() { stat -c %u "$1" 2>/dev/null || stat -f %u "$1"; }

RE_ALIAS='^[a-z0-9][a-z0-9-]{0,31}$'
RE_SSH='^[A-Za-z0-9][A-Za-z0-9._@-]{0,127}$'
RE_KEY='^SHA256:[A-Za-z0-9+/]{43}$'
RE_DATE='^[0-9]{4}-[0-9]{2}-[0-9]{2}$'

T_PLATFORM='' T_SSH='' T_KEY='' T_DATE=''
load_targets() {
  local f="$1" ln=0 a p s k d dt extra seen='|' mode found=no
  [ -L "$f" ] && die "targets file $f is a symlink; refusing"
  [ -f "$f" ] || die "targets file $f not found"
  [ "$(file_uid "$f")" = "$(id -u)" ] || die "targets file $f is not owned by $(id -un)"
  mode="$(file_mode "$f")"
  case "$mode" in *[2367][0-7]|*[2367]) die "targets file $f is group- or world-writable (mode $mode)" ;; esac
  while IFS="$TAB" read -r a p s k d dt extra || [ -n "${a:-}" ]; do
    ln=$((ln + 1))
    case "$a" in ''|'#'*) continue ;; esac
    [ -z "${extra:-}" ] || die "targets file $f:$ln: more than 6 columns"
    [ -n "${dt:-}" ] || die "targets file $f:$ln: expected 6 tab-separated columns (alias platform ssh host_key designation designated_on)"
    [[ "$a" =~ $RE_ALIAS ]] || die "targets file $f:$ln: bad alias"
    case "$p" in linux|macos) ;; *) die "targets file $f:$ln: platform must be linux or macos" ;; esac
    [[ "$s" =~ $RE_SSH ]] || die "targets file $f:$ln: ssh alias has unexpected characters"
    [[ "$k" =~ $RE_KEY ]] || die "targets file $f:$ln: host key must be a SHA256 fingerprint"
    [ "$d" = disposable ] || die "targets file $f:$ln: designation must be the literal 'disposable'"
    [[ "$dt" =~ $RE_DATE ]] || die "targets file $f:$ln: designated_on must be YYYY-MM-DD"
    case "$seen" in *"|$a|"*) die "targets file $f:$ln: duplicate alias '$a'" ;; esac
    seen="$seen$a|"
    if [ "$op" = validate ]; then
      printf '%s\t%s\t%s\t%s\n' "$a" "$p" "$s" "$dt"
    elif [ "$a" = "$alias_" ]; then
      T_PLATFORM="$p" T_SSH="$s" T_KEY="$k" T_DATE="$dt" found=yes
    fi
  done <"$f"
  if [ "$op" != validate ] && [ "$found" != yes ]; then
    die "unknown alias '$alias_' (not in targets file $f)"
  fi
  return 0
}

load_targets "$targets"
[ "$op" = validate ] && exit 0

case "$op" in
  sever-upstream|heal-upstream|freeze-upstream|thaw-upstream|build-proxy|recreate-proxy|fault-route|heal-route|thaw-on-request|arm-prepare|arm-set)
    case " $UPSTREAM_COMPONENTS " in
      *" $component "*) [ -n "$component" ] || die "--component is required" ;;
      *) die "component '$component' is not an upstream component (allowed: $UPSTREAM_COMPONENTS)" ;;
    esac ;;
  *) [ -z "$component" ] || die "--component is only valid for sever/heal/freeze/thaw-upstream, build/recreate-proxy, fault/heal-route, thaw-on-request and arm-prepare/arm-set" ;;
esac
case "$op" in
  fault-route|heal-route|route-apply)
    # The identity routes only: `compat` is never selected (DEC-005).
    case " $FAULT_ROUTES " in
      *" $i_route "*) [ -n "$i_route" ] || die "--route is required" ;;
      *) die "route '$i_route' is not an identity route (allowed: $FAULT_ROUTES)" ;;
    esac ;;
  build-proxy)
    [[ "$i_sha" =~ ^[0-9a-f]{40}$ ]] || die "build-proxy needs --source-sha <40-hex commit of the $component sibling>"
    PSIB="$(cd "$ND_CHECKOUT/.." && pwd -P)/$component"
    [ "$(git -C "$PSIB" cat-file -t "$i_sha" 2>/dev/null)" = commit ] || die "--source-sha $i_sha is not a commit in $PSIB" ;;
  install-controller|install-agent)
    [[ "$i_sha" =~ ^[0-9a-f]{40}$ ]] || die "$op needs --source-sha <40-hex nice-dns commit>"
    [ "$(git -C "$ND_CHECKOUT" cat-file -t "$i_sha" 2>/dev/null)" = commit ] || die "--source-sha $i_sha is not a commit in $ND_CHECKOUT"
    [ "$op" = install-agent ] || case "$i_mode" in shadow|active) ;; *) die "install-controller needs --mode shadow|active" ;; esac ;;
esac

# collect parameters travel as NAME=value words in the ssh command, so every
# value is checked against a narrow character set here, before connecting.
RE_WORD='^[a-z0-9][a-z0-9-]{0,31}$'
RE_IDVAL='^[A-Za-z0-9._:@,/+=-]{1,512}$'
RE_RUNID='^[A-Za-z0-9._-]{1,64}$'
freeze_max="${NICE_DNS_FREEZE_MAX_SECS:-900}"
case "$freeze_max" in ''|*[!0-9]*) die "NICE_DNS_FREEZE_MAX_SECS must be an integer" ;; esac
[ "$freeze_max" -ge 60 ] && [ "$freeze_max" -le 1800 ] || die "NICE_DNS_FREEZE_MAX_SECS must be 60..1800"
INSTALL_ENV=''
watch_secs="${NICE_DNS_WATCH_SECS:-1800}"
case "$watch_secs" in ''|*[!0-9]*) die "NICE_DNS_WATCH_SECS must be an integer" ;; esac
[ "$watch_secs" -ge 10 ] && [ "$watch_secs" -le 3600 ] || die "NICE_DNS_WATCH_SECS must be 10..3600"
if [ "$op" = mark-state ]; then
  [[ "${RUN_ID:-}" =~ $RE_RUNID ]] || die "mark-state needs RUN_ID (the run's id) in the environment"
fi
if [ "$op" = install-cell ] || [ "$op" = uninstall-cell ]; then
  case "$i_cell" in haproxy/standard|haproxy/hardened|socat/standard|socat/hardened) ;;
    *) die "$op needs --cell haproxy|socat/standard|hardened" ;; esac
  [[ "$i_sha" =~ ^[0-9a-f]{40}$ ]] || die "$op needs --source-sha <40-hex commit>"
  [ "$(git -C "$ND_CHECKOUT" cat-file -t "$i_sha" 2>/dev/null)" = commit ] || die "--source-sha $i_sha is not a commit in $ND_CHECKOUT"
  INSTALL_ENV="NICE_DNS_ACTION=${op%-cell} NICE_DNS_PROXY=${i_cell%/*} NICE_DNS_PIHOLE=${i_cell#*/} NICE_DNS_SOURCE_SHA=$i_sha"
  HSIB="$(cd "$ND_CHECKOUT/.." && pwd -P)/pi-hole-hardened"
  if [ "${i_cell#*/}" = hardened ]; then
    [[ "$i_hsha" =~ ^[0-9a-f]{40}$ ]] || die "a hardened cell needs --hardened-sha <40-hex pi-hole-hardened commit>"
    [ "$(git -C "$HSIB" rev-parse HEAD 2>/dev/null)" = "$i_hsha" ] \
      || die "--hardened-sha $i_hsha is not the HEAD of $HSIB"
    INSTALL_ENV="$INSTALL_ENV NICE_DNS_HARDENED_SHA=$i_hsha"
  else
    [ -z "$i_hsha" ] || die "--hardened-sha is only for hardened cells"
  fi
fi
ID_ENV=''
if [ "$op" = collect ]; then
  [[ "$c_workload" =~ $RE_WORD ]] || die "collect needs --workload NAME (lowercase word)"
  [[ "$c_count" =~ ^[1-9][0-9]{0,4}$ ]] || die "collect needs --count 1..99999"
  [[ "$c_timeout" =~ ^[1-9][0-9]{3,5}$ ]] || die "--timeout-ms must be 1000..999999"
  [[ "$c_pause" =~ ^[0-9]{1,6}$ ]] || die "--pause-ms must be 0..999999"
  [[ "${RUN_ID:-}" =~ $RE_RUNID ]] || die "collect needs RUN_ID (the run's id) in the environment"
  [ -n "$c_identity" ] && [ -f "$c_identity" ] && [ ! -L "$c_identity" ] || die "collect needs --identity FILE (a regular file)"
  for k in target_id platform proxy pihole source_rev images; do
    v="$(awk -F '\t' -v k="$k" '$1 == k { print $2; n++ } END { if (n != 1) exit 1 }' "$c_identity")" \
      || die "identity file needs exactly one '$k' row"
    [[ "$v" =~ $RE_IDVAL ]] || die "identity value for '$k' has unexpected characters"
    ID_ENV="$ID_ENV NICE_DNS_ID_$(printf '%s' "$k" | tr a-z A-Z)=$v"
    case "$k" in
      target_id) [ "$v" = "$alias_" ] || die "identity target_id '$v' is not the alias '$alias_'" ;;
      platform) [ "$v" = "$T_PLATFORM" ] || die "identity platform '$v' is not the target's '$T_PLATFORM'" ;;
    esac
  done
fi

# ─── this machine ────────────────────────────────────────────────────────────

local_machine_id() {
  if [ -r /etc/machine-id ]; then cat /etc/machine-id
  else ioreg -rd1 -c IOPlatformExpertDevice 2>/dev/null | awk -F'"' '/IOPlatformUUID/ { print $4 }'
  fi
}

local_addresses() {
  printf '127.0.0.1\n::1\nlocalhost\n0.0.0.0\n'
  hostname 2>/dev/null
  hostname -s 2>/dev/null
  hostname -f 2>/dev/null
  if command -v ip >/dev/null 2>&1; then
    ip -o addr show 2>/dev/null | awk '{ sub(/\/.*/, "", $4); print $4 }'
  else
    ifconfig 2>/dev/null | awk '$1 == "inet" || $1 == "inet6" { sub(/%.*/, "", $2); print $2 }'
  fi
}

# ─── ssh ─────────────────────────────────────────────────────────────────────

SSH_OPTS=(-o BatchMode=yes -o StrictHostKeyChecking=yes -o UpdateHostKeys=no
  -o ForwardAgent=no -o ForwardX11=no -o ClearAllForwardings=yes
  -o PermitLocalCommand=no -o ControlMaster=no -o ControlPath=none -o ConnectTimeout=15
  -o ServerAliveInterval=30 -o ServerAliveCountMax=6)

preconnect_guards() {
  local cfg host port name kh files f fps='' line
  cfg="$(ssh -G "$T_SSH" 2>/dev/null)" || die "ssh -G $T_SSH failed"
  host="$(printf '%s\n' "$cfg" | awk '$1 == "hostname" { print $2; exit }')"
  port="$(printf '%s\n' "$cfg" | awk '$1 == "port" { print $2; exit }')"
  files="$(printf '%s\n' "$cfg" | awk '$1 == "userknownhostsfile" { for (i = 2; i <= NF; i++) print $i }')"
  [ -n "$host" ] || die "ssh -G $T_SSH gave no hostname"
  if local_addresses | grep -Fxq -- "$host"; then
    die "ssh target $T_SSH resolves to this machine ($host); the developer/production DNS host is never a test target"
  fi
  if [ -z "$port" ] || [ "$port" = 22 ]; then name="$host"; else name="[$host]:$port"; fi
  for kh in "" $files; do
    case "$kh" in \~/*) kh="$HOME/${kh#\~/}" ;; esac
    if [ -z "$kh" ]; then
      line="$(ssh-keygen -F "$name" -l 2>/dev/null)" || continue
    else
      [ -f "$kh" ] || continue
      line="$(ssh-keygen -F "$name" -l -f "$kh" 2>/dev/null)" || continue
    fi
    # "NAME TYPE SHA256:..." per key; take the fingerprint field, not a column.
    fps="$fps$(printf '%s\n' "$line" | awk '!/^#/ { for (i = 1; i <= NF; i++) if ($i ~ /^SHA256:/) print $i }')
"
  done
  [ -n "$(printf '%s' "$fps" | tr -d '\n')" ] \
    || die "host key for $name is not in known_hosts; verify it out of band and add it (no trust on first use)"
  printf '%s' "$fps" | grep -Fxq -- "$T_KEY" \
    || die "host key mismatch for $name: known_hosts has $(printf '%s' "$fps" | tr '\n' ' '), targets file pins $T_KEY"
}

# remote_run <env-prefix> : sends the op's constant script to /bin/sh -s
# (collect first prepends the bundle: collect.sh and its two manifests, copied
# verbatim from this checkout into a remote temporary directory).
# The whole payload is built and checked before ssh starts, so a bundle that
# fails is never half-sent (a pipeline would report only ssh's status). Not
# `set -o pipefail` file-wide: guards such as `local_addresses | grep -Fxq`
# must not turn a SIGPIPE'd producer into a false negative.
remote_run() {
  local payload rc
  payload="$(mktemp "${TMPDIR:-/tmp}/nice-dns-payload.XXXXXX")" || return 1
  if ! build_payload >"$payload"; then
    rm -f "$payload"
    printf 'target.sh: could not build the remote payload; nothing was sent\n' >&2
    return 2
  fi
  ssh "${SSH_OPTS[@]}" "$T_SSH" "$1 /bin/sh -s" <"$payload"
  rc=$?
  rm -f "$payload"
  return "$rc"
}

build_payload() {
  if [ "$op" = collect ]; then remote_bundle || return 1; fi
  case "$op" in install-cell|uninstall-cell|install-controller|install-agent|arm-prepare) source_bundle || return 1 ;; esac
  if [ "$op" = build-proxy ]; then proxy_bundle || return 1; fi
  case "$op" in install-cell|uninstall-cell) [ -z "$i_hsha" ] || hardened_bundle || return 1 ;; esac
  remote_script
}

BUNDLE_EOF=__NICE_DNS_BUNDLE_EOF__
remote_bundle() {
  local f
  printf '%s\n' 'ND_BUNDLE=$(mktemp -d "${TMPDIR:-/tmp}/nice-dns-collect.XXXXXX") || exit 1' \
    'trap '"'"'rm -rf "$ND_BUNDLE"'"'"' EXIT' \
    'mkdir -p "$ND_BUNDLE/tests/live" "$ND_BUNDLE/tests/manifests" || exit 1'
  for f in tests/live/collect.sh tests/manifests/workloads.tsv tests/manifests/matrix.tsv; do
    [ -f "$ND_CHECKOUT/$f" ] || { printf 'target.sh: bundle file %s missing\n' "$f" >&2; return 1; }
    if grep -q "$BUNDLE_EOF" "$ND_CHECKOUT/$f"; then printf 'target.sh: %s contains the bundle delimiter\n' "$f" >&2; return 1; fi
    printf "cat >\"\$ND_BUNDLE/%s\" <<'%s'\n" "$f" "$BUNDLE_EOF"
    cat "$ND_CHECKOUT/$f"
    printf '%s\n' "$BUNDLE_EOF"
  done
}

source_bundle() {
  # nice-dns at the pinned commit, base64 tar.gz, decoded into ND_SOURCE_TGZ.
  printf '%s\n' 'ND_SOURCE_TGZ=$(mktemp "${TMPDIR:-/tmp}/nice-dns-source.XXXXXX") || exit 1' \
    "{ base64 -d 2>/dev/null || base64 -D; } >\"\$ND_SOURCE_TGZ\" <<'$BUNDLE_EOF'"
  ( set -o pipefail; git -C "$ND_CHECKOUT" archive --format=tar "$i_sha" | gzip -9 | base64 ) || return 1
  printf '%s\n' "$BUNDLE_EOF"
}

proxy_bundle() {
  # The proxy sibling at the pinned commit (tracked files only: never the
  # untracked local bridge-eval binary), base64 tar.gz, into ND_PROXY_TGZ.
  printf '%s\n' 'ND_PROXY_TGZ=$(mktemp "${TMPDIR:-/tmp}/nice-dns-proxy.XXXXXX") || exit 1' \
    "{ base64 -d 2>/dev/null || base64 -D; } >\"\$ND_PROXY_TGZ\" <<'$BUNDLE_EOF'"
  ( set -o pipefail; git -C "$PSIB" archive --format=tar "$i_sha" | gzip -9 | base64 ) || return 1
  printf '%s\n' "$BUNDLE_EOF"
}

hardened_bundle() {
  # The pi-hole-hardened tree at the pinned commit, base64 tar.gz, decoded
  # into ND_HARDENED_TGZ on the target.
  printf '%s\n' 'ND_HARDENED_TGZ=$(mktemp "${TMPDIR:-/tmp}/nice-dns-hardened.XXXXXX") || exit 1' \
    "{ base64 -d 2>/dev/null || base64 -D; } >\"\$ND_HARDENED_TGZ\" <<'$BUNDLE_EOF'"
  ( set -o pipefail; git -C "$HSIB" archive --format=tar "$i_hsha" | gzip -9 | base64 ) || return 1
  printf '%s\n' "$BUNDLE_EOF"
}

remote_script() {
  cat <<'SH'
set -u
if [ "$(uname -s)" = Darwin ]; then
  plat=macos
  mid=$(ioreg -rd1 -c IOPlatformExpertDevice | awk -F'"' '/IOPlatformUUID/ { print $4 }')
  C=$(command -v container || ls /opt/homebrew/bin/container /usr/local/bin/container 2>/dev/null | head -1)
  RESOLVER='172.31.240.250#53'
  HEALTH_LOG="$HOME/Library/Logs/nice-dns-health/health.log"
else
  plat=linux
  mid=$(cat /etc/machine-id 2>/dev/null)
  C=podman
  RESOLVER='127.0.0.1#53'
  HEALTH_LOG="${XDG_STATE_HOME:-$HOME/.local/state}/nice-dns-health/health.log"
  # systemctl --user over ssh has no session bus address otherwise.
  XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"; export XDG_RUNTIME_DIR
fi
ctl() { "$C" "$@"; }
# exec never reads this script's stdin (the script itself arrives on it).
ctl_exec() { "$C" exec "$@" </dev/null; }
sha_of() { if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | cut -d' ' -f1; else shasum -a 256 "$1" | cut -d' ' -f1; fi; }
containers() {
  # name <TAB> state <TAB> address (or -)
  if [ "$plat" = macos ]; then
    ctl list --all | awk 'NR > 1 { ip = "-"; for (i = 6; i <= NF; i++) if ($i ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+\//) ip = $i; printf "%s\t%s\t%s\n", $1, $5, ip }'
  else
    for n in $(ctl ps -a --format '{{.Names}}'); do
      ctl inspect "$n" --format '{{.Name}}	{{.State.Status}}	{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' 2>/dev/null |
        awk -F '\t' '{ printf "%s\t%s\t%s\n", $1, $2, ($3 == "" ? "-" : $3) }'
    done
  fi
}
running() { containers | awk -F '\t' -v c="$1" '$1 == c && $2 == "running" { f = 1 } END { exit !f }'; }
identity() {
  printf 'machine_id\t%s\nhostname\t%s\nplatform\t%s\n' "$mid" "$(hostname)" "$plat"
  if [ "$plat" = macos ]; then
    printf 'os\tmacOS %s\nruntime\t%s\n' "$(sw_vers -productVersion)" "$(ctl --version 2>&1 | head -1)"
  else
    printf 'os\t%s\nruntime\t%s\n' "$(. /etc/os-release && echo "$PRETTY_NAME")" "$(podman --version)"
  fi
}
dns_owner() {
  if [ "$plat" = macos ]; then
    # Enabled services only, as mac/start-container-root.sh services(): a
    # disabled one is never nice-dns's and may carry its own DNS (round-2
    # review, 2026-09-28).
    networksetup -listallnetworkservices | tail -n +2 | { grep -v '^\*' || true; } | while IFS= read -r svc; do
      printf '%s\t%s\n' "$svc" "$(networksetup -getdnsservers "$svc" | tr '\n' ' ')"
    done
    printf 'section\tagents\n'
    launchctl list | awk '/nice-dns/'
  else
    printf 'resolv.conf\t%s\n' "$(readlink -f /etc/resolv.conf)"
    grep '^nameserver' /etc/resolv.conf
    printf 'systemd-resolved\t%s\n' "$(systemctl is-active systemd-resolved 2>&1)"
    printf 'section\tunits\n'
    systemctl --user list-units --plain --no-legend --all 'pi-hole*' 'unbound*' 'tor-*' 'nice-dns*' 2>&1
  fi
}
health_tool() {
  for t in "$HOME/.local/bin/nice-dns-health" "${XDG_STATE_HOME:-$HOME/.local/state}/nice-dns-health/bin/nice-dns-health"; do
    [ -x "$t" ] && { printf '%s\n' "$t"; return 0; }
  done
  return 1
}
# redact: no bridge certificate or fingerprint leaves the target.
redact() {
  sed -E -e 's#cert=[A-Za-z0-9+/=]+#cert=<redacted>#g' \
    -e 's/(^|[^0-9A-Fa-f])[0-9A-F]{40}([^0-9A-Fa-f]|$)/\1<fingerprint>\2/g'
}
homebrew_path() { PATH="/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:$PATH"; export PATH; }
# mac_room: a macOS build (install, arm-prepare) needs room: one tune-resolver
# cell took about 12 GiB of Apple's container store, and the mac was down to
# 271 MiB free on 2026-09-29. Refused before anything changes, never mid-build.
mac_room() {
  [ "$plat" = macos ] || return 0
  k=$(df -k "$HOME" | awk 'NR == 2 { print $4 }')
  case "$k" in ''|*[!0-9]*) echo "cannot read the free space on the mac" >&2; return 1 ;; esac
  [ "$k" -ge 20971520 ] || { echo "only $((k / 1048576)) GiB free on the mac; a build needs 20 GiB" >&2; return 1; }
}
# started <container>: its start time (changes on every recreate), or nothing.
started() {
  if [ "$plat" = macos ]; then ctl list --all | awk -v c="$1" '$1 == c && $5 == "running" { print $NF }'
  else ctl inspect "$1" --format '{{.Id}} {{.State.StartedAt}}' 2>/dev/null; fi
}
image_of() {
  if [ "$plat" = macos ]; then
    ctl inspect "$1" 2>/dev/null | tr ',' '\n' | sed -n 's/.*"digest"[[:space:]]*:[[:space:]]*"\(sha256:[0-9a-f]*\)".*/\1/p' | head -1
  else ctl inspect "$1" --format '{{.Image}}' 2>/dev/null; fi
}
tor_states() {
  # One process-state letter per tor pid in the proxy container (T = stopped).
  # Field 3 of /proc/PID/stat is the state only while comm (field 2) has no
  # space; it is the literal "(tor)" here.
  ctl_exec "$1" sh -c 'for p in $(pgrep -x tor); do awk "{ print \$3 }" /proc/$p/stat; done' | tr '\n' ' ' | sed 's/ $//'
}
case "$NICE_DNS_OP" in
  probe|snapshot)
    identity
    printf 'section\tcontainers\n'
    containers
    if [ "$NICE_DNS_OP" = snapshot ]; then
      printf 'section\timages\n'
      if [ "$plat" = macos ]; then ctl image list 2>&1; else podman images --digests --format '{{.Repository}}:{{.Tag}}\t{{.Digest}}'; fi
      printf 'section\tdns\n'
      dns_owner
    fi ;;
  config)
    identity
    printf 'section\tcontainers\n'
    containers
    printf 'section\timages\n'
    for c in pi-hole unbound tor-haproxy tor-socat; do
      if [ "$plat" = macos ]; then
        j=$(ctl inspect "$c" 2>/dev/null | tr ',' '\n' | sed 's#\\/#/#g') || continue
        ref=$(printf '%s\n' "$j" | sed -n 's/.*"reference"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)
        dg=$(printf '%s\n' "$j" | sed -n 's/.*"digest"[[:space:]]*:[[:space:]]*"\(sha256:[0-9a-f]*\)".*/\1/p' | head -1)
      else
        line=$(ctl inspect "$c" --format '{{.ImageName}} {{.ImageDigest}}' 2>/dev/null) || continue
        ref=${line% *} dg=${line##* }
      fi
      [ -n "$ref$dg" ] && printf 'image\t%s\t%s\t%s\n' "$c" "${ref:--}" "${dg:--}"
    done
    if [ "$plat" = macos ]; then
      ctl list --all | awk 'NR > 1 && $5 == "running" { printf "started\t%s\t%s\n", $1, $NF }'
    else
      for c in pi-hole unbound tor-haproxy tor-socat; do
        s=$(ctl inspect "$c" --format '{{.State.StartedAt}}' 2>/dev/null) && printf 'started\t%s\t%s\n' "$c" "$s"
      done
    fi
    printf 'section\tpihole\n'
    if running pi-hole; then
      printf 'pihole_variant\t%s\n' "$(ctl_exec pi-hole sh -c 'test -d /pihole && echo hardened || echo standard')"
      ctl_exec pi-hole sh -c 'grep -h "^server=" /etc/pihole/dnsmasq.conf /etc/dnsmasq.d/*.conf 2>/dev/null; sed -n "/^[[:space:]]*upstreams[[:space:]]*=/,/]/p" /etc/pihole/pihole.toml 2>/dev/null | sed "s/[[:space:]]###.*//" | tr -d "\n" | sed "s/  */ /g"; echo' |
        sed 's/^[[:space:]]*/pihole_upstream	/'
      printf 'pihole_version\t%s\n' "$(ctl_exec pi-hole sh -c 'pihole-FTL --version 2>/dev/null | head -1')"
    fi
    printf 'section\tunbound\n'
    if running unbound; then
      printf 'unbound_version\t%s\n' "$(ctl_exec unbound sh -c 'unbound -V 2>&1 | head -1')"
      ctl_exec unbound sh -c 'grep -v "^[[:space:]]*#" /etc/unbound/unbound.conf | grep -v "^[[:space:]]*$"' |
        sed 's/^/unbound_conf	/'
    fi
    printf 'section\tproxy\n'
    for c in tor-haproxy tor-socat; do
      running "$c" || continue
      printf 'proxy_component\t%s\n' "$c"
      printf 'tor_version\t%s\n' "$(ctl_exec "$c" sh -c 'tor --version 2>/dev/null | head -1')"
      printf 'tor_state\t%s\n' "$(tor_states "$c")"
      # Never tor's own arguments or torrc: they carry bridge certificates.
      if [ "$c" = tor-haproxy ]; then
        ctl_exec "$c" sh -c 'grep -E "^[[:space:]]*(frontend|backend|bind|server|default_backend|use_backend|timeout)[[:space:]]" /etc/haproxy/haproxy.cfg' |
          sed 's/^[[:space:]]*/proxy_conf	/'
      else
        ctl_exec "$c" sh -c 'for p in $(pgrep -x socat); do tr "\000" " " </proc/$p/cmdline; echo; done' |
          sed 's/^/proxy_conf	/'
      fi
    done
    printf 'section\thealth-config\n'
    if t=$(health_tool); then printf 'health_tool\t%s\t%s\n' "$t" "$(sha_of "$t")"; else printf 'health_tool\tabsent\t-\n'; fi
    if [ "$plat" = macos ]; then
      for p in "$HOME"/Library/LaunchAgents/org.nice-dns.*.plist; do
        [ -f "$p" ] || continue
        printf 'launchd_agent\t%s\tStartInterval=%s\tKeepAlive=%s\n' "$(basename "$p" .plist)" \
          "$(plutil -extract StartInterval raw -o - "$p" 2>/dev/null || echo -)" \
          "$(plutil -extract KeepAlive raw -o - "$p" 2>/dev/null || echo -)"
      done
    else
      for c in pi-hole unbound tor-haproxy tor-socat; do
        hc=$(ctl inspect "$c" --format '{{.Config.Healthcheck}}' 2>/dev/null) || continue
        oa=$(ctl inspect "$c" --format '{{.Config.HealthcheckOnFailureAction}}' 2>/dev/null) || oa=unknown
        printf 'healthcheck\t%s\t%s\ton_failure=%s\n' "$c" "$hc" "${oa:-none}"
      done
      systemctl --user list-timers --all --no-legend 2>/dev/null | awk '/nice-dns/ { print "timer\t" $0 }'
    fi
    printf 'section\tdns\n'
    dns_owner ;;
  health)
    identity
    printf 'section\thealth\n'
    if [ "$plat" = linux ]; then
      for c in pi-hole unbound tor-haproxy tor-socat; do
        st=$(ctl inspect "$c" --format '{{.State.Status}}	{{.State.Health.Status}}	{{.State.Health.FailingStreak}}' 2>/dev/null) || continue
        printf '%s\n' "$st" | awk -F '\t' -v c="$c" '{ printf "health\tpodman:%s\t%s\tstate=%s streak=%s\n", c, ($2 == "" ? "none" : $2), $1, ($3 == "" ? "-" : $3) }'
        # The runtime's retained check history: start time and exit code of each.
        hl=$(ctl inspect "$c" --format '{{range .State.Health.Log}}{{.Start}} rc={{.ExitCode}}; {{end}}' 2>/dev/null)
        [ -n "$hl" ] && printf 'health_log\tpodman:%s\t%s\n' "$c" "$hl"
        # When this container instance started: a restart of a unit that
        # requires another would show here (Sub-plan 3 close-out, M2).
        sa=$(ctl inspect "$c" --format '{{.State.StartedAt}}' 2>/dev/null) && printf 'started\tpodman:%s\t%s\n' "$c" "$sa"
      done
    else
      launchctl list | awk '/nice-dns/ { printf "health\tlaunchd:%s\tlast_exit=%s\tpid=%s\n", $3, $2, $1 }'
    fi
    if t=$(health_tool) && "$t" help 2>/dev/null | grep -q '^  observe '; then
      # A controller-era tool: `run` is an active controller pass (it may
      # switch a route or repair the runtime), so only the read-only
      # observe runs, judged as `run` would log it.
      o=$("$t" observe </dev/null 2>/dev/null); rc=$?
      last=$(printf '%s\n' "$o" | awk -F '\t' '$1 == "obs" && $3 == "unhealthy" { printf "%s%s", s, $2; s = " " }
        $1 == "obs" && $2 ~ /^route:/ { r++; if ($3 == "healthy") ok++ }
        END { if (r > 0 && ok == 0) printf "%schain-resolves", s }')
      if [ "$rc" -eq 0 ] && [ -z "$last" ]; then v=pass; else v=fail; [ "$rc" -eq 0 ] && rc=1; fi
      printf 'health\tnice-dns-health\t%s\trc=%s failed=[%s]\n' "$v" "$rc" "$last"
    elif t=$(health_tool); then
      # A huge grace keeps the tool's own recovery path unreachable: it logs only.
      NICE_DNS_RESTART_GRACE_SECS=2147483647 "$t" run </dev/null >/dev/null 2>&1; rc=$?
      last=$(tail -n 1 "$HEALTH_LOG" 2>/dev/null | sed -n 's/.*\(\[[^]]*\]\).*/\1/p')
      if [ "$rc" -eq 0 ]; then v=pass; else v=fail; fi
      printf 'health\tnice-dns-health\t%s\trc=%s failed=%s\n' "$v" "$rc" "${last:--}"
    else
      printf 'health\tnice-dns-health\tabsent\t-\n'
    fi ;;
  collect)
    {
      printf 'target_id\t%s\nplatform\t%s\nproxy\t%s\n' "$NICE_DNS_ID_TARGET_ID" "$NICE_DNS_ID_PLATFORM" "$NICE_DNS_ID_PROXY"
      printf 'pihole\t%s\nsource_rev\t%s\nimages\t%s\n' "$NICE_DNS_ID_PIHOLE" "$NICE_DNS_ID_SOURCE_REV" "$NICE_DNS_ID_IMAGES"
    } >"$ND_BUNDLE/identity.tsv"
    RUN_ID="$NICE_DNS_RUN_ID" bash "$ND_BUNDLE/tests/live/collect.sh" --resolver "$RESOLVER" \
      --workload "$NICE_DNS_WORKLOAD" --count "$NICE_DNS_COUNT" --timeout-ms "$NICE_DNS_TIMEOUT_MS" \
      --pause-ms "$NICE_DNS_PAUSE_MS" --identity "$ND_BUNDLE/identity.tsv" \
      --out "$ND_BUNDLE/samples.tsv" </dev/null >&2
    rc=$?
    [ -f "$ND_BUNDLE/samples.tsv" ] && cat "$ND_BUNDLE/samples.tsv"
    exit $rc ;;
  freeze-upstream)
    running "$NICE_DNS_COMPONENT" || { echo "$NICE_DNS_COMPONENT is not running" >&2; exit 1; }
    [ "$(ctl_exec "$NICE_DNS_COMPONENT" pgrep -x tor | grep -c .)" = 1 ] || { echo "expected exactly one tor process" >&2; exit 1; }
    # Dead-man thaw, started before the freeze: SIGCONT after the maximum
    # whatever happens to this session. Harmless if tor is already running.
    nohup sh -c 'sleep "$1"; "$2" exec "$3" pkill -CONT -x tor' nice-dns-freeze-watchdog \
      "$NICE_DNS_FREEZE_MAX" "$C" "$NICE_DNS_COMPONENT" </dev/null >/dev/null 2>&1 &
    ctl_exec "$NICE_DNS_COMPONENT" pkill -STOP -x tor || exit 1
    s=$(tor_states "$NICE_DNS_COMPONENT")
    printf 'tor_state\t%s\n' "$s"
    [ "$s" = T ] ;;
  thaw-upstream)
    ctl_exec "$NICE_DNS_COMPONENT" pkill -CONT -x tor; rc=$?
    pkill -f nice-dns-freeze-watchdog 2>/dev/null
    s=$(tor_states "$NICE_DNS_COMPONENT")
    printf 'tor_state\t%s\n' "$s"
    [ "$rc" -eq 0 ] && [ -n "$s" ] && case " $s " in *" T "*) false ;; *) true ;; esac ;;
  install-cell|uninstall-cell)
    case "$plat/$NICE_DNS_PIHOLE" in
      linux/standard) inst=install-deb.sh ;;
      linux/hardened) inst=install-deb-hardened.sh ;;
      macos/standard) inst=install-mac.sh ;;
      macos/hardened) inst=install-mac-hardened.sh ;;
      *) echo "no installer for $plat/$NICE_DNS_PIHOLE" >&2; exit 2 ;;
    esac
    # A non-login ssh shell lacks Homebrew's bin dir, which the macOS
    # installers need (brew, container); a login shell would have it.
    if [ "$plat" = macos ]; then PATH="/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:$PATH"; export PATH; fi
    [ "$NICE_DNS_ACTION" = uninstall ] || mac_room || exit 2
    w=$(mktemp -d "$HOME/.nice-dns-harness-install.XXXXXX") || exit 1
    trap 'rm -rf "$w"' EXIT
    [ -s "${ND_SOURCE_TGZ:-}" ] || { echo "install without the nice-dns source archive" >&2; exit 2; }
    mkdir "$w/nice-dns" && tar -xzf "$ND_SOURCE_TGZ" -C "$w/nice-dns" || exit 1
    rm -f "$ND_SOURCE_TGZ"
    if [ "$NICE_DNS_PIHOLE" = hardened ]; then
      [ -s "${ND_HARDENED_TGZ:-}" ] || { echo "hardened cell without the pi-hole-hardened archive" >&2; exit 2; }
      mkdir "$w/pi-hole-hardened" && tar -xzf "$ND_HARDENED_TGZ" -C "$w/pi-hole-hardened" || exit 1
      rm -f "$ND_HARDENED_TGZ"
      printf 'hardened_sha\t%s\n' "$NICE_DNS_HARDENED_SHA"
    fi
    printf '%s_cell\t%s/%s\ninstaller\t%s\nsource_sha\t%s\nstarted_utc\t%s\n' "$NICE_DNS_ACTION" "$NICE_DNS_PROXY" "$NICE_DNS_PIHOLE" "$inst" \
      "$NICE_DNS_SOURCE_SHA" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    if [ "$NICE_DNS_ACTION" = uninstall ]; then
      (cd "$w/nice-dns" && bash "./$inst" uninstall) </dev/null 2>&1
    else
      (cd "$w/nice-dns" && bash "./$inst" "$NICE_DNS_PROXY" main) </dev/null 2>&1
    fi
    rc=$?
    # Apple's runtime keeps a guest-side cause (e.g. `internalError: "mount"`,
    # live 2026-09-28, mac) only in its own log, and keeps only its errors
    # past a few minutes: take it with the failure, or it is gone.
    if [ "$rc" -ne 0 ] && [ "$plat" = macos ]; then
      echo "── runtime state after the failure ──"
      container ls -a 2>&1; container volume list 2>&1
      container system logs --last 10m 2>&1 | tail -n 400
    fi
    printf 'finished_utc\t%s\ninstaller_exit\t%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$rc"
    exit $rc ;;
  route-report|route-apply|route-onion)
    [ "$plat" = macos ] && homebrew_path
    if [ "$plat" = macos ]; then hd="$HOME/Library/Application Support/nice-dns-health"
    else hd="${XDG_DATA_HOME:-$HOME/.local/share}/nice-dns-health"; fi
    b=$(awk -F '\t' 'NR == 1 && $0 != "schema\tnice-dns-health-install/1" { exit } $1 == "bundle" { print $2; exit }' "$hd/install.tsv" 2>/dev/null)
    case "$b" in ''|*[!A-Za-z0-9._-]*) echo "no installed controller bundle" >&2; exit 2 ;; esac
    [ -f "$hd/bundles/$b/lib/recovery.sh" ] || { echo "the installed bundle $b has no lib/recovery.sh" >&2; exit 2; }
    if [ "$NICE_DNS_OP" = route-report ]; then
      identity
      printf 'section\troute\nbundle\t%s\n' "$b"
      # shellcheck disable=SC2016  # expanded by the bundle's bash
      ND_PLATFORM="$plat" ND_ROUTES_FILE="$hd/bundles/$b/routes/providers.tsv" bash -c '
        . "$1/lib/recovery.sh" || exit 2
        d=$(nd_platform_route_dir)
        printf "dir_mode\t%s\n" "$(stat -c %a "$d" 2>/dev/null || stat -f %Lp "$d" 2>/dev/null || echo absent)"
        printf "include\t%s\n" "$(sed -n "s/.*\"\(route=[^\"]*\)\".*/\1/p" "$d/forward-route.conf" 2>/dev/null)"
        printf "forwarder\t%s\n" "$(awk "\$1 == \"forward-addr:\" { print \$2 }" "$d/forward-route.conf" 2>/dev/null)"
        printf "desired\t%s\n" "$(awk -F "\t" "\$1 == \"route\" || \$1 == \"generation\" { printf \"%s%s\", s, \$2; s = \" \" }" "$d/desired.tsv" 2>/dev/null)"
        h=$(cat "$d/forward-route.conf" 2>/dev/null | cksum)
        c=$(nd_platform_unbound_exec cat /etc/unbound/route/forward-route.conf 2>/dev/null </dev/null | cksum)
        if [ -s "$d/forward-route.conf" ] && [ "$h" = "$c" ]; then printf "container_sees_host\tyes\n"; else printf "container_sees_host\tno\n"; fi
        if rb=$(route_readback </dev/null); then printf "readback\t%s\n" "$(printf "%s" "$rb" | tr "\t" " ")"; else printf "readback\tnone\n"; fi
        nd_platform_unbound_exec /usr/local/bin/nice-dns-unbound-start probe-route . >/dev/null 2>&1 </dev/null
        printf "probe_route\t%s\n" "$?"
      ' _ "$hd/bundles/$b" </dev/null
      n=$(od -An -N8 -tx1 /dev/urandom | tr -d ' \n')
      st=$(dig "@${RESOLVER%#*}" -p "${RESOLVER#*#}" +time=10 +tries=1 "nd-route-$n.example.com" A 2>/dev/null | awk '/status:/ { sub(/,.*/, "", $6); print $6; exit }')
      printf 'client_fresh\t%s\n' "${st:-timeout}"
    elif [ "$NICE_DNS_OP" = route-onion ]; then
      # shellcheck disable=SC2016
      ND_PLATFORM="$plat" ND_ROUTES_FILE="$hd/bundles/$b/routes/providers.tsv" bash -c '
        . "$1/lib/recovery.sh" || exit 2
        nd_state_init || exit 2
        tok=$(nd_state_lock) || { echo "the controller state lock is held" >&2; exit 5; }
        d=$(nd_platform_route_dir)
        g=0
        _nd_route_read_desired "$d" 2>/dev/null && [ -n "$_ND_DES_GEN" ] && g=$_ND_DES_GEN
        i=$(_nd_route_file_info "$d/forward-route.conf" 2>/dev/null | cut -f2)
        case "$i" in ""|*[!0-9]*) ;; *) [ "$i" -gt "$g" ] && g=$i ;; esac
        g=$((g + 1)); rc=1
        if _nd_route_resolve cloudflare-onion >/dev/null \
          && _nd_route_write_desired "$d" cloudflare-onion "$g" \
          && (umask 022 && _nd_route_render cloudflare-onion "$g" "$_ND_FWD" >"$d/.forward-route.conf.staged") \
          && chmod 0644 "$d/.forward-route.conf.staged" && mv -f "$d/.forward-route.conf.staged" "$d/forward-route.conf"; then rc=0; fi
        nd_state_unlock "$tok"
        [ "$rc" = 0 ] && printf "result\tapplied\nroute\tcloudflare-onion\ngeneration\t%s\n" "$g"
        exit $rc
      ' _ "$hd/bundles/$b" </dev/null
      exit $?
    else
      # shellcheck disable=SC2016
      ND_PLATFORM="$plat" ND_ROUTES_FILE="$hd/bundles/$b/routes/providers.tsv" bash -c '
        . "$1/lib/recovery.sh" || exit 2
        nd_state_init || exit 2
        tok=$(nd_state_lock) || { echo "the controller state lock is held" >&2; exit 5; }
        g=0
        _nd_route_read_desired "$(nd_platform_route_dir)" 2>/dev/null && [ -n "$_ND_DES_GEN" ] && g=$_ND_DES_GEN
        s=$(nd_state_load 2>/dev/null | awk -F "\t" "\$1 == \"generation\" { print \$2; exit }")
        case "$s" in ""|*[!0-9]*) ;; *) [ "$s" -gt "$g" ] && g=$s ;; esac
        ND_RECOVERY_LOCK_TOKEN="$tok" apply_route "$2" $((g + 1)) </dev/null; rc=$?
        nd_state_unlock "$tok"
        exit $rc
      ' _ "$hd/bundles/$b" "$NICE_DNS_ROUTE" </dev/null
      exit $?
    fi ;;
  arm-prepare|arm-set)
    [ "$plat" = macos ] && homebrew_path
    c="$NICE_DNS_COMPONENT"
    # The stack's image names (what its quadlets and launch paths run) and
    # the arm tags (DEC-012).
    if [ "$plat" = macos ]; then u_ref=unbound:latest p_ref=pi-hole:latest; else u_ref=localhost/unbound:latest p_ref=localhost/pi-hole:latest; fi
    x_ref="docker.io/sureserver/$c:latest"
    arm_ref() { printf 'nd-arm-%s:%s\n' "$1" "$2"; }
    img_id() {
      if [ "$plat" = macos ]; then ctl image inspect "$1" 2>/dev/null | tr ',' '\n' | sed -n 's/.*"digest"[[:space:]]*:[[:space:]]*"\(sha256:[0-9a-f]*\)".*/\1/p' | head -1
      else ctl image inspect --format '{{.Id}}' "$1" 2>/dev/null; fi
    }
    # ready [tries]: Pi-hole answers within tries x (up to 10 s); default 60.
    ready() {
      i=0
      while [ "$i" -lt "${1:-60}" ]; do
        dig "@${RESOLVER%#*}" -p "${RESOLVER#*#}" +time=5 +tries=1 +short example.com A 2>/dev/null | grep -Eq '^[0-9.]+$' && return 0
        i=$((i + 1)); sleep 5
      done
      return 1
    }
    # first_answer <t0 epoch s> <cap s>: DEC-014's sample. A fresh name every
    # 0.5 s, each waiting 5 s as collect.sh's queries do (a shorter wait would
    # abandon a slow first answer through Tor); the first answered one ends it.
    # Prints: first_answer, t0 UTC, elapsed us (to the arrival, +-50 ms),
    # outcome, rcode, qname, cap ms. No answer within the cap is a timeout.
    first_answer() {
      perl -MTime::HiRes=time,sleep -MPOSIX=WNOHANG,strftime -e '
        my ($t0, $cap, $addr, $port) = @ARGV;
        my (%kid, $best, $q, $rc);
        my $next = time;
        while (1) {
          my $now = time;
          if ($now >= $next && $now - $t0 < $cap) {
            my $n = join("", map { sprintf "%02x", int(rand(256)) } 1 .. 8) . ".example.com";
            pipe(my $r, my $w) or die "pipe: $!";
            my $pid = fork(); die "fork: $!" unless defined $pid;
            if (!$pid) {
              close $r; open(STDOUT, ">&", $w); open(STDERR, ">", "/dev/null");
              exec("dig", "\@$addr", "-p", $port, "+time=5", "+tries=1", "+noall", "+comments", $n, "A"); exit 127;
            }
            close $w; $kid{$pid} = [$r, $n]; $next = $now + 0.5;
          }
          while ((my $pid = waitpid(-1, WNOHANG)) > 0) {
            my $k = delete $kid{$pid} or next;
            my $end = time; my $fh = $k->[0]; local $/; my $out = <$fh> // ""; close $fh;
            my ($s) = $out =~ /status: ([A-Z]+)/;
            if (defined $s && ($s eq "NOERROR" || $s eq "NXDOMAIN") && (!defined $best || $end < $best)) { ($best, $q, $rc) = ($end, $k->[1], $s); }
          }
          last if defined $best || (time - $t0 >= $cap && !%kid);
          sleep 0.05;
        }
        kill "TERM", keys %kid;
        my $iso = strftime("%Y-%m-%dT%H:%M:%S", gmtime($t0)) . sprintf(".%06dZ", int(($t0 - int($t0)) * 1e6));
        if (defined $best) {
          printf "first_answer\t%s\t%d\t%s\t%s\t%s\t%d\n", $iso, int(($best - $t0) * 1e6), $rc eq "NOERROR" ? "ok" : "nxdomain", $rc, $q, $cap * 1000;
          exit 0;
        }
        printf "first_answer\t%s\t%d\ttimeout\t-\t-\t%d\n", $iso, $cap * 1e6, $cap * 1000;
        exit 1;' "$1" "$2" "${RESOLVER%#*}" "${RESOLVER#*#}"
    }
    restart_stack() {
      if [ "$plat" = macos ]; then
        for x in pi-hole unbound "$c"; do ctl stop "$x" >/dev/null 2>&1; ctl rm "$x" >/dev/null 2>&1; done
        launchctl kickstart -k "gui/$(id -u)/org.nice-dns.start-container" || return 1
      else
        systemctl --user restart nice-dns-pod.service || return 1
      fi
    }
    running "$c" || { echo "the stack does not run $c" >&2; exit 2; }
    if [ "$NICE_DNS_OP" = arm-prepare ]; then
      mac_room || exit 2
      w=$(mktemp -d "$HOME/.nice-dns-harness-arm.XXXXXX") || exit 1
      trap 'rm -rf "$w"' EXIT
      [ -s "${ND_SOURCE_TGZ:-}" ] || { echo "arm-prepare without the nice-dns source archive" >&2; exit 2; }
      mkdir "$w/nice-dns" && tar -xzf "$ND_SOURCE_TGZ" -C "$w/nice-dns" || exit 1
      rm -f "$ND_SOURCE_TGZ"
      # candidate: what runs now
      # The candidate is what runs, so never while the stack runs the baseline arm.
      if [ -n "$(img_id "$(arm_ref unbound baseline)")" ] && [ "$(img_id "$(arm_ref unbound baseline)")" = "$(img_id "$u_ref")" ]; then
        echo "the stack runs the baseline arm: arm-set candidate first" >&2; exit 2
      fi
      ctl image tag "$u_ref" "$(arm_ref unbound candidate)" && ctl image tag "$p_ref" "$(arm_ref pi-hole candidate)" \
        && ctl image tag "$x_ref" "$(arm_ref "$c" candidate)" || exit 1
      # baseline proxy, by its published tag
      if [ "$plat" = macos ]; then ctl image pull "docker.io/sureserver/$c:$NICE_DNS_PROXY_TAG" >/dev/null || exit 1
      else ctl pull -q "docker.io/sureserver/$c:$NICE_DNS_PROXY_TAG" >/dev/null || exit 1; fi
      ctl image tag "docker.io/sureserver/$c:$NICE_DNS_PROXY_TAG" "$(arm_ref "$c" baseline)" || exit 1
      # The bases b85bc9b built on when the baseline ran (2026-09-23), pinned
      # on both platforms: hardened-unbound v1.3.4 (:latest from 2026-09-16
      # to v1.4.0 on 2026-09-27, which stopped shipping the remote-control
      # keys b85bc9b's unbound.conf needs) and pihole/pihole 2026.09.0
      # (:latest since 2026-09-19). Pulled while the stack runs (a pull does
      # not wedge dnsnet; a build does) and named locally, so no build step
      # reaches a registry (on macOS host DNS then points at the stopped stack).
      if [ "$plat" = macos ]; then ub_base=nd-arm-unbound-base:baseline ph_base=nd-arm-pihole-base:baseline
      else ub_base=localhost/nd-arm-unbound-base:baseline ph_base=localhost/nd-arm-pihole-base:baseline; fi
      for pair in "docker.io/sureserver/hardened-unbound:v1.3.4 $ub_base" "docker.io/pihole/pihole:2026.09.0 $ph_base"; do
        src="${pair% *}" dst="${pair#* }"
        if [ "$plat" = macos ]; then ctl image pull "$src" >/dev/null || exit 1; else ctl pull -q "$src" >/dev/null || exit 1; fi
        ctl image tag "$src" "$dst" || exit 1
        printf 'base\t%s\t%s\n' "$src" "$(img_id "$src")"
      done
      sed -e "s|^FROM sureserver/hardened-unbound:latest\$|FROM $ub_base|" "$w/nice-dns/unbound/Containerfile" >"$w/uc" && mv "$w/uc" "$w/nice-dns/unbound/Containerfile"
      sed -e "s|^FROM pihole/pihole:latest\$|FROM $ph_base|" "$w/nice-dns/pihole/Containerfile" >"$w/pc" && mv "$w/pc" "$w/nice-dns/pihole/Containerfile"
      grep -qx "FROM $ub_base" "$w/nice-dns/unbound/Containerfile" && grep -qx "FROM $ph_base" "$w/nice-dns/pihole/Containerfile" \
        || { echo "the baseline Containerfiles were not pinned as expected" >&2; exit 1; }
      if [ "$plat" = macos ]; then
        # b85bc9b's own macOS rewrites (its install-mac.sh:221-224).
        sed -i '' -e 's|^    interface: 127\.0\.0\.1$|    interface: 0.0.0.0|' \
          -e 's|^    access-control: 127\.0\.0\.0/8 allow$|    access-control: 127.0.0.0/8 allow\
    access-control: 172.31.240.248/29 allow|' \
          -e 's|^    forward-addr: 127\.0\.0\.1@853#tor\.cloudflare-dns\.com$|    forward-addr: 172.31.240.252@853#tor.cloudflare-dns.com|' \
          "$w/nice-dns/unbound/etc/unbound.conf"
        grep -q '172.31.240.252@853' "$w/nice-dns/unbound/etc/unbound.conf" || { echo "the baseline tree was not rewritten as expected" >&2; exit 1; }
        for x in pi-hole unbound "$c"; do ctl stop "$x" >/dev/null 2>&1; done
        ctl builder start >/dev/null 2>&1
        rc=0
        ctl build --dns 1.1.1.1 --no-cache -t "$(arm_ref unbound baseline)" "$w/nice-dns/unbound" >"$w/build.log" 2>&1 \
          && ctl build --dns 1.1.1.1 --no-cache -t "$(arm_ref pi-hole baseline)" "$w/nice-dns/pihole" >>"$w/build.log" 2>&1 || rc=1
        [ "$rc" = 0 ] || tail -n 20 "$w/build.log" >&2
        # A fresh datapath before the stack returns (lib/install.sh
        # nd_install_macos_fresh_datapath), whether or not the build worked.
        ctl builder stop >/dev/null 2>&1; ctl system stop >/dev/null 2>&1; sleep 8
        { yes 2>/dev/null || true; } | ctl system start >/dev/null 2>&1
        i=0; until ctl system status >/dev/null 2>&1; do i=$((i + 1)); [ "$i" -lt 10 ] || break; sleep 4; done
        # 15 min: after a runtime restart the agent waits 300 s for Tor and 150 s
        # for the chain before its one rebuild (live mac 2026-09-28: Tor did not
        # bootstrap on the reused bridges; the rebuild bootstrapped in 52 s, just
        # after a 10-minute wait had given up).
        restart_stack; ready 90 || { echo "the stack did not answer after the baseline build" >&2; exit 1; }
        [ "$rc" = 0 ] || exit 1
      else
        ctl build -q -t "$(arm_ref unbound baseline)" "$w/nice-dns/unbound" >/dev/null 2>"$w/build.log" \
          && ctl build -q -t "$(arm_ref pi-hole baseline)" "$w/nice-dns/pihole" >/dev/null 2>>"$w/build.log" \
          || { tail -n 20 "$w/build.log" >&2; exit 1; }
      fi
      for x in unbound pi-hole "$c"; do for a in baseline candidate; do printf 'arm\t%s\t%s\t%s\n' "$a" "$x" "$(img_id "$(arm_ref "$x" "$a")")"; done; done
      exit 0
    fi
    # arm-set
    a="$NICE_DNS_MODE"
    for x in unbound pi-hole "$c"; do [ -n "$(img_id "$(arm_ref "$x" "$a")")" ] || { echo "no $a image for $x: run arm-prepare first" >&2; exit 2; }; done
    ctl image tag "$(arm_ref unbound "$a")" "$u_ref" && ctl image tag "$(arm_ref pi-hole "$a")" "$p_ref" \
      && ctl image tag "$(arm_ref "$c" "$a")" "$x_ref" || exit 1
    # DEC-014: timed from the restart command, both arms through this path.
    t0=$(perl -MTime::HiRes=time -e 'printf "%.6f", time')
    restart_stack || exit 1
    printf 'resolver\t%s\n' "$RESOLVER"
    fa_rc=0; first_answer "$t0" 600 || fa_rc=1
    # The proxy's own readiness line for this start (Sub-plan 5 Task 1.4, fix B:
    # "bootstrapped after N s, a stream works after M s (exit|onion)"); empty
    # for an image from before it.
    printf 'proxy_ready\t%s\n' "$(ctl logs "$c" 2>&1 | grep 'a stream works after' | tail -n 1)"
    if [ "$fa_rc" != 0 ]; then
      echo "the stack did not answer on the $a arm" >&2
      # Never leave the host on a dead arm: the candidate (the deployment
      # the installer made) comes back.
      if [ "$a" = baseline ]; then
        ctl image tag "$(arm_ref unbound candidate)" "$u_ref" && ctl image tag "$(arm_ref pi-hole candidate)" "$p_ref" \
          && ctl image tag "$(arm_ref "$c" candidate)" "$x_ref" && restart_stack && ready \
          && echo "back on the candidate arm" >&2 || echo "the candidate arm did not come back either" >&2
      fi
      exit 1
    fi
    # A container missing here is the macOS agent rebuilding the stack in its
    # own recovery (live 2026-09-29: first answer after 548 s, one second
    # before the agent's rebuild), from the same image names: wait until it
    # answers again and look again, up to 3 times. A container running
    # another image is the wrong arm and fails at once.
    try=1
    while :; do
      bad=0 gone=0 out=''
      for x in unbound pi-hole "$c"; do
        want=$(img_id "$(arm_ref "$x" "$a")"); got=$(image_of "$x")
        out="$out$(printf 'runs\t%s\t%s\t%s' "$x" "$a" "$got")
"
        [ -n "$got" ] || gone=1
        [ -z "$got" ] || [ "${got#sha256:}" = "${want#sha256:}" ] || { echo "$x runs $got, not the $a image $want" >&2; bad=1; }
      done
      if [ "$bad" = 0 ] && [ "$gone" = 1 ] && [ "$try" -lt 3 ]; then
        echo "a container is missing (the agent rebuilding?); waiting for the stack (try $try)" >&2
        try=$((try + 1)); ready 60 || true; continue
      fi
      printf '%s' "$out"
      [ "$gone" = 0 ] || { echo "a container of the $a arm is not running" >&2; bad=1; }
      exit $bad
    done ;;
  lifecycle-report)
    [ "$plat" = macos ] && homebrew_path
    if [ "$plat" = macos ]; then
      sd="$HOME/Library/Application Support/nice-dns-install"; hd="$HOME/Library/Application Support/nice-dns-health"
      base=http://172.31.240.250
    else
      sd="${XDG_STATE_HOME:-$HOME/.local/state}/nice-dns-install"; hd="${XDG_DATA_HOME:-$HOME/.local/share}/nice-dns-health"
      base=http://127.0.0.1:8880
    fi
    pwf="${XDG_STATE_HOME:-$HOME/.local/state}/nice-dns/secrets/pihole/pihole_webpassword"
    {
      identity
      printf 'now\t%s\n' "$(date +%s)"
      printf 'section\tdns\n'; dns_owner
      # Through the host's own resolver, the health probes' controlled name.
      printf 'section\tresolution\n'
      if [ "$plat" = macos ]; then
        if dscacheutil -q host -a name cloudflare.com 2>/dev/null | grep -q '^ip_address'; then printf 'resolves\tyes\n'; else printf 'resolves\tno\n'; fi
      elif getent ahostsv4 cloudflare.com >/dev/null 2>&1; then printf 'resolves\tyes\n'; else printf 'resolves\tno\n'; fi
      printf 'section\tgeneration\n'
      g=$(cat "$sd/current" 2>/dev/null)
      printf 'current\t%s\n' "${g:-none}"
      [ -n "$g" ] && awk -F '\t' '$1 ~ /^(generation|entrypoint|pihole|variant|source_commit|previous|rollback|replaces|image|credential|status)$/' "$sd/generations/$g/prepare.tsv" 2>/dev/null
      printf 'section\trunning\n'
      for c in pi-hole unbound tor-haproxy tor-socat; do
        running "$c" && printf 'running\t%s\t%s\n' "$c" "$(image_of "$c")"
      done
      printf 'section\tcontroller\n'; cat "$hd/install.tsv" 2>/dev/null
      printf 'section\tvolumes\n'
      if [ "$plat" = macos ]; then ctl volume list 2>/dev/null | awk 'NR > 1 && $1 ~ /^nice-dns-/ { print "volume\t" $1 }'
      else ctl volume ls --format '{{.Name}}' 2>/dev/null | awk '/^nice-dns-/ { print "volume\t" $0 }'; fi
      printf 'section\tstate\n'
      for c in tor-haproxy tor-socat; do
        running "$c" || continue
        printf 'tor_marker\t%s\t%s\n' "$c" "$(ctl_exec "$c" cat /app/data/.nd-live-marker 2>/dev/null)"
        printf 'tor_state_file\t%s\t%s\n' "$c" "$(ctl_exec "$c" sh -c 'test -s /app/data/tor/state && echo present || echo absent' 2>/dev/null)"
      done
      if running unbound; then
        printf 'anchor_marker\t%s\n' "$(ctl_exec unbound cat /var/lib/unbound/.nd-live-marker 2>/dev/null)"
        printf 'anchor_file\t%s\n' "$(ctl_exec unbound sh -c 'test -s /var/lib/unbound/root.key && echo present || echo absent' 2>/dev/null)"
      fi
      if running pi-hole; then
        printf 'lists_seed\t%s\t%s\n' "$(ctl_exec pi-hole cat /var/lib/nice-dns-pihole/seed-id 2>/dev/null)" "$(ctl_exec pi-hole cat /usr/share/nice-dns/pihole/seed-id 2>/dev/null)"
        printf 'lists_marker_rules\t%s\n' "$(ctl_exec pi-hole pihole-FTL sqlite3 -ni /var/lib/nice-dns-pihole/gravity.db "SELECT group_concat(domain) FROM domainlist WHERE domain LIKE 'nd-live-%.example'" 2>/dev/null)"
      fi
      printf 'section\tadmin\n'
      printf 'admin_secret_mode\t%s\n' "$(ls -ln "$pwf" 2>/dev/null | cut -c1-10)"
      printf 'anonymous\t%s\n' "$(curl -s -m 5 -o /dev/null -w '%{http_code}' "$base/api/stats/summary")"
      printf 'wrong\t%s\n' "$(curl -s -m 10 --data '{"password":"nd-live-wrong"}' "$base/api/auth" | grep -o '"valid":[a-z]*')"
      if [ -s "$pwf" ]; then
        r=$({ printf '{"password":"'; tr -d '\n' <"$pwf"; printf '"}'; } | curl -s -m 10 --data @- "$base/api/auth")
        printf 'right\t%s\n' "$(printf '%s' "$r" | grep -o '"valid":[a-z]*')"
        sid=$(printf '%s' "$r" | sed -n 's/.*"sid":"\([^"]*\)".*/\1/p')
        [ -n "$sid" ] && curl -s -m 5 -o /dev/null -X DELETE -H "X-FTL-SID: $sid" "$base/api/auth"
      else
        printf 'right\tno-secret-file\n'
      fi
      printf 'section\tlisteners\n'
      if [ "$plat" = linux ]; then ss -H -lntu 2>/dev/null | awk '$5 ~ /:53$/ { print "listen\t" $1 "\t" $5 }'; fi
      printf 'section\tprivilege\n'
      if [ "$plat" = macos ]; then sudo -n cat /etc/sudoers.d/start-container 2>/dev/null | grep -v '^[[:space:]]*#' | grep . | sed 's/^/sudoers\t/'
      else for f in /etc/sudoers.d/*; do case "$f" in *nice*|*start-container*) printf 'sudoers\t%s\n' "$f" ;; esac; done; fi
      printf 'section\tschedules\n'
      if [ "$plat" = macos ]; then launchctl list | awk '$3 ~ /^org\.nice-dns\./ { print "agent\t" $3 }'
      else systemctl --user list-unit-files --no-legend 'nice-dns*' 2>/dev/null | awk '{ print "unit\t" $1 "\t" $2 }'; fi
    } | redact ;;
  watch-dns)
    end=$(( $(date +%s) + NICE_DNS_WATCH_SECS ))
    while [ "$(date +%s)" -lt "$end" ]; do
      if [ "$plat" = macos ]; then
        s=$(networksetup -listallnetworkservices | tail -n +2 | { grep -v '^\*' || true; } | while IFS= read -r svc; do
              printf '%s=%s;' "$svc" "$(networksetup -getdnsservers "$svc" | tr '\n' ' ' | sed 's/ $//')"; done)
      else
        s="$(readlink /etc/resolv.conf 2>/dev/null || echo file);$(awk '/^nameserver/ { printf "%s ", $2 }' /etc/resolv.conf 2>/dev/null)"
      fi
      printf '%s\t%s\n' "$(date +%s)" "$s" || exit 0
      sleep 2
    done ;;
  mark-state)
    [ "$plat" = macos ] && homebrew_path
    m="nd-live-$NICE_DNS_RUN_ID"
    rc=0
    for c in tor-haproxy tor-socat; do
      running "$c" || continue
      ctl_exec "$c" sh -c "printf '%s\n' '$m' >/app/data/.nd-live-marker" && printf 'marked\t%s\n' "$c" || rc=1
    done
    if running unbound; then ctl_exec --user unbound unbound sh -c "printf '%s\n' '$m' >/var/lib/unbound/.nd-live-marker" && printf 'marked\tunbound\n' || rc=1; fi
    if [ "$plat" = macos ]; then base=http://172.31.240.250; else base=http://127.0.0.1:8880; fi
    pwf="${XDG_STATE_HOME:-$HOME/.local/state}/nice-dns/secrets/pihole/pihole_webpassword"
    r=$({ printf '{"password":"'; tr -d '\n' <"$pwf"; printf '"}'; } | curl -s -m 10 --data @- "$base/api/auth")
    sid=$(printf '%s' "$r" | sed -n 's/.*"sid":"\([^"]*\)".*/\1/p')
    if [ -n "$sid" ]; then
      a=$(curl -s -m 10 -H "X-FTL-SID: $sid" --data "{\"domain\":\"$m.example\",\"comment\":\"nice-dns live marker\"}" "$base/api/domains/allow/exact")
      curl -s -m 5 -o /dev/null -X DELETE -H "X-FTL-SID: $sid" "$base/api/auth"
      case "$a" in *'"errors":[]'*) printf 'marked\tpi-hole-lists\n' ;; *) echo "Pi-hole refused the marker rule" >&2; rc=1 ;; esac
    else
      echo "no admin session" >&2; rc=1
    fi
    exit $rc ;;
  quiesce-agents)
    if [ "$plat" = macos ]; then
      for l in org.nice-dns.health org.nice-dns.bridge-eval org.nice-dns.health-bridges; do
        if launchctl list "$l" >/dev/null 2>&1; then
          launchctl bootout "gui/$(id -u)/$l"; printf 'quiesced\t%s\trc=%s\n' "$l" "$?"
        else printf 'absent\t%s\n' "$l"; fi
      done
      launchctl list | awk '$3 ~ /^org\.nice-dns\./ { printf "loaded\t%s\n", $3 }'
    else
      for u in nice-dns-health.timer nice-dns-health-bridges.timer; do
        if systemctl --user is-active --quiet "$u"; then
          systemctl --user stop "$u"; printf 'quiesced\t%s\trc=%s\n' "$u" "$?"
        else printf 'absent\t%s\n' "$u"; fi
      done
      systemctl --user list-units --plain --no-legend --all 'nice-dns*' | awk '{ printf "unit\t%s\t%s\n", $1, $4 }'
    fi ;;
  build-proxy)
    c="$NICE_DNS_COMPONENT"
    [ "$plat" = macos ] && { homebrew_path; C=$(command -v container); }
    [ -s "${ND_PROXY_TGZ:-}" ] || { echo "build without the proxy source archive" >&2; exit 2; }
    cand="nice-dns-candidate/$c:$(printf '%s' "$NICE_DNS_SOURCE_SHA" | cut -c1-12)"
    [ "$plat" = linux ] && cand="localhost/$cand"
    pub="docker.io/sureserver/$c:latest"
    if [ "$plat" = macos ]; then
      printf 'previous\t%s\t%s\n' "$pub" "$(ctl image inspect "$pub" 2>/dev/null | tr ',' '\n' | sed -n 's/.*"digest"[[:space:]]*:[[:space:]]*"\(sha256:[0-9a-f]*\)".*/\1/p' | head -1)"
      have() { ctl image inspect "$cand" >/dev/null 2>&1; }
    else
      printf 'previous\t%s\t%s\n' "$pub" "$(podman image inspect "$pub" --format '{{.Id}}' 2>/dev/null)"
      have() { podman image exists "$cand"; }
    fi
    if have; then
      printf 'build\t%s\tcached\n' "$cand"
    else
      w=$(mktemp -d "$HOME/.nice-dns-harness-build.XXXXXX") || exit 1
      trap 'rm -rf "$w"' EXIT
      tar -xzf "$ND_PROXY_TGZ" -C "$w" || exit 1
      rm -f "$ND_PROXY_TGZ"
      if [ "$plat" = macos ]; then
        # Apple's builder runs on the default network, and starting it wedges
        # dnsnet and with it the Mac's DNS (debug-monitor, 2026-09-24 and
        # 2026-09-25). So it gets its own resolver, a declared bootstrap
        # exception (PRIV-BOOTSTRAP-DECLARED: image pulls, never client
        # queries), and is stopped afterwards; recreate-proxy's
        # start-container run repairs the datapath.
        # The host's image service fetches the base images, and the wedge
        # takes the host's DNS too: pull them first, while it answers.
        : >"$w.log"
        for im in $(awk '$1 == "FROM" { for (i = 2; i <= NF; i++) if ($i !~ /^--/) { print $i; break } }' "$w/Dockerfile" | sort -u); do
          case "$im" in */*) ;; *) im="docker.io/library/$im" ;; esac
          ctl image pull "$im" </dev/null >>"$w.log" 2>&1 || { tail -n 3 "$w.log"; echo "pull of $im failed" >&2; exit 1; }
        done
        ctl builder stop >/dev/null 2>&1
        ctl builder start --dns 1.1.1.1 </dev/null >>"$w.log" 2>&1
        (cd "$w" && ctl build --progress plain -t "$cand" .) </dev/null >>"$w.log" 2>&1
        rc=$?
        ctl builder stop >/dev/null 2>&1
        printf 'builder\tstopped\n'
      else
        podman build --format docker -t "$cand" "$w" </dev/null >"$w.log" 2>&1
        rc=$?
      fi
      tail -n 5 "$w.log"; rm -f "$w.log"
      [ "$rc" -eq 0 ] || { echo "build of $cand failed" >&2; exit 1; }
      printf 'build\t%s\tbuilt\n' "$cand"
    fi
    if [ "$plat" = macos ]; then
      ctl image tag "$cand" "$pub" || exit 1
      printf 'candidate\t%s\t%s\n' "$cand" "$(ctl image inspect "$pub" 2>/dev/null | tr ',' '\n' | sed -n 's/.*"digest"[[:space:]]*:[[:space:]]*"\(sha256:[0-9a-f]*\)".*/\1/p' | head -1)"
    else
      podman tag "$cand" "$pub" || exit 1
      printf 'candidate\t%s\t%s\n' "$cand" "$(podman image inspect "$pub" --format '{{.Id}}')"
    fi ;;
  recreate-proxy)
    c="$NICE_DNS_COMPONENT"
    [ "$plat" = macos ] && homebrew_path
    before=$(started "$c")
    printf 'before\t%s\t%s\n' "$c" "${before:--}"
    if [ "$plat" = macos ]; then
      # Removing the proxy leaves the chain broken, so start-container.sh
      # takes its full recreate path (its fast path needs a healthy chain).
      ctl stop "$c" >/dev/null 2>&1; ctl delete "$c" >/dev/null 2>&1
      launchctl kickstart -k "gui/$(id -u)/org.nice-dns.start-container" || exit 1
    else
      systemctl --user restart "$c.service" || exit 1
    fi
    i=0
    while [ "$i" -lt 120 ]; do
      now=$(started "$c")
      if [ -n "$now" ] && [ "$now" != "$before" ]; then
        printf 'after\t%s\t%s\nimage\t%s\t%s\n' "$c" "$now" "$c" "$(image_of "$c")"
        exit 0
      fi
      sleep 5; i=$((i + 1))
    done
    echo "$c did not start again within 600 s" >&2
    exit 1 ;;
  install-controller)
    [ "$plat" = macos ] && homebrew_path
    [ -s "${ND_SOURCE_TGZ:-}" ] || { echo "install without the nice-dns source archive" >&2; exit 2; }
    w=$(mktemp -d "$HOME/.nice-dns-harness-ctl.XXXXXX") || exit 1
    trap 'rm -rf "$w"' EXIT
    tar -xzf "$ND_SOURCE_TGZ" -C "$w" || exit 1
    rm -f "$ND_SOURCE_TGZ"
    chmod -R go-w "$w"
    if [ "$NICE_DNS_MODE" = shadow ]; then bash "$w/health/nice-dns-health" install --shadow </dev/null 2>&1
    else bash "$w/health/nice-dns-health" install </dev/null 2>&1; fi
    rc=$?
    if [ "$plat" = macos ]; then r="$HOME/Library/Application Support/nice-dns-health/install.tsv"
    else r="${XDG_DATA_HOME:-$HOME/.local/share}/nice-dns-health/install.tsv"; fi
    sed 's/^/receipt	/' "$r" 2>/dev/null
    exit $rc ;;
  fault-route|heal-route)
    c="$NICE_DNS_COMPONENT"
    running "$c" || { echo "$c is not running" >&2; exit 1; }
    case "$NICE_DNS_ROUTE" in
      cloudflare-onion) be=route_cloudflare_onion sv=onion port=18531 ;;
      cloudflare-exit) be=route_cloudflare_exit sv='cf1 cf2' port=18532 ;;
      quad9-exit) be=route_quad9_exit sv='q1 q2' port=18533 ;;
      *) echo "unknown route" >&2; exit 2 ;;
    esac
    if [ "$c" = tor-haproxy ]; then
      if [ "$NICE_DNS_OP" = fault-route ]; then verb=disable; else verb=enable; fi
      # Dead-man heal, started before the fault, whatever happens here.
      # (An if block: a backgrounded and-list runs in a subshell which
      # holds ssh's stdout until the timer ends.)
      if [ "$verb" = disable ]; then
        nohup sh -c 'sleep "$1"; shift; exec "$@"' nice-dns-route-watchdog "$NICE_DNS_FREEZE_MAX" \
          "$C" exec "$c" sh -c "for s in $sv; do printf 'enable server $be/%s\\n' \"\$s\" | socat -t 5 - UNIX-CONNECT:/tmp/haproxy.sock; done" </dev/null >/dev/null 2>&1 &
      else
        pkill -f nice-dns-route-watchdog 2>/dev/null
      fi
      for s in $sv; do
        ctl_exec "$c" sh -c 'printf "%s\n" "$1" | socat -t 5 - UNIX-CONNECT:/tmp/haproxy.sock' sh "$verb server $be/$s" || exit 1
      done
      ctl_exec "$c" sh -c 'printf "%s\n" "$1" | socat -t 5 - UNIX-CONNECT:/tmp/haproxy.sock' sh "show servers state $be" |
        awk -v b="$be" '$2 == b { printf "server\t%s/%s\tadmin=%s\n", b, $4, $7 }'
    else
      # The route's listener: the socat whose argv binds the port and whose
      # parent is not a socat (forked children share the argv).
      pid=$(ctl_exec "$c" sh -c 'for p in $(pgrep -x socat); do
          tr "\000" " " </proc/$p/cmdline | grep -q "TCP4-LISTEN:$1," || continue
          pp=$(awk "{ print \$4 }" /proc/$p/stat); [ "$(cat /proc/$pp/comm 2>/dev/null)" = socat ] || echo $p
        done' sh "$port")
      [ "$(printf '%s\n' "$pid" | grep -c '^[0-9][0-9]*$')" = 1 ] || { echo "expected one $port listener, got: $pid" >&2; exit 1; }
      if [ "$NICE_DNS_OP" = fault-route ]; then
        nohup sh -c 'sleep "$1"; "$2" exec "$3" kill -CONT "$4"' nice-dns-route-watchdog "$NICE_DNS_FREEZE_MAX" "$C" "$c" "$pid" </dev/null >/dev/null 2>&1 &
        ctl_exec "$c" kill -STOP "$pid" || exit 1
      else
        ctl_exec "$c" kill -CONT "$pid"; rc=$?
        pkill -f nice-dns-route-watchdog 2>/dev/null
        [ "$rc" -eq 0 ] || exit 1
      fi
      printf 'listener\t%s\tstate=%s\n' "$port" "$(ctl_exec "$c" awk '{ print $3 }' "/proc/$pid/stat")"
    fi ;;
  thaw-on-request)
    c="$NICE_DNS_COMPONENT"; i=0
    while [ "$i" -lt "$NICE_DNS_FREEZE_MAX" ]; do
      # The image claims a request (tor-restart-request -> tor-restart-pending)
      # before it sends TERM; a frozen tor holds that TERM until it is thawed.
      if ctl_exec "$c" sh -c 'test -e /app/data/control/tor-restart-pending || test -e /app/data/control/tor-restart-request' 2>/dev/null; then
        ctl_exec "$c" pkill -CONT -x tor
        pkill -f nice-dns-freeze-watchdog 2>/dev/null
        printf 'thawed\t%s\n' "$i"
        exit 0
      fi
      sleep 1; i=$((i + 1))
    done
    ctl_exec "$c" pkill -CONT -x tor
    echo "no restart request in $c within ${NICE_DNS_FREEZE_MAX}s; thawed anyway" >&2
    exit 1 ;;
  wedge-runtime)
    if [ "$plat" = macos ]; then
      homebrew_path
      # Any container on the default network; the image is one the proxy
      # build pulled (alpine), run for at most the freeze maximum.
      ctl run -d --name nice-dns-wedge docker.io/library/alpine:3.23.4 sleep "$NICE_DNS_FREEZE_MAX" </dev/null || exit 1
    else
      systemctl --user stop pi-hole.service || exit 1
    fi
    printf 'wedged\t%s\n' "$(date +%s)" ;;
  heal-runtime)
    if [ "$plat" = macos ]; then
      homebrew_path
      ctl delete --force nice-dns-wedge >/dev/null 2>&1
    fi
    printf 'healed\t%s\n' "$(date +%s)" ;;
  bridges-refresh)
    [ "$plat" = macos ] && homebrew_path
    t=$(health_tool) || { echo "no installed controller" >&2; exit 1; }
    o=$(mktemp "${TMPDIR:-/tmp}/nd-br.XXXXXX") || exit 1
    "$t" bridges-refresh </dev/null >"$o" 2>&1; rc=$?
    redact <"$o"; rm -f "$o"
    exit "$rc" ;;
  set-tunables)
    if [ "$plat" = macos ]; then f="$HOME/Library/Application Support/nice-dns-health/tunables.tsv"
    else f="${XDG_DATA_HOME:-$HOME/.local/share}/nice-dns-health/tunables.tsv"; fi
    [ -d "$(dirname "$f")" ] || { echo "no installed controller at $(dirname "$f")" >&2; exit 1; }
    if [ "$NICE_DNS_MODE" = fast ]; then
      (umask 077 && printf 'ND_POLICY_STARTUP_S\t30\nND_POLICY_GRACE_S\t30\nND_POLICY_COOLDOWN_S\t30\n' >"$f") || exit 1
    else
      rm -f "$f"
    fi
    printf 'tunables\t%s\n' "$NICE_DNS_MODE" ;;
  install-agent)
    if [ "$plat" != macos ]; then echo "install-agent is for macOS targets" >&2; exit 2; fi
    [ -s "${ND_SOURCE_TGZ:-}" ] || { echo "install-agent without the nice-dns source archive" >&2; exit 2; }
    w=$(mktemp -d "$HOME/.nice-dns-harness-agent.XXXXXX") || exit 1
    trap 'rm -rf "$w"' EXIT
    tar -xzf "$ND_SOURCE_TGZ" -C "$w" mac/start-container.sh || exit 1
    rm -f "$ND_SOURCE_TGZ"
    sudo -n install -m 755 "$w/mac/start-container.sh" /usr/local/sbin/start-container.sh || exit 1
    printf 'agent\t%s\n' "$(shasum -a 256 /usr/local/sbin/start-container.sh | cut -d' ' -f1)" ;;
  hold-bridge-refresh)
    if [ "$plat" = macos ]; then st="$HOME/Library/Application Support/nice-dns/controller"
    else st="${XDG_STATE_HOME:-$HOME/.local/state}/nice-dns/controller"; fi
    if [ ! -d "$st" ] || [ -L "$st" ]; then echo "no controller state directory at $st" >&2; exit 1; fi
    (umask 077 && date +%s >"$st/bridges.last") || exit 1
    printf 'held\t%s\n' "$(cat "$st/bridges.last")" ;;
  controller-report)
    [ "$plat" = macos ] && homebrew_path
    if [ "$plat" = macos ]; then
      data="$HOME/Library/Application Support/nice-dns-health"; st="$HOME/Library/Application Support/nice-dns/controller"
      lg="$HOME/Library/Logs/nice-dns-health/health.log"
    else
      data="${XDG_DATA_HOME:-$HOME/.local/share}/nice-dns-health"; st="${XDG_STATE_HOME:-$HOME/.local/state}/nice-dns/controller"
      lg="${XDG_STATE_HOME:-$HOME/.local/state}/nice-dns-health/health.log"
    fi
    {
      identity
      printf 'now\t%s\n' "$(date +%s)"
      printf 'section\tinstall\n'; cat "$data/install.tsv" 2>/dev/null
      printf 'section\tticks\n'; grep -E ' (TICK|controller) ' "$lg" 2>/dev/null | tail -n 400
      printf 'section\tstate-active\n'; cat "$st/state.tsv" 2>/dev/null
      printf 'section\tstate-shadow\n'; cat "$st/shadow/state.tsv" 2>/dev/null
      printf 'section\tjournal-active\n'; tail -n 200 "$st/recovery.tsv" 2>/dev/null
      printf 'section\tjournal-shadow\n'; tail -n 200 "$st/shadow/recovery.tsv" 2>/dev/null
      printf 'section\tbridges\n'
      bf="${XDG_CONFIG_HOME:-$HOME/.config}/nice-dns/bridges.env"
      bl=$(grep -E '^BRIDGE[0-9]+=obfs4 [0-9]{1,3}(\.[0-9]{1,3}){3}:[0-9]{1,5} [0-9A-F]{40} cert=[A-Za-z0-9+/=]+ iat-mode=[0-2]$' "$bf" 2>/dev/null | sed 's/^BRIDGE[0-9]*=//' | LC_ALL=C sort -u)
      if [ -n "$bl" ]; then printf 'set\t%s\t%s\n' "$(printf '%s\n' "$bl" | grep -c .)" "$(printf '%s\n' "$bl" | { sha256sum 2>/dev/null || shasum -a 256; } | cut -c1-16)"
      else printf 'set\t0\tnone\n'; fi
      printf 'section\tproxy\n'
      for c in tor-haproxy tor-socat; do
        running "$c" || continue
        printf 'proxy\t%s\t%s\t%s\n' "$c" "$(started "$c")" "$(image_of "$c")"
        printf 'tor_state\t%s\n' "$(tor_states "$c")"
      done
      printf 'section\tsummary\n'
      if running tor-haproxy; then
        if [ "$plat" = macos ]; then ctl logs tor-haproxy 2>/dev/null; else ctl logs tor-haproxy 2>&1; fi | grep '^backends ' >"${TMPDIR:-/tmp}/nd-sum.$$"
        printf 'count\t%s\n' "$(grep -c . "${TMPDIR:-/tmp}/nd-sum.$$")"
        tail -n 3 "${TMPDIR:-/tmp}/nd-sum.$$" | sed 's/^/line	/'
        rm -f "${TMPDIR:-/tmp}/nd-sum.$$"
      fi
      printf 'section\tpower\n'
      # macOS: Sleep entries of the power log (pmset's "Sleep Count" stayed 0
      # across a logged sleep on the target, 2026-09-26).
      if [ "$plat" = macos ]; then printf 'sleeps\t%s\n' "$(pmset -g log 2>/dev/null | grep -cE '^[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9:]{8} [+-][0-9]{4} Sleep ')"
      else printf 'sleeps\t%s\n' "$(cat /sys/power/suspend_stats/success 2>/dev/null)"; fi
      printf 'section\tobserve\n'
      if t=$(health_tool); then "$t" observe </dev/null 2>&1; fi
    } | redact ;;
  sever-upstream) ctl stop "$NICE_DNS_COMPONENT" ;;
  heal-upstream) ctl start "$NICE_DNS_COMPONENT" ;;
  restore)
    rc=0
    for c in $NICE_DNS_COMPONENTS; do ctl start "$c" || rc=1; done
    exit $rc ;;
  *) echo "unknown op" >&2; exit 2 ;;
esac
SH
}

kv() { printf '%s\n' "$2" | awk -F '\t' -v k="$1" '$1 == k { print $2; exit }'; }

probe_identity() {
  # Runs the read-only probe/snapshot and checks the identity it reports.
  local out mid plat
  out="$(remote_run "NICE_DNS_OP=$1")" || { printf '%s\n' "$out" >&2; exit 1; }
  mid="$(kv machine_id "$out")"
  plat="$(kv platform "$out")"
  [ -n "$mid" ] || die "target $alias_ reported no machine id"
  [ "$mid" != "$(local_machine_id)" ] || die "target $alias_ reports this machine's identity; the developer/production DNS host is never a test target"
  [ "$plat" = "$T_PLATFORM" ] || die "platform mismatch: targets file says $T_PLATFORM, $alias_ reports '$plat'"
  PROBE_OUT="$out" PROBE_MID="$mid"
}

state_dir() {
  local base="${ARTIFACT_DIR:-}" p
  case "$base" in /*) ;; *) die "ARTIFACT_DIR must be set to the run's absolute artifact dir" ;; esac
  for p in "$base" "$base/targets" "$base/targets/$alias_"; do
    [ -L "$p" ] && die "state path $p is a symlink; refusing"
  done
  mkdir -p "$base/targets/$alias_" || die "cannot create $base/targets/$alias_"
  STATE="$base/targets/$alias_"
  # Every file this script writes here (the full set); none may be a link.
  for p in snapshot.tsv receipt.tsv ops.tsv; do
    [ -L "$STATE/$p" ] && die "state file $STATE/$p is a symlink; refusing"
  done
  return 0
}

log_op() { printf '%s\t%s\t%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$op" "$1" >>"$STATE/ops.tsv"; }

# ─── operations ──────────────────────────────────────────────────────────────

case "$op" in
  probe)
    preconnect_guards
    probe_identity probe
    printf '%s\n' "$PROBE_OUT" ;;
  snapshot)
    state_dir
    preconnect_guards
    probe_identity snapshot
    (umask 077 && printf '%s\n' "$PROBE_OUT" >"$STATE/snapshot.tsv")
    {
      printf 'alias\t%s\nssh\t%s\nhost_key\t%s\nmachine_id\t%s\nplatform\t%s\n' "$alias_" "$T_SSH" "$T_KEY" "$PROBE_MID" "$T_PLATFORM"
      printf 'designated_on\t%s\ntaken_utc\t%s\nrun_id\t%s\n' "$T_DATE" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "${RUN_ID:-unknown}"
    } >"$STATE/receipt.tsv"
    log_op 0
    printf 'snapshot %s -> %s\n' "$alias_" "$STATE/snapshot.tsv" ;;
  config|health|controller-report|lifecycle-report|route-report)
    # Read-only; the output starts with the identity lines, which are checked.
    preconnect_guards
    probe_identity "$op"
    printf '%s\n' "$PROBE_OUT" ;;
  watch-dns)
    # Read-only and streamed: the identity is checked first, separately.
    preconnect_guards
    probe_identity probe
    remote_run "NICE_DNS_OP=watch-dns NICE_DNS_WATCH_SECS=$watch_secs"
    exit 0 ;;
  collect)
    preconnect_guards
    probe_identity probe
    remote_run "NICE_DNS_OP=collect NICE_DNS_WORKLOAD=$c_workload NICE_DNS_COUNT=$c_count NICE_DNS_TIMEOUT_MS=$c_timeout NICE_DNS_PAUSE_MS=$c_pause NICE_DNS_RUN_ID=$RUN_ID$ID_ENV"
    # 1 = collect.sh wrote rows with failed attempts; 2 = refused (nothing sent
    # or nothing written); anything else (ssh 255, ...) = the operation failed.
    case $? in 0) exit 0 ;; 1) exit 3 ;; 2) exit 2 ;; *) exit 1 ;; esac ;;
  sever-upstream|heal-upstream|restore|freeze-upstream|thaw-upstream|install-cell|uninstall-cell|quiesce-agents|build-proxy|recreate-proxy|install-controller|fault-route|heal-route|thaw-on-request|wedge-runtime|heal-runtime|bridges-refresh|hold-bridge-refresh|install-agent|set-tunables|mark-state|route-apply|route-onion|arm-prepare|arm-set)
    state_dir
    [ -f "$STATE/snapshot.tsv" ] && [ -f "$STATE/receipt.tsv" ] \
      || die "no restore snapshot for $alias_ in this run; run 'target.sh snapshot $alias_' first"
    preconnect_guards
    probe_identity probe
    [ "$(kv machine_id "$(cat "$STATE/receipt.tsv")")" = "$PROBE_MID" ] \
      || die "snapshot for $alias_ is of machine $(kv machine_id "$(cat "$STATE/receipt.tsv")"), target now reports $PROBE_MID"
    if [ "$op" = install-cell ] || [ "$op" = uninstall-cell ]; then
      remote_run "NICE_DNS_OP=$op $INSTALL_ENV"; rc=$?
    elif [ "$op" = mark-state ]; then
      remote_run "NICE_DNS_OP=mark-state NICE_DNS_RUN_ID=$RUN_ID"; rc=$?
    elif [ "$op" = restore ]; then
      names=''
      for c in $(awk -F '\t' '$1 == "section" { s = $2; next } s == "containers" && $2 == "running" { print $1 }' "$STATE/snapshot.tsv"); do
        case " $COMPONENTS " in *" $c "*) names="$names $c" ;; esac
      done
      remote_run "NICE_DNS_OP=restore NICE_DNS_COMPONENTS='${names# }'"; rc=$?
    else
      remote_run "NICE_DNS_OP=$op NICE_DNS_COMPONENT=$component NICE_DNS_FREEZE_MAX=$freeze_max NICE_DNS_ROUTE=$i_route NICE_DNS_MODE=$i_mode NICE_DNS_SOURCE_SHA=$i_sha NICE_DNS_PROXY_TAG=$i_ptag"; rc=$?
    fi
    log_op "$rc"
    [ "$rc" -eq 0 ] || exit 1 ;;
esac
exit 0
