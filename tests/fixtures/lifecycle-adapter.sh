#!/usr/bin/env bash
# Fake target adapter for the install-lifecycle dry run (Sub-plan 4 Task 2.3):
# stands in for tests/live/target.sh with the same operation names, arguments
# and report format, and keeps each fake target's state under IL_FAKE_DIR
# (default $ARTIFACT_DIR/il-fake). One defect can be seeded by writing its
# name to $IL_FAKE_DIR/break:
#   admin-open        the admin API answers an anonymous request (200)
#   public-sample     one resolver sample during an install is public DNS
#   marker-lost       a reinstall loses the Tor, anchor and lists marks
#   volume-left       uninstall leaves the state volumes
#   dns-not-restored  uninstall leaves the resolver pinned
#   image-mismatch    Pi-hole runs an image that is not the generation's
#   sudoers-extra     the macOS sudoers rule allows one more command
#   listen-all        Linux publishes :53 on every interface
# Nothing here touches the host.
set -u
op="${1:-}"; shift || true
alias_=""
[ "$op" = validate ] || { alias_="${1:-}"; shift || true; }
cell=""
while [ $# -gt 0 ]; do
  case "$1" in --cell) cell="$2"; shift 2 ;; --targets|--source-sha) shift 2 ;; *) shift ;; esac
done
F="${IL_FAKE_DIR:-${ARTIFACT_DIR:?}/il-fake}"
brk="$(cat "$F/break" 2>/dev/null || true)"
case "$alias_" in lin1) plat=linux ;; mac1) plat=macos ;; *) plat="" ;; esac
S="$F/$alias_"
get() { cat "$S/$1" 2>/dev/null || printf '%s\n' "${2:-}"; }
put() { mkdir -p "$S"; printf '%s\n' "$2" >"$S/$1"; }

if [ "$op" = validate ]; then printf 'lin1\tlinux\tlin1-ssh\nmac1\tmacos\tmac1-ssh\n'; exit 0; fi
mkdir -p "$S"
[ -f "$S/installed" ] || { put installed legacy; put proxy "$([ "$plat" = linux ] && echo haproxy || echo socat)"; put dns pinned; put gen 0; }
inst="$(get installed)" proxy="$(get proxy)" gen="$(get gen 0)" dns="$(get dns)"

report() {
  local m
  printf 'machine_id\tfake-%s\nplatform\t%s\nnow\t%s\n' "$alias_" "$plat" "$(date +%s)"
  printf 'section\tdns\n'
  if [ "$plat" = linux ]; then
    if [ "$dns" = pinned ]; then printf 'resolv.conf\t/etc/resolv.conf\nnameserver 127.0.0.1\nsystemd-resolved\tinactive\n'
    else printf 'resolv.conf\t/run/systemd/resolve/stub-resolv.conf\nnameserver 127.0.0.53\nsystemd-resolved\tactive\n'; fi
    printf 'section\tunits\n'
  else
    for s in Wi-Fi Ethernet; do
      if [ "$dns" = pinned ]; then printf '%s\t172.31.240.250 \n' "$s"; else printf "%s\tThere aren't any DNS Servers set on %s. \n" "$s" "$s"; fi
    done
    printf 'section\tagents\n'
  fi
  printf 'section\tgeneration\n'
  if [ "$inst" = 1 ]; then
    printf 'current\tgen-%s\n' "$gen"
    printf 'image\tunbound\tlocalhost/unbound:gen-%s\tu%063d\n' "$gen" "$gen"
    printf 'image\tpi-hole\tlocalhost/pi-hole:gen-%s\tp%063d\n' "$gen" "$gen"
    printf 'image\tproxy\tlocalhost/tor-%s:gen-%s\tt%063d\n' "$proxy" "$gen" "$gen"
  else printf 'current\tnone\n'; fi
  printf 'section\trunning\n'
  if [ "$inst" != 0 ]; then
    local pi
    pi="p$(printf '%063d' "$gen")"
    [ "$brk" = image-mismatch ] && pi="x$(printf '%063d' "$gen")"
    if [ "$plat" = macos ]; then pfx=sha256:; else pfx=; fi
    printf 'running\tpi-hole\t%s%s\nrunning\tunbound\t%su%063d\nrunning\ttor-%s\t%st%063d\n' "$pfx" "$pi" "$pfx" "$gen" "$proxy" "$pfx" "$gen"
  fi
  printf 'section\tcontroller\n'
  [ "$inst" = 1 ] && printf 'schema\tnice-dns-health-install/1\nentrypoint\t/home/t/.local/bin/nice-dns-health\n'
  printf 'section\tvolumes\n'
  if [ "$inst" = 1 ] || { [ "$inst" = 0 ] && [ "$brk" = volume-left ]; }; then
    printf 'volume\tnice-dns-pihole-lists\nvolume\tnice-dns-unbound-anchor\n'
    [ "$plat" = linux ] && printf 'volume\tnice-dns-tor-%s\n' "$proxy"
  fi
  printf 'section\tstate\n'
  if [ "$inst" != 0 ]; then
    m="$(get mark)"
    printf 'tor_marker\ttor-%s\t%s\ntor_state_file\ttor-%s\tpresent\n' "$proxy" "$m" "$proxy"
    printf 'anchor_marker\t%s\nanchor_file\tpresent\n' "$m"
    printf 'lists_seed\tseed%s\tseed%s\n' "$gen" "$gen"
    printf 'lists_marker_rules\t%s\n' "$([ -n "$m" ] && echo "$m.example")"
  fi
  printf 'section\tadmin\n'
  if [ "$inst" = 1 ]; then
    printf 'admin_secret_mode\t-rw-------\n'
    printf 'anonymous\t%s\n' "$([ "$brk" = admin-open ] && echo 200 || echo 401)"
    printf 'wrong\t"valid":false\nright\t"valid":true\n'
  else printf 'admin_secret_mode\t\nanonymous\t000\n'; fi
  printf 'section\tlisteners\n'
  if [ "$plat" = linux ] && [ "$inst" != 0 ]; then
    printf 'listen\tudp\t%s:53\nlisten\ttcp\t%s:53\n' "$([ "$brk" = listen-all ] && echo 0.0.0.0 || echo 127.0.0.1)" "127.0.0.1"
  fi
  printf 'section\tprivilege\n'
  if [ "$plat" = macos ] && [ "$inst" != 0 ]; then
    printf 'sudoers\tt ALL=(root) NOPASSWD: /usr/local/sbin/start-container-root.sh pre, /usr/local/sbin/start-container-root.sh repair-dnsnet, /usr/local/sbin/start-container-root.sh post%s\n' \
      "$([ "$brk" = sudoers-extra ] && echo ', /bin/sh')"
  fi
  printf 'section\tschedules\n'
  if [ "$plat" = macos ]; then
    [ "$inst" != 0 ] && printf 'agent\torg.nice-dns.start-container\nagent\torg.nice-dns.health\n'
    printf 'agent\torg.nice-dns.debug-monitor\n'
  elif [ "$inst" != 0 ]; then printf 'unit\tnice-dns-health.timer\tenabled\n'; fi
}

case "$op" in
  snapshot) echo "snapshot $alias_" ;;
  lifecycle-report) report ;;
  watch-dns)
    pinned=0; [ "$dns" = pinned ] && pinned=1
    for i in 1 2 3 4 5; do
      [ "$i" = 3 ] && pinned=1   # an install pins by the third sample at the latest
      if [ "$brk" = public-sample ] && [ "$i" = 4 ]; then s=public
      elif [ "$pinned" = 1 ]; then s=pinned; else s=restored; fi
      if [ "$plat" = linux ]; then
        case "$s" in pinned) v='file;127.0.0.1 ' ;; public) v='file;9.9.9.9 ' ;; *) v='../run/systemd/resolve/stub-resolv.conf;127.0.0.53 ' ;; esac
      else
        case "$s" in pinned) v='Wi-Fi=172.31.240.250;Ethernet=172.31.240.250;' ;; public) v='Wi-Fi=9.9.9.9;Ethernet=172.31.240.250;' ;;
          *) v="Wi-Fi=There aren't any DNS Servers set on Wi-Fi.;Ethernet=There aren't any DNS Servers set on Ethernet.;" ;; esac
      fi
      printf '%s\t%s\n' "$(( $(date +%s) + i * 2 ))" "$v"
    done ;;
  install-cell)
    sleep 1
    put installed 1; put gen $((gen + 1)); put proxy "${cell%/*}"; put dns pinned
    [ "$brk" = marker-lost ] && put mark ""
    echo "fake install ${cell}" ;;
  uninstall-cell)
    sleep 1
    put installed 0; put mark ""
    [ "$brk" = dns-not-restored ] || put dns restored
    echo "fake uninstall" ;;
  mark-state) put mark "nd-live-${RUN_ID:?}"; printf 'marked\tunbound\n' ;;
  *) echo "fake adapter: unsupported op $op" >&2; exit 2 ;;
esac
