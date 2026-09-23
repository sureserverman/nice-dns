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
#                    from a fresh clone of nice-dns checked out at
#                    --source-sha SHA (install-mac.sh clones main itself, so
#                    it is refused unless origin/main is that commit). The
#                    installer's output is streamed back; it may carry bridge
#                    lines, so keep it out of portable evidence.
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

die() { printf 'target.sh: %s\n' "$*" >&2; exit 2; }

TAB="$(printf '\t')"
OPS='validate probe snapshot sever-upstream heal-upstream restore config health collect freeze-upstream thaw-upstream install-cell'
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
targets='' component='' c_workload='' c_count='' c_timeout=5000 c_pause=0 c_identity='' i_cell='' i_sha=''
while [ $# -gt 0 ]; do
  case "$1" in
    --targets|--component|--workload|--count|--timeout-ms|--pause-ms|--identity|--cell|--source-sha)
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
        --source-sha) i_sha="$2" ;;
      esac
      shift 2 ;;
    *) die "unknown option '$1'" ;;
  esac
done
[ -n "$targets" ] || die "missing --targets FILE"
if [ "$op" != collect ] && [ -n "$c_workload$c_count$c_identity" ]; then
  die "--workload/--count/--identity are only valid for collect"
fi
if [ "$op" != install-cell ] && [ -n "$i_cell$i_sha" ]; then
  die "--cell/--source-sha are only valid for install-cell"
fi

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
  sever-upstream|heal-upstream|freeze-upstream|thaw-upstream)
    case " $UPSTREAM_COMPONENTS " in
      *" $component "*) [ -n "$component" ] || die "--component is required" ;;
      *) die "component '$component' is not an upstream component (allowed: $UPSTREAM_COMPONENTS)" ;;
    esac ;;
  *) [ -z "$component" ] || die "--component is only valid for sever/heal/freeze/thaw-upstream" ;;
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
if [ "$op" = install-cell ]; then
  case "$i_cell" in haproxy/standard|haproxy/hardened|socat/standard|socat/hardened) ;;
    *) die "install-cell needs --cell haproxy|socat/standard|hardened" ;; esac
  [[ "$i_sha" =~ ^[0-9a-f]{40}$ ]] || die "install-cell needs --source-sha <40-hex commit>"
  INSTALL_ENV="NICE_DNS_PROXY=${i_cell%/*} NICE_DNS_PIHOLE=${i_cell#*/} NICE_DNS_SOURCE_SHA=$i_sha"
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
remote_run() {
  { if [ "$op" = collect ]; then remote_bundle || exit 1; fi; remote_script; } \
    | ssh "${SSH_OPTS[@]}" "$T_SSH" "$1 /bin/sh -s"
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
    networksetup -listallnetworkservices | tail -n +2 | sed 's/^\*//' | while IFS= read -r svc; do
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
tor_states() {
  # One process-state letter per tor pid in the proxy container (T = stopped).
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
      printf 'pihole_variant\t%s\n' "$(ctl_exec pi-hole sh -c 'test -e /pihole/post-install.sh && echo hardened || echo standard')"
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
      done
    else
      launchctl list | awk '/nice-dns/ { printf "health\tlaunchd:%s\tlast_exit=%s\tpid=%s\n", $3, $2, $1 }'
    fi
    if t=$(health_tool); then
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
  install-cell)
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
    w=$(mktemp -d "$HOME/.nice-dns-harness-install.XXXXXX") || exit 1
    trap 'rm -rf "$w"' EXIT
    git clone -q https://github.com/sureserverman/nice-dns.git "$w/nice-dns" </dev/null || exit 1
    git -C "$w/nice-dns" checkout -q "$NICE_DNS_SOURCE_SHA" </dev/null || { echo "commit $NICE_DNS_SOURCE_SHA not found" >&2; exit 1; }
    if [ "$inst" = install-mac.sh ] && [ "$(git -C "$w/nice-dns" rev-parse origin/main)" != "$NICE_DNS_SOURCE_SHA" ]; then
      echo "install-mac.sh installs origin/main, which is not $NICE_DNS_SOURCE_SHA; refusing" >&2; exit 2
    fi
    printf 'install_cell\t%s/%s\ninstaller\t%s\nsource_sha\t%s\nstarted_utc\t%s\n' "$NICE_DNS_PROXY" "$NICE_DNS_PIHOLE" "$inst" \
      "$(git -C "$w/nice-dns" rev-parse HEAD)" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    (cd "$w/nice-dns" && bash "./$inst" "$NICE_DNS_PROXY" main) </dev/null 2>&1
    rc=$?
    printf 'finished_utc\t%s\ninstaller_exit\t%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$rc"
    exit $rc ;;
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
  config|health)
    # Read-only; the output starts with the identity lines, which are checked.
    preconnect_guards
    probe_identity "$op"
    printf '%s\n' "$PROBE_OUT" ;;
  collect)
    preconnect_guards
    probe_identity probe
    remote_run "NICE_DNS_OP=collect NICE_DNS_WORKLOAD=$c_workload NICE_DNS_COUNT=$c_count NICE_DNS_TIMEOUT_MS=$c_timeout NICE_DNS_PAUSE_MS=$c_pause NICE_DNS_RUN_ID=$RUN_ID$ID_ENV"
    case $? in 0) exit 0 ;; 1) exit 3 ;; *) exit 1 ;; esac ;;
  sever-upstream|heal-upstream|restore|freeze-upstream|thaw-upstream|install-cell)
    state_dir
    [ -f "$STATE/snapshot.tsv" ] && [ -f "$STATE/receipt.tsv" ] \
      || die "no restore snapshot for $alias_ in this run; run 'target.sh snapshot $alias_' first"
    preconnect_guards
    probe_identity probe
    [ "$(kv machine_id "$(cat "$STATE/receipt.tsv")")" = "$PROBE_MID" ] \
      || die "snapshot for $alias_ is of machine $(kv machine_id "$(cat "$STATE/receipt.tsv")"), target now reports $PROBE_MID"
    if [ "$op" = install-cell ]; then
      remote_run "NICE_DNS_OP=install-cell $INSTALL_ENV"; rc=$?
    elif [ "$op" = restore ]; then
      names=''
      for c in $(awk -F '\t' '$1 == "section" { s = $2; next } s == "containers" && $2 == "running" { print $1 }' "$STATE/snapshot.tsv"); do
        case " $COMPONENTS " in *" $c "*) names="$names $c" ;; esac
      done
      remote_run "NICE_DNS_OP=restore NICE_DNS_COMPONENTS='${names# }'"; rc=$?
    else
      remote_run "NICE_DNS_OP=$op NICE_DNS_COMPONENT=$component NICE_DNS_FREEZE_MAX=$freeze_max"; rc=$?
    fi
    log_op "$rc"
    [ "$rc" -eq 0 ] || exit 1 ;;
esac
exit 0
