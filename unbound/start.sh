#!/bin/sh
# nice-dns Unbound entrypoint (installed as /usr/local/bin/nice-dns-unbound-start).
#
#   nice-dns-unbound-start                 validate state, then exec unbound -d -p
#   nice-dns-unbound-start build-seed [SRC [OUT]]
#                                          image build only (root): write the
#                                          verified read-only root anchor seed
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
#   4. unbound-checkconf must pass. Then Unbound replaces this shell.
# Every refusal prints "nice-dns-unbound-start: FATAL: ..." and exits 1
# before Unbound starts: a resolver without a usable anchor is never run.
#
# busybox sh; no bash features.

set -u

SEED=/usr/share/nice-dns/root-anchor.seed
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

start() {
  cd / || die "cannot chdir to /"
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

  n="$(unbound-checkconf 2>&1)" || die "unbound-checkconf failed: $n"
  exec unbound -d -p
}

case "${1:-}" in
  '') start ;;
  build-seed) build_seed "${2:-/usr/share/dnssec-root/trusted-key.key}" "${3:-$SEED}" ;;
  *) die "unknown command '$1' (usage: $ME [build-seed [SRC [OUT]]])" ;;
esac
