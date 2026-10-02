#!/bin/sh
# nice-dns Unbound entrypoint (installed as /usr/local/bin/nice-dns-unbound-start).
#
#   nice-dns-unbound-start                 validate state, then exec unbound -d -p
#   nice-dns-unbound-start build-seed [SRC [OUT]]
#                                          image build only (root): write the
#                                          verified read-only root anchor seed
#   nice-dns-unbound-start probe-route [QNAME]
#                                          one DNS-over-TLS query (QNAME, default
#                                          ".", type SOA) straight to the active
#                                          include's forwarder, authenticated like
#                                          Unbound's own sessions; bypasses the cache
#   nice-dns-unbound-start check-route FILE
#                                          validate a staged route include: its
#                                          shape, then the complete candidate
#                                          config with FILE in place of the
#                                          active include (unbound-checkconf)
#
# Start (runs as the unbound user under tini):
#   1. The configured auto-trust-anchor-file must live in a real directory
#      (not a symlink) owned by this user and writable by it. That directory
#      is the persistent state volume (/var/lib/unbound).
#   2. If the anchor file is absent it is seeded from the image's verified
#      seed. If it exists it must be a regular file (not a symlink), writable,
#      and hold at least one usable root key; anything else is refused.
#   3. The control socket directory (/run/unbound) must be a real directory
#      owned by this user and closed to others; it is created when missing and
#      the parent allows it.
#   4. The route include (/etc/unbound/route/forward-route.conf) must hold
#      exactly one root forward-zone over TLS with one named forwarder and no
#      direct fallback, and no other root forward-zone or stub-zone may exist
#      in the main config (see check_route_policy).
#   5. unbound-checkconf must pass.
#   6. The start waits, within NICE_DNS_ROUTE_WAIT seconds (default 240), until
#      the active route returns a DNS response (wait_for_route), so Unbound
#      never begins by backing off a forwarder that was not up yet. Then
#      Unbound replaces this shell.
# Every refusal prints "nice-dns-unbound-start: FATAL: ..." and exits 1
# before Unbound starts: a resolver without a usable anchor is never run.
#
# busybox sh; no bash features.

set -u

SEED=/usr/share/nice-dns/root-anchor.seed
CONF=/etc/unbound/unbound.conf
ROUTE=/etc/unbound/route/forward-route.conf
ME=nice-dns-unbound-start

log() { printf '%s: %s\n' "$ME" "$*" >&2; }
die() { printf '%s: FATAL: %s\n' "$ME" "$*" >&2; exit 1; }

# owned_private_dir <dir> <what>: a real directory owned by us, writable by
# us, not writable by group or others.
owned_private_dir() {
  [ -L "$1" ] && die "$2 $1 is a symlink; refusing (state must not follow links)"
  [ -d "$1" ] || die "$2 $1 is missing or not a directory"
  [ -n "$(find "$1" -maxdepth 0 -user "$(id -u)" 2>/dev/null)" ] \
    || die "$2 $1 is not owned by uid $(id -u) ($(id -un))"
  # A real write probe: busybox `test -w` checks mode bits only and misses a
  # read-only mount. Subshell: a failed redirection on `:` (a special
  # built-in) would otherwise end this shell without a message.
  if ! (: >"$1/.nice-dns-write-probe.$$" && rm -f "$1/.nice-dns-write-probe.$$") 2>/dev/null; then
    die "$2 $1 is not writable by $(id -un) (read-only mount or wrong permissions)"
  fi
  [ -z "$(find "$1" -maxdepth 0 -perm -0002 2>/dev/null)$(find "$1" -maxdepth 0 -perm -0020 2>/dev/null)" ] \
    || die "$2 $1 is writable by group or others"
  return 0
}

# anchor_usable <file>: exit 0 when every non-comment line parses as a root
# trust-anchor record and at least one of them is a key Unbound will trust:
# a root DS, or a root DNSKEY with the SEP flag (257, not revoked) whose
# RFC 5011 state (when recorded) is VALID(2) or MISSING(3).
anchor_usable() {
  awk '
    /^[[:space:]]*(;|$)/ { next }
    {
      st = ""
      if (match($0, /;;state=[0-9]+/)) st = substr($0, RSTART + 8, RLENGTH - 8)
      line = $0; sub(/;.*/, "", line)
      n = split(line, f, /[[:space:]]+/)
      i = 1; while (i <= n && f[i] == "") i++
      if (f[i] != ".") { bad = 1; next }
      t = 0; for (j = i + 1; j <= n; j++) if (f[j] == "DS" || f[j] == "DNSKEY") { t = j; break }
      if (!t) { bad = 1; next }
      if (f[t] == "DS") {
        if (f[t+1] ~ /^[0-9]+$/ && f[t+2] ~ /^[0-9]+$/ && f[t+3] ~ /^[0-9]+$/ && f[t+4] ~ /^[0-9A-Fa-f]+$/) ok++
        else bad = 1
        next
      }
      if (f[t+1] !~ /^[0-9]+$/ || f[t+2] != "3" || f[t+3] !~ /^[0-9]+$/ || f[t+4] !~ /^[A-Za-z0-9+\/=]+$/) { bad = 1; next }
      if (f[t+1] == "257" && (st == "" || st == "2" || st == "3")) ok++
    }
    END { exit !(ok > 0 && !bad) }' "$1"
}

# build_seed <src> <out>: the trust root is the DS set compiled into
# unbound-anchor (`unbound-anchor -l`). Every root DNSKEY 257 3 8 in the
# packaged key file must match one of those DS records by its SHA-256 digest
# and is kept; one that matches none means the two packages disagree, and the
# build fails. A required KSK tag the packaged file lacks is seeded from its
# builtin DS line instead (an older dnssec-root package carries only
# KSK-2017); Unbound's RFC 5011 tracking accepts a DS anchor. The mirror of
# this logic is hardened-unbound's Dockerfile; keep the two in step.
build_seed() {
  src="$1" out="$2" dnskeys="" dss=""
  required="${REQUIRED_ROOT_KSK_TAGS-20326 38696}"
  [ "$(id -u)" = 0 ] || die "build-seed runs as root at image build"
  [ -n "$(printf '%s' "$required" | tr -d ' ')" ] || die "REQUIRED_ROOT_KSK_TAGS is empty; at least one root KSK tag is required"
  case "$required" in *[!0-9\ ]*) die "REQUIRED_ROOT_KSK_TAGS must be numeric key tags: '$required'" ;; esac
  [ -s "$src" ] || die "root key source $src is missing or empty"
  builtin="$(unbound-anchor -l | grep -E '^\. IN DS [0-9]+ 8 2 [0-9A-F]{64}$')"
  [ -n "$builtin" ] || die "unbound-anchor -l printed no builtin root DS"
  (: >"$out.tmp") 2>/dev/null || die "cannot write $out.tmp"
  while read -r owner class type flags proto alg key; do
    [ "$owner $class $type $flags $proto $alg" = ". IN DNSKEY 257 3 8" ] || continue
    digest="$( { printf '\000\001\001\003\010'; printf '%s' "$key" | openssl base64 -d -A 2>/dev/null; } \
      | openssl dgst -sha256 -r | cut -d' ' -f1 | tr a-f A-F)"
    tag="$(printf '%s\n' "$builtin" | awk -v d="$digest" '$7 == d { print $4 }')"
    [ -n "$tag" ] || { rm -f "$out.tmp"; die "a root DNSKEY in $src matches no builtin DS (tampered or unknown key)"; }
    printf '. IN DNSKEY 257 3 8 %s ; key tag %s\n' "$key" "$tag" >>"$out.tmp"
    dnskeys="$dnskeys $tag"
  done <"$src"
  [ -n "$dnskeys" ] || { rm -f "$out.tmp"; die "no root DNSKEY 257 3 8 in $src"; }
  for t in $required; do
    case " $dnskeys " in *" $t "*) continue ;; esac
    ds="$(printf '%s\n' "$builtin" | awk -v t="$t" '$4 == t')"
    [ -n "$ds" ] || { rm -f "$out.tmp"; die "root KSK $t is neither in $src nor among unbound-anchor's builtin DS"; }
    printf '%s ; key tag %s (builtin DS)\n' "$ds" "$t" >>"$out.tmp"
    dss="$dss $t"
  done
  anchor_usable "$out.tmp" || { rm -f "$out.tmp"; die "built seed is not a usable anchor"; }
  if ! { chmod 0444 "$out.tmp" && mv "$out.tmp" "$out"; }; then die "cannot install $out"; fi
  log "seed $out verified (DNSKEY tags:$dnskeys; builtin DS tags:${dss:- none})"
}

# check_route_policy <file>: print each problem; exit 0 when the include holds
# only the route marker (a static nice-dns-route.invalid. zone with one TXT
# record) and one root forward-zone: forward-tls-upstream yes, forward-first
# no and a single forward-addr ADDR@PORT#TLS-NAME. Anything else (a server
# option, a second zone or forwarder, a missing TLS name) is refused, so a
# route change can never alter sockets, threads or cache sizes.
check_route_policy() {
  awk -v q="'" '
    function bad(m) { print m; err = 1 }
    BEGIN {
      marker = "^local-data: " q "nice-dns-route\\.invalid\\. 0 IN TXT \"route=[a-z0-9-]+ generation=[0-9]+\"" q "$"
    }
    /^[[:space:]]*(#|$)/ { next }
    {
      line = $0; sub(/^[[:space:]]+/, "", line); sub(/[[:space:]]+$/, "", line)
      if (line == "server:") { clause = "server"; next }
      if (line == "forward-zone:") { clause = "fwd"; nfz++; next }
      if (clause == "server" && line == "local-zone: \"nice-dns-route.invalid.\" static") { lz++; next }
      if (clause == "server" && line ~ marker) { ld++; next }
      if (clause == "fwd" && line == "name: \".\"") { nm++; next }
      if (clause == "fwd" && line == "forward-tls-upstream: yes") { tls++; next }
      if (clause == "fwd" && line == "forward-first: no") { ff++; next }
      if (clause == "fwd" && line ~ /^forward-addr: [0-9]+\.[0-9]+\.[0-9]+\.[0-9]+@[1-9][0-9]?[0-9]?[0-9]?[0-9]?#[a-z0-9]([a-z0-9.-]*[a-z0-9])?$/) { fa++; next }
      bad("line " NR ": not allowed in the route include: " line)
    }
    END {
      if (nfz != 1) bad("exactly one forward-zone is required (found " nfz + 0 ")")
      if (nm != 1) bad("the forward-zone must be for the root, name: \".\"")
      if (tls != 1) bad("forward-tls-upstream: yes is required")
      if (ff != 1) bad("forward-first: no is required (no direct recursive fallback)")
      if (fa != 1) bad("exactly one forward-addr ADDR@PORT#TLS-NAME is required (found " fa + 0 ")")
      if (lz != 1 || ld != 1) bad("the route marker (nice-dns-route.invalid.) is required exactly once")
      exit err
    }' "$1"
}

# main_conf_guard <conf>: the main config includes the route file exactly
# once and names no root forward-zone or stub-zone of its own (Unbound would
# otherwise use one of two root zones, or recurse directly).
main_conf_guard() {
  n="$(grep -c "^include: \"$ROUTE\"\$" "$1")"
  [ "$n" -eq 1 ] || die "$1 must include $ROUTE exactly once (found $n)"
  root="$(awk '
    /^[[:space:]]*(#|$)/ { next }
    /^[a-z-]+:[[:space:]]*$/ { clause = $1 }
    (clause == "forward-zone:" || clause == "stub-zone:") && $1 == "name:" && ($2 == "\".\"" || $2 == ".") { print NR ": " clause " " $0 }
  ' "$1")"
  [ -z "$root" ] || die "$1 defines a root zone outside $ROUTE: $root"
}

# check_route <file>: the file is a regular file with the route shape, and
# the complete config with it in place of the active include passes
# unbound-checkconf. Runs as the unbound user, before the file is activated.
check_route() {
  # The path is substituted into a sed program below.
  case "$1" in /*) ;; *) die "unsafe route include path '$1' (absolute paths of [A-Za-z0-9._/-] only)" ;; esac
  case "$1" in *[!A-Za-z0-9._/-]*) die "unsafe route include path '$1' (absolute paths of [A-Za-z0-9._/-] only)" ;; esac
  [ -L "$1" ] && die "route include $1 is a symlink; refusing"
  [ -f "$1" ] || die "route include $1 is missing or not a regular file"
  out="$(check_route_policy "$1")" || die "route include $1 refused: $out"
  main_conf_guard "$CONF"
  cand="$(mktemp /tmp/nice-dns-candidate.XXXXXX)" || die "cannot create a candidate config"
  if ! sed "s#^include: \"$ROUTE\"\$#include: \"$1\"#" "$CONF" >"$cand"; then
    rm -f "$cand"; die "cannot write the candidate config"
  fi
  if ! out="$(unbound-checkconf "$cand" 2>&1)"; then
    rm -f "$cand"; die "candidate config with $1 rejected by unbound-checkconf: $out"
  fi
  rm -f "$cand"
  log "route include $1 accepted"
}

# probe_route [QNAME]: resolution through the active route, bypassing the
# cache (a reload keeps it, and aggressive NSEC can answer from it). The
# certificate must chain to the effective tls-cert-bundle and match the
# forwarder's TLS name, as for Unbound's own sessions. Prints one line;
# exit 0 only for a NOERROR or NXDOMAIN response.
probe_route() {
  qname="${1:-.}"
  case "$qname" in ''|*[!A-Za-z0-9._-]*) die "unsafe probe name '$qname'" ;; esac
  fwd="$(awk '/^[[:space:]]*forward-addr:/ { print $2 }' "$ROUTE")"
  addr="${fwd%%@*}" rest="${fwd#*@}"
  port="${rest%%#*}" name="${rest#*#}"
  [ -n "$addr" ] && [ -n "$port" ] && [ -n "$name" ] && [ "$fwd" != "$addr" ] \
    || die "cannot read a forwarder ADDR@PORT#NAME from $ROUTE"
  bundle="$(unbound-checkconf -o tls-cert-bundle 2>/dev/null)"
  [ -r "$bundle" ] || die "tls-cert-bundle '$bundle' is not readable"
  # dig 9.20 does not bound a TLS session by +time (20-30 s at +time=3), so
  # the whole query runs under timeout(1); an expiry is reported as one.
  t="${NICE_DNS_PROBE_TIMEOUT:-15}"
  case "$t" in ''|*[!0-9]*|0) die "NICE_DNS_PROBE_TIMEOUT '$t' is not a positive number of seconds" ;; esac
  out="$(timeout -s KILL "$t" dig +tls +tls-ca="$bundle" +tls-hostname="$name" +tries=1 +retry=0 \
    +time="$t" -p "$port" "@$addr" "$qname" SOA 2>&1)"
  drc=$?
  rcode="$(printf '%s\n' "$out" | sed -n 's/^;; ->>HEADER<<- opcode: [A-Z]*, status: \([A-Z]*\), id: [0-9]*$/\1/p' | head -n 1)"
  extra=""
  [ "$drc" -eq 137 ] && [ -z "$rcode" ] && extra=" error=timeout"
  printf 'forwarder=%s qname=%s rcode=%s%s\n' "$fwd" "$qname" "${rcode:--}" "$extra"
  case "$rcode" in NOERROR|NXDOMAIN) return 0 ;; esac
  return 1
}

# wait_for_route: until the active route returns a DNS response to one
# authenticated query (probe_route; any rcode is a response), at most
# NICE_DNS_ROUTE_WAIT seconds (default 240, under the quadlet's 300 s health
# start period; 0: no wait). Sub-plan 5 Stage 1 gate (DEC-015): at a stack
# start Unbound asked its only forwarder before the proxy could carry a
# stream and then waited out its back-off, so the first answer came 29-46 s
# after a restart with the proxy ready after 11-15 s (Linux, 2026-09-30). A
# route that never answers ends the wait too: Unbound then starts as it
# always did, and its health check reports.
wait_for_route() {
  w="${NICE_DNS_ROUTE_WAIT:-240}"
  case "$w" in ''|*[!0-9]*) die "NICE_DNS_ROUTE_WAIT '$w' is not a number of seconds" ;; esac
  [ "$w" -gt 0 ] || return 0
  t0="$(cut -d. -f1 /proc/uptime 2>/dev/null)" || t0=""
  case "$t0" in ''|*[!0-9]*) return 0 ;; esac
  while :; do
    # In a subshell: a refusal inside the probe (die) must not end the start.
    # Nor is it a "not yet": waiting would only delay Unbound by the bound.
    out="$(NICE_DNS_PROBE_TIMEOUT=8 probe_route . 2>&1)" || true
    el=$(( $(cut -d. -f1 /proc/uptime) - t0 ))
    case "$out" in
      *forwarder=*|'') ;;
      *) echo "$ME: the route probe was refused ($out); starting Unbound without waiting" >&2; return 0 ;;
    esac
    case "$out" in
      *' rcode=-'*|'') ;;
      *' rcode='*) echo "$ME: the route answers after $el s ($out)"; return 0 ;;
    esac
    if [ "$el" -ge "$w" ]; then
      echo "$ME: the route did not answer within $w s ($out); starting Unbound anyway" >&2
      return 0
    fi
    sleep 1
  done
}

start() {
  anchor="$(unbound-checkconf -o auto-trust-anchor-file 2>&1)" \
    || die "unbound-checkconf rejected the configuration: $anchor"
  n="$(printf '%s\n' "$anchor" | grep -c .)"
  [ "$n" -eq 1 ] || die "the configuration must set exactly one auto-trust-anchor-file (found $n); refusing to run without DNSSEC root validation"
  case "$anchor" in /*) ;; *) die "auto-trust-anchor-file '$anchor' is not an absolute path" ;; esac

  dir="$(dirname "$anchor")"
  owned_private_dir "$dir" "anchor directory"
  if [ -L "$anchor" ]; then
    die "anchor $anchor is a symlink; refusing"
  elif [ ! -e "$anchor" ]; then
    if [ ! -s "$SEED" ] || ! anchor_usable "$SEED"; then die "image seed $SEED is missing or unusable"; fi
    if ! { cp "$SEED" "$anchor.seed.$$" && chmod 0600 "$anchor.seed.$$" && mv "$anchor.seed.$$" "$anchor"; }; then
      rm -f "$anchor.seed.$$"
      die "cannot seed $anchor from $SEED"
    fi
    log "seeded $anchor from $SEED"
  else
    [ -f "$anchor" ] || die "anchor $anchor is not a regular file"
    # Append-open writes nothing but fails on a read-only mount, which the
    # mode-bits-only busybox `test -w` misses (see owned_private_dir).
    (: >>"$anchor") 2>/dev/null || die "anchor $anchor is not writable by $(id -un) (read-only mount or wrong permissions); RFC 5011 updates would be lost"
    anchor_usable "$anchor" || die "anchor $anchor is unusable (empty, malformed or without a trusted root key); refusing to start Unbound. Remove it to re-seed from $SEED."
    log "using existing anchor $anchor"
  fi

  # With control enabled, every control-interface must be a Unix socket path:
  # a network control listener is refused, not just left out of the shipped
  # config.
  ctl_on="$(unbound-checkconf -o control-enable 2>/dev/null)"
  for ctl in $(unbound-checkconf -o control-interface 2>/dev/null); do
    case "$ctl" in
      /*) ;;
      *) [ "$ctl_on" != yes ] || die "control-interface $ctl is a network address; only a Unix socket path is allowed" ;;
    esac
    case "$ctl" in
      /*)
        dir="$(dirname "$ctl")"
        if [ ! -e "$dir" ] && [ ! -L "$dir" ]; then
          (umask 027 && mkdir "$dir") 2>/dev/null || die "control socket directory $dir is missing and cannot be created"
        fi
        owned_private_dir "$dir" "control socket directory"
        [ -z "$(find "$dir" -maxdepth 0 -perm -0001 2>/dev/null)$(find "$dir" -maxdepth 0 -perm -0004 2>/dev/null)" ] \
          || die "control socket directory $dir is open to others"
        ;;
    esac
  done

  # The active route: its shape, and no second root zone in the main config.
  main_conf_guard "$CONF"
  [ -L "$ROUTE" ] && die "route include $ROUTE is a symlink; refusing"
  [ -f "$ROUTE" ] || die "route include $ROUTE is missing or not a regular file"
  n="$(check_route_policy "$ROUTE")" || die "route include $ROUTE refused: $n"

  n="$(unbound-checkconf 2>&1)" || die "unbound-checkconf failed: $n"
  wait_for_route
  exec unbound -d -p
}

# Every command runs from /: the image WORKDIR is closed to the unbound user,
# and unbound-checkconf resolves relative paths from the working directory.
cd / || die "cannot chdir to /"

case "${1:-}" in
  '') start ;;
  build-seed) build_seed "${2:-/usr/share/dnssec-root/trusted-key.key}" "${3:-$SEED}" ;;
  check-route) [ $# -eq 2 ] || die "usage: $ME check-route FILE"; check_route "$2" ;;
  probe-route) [ $# -le 2 ] || die "usage: $ME probe-route [QNAME]"; probe_route "${2:-.}" ;;
  *) die "unknown command '$1' (usage: $ME [build-seed [SRC [OUT]] | check-route FILE | probe-route [QNAME]])" ;;
esac
