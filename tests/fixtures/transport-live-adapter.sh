#!/usr/bin/env bash
# Fake target adapter for the transport-live dry run (Sub-plan 4 Task 2.3,
# BL-042): the operations live/transport-live adds, with target.sh's report
# formats. Snapshots, lifecycle reports and validate go on to
# tests/fixtures/command-recovery-adapter.sh. Every operation is appended to
# $IL_FAKE_DIR/<alias>/oplog. One defect can be seeded by writing its name to
# $IL_FAKE_DIR/break:
#   dnssec-noerror  dnssec-failed.org answers NOERROR through the client resolver
#   no-ad           the signed name has no `ad` at Unbound (no validation)
#   unsigned-ad     the "unsigned" name carries `ad` (it is signed after all)
#   tcp-8953        something listens on TCP 8953 in the Unbound container
#   control-tcp     the control interface is an address, not a Unix socket
#   tls-answers     a fresh name still answers under the wrong TLS name
#   heal-fails      no fresh name answers after heal-route
#   fault-fails     fault-route exits 1
#   cold-before-heal  no fresh name answers until a heal-route ran (a cold or
#                   dead upstream, which a TLS fault cannot be told from)
#   control-fails   a fresh name fails under the route's own name (tls-control)
#   cd-servfail     dnssec-failed.org is SERVFAIL at Unbound even with +cd
# Nothing here touches the host.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
op="${1:-}"
case "$op" in
  transport-report|fault-route|heal-route|fresh-name) ;;
  *) exec bash "$HERE/command-recovery-adapter.sh" "$@" ;;
esac
alias_="${2:-}"
shift 2
F="${IL_FAKE_DIR:-${ARTIFACT_DIR:?}/il-fake}"
mkdir -p "$F/$alias_"
printf '%s\n' "$op" >>"$F/$alias_/oplog"
brk="$(cat "$F/break" 2>/dev/null || true)"
is() { [ "$brk" = "$1" ]; }
mode="" route=""
while [ $# -gt 0 ]; do
  case "$1" in
    --mode) mode="$2"; shift 2 ;;
    --route) route="$2"; shift 2 ;;
    *) shift ;;
  esac
done
case "$alias_" in mac1) plat=macos ;; *) plat=linux ;; esac
idrows() { printf 'machine_id\tfake-%s\nhostname\t%s\nplatform\t%s\n' "$alias_" "$alias_" "$plat"; }
case "$op" in
  transport-report)
    idrows
    printf 'section\ttransport\n'
    printf 'route\trunning\tcloudflare-onion\t7\nproxy_generation\trunning\tc0ffee 2026-01-01T00:00:00Z running\n'
    b=SERVFAIL; is dnssec-noerror && b=NOERROR
    sa=ad; is no-ad && sa=noad
    ua=noad; is unsigned-ad && ua=ad
    printf 'dnssec\tclient\tsigned\tcloudflare.com\tNOERROR\tnoad\n'
    printf 'dnssec\tclient\tunsigned\tneverssl.com\tNOERROR\tnoad\n'
    printf 'dnssec\tclient\tbogus\tdnssec-failed.org\t%s\tnoad\n' "$b"
    printf 'dnssec\tunbound\tsigned\tcloudflare.com\tNOERROR\t%s\n' "$sa"
    printf 'dnssec\tunbound\tunsigned\tneverssl.com\tNOERROR\t%s\n' "$ua"
    printf 'dnssec\tunbound\tbogus\tdnssec-failed.org\tSERVFAIL\tnoad\n'
    c=NOERROR; is cd-servfail && c=SERVFAIL
    printf 'dnssec\tunbound\tbogus-cd\tdnssec-failed.org\t%s\tnoad\n' "$c"
    if is tcp-8953; then printf 'control\ttcp_8953\tlistening\n'; else printf 'control\ttcp_8953\tnone\n'; fi
    if is control-tcp; then
      printf 'control\tinterface\t127.0.0.1\ncontrol\tsocket\tabsent\n'
    else
      printf 'control\tinterface\t/run/unbound/control.sock\ncontrol\tsocket\tunix\n'
    fi
    printf 'control\tanswers\tyes\n' ;;
  fault-route|heal-route)
    case "$mode" in tls-name|tls-control) ;; *) echo "the fake knows only --mode tls-name|tls-control" >&2; exit 2 ;; esac
    [ "$route" = cloudflare-onion ] || { echo "the running route is cloudflare-onion, not $route" >&2; exit 2; }
    if [ "$op" = fault-route ]; then
      if [ "$mode" = tls-control ]; then
        rm -f "$F/$alias_/faulted"; : >"$F/$alias_/control"
        printf 'tls_name\tcontrol\t%s\nforwarder\t127.0.0.1@18531#tor.cloudflare-dns.com\n' "$route"
      else
        is fault-fails && { echo "unbound-control forward_add failed" >&2; exit 1; }
        rm -f "$F/$alias_/control"; : >"$F/$alias_/faulted"
        printf 'tls_name\tfaulted\t%s\nforwarder\t127.0.0.1@18531#nd-wrong-name.invalid\n' "$route"
      fi
    else
      rm -f "$F/$alias_/faulted" "$F/$alias_/control"
      printf 'tls_name\thealed\t%s\nforwarder\t127.0.0.1@18531#tor.cloudflare-dns.com\n' "$route"
    fi ;;
  fresh-name)
    idrows
    n="nd-cr-$(date +%s)-$$.example.com"
    if [ -f "$F/$alias_/faulted" ]; then
      st=SERVFAIL; is tls-answers && st=NXDOMAIN
    elif is cold-before-heal && ! grep -qx heal-route "$F/$alias_/oplog"; then
      st=SERVFAIL
    elif [ -f "$F/$alias_/control" ] && is control-fails; then
      st=SERVFAIL
    elif is heal-fails && grep -qx heal-route "$F/$alias_/oplog"; then
      st=SERVFAIL
    else
      st=NXDOMAIN
    fi
    printf 'fresh_name\t%s\t%s\n' "$n" "$st" ;;
esac
exit 0
