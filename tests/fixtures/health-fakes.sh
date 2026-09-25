# shellcheck shell=bash
# Health fakes shared by unit/observations and integration/controller-interaction
# (Sub-plan 3). Sourced by group files; the runner provides CASE_DIR. POSIX sh
# stubs for dig, podman/container, networksetup, scutil, systemctl,
# journalctl, launchctl, ss, lsof and uname, whose behaviour comes from files
# under $FAKE and whose calls are appended to $FAKE_LOG; the runtime fake also
# plays the proxy image's /app/data/control restart interface.
#
#   ob_write_stubs <bindir>      write the stubs
#   ob_dig_file <file> <qname> <status> [owner TYPE rdata]...
#   ob_dig <qname> <status> [...]   the same into $FAKE/dig/<qname>
#   ob_fake_data <dir> <platform>   a healthy stack

# ob_write_stubs <bindir>: POSIX sh fakes. Behaviour comes from files under
# $FAKE; every call is appended to $FAKE_LOG.
ob_write_stubs() {
  local b="$1"
  mkdir -p "$b"
  cat >"$b/dig" <<'STUB'
#!/bin/sh
l=dig; for a in "$@"; do l="$l $a"; done; printf '%s\n' "$l" >>"$FAKE_LOG"
server="" port=53 q=""
while [ $# -gt 0 ]; do
  case "$1" in
    @*) server="${1#@}" ;;
    -p) port="$2"; shift ;;
    +*|-*) ;;
    *) [ -z "$q" ] && q="$1" ;;
  esac
  shift
done
f="$FAKE/dig/$q"
if [ "$server" != "$(cat "$FAKE/addr")" ] || [ "$port" != 53 ] || [ ! -f "$f" ]; then
  printf '\n; <<>> DiG 9.10.6 <<>> @%s %s\n; (1 server found)\n;; global options: +cmd\n;; connection timed out; no servers could be reached\n' "$server" "$q"
  exit 9
fi
if [ -f "$f.hang" ]; then sleep "$(cat "$FAKE/hang_secs")" & wait; exit 9; fi
cat "$f"
exit "$(cat "$f.rc" 2>/dev/null || echo 0)"
STUB
  # One runtime fake serves as podman (Linux) and container (macOS).
  cat >"$b/podman" <<'STUB'
#!/bin/sh
me="$(basename "$0")"
l="$me"; for a in "$@"; do l="$l $a"; done; printf '%s\n' "$l" >>"$FAKE_LOG"
if [ -f "$FAKE/rt.hang" ]; then sleep "$(cat "$FAKE/hang_secs")" & wait; exit 1; fi
table() {
  printf 'ID           IMAGE                                    OS     ARCH   STATE    IP                 CPUS  MEMORY  STARTED\n'
  while IFS= read -r n; do
    [ -n "$n" ] && printf '%-12s %-40s linux  arm64  running  172.31.240.25x/29  1     256 MB  %s\n' "$n" "$n:latest" "$(cat "$FAKE/started" 2>/dev/null || echo 2026-09-23T22:16:33Z)"
  done <"$FAKE/running"
  if [ "$1" = all ] && [ -f "$FAKE/stopped" ]; then
    while IFS= read -r n; do
      [ -n "$n" ] && printf '%-12s %-40s linux  arm64  stopped                     1     256 MB\n' "$n" "$n:latest"
    done <"$FAKE/stopped"
  fi
}
case "$1" in
  ps)
    if [ "$me" = container ]; then echo "Error: Plugin 'container-ps' not found."; exit 0; fi
    if [ -f "$FAKE/rt.down" ]; then printf 'Error: cannot open storage:\tdatabase is locked\nsecond line\n' >&2; exit 125; fi
    case "$*" in *-a*) cat "$FAKE/running" "$FAKE/stopped" 2>/dev/null ;; *) cat "$FAKE/running" ;; esac
    exit 0 ;;
  ls|list)
    [ "$me" = container ] || { echo "Error: unknown command \"$1\" for \"podman\"" >&2; exit 125; }
    if [ -f "$FAKE/rt.errexit0" ]; then echo "Error: XPC connection error: Connection invalid"; exit 0; fi
    if [ -f "$FAKE/rt.down" ]; then echo "Error: failed to connect to the container API server" >&2; exit 1; fi
    case "${2:-}" in -a|--all) table all ;; *) table running ;; esac
    exit 0 ;;
  exec)
    # `exec --user U C cmd...` (the Unbound container, run as unbound).
    if [ "$2" = --user ]; then a1="$1"; shift 3; set -- "$a1" "$@"; fi
    c="$2"; shift 2
    if ! grep -qxF "$c" "$FAKE/running"; then echo "Error: no container with name or ID \"$c\" found: no such container" >&2; exit 125; fi
    case "$1" in
      /usr/local/bin/nice-dns-route-probe)
        port="$2" name="$3"
        mode="$(cat "$FAKE/probe/$port" 2>/dev/null || echo ok)"
        case "$mode" in
          ok) echo "port=$port name=$name result=ok rcode=NOERROR ms=412"; exit 0 ;;
          nxdomain) echo "port=$port name=$name result=ok rcode=NXDOMAIN ms=380"; exit 0 ;;
          servfail) echo "port=$port name=$name result=dns-error rcode=SERVFAIL ms=90"; exit 1 ;;
          no-answer) echo "port=$port name=$name result=no-answer rcode=- ms=10004"; exit 1 ;;
          timeout) echo "port=$port name=$name result=no-answer rcode=- ms=10002 error=timeout"; exit 1 ;;
          wrong-port) echo "port=1 name=$name result=ok rcode=NOERROR ms=5"; exit 0 ;;
          garbage) printf 'OCI runtime exec failed:\texec failed\nno such file\n' >&2; exit 126 ;;
          hang) sleep "$(cat "$FAKE/hang_secs")" & wait; exit 1 ;;
        esac ;;
      /usr/local/bin/nice-dns-unbound-start)
        # "missing": an Unbound image without the tool, as each runtime
        # really reports it (observed 2026-09-25): podman/crun 127, Apple
        # container exit 1 with its own message.
        if [ "$(cat "$FAKE/unbound_probe_rc" 2>/dev/null)" = missing ]; then
          if [ "$me" = container ]; then echo 'Error: failed to start process (cause: "internalError: "failed to find target executable /usr/local/bin/nice-dns-unbound-start"")' >&2; exit 1; fi
          echo 'Error: crun: executable file `/usr/local/bin/nice-dns-unbound-start` not found in $PATH: No such file or directory: OCI runtime attempted to invoke a command that was not found' >&2; exit 127
        fi
        exit "$(cat "$FAKE/unbound_probe_rc" 2>/dev/null || echo 0)" ;;
      # The proxy image's acknowledged-restart control directory
      # (/app/data/control): $FAKE/ctl holds its files; $FAKE/ack (new, same
      # or refused) makes the image answer a request.
      test) exit "$(cat "$FAKE/cap_rc" 2>/dev/null || echo 0)" ;;
      cat) f="$FAKE/ctl/$(basename "$2")"; [ -f "$f" ] || exit 1; cat "$f" ;;
      sh)
        id="$5"; mkdir -p "$FAKE/ctl"
        printf '%s\n' "$id" >"$FAKE/ctl/tor-restart-request"
        if [ -f "$FAKE/ack" ]; then
          g="$(awk -F '\t' '$1 == "generation" { print $2 }' "$FAKE/ctl/tor-generation" 2>/dev/null)"; g="${g:-1}"
          p="$(awk -F '\t' '$1 == "tor_pid" { print $2 }' "$FAKE/ctl/tor-generation" 2>/dev/null)"; st=respawned
          case "$(cat "$FAKE/ack")" in new) g=$((g + 1)); p=$((1000 + g)) ;; refused) st=refused ;; esac
          printf 'request_id\t%s\nstatus\t%s\ngeneration\t%s\ntor_pid\t%s\nutc\tx\n' "$id" "$st" "$g" "$p" >"$FAKE/ctl/tor-restart-ack"
          printf 'generation\t%s\ntor_pid\t%s\n' "$g" "$p" >"$FAKE/ctl/tor-generation"
        fi ;;
    esac
    exit 0 ;;
  logs)
    # Each CLI's own tail flag: podman --tail N, Apple container -n N (it has
    # no --tail). $FAKE/logs holds the container output.
    if [ "$me" = container ]; then want=-n; else want=--tail; fi
    if [ "$2" != "$want" ]; then echo "Error: unknown option '$2'" >&2; exit 64; fi
    cat "$FAKE/logs" 2>/dev/null; exit 0 ;;
  inspect) printf 'id-1 %s running\n' "$(cat "$FAKE/started" 2>/dev/null || echo 2026-09-23T22:16:33Z)" ;;
  run)
    # The image's bridge-eval (Task 2.2): -v <host>:/pool, -out /pool/<file>.
    # $FAKE/bridge_eval: "set <file>" writes that file, "fail" exits 1,
    # "slow <secs> <file>" sleeps first.
    pool="" out=""
    while [ $# -gt 0 ]; do
      case "$1" in
        -v) pool="${2%%:*}"; shift ;;
        -out) out="${2#/pool/}"; shift ;;
      esac
      shift
    done
    set -- $(cat "$FAKE/bridge_eval" 2>/dev/null || echo fail)
    case "$1" in
      set) cat "$2" >"$pool/$out" ;;
      slow) sleep "$2"; cat "$3" >"$pool/$out" ;;
      *) exit 1 ;;
    esac
    exit 0 ;;
  system) exit 0 ;;
esac
exit 0
STUB
  cp "$b/podman" "$b/container"
  cat >"$b/networksetup" <<'STUB'
#!/bin/sh
l=networksetup; for a in "$@"; do l="$l $a"; done; printf '%s\n' "$l" >>"$FAKE_LOG"
case "$1" in
  -listallnetworkservices)
    echo "An asterisk (*) denotes that a network service is disabled."
    cat "$FAKE/services" ;;
  -getdnsservers)
    if [ -s "$FAKE/dns/$2" ]; then cat "$FAKE/dns/$2"; else echo "There aren't any DNS Servers set on $2."; fi ;;
esac
exit 0
STUB
  cat >"$b/scutil" <<'STUB'
#!/bin/sh
l=scutil; for a in "$@"; do l="$l $a"; done; printf '%s\n' "$l" >>"$FAKE_LOG"
[ "$1" = --dns ] || exit 0
printf 'DNS configuration\n\nresolver #1\n  search domain[0] : Home\n  nameserver[0] : %s\n  flags    : Request A records\n  reach    : 0x00000002 (Reachable)\n\n' "$(cat "$FAKE/scutil_ns")"
printf 'resolver #2\n  domain   : local\n  options  : mdns\n  timeout  : 5\n  flags    : Request A records\n  reach    : 0x00000000 (Not Reachable)\n  order    : 300000\n\n'
printf 'DNS configuration (for scoped queries)\n\nresolver #1\n  search domain[0] : Home\n  nameserver[0] : 192.168.1.1\n  if_index : 15 (en0)\n  flags    : Scoped, Request A records\n  reach    : 0x00020002 (Reachable,Directly Reachable Address)\n'
exit 0
STUB
  local s
  # shellcheck disable=SC2016  # the stubs expand these when they run
  for s in systemctl journalctl launchctl ss lsof; do
    printf '#!/bin/sh\nl=%s; for a in "$@"; do l="$l $a"; done; printf "%%s\\n" "$l" >>"$FAKE_LOG"\nexit 0\n' "$s" >"$b/$s"
  done
  # A service restart (systemctl --user restart, launchctl kickstart -k)
  # gives the containers a new start time when $FAKE/restart_changes exists.
  for s in systemctl launchctl; do
    cat >"$b/$s" <<'STUB'
#!/bin/sh
me="$(basename "$0")"
l="$me"; for a in "$@"; do l="$l $a"; done; printf '%s\n' "$l" >>"$FAKE_LOG"
case "$me $*" in
  "systemctl --user restart "*|"launchctl kickstart -k "*)
    [ -f "$FAKE/restart_changes" ] && echo "restarted-$(date +%s)-$$" >"$FAKE/started" ;;
esac
exit 0
STUB
  done
  # shellcheck disable=SC2016  # expanded by the stub
  printf '#!/bin/sh\nprintf "%%s\\n" "${FAKE_UNAME:-Linux}"\n' >"$b/uname"
  for s in dig podman container networksetup scutil systemctl journalctl launchctl ss lsof uname; do chmod 755 "$b/$s"; done
}

# ob_dig_file <file> <qname> <status> [owner TYPE rdata]...: a full dig
# response (header, question, answer and, for negative answers, authority).
ob_dig_file() {
  local f="$1" q="$2" st="$3" r o t d
  shift 3
  {
    printf '\n; <<>> DiG 9.18.39-0ubuntu0.24.04.2-Ubuntu <<>> -p 53 @x %s A\n; (1 server found)\n;; global options: +cmd\n;; Got answer:\n' "$q"
    printf ';; ->>HEADER<<- opcode: QUERY, status: %s, id: 4242\n' "$st"
    printf ';; flags: qr rd ra; QUERY: 1, ANSWER: %s, AUTHORITY: 0, ADDITIONAL: 1\n\n' "$#"
    printf ';; OPT PSEUDOSECTION:\n; EDNS: version: 0, flags:; udp: 1232\n;; QUESTION SECTION:\n;%s.\t\t\tIN\tA\n\n' "$q"
    if [ $# -gt 0 ]; then
      printf ';; ANSWER SECTION:\n'
      for r in "$@"; do
        o="${r%% *}"; t="${r#* }"; d="${t#* }"; t="${t%% *}"
        printf '%s.\t300\tIN\t%s\t%s\n' "$o" "$t" "$d"
      done
      printf '\n'
    fi
    case "$st" in NXDOMAIN|NOERROR)
      [ $# -eq 0 ] && printf ';; AUTHORITY SECTION:\n%s.\t1800\tIN\tSOA\tns1.example. hostmaster.example. 1 2 3 4 5\n\n' "$q" ;;
    esac
    printf ';; Query time: 3 msec\n;; SERVER: x#53(x) (UDP)\n;; WHEN: Thu Sep 25 06:00:00 BST 2026\n;; MSG SIZE  rcvd: 59\n\n'
  } >"$f"
}
ob_dig() { ob_dig_file "$FAKE/dig/$1" "$@"; }

# ob_fake_data <fake dir> <platform>: a healthy stack.
ob_fake_data() {
  local d="$1" svc
  mkdir -p "$d/dig" "$d/probe" "$d/dns"
  : >"$d/calls.log"
  printf 'pi-hole\nunbound\ntor-haproxy\n' >"$d/running"
  if [ "$2" = macos ]; then printf '172.31.240.250\n' >"$d/addr"; else printf '127.0.0.1\n' >"$d/addr"; fi
  printf '%s\n' $((4000 + RANDOM % 900)) >"$d/hang_secs"
  printf 'Ethernet\nThunderbolt Bridge\nWi-Fi\n*USB 10/100/1000 LAN\n' >"$d/services"
  for svc in Ethernet 'Thunderbolt Bridge' Wi-Fi; do printf '172.31.240.250\n' >"$d/dns/$svc"; done
  printf '172.31.240.250\n' >"$d/scutil_ns"
  ob_dig_file "$d/dig/pi.hole" pi.hole NOERROR "pi.hole A 10.88.0.5"
  ob_dig_file "$d/dig/doubleclick.net" doubleclick.net NOERROR "doubleclick.net A 0.0.0.0"
  ob_dig_file "$d/dig/cloudflare.com" cloudflare.com NOERROR "cloudflare.com A 104.16.132.229" "cloudflare.com A 104.16.133.229"
  mkdir -p "$d/ctl"
  printf 'generation\t1\ntor_pid\t1001\n' >"$d/ctl/tor-generation"
}
