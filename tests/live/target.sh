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
# Exit: 0 done; 1 the remote operation failed; 2 refused (nothing mutating sent).
# Portability: Bash 3.2, BSD/GNU userland; remote side is /bin/sh.

set -u

die() { printf 'target.sh: %s\n' "$*" >&2; exit 2; }

TAB="$(printf '\t')"
OPS='validate probe snapshot sever-upstream heal-upstream restore'
COMPONENTS='pi-hole unbound tor-haproxy tor-socat'
UPSTREAM_COMPONENTS='tor-haproxy tor-socat'

op="${1:-}"
[ $# -gt 0 ] && shift
case " $OPS " in *" $op "*) ;; *) die "unknown operation '$op' (allowed: $OPS)" ;; esac
alias_=''
if [ "$op" != validate ]; then
  alias_="${1:-}"
  [ $# -gt 0 ] && shift
  case "$alias_" in ''|-*) die "usage: target.sh $op ALIAS --targets FILE" ;; esac
fi
targets='' component=''
while [ $# -gt 0 ]; do
  case "$1" in
    --targets|--component)
      [ $# -ge 2 ] || die "option $1 needs a value"
      if [ "$1" = --targets ]; then targets="$2"; else component="$2"; fi
      shift 2 ;;
    *) die "unknown option '$1'" ;;
  esac
done
[ -n "$targets" ] || die "missing --targets FILE"

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
  sever-upstream|heal-upstream)
    case " $UPSTREAM_COMPONENTS " in
      *" $component "*) [ -n "$component" ] || die "--component is required" ;;
      *) die "component '$component' is not an upstream component (allowed: $UPSTREAM_COMPONENTS)" ;;
    esac ;;
  *) [ -z "$component" ] || die "--component is only valid for sever-upstream/heal-upstream" ;;
esac

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
  -o PermitLocalCommand=no -o ControlMaster=no -o ControlPath=none -o ConnectTimeout=15)

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
    fps="$fps$(printf '%s\n' "$line" | awk '!/^#/ && NF >= 2 { print $2 }')
"
  done
  [ -n "$(printf '%s' "$fps" | tr -d '\n')" ] \
    || die "host key for $name is not in known_hosts; verify it out of band and add it (no trust on first use)"
  printf '%s' "$fps" | grep -Fxq -- "$T_KEY" \
    || die "host key mismatch for $name: known_hosts has $(printf '%s' "$fps" | tr '\n' ' '), targets file pins $T_KEY"
}

# remote_run <env-prefix> : sends the op's constant script to /bin/sh -s.
remote_run() {
  remote_script | ssh "${SSH_OPTS[@]}" "$T_SSH" "$1 /bin/sh -s"
}

remote_script() {
  cat <<'SH'
set -u
if [ "$(uname -s)" = Darwin ]; then
  plat=macos
  mid=$(ioreg -rd1 -c IOPlatformExpertDevice | awk -F'"' '/IOPlatformUUID/ { print $4 }')
  C=$(command -v container || ls /opt/homebrew/bin/container /usr/local/bin/container 2>/dev/null | head -1)
else
  plat=linux
  mid=$(cat /etc/machine-id 2>/dev/null)
  C=podman
fi
ctl() { "$C" "$@"; }
containers() {
  if [ "$plat" = macos ]; then ctl list --all | awk 'NR > 1 { printf "%s\t%s\n", $1, $5 }'
  else ctl ps -a --format '{{.Names}}\t{{.State}}'
  fi
}
case "$NICE_DNS_OP" in
  probe|snapshot)
    printf 'machine_id\t%s\nhostname\t%s\nplatform\t%s\n' "$mid" "$(hostname)" "$plat"
    if [ "$plat" = macos ]; then
      printf 'os\tmacOS %s\nruntime\t%s\n' "$(sw_vers -productVersion)" "$(ctl --version 2>&1 | head -1)"
    else
      printf 'os\t%s\nruntime\t%s\n' "$(. /etc/os-release && echo "$PRETTY_NAME")" "$(podman --version)"
    fi
    printf 'section\tcontainers\n'
    containers
    if [ "$NICE_DNS_OP" = snapshot ]; then
      printf 'section\timages\n'
      if [ "$plat" = macos ]; then ctl image list 2>&1; else podman images --digests --format '{{.Repository}}:{{.Tag}}\t{{.Digest}}'; fi
      printf 'section\tdns\n'
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
    fi ;;
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
  sever-upstream|heal-upstream|restore)
    state_dir
    [ -f "$STATE/snapshot.tsv" ] && [ -f "$STATE/receipt.tsv" ] \
      || die "no restore snapshot for $alias_ in this run; run 'target.sh snapshot $alias_' first"
    preconnect_guards
    probe_identity probe
    [ "$(kv machine_id "$(cat "$STATE/receipt.tsv")")" = "$PROBE_MID" ] \
      || die "snapshot for $alias_ is of machine $(kv machine_id "$(cat "$STATE/receipt.tsv")"), target now reports $PROBE_MID"
    if [ "$op" = restore ]; then
      names=''
      for c in $(awk -F '\t' '$1 == "section" { s = $2; next } s == "containers" && $2 == "running" { print $1 }' "$STATE/snapshot.tsv"); do
        case " $COMPONENTS " in *" $c "*) names="$names $c" ;; esac
      done
      remote_run "NICE_DNS_OP=restore NICE_DNS_COMPONENTS='${names# }'"; rc=$?
    else
      remote_run "NICE_DNS_OP=$op NICE_DNS_COMPONENT=$component"; rc=$?
    fi
    log_op "$rc"
    [ "$rc" -eq 0 ] || exit 1 ;;
esac
exit 0
