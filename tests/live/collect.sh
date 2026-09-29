#!/usr/bin/env bash
# DNS timing collector (sub-plan 01, Task 1.3; ARCH-09).
#
# Usage:
#   bash tests/live/collect.sh --resolver ADDR[#PORT] --workload NAME --count N \
#     --identity FILE --out FILE [--workloads FILE] [--timeout-ms MS]
#     [--pause-ms MS] [--transport udp|tcp] [--matrix FILE]
#
# Appends one row per attempted query to FILE (schema nice-dns-sample/1),
# failures included. Query names come only from the workload manifest
# (default tests/manifests/workloads.tsv; {nonce} expands to 16 fresh hex
# digits), so no client query history can enter a sample file. Elapsed time is
# monotonic (perl Time::HiRes CLOCK_MONOTONIC), in microseconds, around one dig
# with +tries=1. The identity file (key<TAB>value, parsed as data) must carry
# target_id platform proxy pihole source_rev images, and platform/proxy/pihole
# must be one of the eight cells in the matrix (default
# tests/manifests/matrix.tsv), so every sample belongs to a real cell.
#
# Exit: 0 every attempt answered (NOERROR or NXDOMAIN); 1 rows written but at
# least one attempt failed (timeout, SERVFAIL, REFUSED, error); 2 refused
# (usage, unknown workload, incomplete identity, bad existing file, a file
# from another run) with nothing written.
#
# Portability: Bash 3.2, BSD/GNU userland, perl and dig (9.x).

set -u

COLLECT_ROOT="$(cd "$(dirname "$0")/../.." && pwd -P)"
SCHEMA='nice-dns-sample/1'
COLUMNS='run_id	sample_id	utc_start	elapsed_us	workload	cache_class	target_id	platform	proxy	pihole	source_rev	images	resolver	transport	qname	qtype	outcome	rcode	timeout_ms'
IDENTITY_KEYS='target_id platform proxy pihole source_rev images'

die() { printf 'collect.sh: %s\n' "$*" >&2; exit 2; }

resolver='' workload='' count='' identity='' out=''
workloads="$COLLECT_ROOT/tests/manifests/workloads.tsv"
matrix="$COLLECT_ROOT/tests/manifests/matrix.tsv"
timeout_ms=5000 pause_ms=0 transport=udp
while [ $# -gt 0 ]; do
  case "$1" in
    --resolver|--workload|--count|--identity|--out|--workloads|--timeout-ms|--pause-ms|--transport|--matrix)
      [ $# -ge 2 ] || die "option $1 needs a value"
      case "$1" in
        --resolver) resolver="$2" ;;
        --workload) workload="$2" ;;
        --count) count="$2" ;;
        --identity) identity="$2" ;;
        --out) out="$2" ;;
        --workloads) workloads="$2" ;;
        --timeout-ms) timeout_ms="$2" ;;
        --pause-ms) pause_ms="$2" ;;
        --transport) transport="$2" ;;
        --matrix) matrix="$2" ;;
      esac
      shift 2 ;;
    *) die "unknown option '$1'" ;;
  esac
done

for v in resolver workload count identity out; do
  eval "[ -n \"\${$v}\" ]" || die "missing --$v"
done
case "$count" in ''|*[!0-9]*|0) die "--count must be a positive integer" ;; esac
case "$timeout_ms" in ''|*[!0-9]*) die "--timeout-ms must be an integer" ;; esac
[ "$timeout_ms" -ge 1000 ] && [ $((timeout_ms % 1000)) -eq 0 ] \
  || die "--timeout-ms must be a positive multiple of 1000 (dig +time has 1 s resolution)"
case "$pause_ms" in ''|*[!0-9]*) die "--pause-ms must be an integer" ;; esac
case "$transport" in udp|tcp) ;; *) die "--transport must be udp or tcp" ;; esac

addr="${resolver%%#*}"
port=53
case "$resolver" in *'#'*) port="${resolver#*#}" ;; esac
case "$addr" in ''|*[!0-9a-fA-F.:]*) die "--resolver address must be an IP literal: '$addr'" ;; esac
case "$port" in ''|*[!0-9]*) die "--resolver port must be numeric: '$port'" ;; esac

# Identity: data only, never sourced.
[ -f "$identity" ] || die "identity file not found: $identity"
id_target_id='' id_platform='' id_proxy='' id_pihole='' id_source_rev='' id_images=''
while IFS='	' read -r k val || [ -n "$k" ]; do
  case "$val" in *'	'*) die "identity value for '$k' contains a tab" ;; esac
  case "$k" in
    target_id) id_target_id="$val" ;;
    platform) id_platform="$val" ;;
    proxy) id_proxy="$val" ;;
    pihole) id_pihole="$val" ;;
    source_rev) id_source_rev="$val" ;;
    images) id_images="$val" ;;
  esac
done <"$identity"
for k in $IDENTITY_KEYS; do
  eval "[ -n \"\${id_$k}\" ]" || die "identity file $identity has no value for required key '$k'"
done

[ -f "$matrix" ] || die "matrix not found: $matrix"
cell_ok=no
while IFS='	' read -r mp mx mh mextra || [ -n "$mp" ]; do
  case "$mp" in ''|'#'*) continue ;; esac
  if [ "$mp" = "$id_platform" ] && [ "$mx" = "$id_proxy" ] && [ "$mh" = "$id_pihole" ] && [ -z "${mextra:-}" ]; then
    cell_ok=yes
  fi
done <"$matrix"
[ "$cell_ok" = yes ] || die "identity $id_platform/$id_proxy/$id_pihole is not a cell of $matrix"

# Workload: exactly one manifest row; names are templates, never free-form.
[ -f "$workloads" ] || die "workload manifest not found: $workloads"
w_class='' w_template='' w_qtype=''
while IFS='	' read -r name class template qtype extra || [ -n "$name" ]; do
  case "$name" in ''|'#'*) continue ;; esac
  [ -z "${extra:-}" ] || die "workload row '$name' has more than four columns"
  if [ "$name" = "$workload" ]; then
    w_class="$class" w_template="$template" w_qtype="$qtype"
  fi
done <"$workloads"
[ -n "$w_template" ] || die "unknown workload '$workload' (not in $workloads)"
# DEC-014: timed from the restart command by target.sh arm-set, never here.
[ "$workload" != restart ] || die "workload 'restart' is timed from the stack restart by target.sh arm-set, not by collect.sh"
case "$w_template" in *[!a-z0-9.{}-]*) die "workload '$workload' template has unexpected characters" ;; esac
case "$w_qtype" in ''|*[!A-Z0-9]*) die "workload '$workload' qtype is invalid" ;; esac

# Existing output must be ours; ids continue from its row count.
next_id=1
if [ -e "$out" ]; then
  [ -f "$out" ] && [ ! -L "$out" ] || die "--out exists and is not a regular file: $out"
  [ "$(sed -n 1p "$out")" = "# schema	$SCHEMA" ] || die "--out has a different schema: $out"
  [ "$(sed -n 2p "$out")" = "$COLUMNS" ] || die "--out has a different header: $out"
  next_id=$(( $(grep -vc '^#' "$out") ))
fi

run_id="${RUN_ID:-standalone-$(date -u +%Y%m%dT%H%M%SZ)}"
if [ "$next_id" -gt 1 ]; then
  prev_runs="$(awk -F '	' 'NR > 2 && !/^#/ { print $1 }' "$out" | sort -u)"
  [ "$prev_runs" = "$run_id" ] || die "--out holds samples from run '$prev_runs', not '$run_id': one file holds one run"
fi

nonce() { od -An -N8 -tx1 /dev/urandom | tr -d ' \n'; }

# One timed dig. Prints: elapsed_us, utc_start, dig exit code, then dig stdout.
timed_dig() {
  perl -MTime::HiRes=clock_gettime,CLOCK_MONOTONIC,time -MPOSIX=strftime -e '
    my $wall = time;
    my $t0 = clock_gettime(CLOCK_MONOTONIC);
    my $out = ""; my $rc = 127;
    if (open(my $fh, "-|", @ARGV)) { local $/; $out = <$fh> // ""; close($fh); $rc = $? >> 8; }
    my $us = int((clock_gettime(CLOCK_MONOTONIC) - $t0) * 1e6); $us = 1 if $us < 1;
    printf "%d\n%s.%06dZ\n%d\n%s", $us, strftime("%Y-%m-%dT%H:%M:%S", gmtime($wall)),
      int(($wall - int($wall)) * 1e6), $rc, $out;' "$@"
}

if [ ! -e "$out" ]; then
  (umask 077 && printf '# schema\t%s\n%s\n' "$SCHEMA" "$COLUMNS" >"$out") || die "cannot write $out"
fi

failed=0 i=0
tflag=''
[ "$transport" = tcp ] && tflag='+tcp'
while [ "$i" -lt "$count" ]; do
  i=$((i + 1))
  if [ "$i" -gt 1 ] && [ "$pause_ms" -gt 0 ]; then
    sleep "$(awk -v m="$pause_ms" 'BEGIN { printf "%.3f", m / 1000 }')"
  fi
  qname="$w_template"
  case "$qname" in *'{nonce}'*) qname="$(nonce)${qname#*\{nonce\}}" ;; esac
  res="$(timed_dig dig "@$addr" -p "$port" ${tflag:+"$tflag"} +tries=1 +time=$((timeout_ms / 1000)) \
    +noall +comments "$qname" "$w_qtype")"
  elapsed="$(printf '%s\n' "$res" | sed -n 1p)"
  utc="$(printf '%s\n' "$res" | sed -n 2p)"
  drc="$(printf '%s\n' "$res" | sed -n 3p)"
  rcode="$(printf '%s\n' "$res" | sed -n 's/.*status: \([A-Z]*\).*/\1/p' | head -1)"
  case "$rcode" in
    NOERROR) outcome=ok ;;
    NXDOMAIN) outcome=nxdomain ;;
    SERVFAIL) outcome=servfail ;;
    REFUSED) outcome=refused ;;
    '') rcode='-'; if [ "$drc" = 9 ]; then outcome=timeout; else outcome=error; fi ;;
    *) outcome=error ;;
  esac
  case "$outcome" in ok|nxdomain) ;; *) failed=$((failed + 1)) ;; esac
  printf '%s\t%d\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$run_id" "$next_id" "$utc" "$elapsed" "$workload" "$w_class" \
    "$id_target_id" "$id_platform" "$id_proxy" "$id_pihole" "$id_source_rev" "$id_images" \
    "$addr#$port" "$transport" "$qname" "$w_qtype" "$outcome" "$rcode" "$timeout_ms" >>"$out"
  next_id=$((next_id + 1))
done

printf 'collect.sh: workload=%s attempted=%d failed=%d out=%s\n' "$workload" "$count" "$failed" "$out"
[ "$failed" -eq 0 ]
