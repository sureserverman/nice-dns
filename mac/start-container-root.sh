#!/usr/bin/env bash
# Privileged pre/post helper for mac/start-container.sh.
#
# pre:           tear down Mullvad (if installed) so it doesn't fight the
#                stack coming up. No-op if Mullvad isn't present.
# repair-dnsnet: unload the stuck Apple vmnet helper for dnsnet and restart
#                InternetSharing so a repaired dnsnet definition can be used.
# post:          pin macOS system DNS to the pi-hole container IP and
#                re-bootstrap Mullvad if we took it down.
#
# Installer verbs (Sub-plan 4 Task 1.2; ARCH-06, WF-DNS-003). They run under
# the operator's own sudo during an install or uninstall and are never in the
# LaunchAgent's NOPASSWD rule (mac/start-container.sudoers):
# snapshot:      record every network service's DNS servers before nice-dns
#                pins them (first install only; a reinstall keeps the first
#                record, which is the state before nice-dns).
# check:         exit 3 when another owner changed a recorded service's DNS
#                servers after nice-dns pinned them; an install refuses then.
# restore:       give each pinned service back its recorded servers
#                (uninstall); a service another owner changed is left alone.
# status:        print pinned (every service at the pi-hole) or unpinned.
# discard:       drop an unused record: a first install that failed before its
#                pin (refused once any service carries the pin).
#
# Only the services' DNS server lists are owned. The record lives in a
# root-only directory and is data, never sourced. ND_DNS_TEST_ROOT prefixes
# the paths for the fixture tests and is honoured only when not running as
# root, so a root run always acts on the real host.

set -euo pipefail

R=""
if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
  if [[ -n ${ND_DNS_TEST_ROOT:-} ]]; then
    R="$ND_DNS_TEST_ROOT"
  else
    echo "run as root" >&2
    exit 1
  fi
fi

MULLVAD_PLIST="$R/Library/LaunchDaemons/net.mullvad.daemon.plist"
PIHOLE_IP=172.31.240.250
DNSNET_LABEL=com.apple.container.container-network-vmnet.dnsnet
RECEIPT_DIR="$R/var/db/nice-dns/dns-owned"
RECEIPT="$RECEIPT_DIR/receipt.tsv"
SCHEMA='nice-dns-dns-owned/1'

restart_internetsharing() {
  launchctl kickstart -k system/com.apple.InternetSharing 2>/dev/null \
    || launchctl start system/com.apple.InternetSharing 2>/dev/null \
    || true
}

# services: the enabled network services, one per line.
services() { networksetup -listallnetworkservices | sed '1d' | { grep -v '^\*' || true; }; }

set_local_dns() {
  services | while read -r svc; do
    networksetup -setdnsservers "$svc" "$PIHOLE_IP" 2>/dev/null || true
  done
}

# dns_of <service>: its DNS servers, space-separated, or Empty.
dns_of() {
  local out
  out="$(networksetup -getdnsservers "$1" 2>/dev/null || true)"
  if printf '%s\n' "$out" | grep -Eq '^[0-9a-fA-F.:]+$'; then
    printf '%s\n' "$out" | grep -E '^[0-9a-fA-F.:]+$' | tr '\n' ' ' | sed 's/ $//'
  else
    echo Empty
  fi
}

receipt_ok() {
  [[ -d $RECEIPT_DIR && ! -L $RECEIPT_DIR && -f $RECEIPT && ! -L $RECEIPT ]] || return 1
  [[ "$(head -n 1 "$RECEIPT")" == "schema	$SCHEMA" ]]
}

# recorded_dns <service>: the recorded servers, or Empty for a service the
# record does not know (added after the install).
recorded_dns() {
  awk -F '\t' -v s="$1" '$1 == "service" && $2 == s { print $3; f = 1; exit } END { if (!f) print "Empty" }' "$RECEIPT"
}

all_pinned() {
  local svc n=0
  while IFS= read -r svc; do
    [[ -n $svc ]] || continue
    n=$((n + 1))
    [[ "$(dns_of "$svc")" == "$PIHOLE_IP" ]] || return 1
  done < <(services)
  (( n > 0 ))
}

any_pinned() {
  local svc
  while IFS= read -r svc; do
    [[ -n $svc ]] || continue
    [[ "$(dns_of "$svc")" == "$PIHOLE_IP" ]] && return 0
  done < <(services)
  return 1
}

cmd_snapshot() {
  local tmp svc origin=fresh
  if receipt_ok; then
    echo "keeping the existing record of the DNS state before nice-dns"
    return 0
  fi
  if [[ -L $R/var/db/nice-dns || -L $RECEIPT_DIR ]]; then
    echo "$R/var/db/nice-dns is a symlink; refusing" >&2
    return 1
  fi
  mkdir -p "$RECEIPT_DIR"
  chmod 700 "$R/var/db/nice-dns" "$RECEIPT_DIR"
  # An install from before records (its agent's helper is installed): the
  # servers before nice-dns are unknown. (A service an operator had set to
  # 172.31.240.250 by hand before any nice-dns install would be taken for the
  # pin; nothing else uses that dnsnet address.) A service carrying the pin is
  # recorded as Empty (DHCP), which is what earlier uninstalls set; one that
  # does not carry it keeps its current servers.
  if [[ -e $R/usr/local/sbin/start-container.sh ]] && any_pinned; then origin=legacy; fi
  tmp="$(mktemp "$RECEIPT_DIR/.receipt.XXXXXX")"
  {
    printf 'schema\t%s\norigin\t%s\ncreated\t%s\n' "$SCHEMA" "$origin" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    while IFS= read -r svc; do
      [[ -n $svc ]] || continue
      if [[ $origin == legacy && "$(dns_of "$svc")" == "$PIHOLE_IP" ]]; then
        printf 'service\t%s\tEmpty\n' "$svc"
      else
        printf 'service\t%s\t%s\n' "$svc" "$(dns_of "$svc")"
      fi
    done < <(services)
  } >"$tmp"
  chmod 600 "$tmp"
  mv -f "$tmp" "$RECEIPT"
  echo "recorded the DNS servers of every network service ($origin)"
}

cmd_check() {
  local svc cur bad=0
  # Before a record exists nothing is ours yet: any state is the owner's.
  receipt_ok || return 0
  while IFS= read -r svc; do
    [[ -n $svc ]] || continue
    # A service the record does not know appeared after the install; its
    # DHCP servers are not another owner's change.
    awk -F '\t' -v s="$svc" '$1 == "service" && $2 == s { f = 1 } END { exit !f }' "$RECEIPT" || continue
    cur="$(dns_of "$svc")"
    if [[ $cur != "$PIHOLE_IP" ]]; then
      echo "the DNS servers of '$svc' were changed by another owner after nice-dns pinned them ($cur)" >&2
      bad=1
    fi
  done < <(services)
  if (( bad )); then
    echo "not changing them. Run the uninstall to restore the recorded state, then install again." >&2
    return 3
  fi
}

cmd_restore() {
  local svc cur rec have=1 failed=0
  if ! receipt_ok; then
    have=0
    echo "no record of the DNS state before nice-dns; setting the pinned services to Empty (DHCP)" >&2
  fi
  while IFS= read -r svc; do
    [[ -n $svc ]] || continue
    cur="$(dns_of "$svc")"
    # Already as recorded (a first install that failed before its pin).
    if (( have )) && [[ $cur == "$(recorded_dns "$svc")" ]]; then continue; fi
    if [[ $cur != "$PIHOLE_IP" ]]; then
      echo "leaving '$svc' as it is ($cur): another owner changed it" >&2
      continue
    fi
    if (( have )); then rec="$(recorded_dns "$svc")"; else rec=Empty; fi
    # One failure does not stop the others; it keeps the record for a retry.
    # shellcheck disable=SC2086 # a recorded list is one word per server
    if ! networksetup -setdnsservers "$svc" $rec; then
      echo "could not restore the DNS servers of '$svc' (still the nice-dns pin)" >&2
      failed=1
    fi
  done < <(services)
  if (( failed )); then
    echo "the restore did not complete; the record is kept: run it again" >&2
    return 1
  fi
  rm -f "${RECEIPT_DIR:?}/receipt.tsv"
  rmdir "$RECEIPT_DIR" 2>/dev/null || true
  echo "restored the DNS servers recorded before nice-dns"
}

cmd_discard() {
  receipt_ok || return 0
  if any_pinned; then
    echo "a network service carries the nice-dns pin; use restore, not discard" >&2
    return 1
  fi
  rm -f "${RECEIPT_DIR:?}/receipt.tsv"
  rmdir "$RECEIPT_DIR" 2>/dev/null || true
}

case "${1:-}" in
  pre)
    if [[ -f "$MULLVAD_PLIST" ]]; then
      launchctl bootout system/net.mullvad.daemon 2>/dev/null || true
    fi
    ;;
  repair-dnsnet)
    if [[ -n ${SUDO_UID:-} ]]; then
      launchctl bootout "gui/${SUDO_UID}/${DNSNET_LABEL}" 2>/dev/null || true
    fi
    restart_internetsharing
    ;;
  post)
    if [[ -f "$MULLVAD_PLIST" ]]; then
      launchctl bootstrap system "$MULLVAD_PLIST" 2>/dev/null || true
    fi
    set_local_dns
    ;;
  snapshot) cmd_snapshot ;;
  check) cmd_check ;;
  restore) cmd_restore ;;
  status) if all_pinned; then echo pinned; else echo unpinned; fi ;;
  discard) cmd_discard ;;
  *)
    echo "usage: $0 {pre|repair-dnsnet|post|snapshot|check|restore|status|discard}" >&2
    exit 2
    ;;
esac
