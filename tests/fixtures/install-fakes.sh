# shellcheck shell=bash
# shellcheck disable=SC2034  # IP_* are read by the groups that source this file
# Installer fakes shared by integration/install-prepare (Sub-plan 4 Task 1.1)
# and integration/dns-transaction (Task 1.2). Sourced by group files; the
# runner provides CASE_DIR and the assert_* helpers. Each public installer
# entrypoint runs against a private HOME, a copy of the checkout and PATH
# stubs for every external command it calls; the stubs log their argv to
# $FAKE_LOG and never touch the host.
#
# By default sudo runs nothing. With $FAKE_ROOT set (ip_world), sudo runs the
# DNS helpers (deb/custom-dns-deb, mac/start-container-root.sh) as the test
# user with ND_DNS_TEST_ROOT=$FAKE_ROOT, and any command whose arguments name
# a path under $FAKE_ROOT; systemctl, sysctl and networksetup then keep their
# state under $FAKE_ROOT. Everything else stays a logged no-op.

IP_TOOLS="awk basename bash cat chmod cmp cp cut date dirname env find grep head id install ln ls mkdir mktemp mv od readlink rm rmdir sed seq sh sha256sum sort stat tail tee test touch tr uniq wc xargs yes"
IP_ALL="install-deb install-deb-hardened install-mac install-mac-hardened"

# The interruption predicate (requirement 4): a call that interrupts the
# running stack or touches host DNS. Preparation makes none of these.
IP_DISRUPTIVE='^sudo tee /etc/resolv\.conf( |$)
^sudo ([^ ]*/)?usr/bin/custom-dns-deb( |$)
^sudo bash [^ ]*/custom-dns-deb (pin|restore)$
^(sudo )?networksetup -setdnsservers( |$)
^sudo systemctl (reload|restart) NetworkManager( |$)
^sudo sed .*NetworkManager\.conf
^sudo tee /etc/NetworkManager/
^sudo systemctl (disable --now|stop|restart|enable --now) custom-dns-deb
^podman (stop|kill|restart|rm|rmi|pod (rm|stop|kill|restart)|network (rm|prune|reload)|image (rm|prune)|system (migrate|reset|prune))( |$)
^systemctl --user (stop|restart|try-restart|reload-or-restart|kill|disable --now)
^container (stop|kill|rm|delete|network (rm|delete)|image (rm|delete|prune)|system stop)( |$)
^(sudo )?launchctl (unload|bootout|remove|kickstart)( |$)
^(HOMEBREW_NO_AUTO_UPDATE=1 )?brew upgrade( --formula)? container
^sudo .*start-container-root\.sh (pre|post|repair-dnsnet|restore)$
^persistent-podman\.sh
^persist\.sh'
# The subset that writes host DNS.
IP_DNS_WRITE='^sudo tee /etc/resolv\.conf( |$)
^sudo ([^ ]*/)?usr/bin/custom-dns-deb( |$)
^sudo bash [^ ]*/custom-dns-deb (pin|restore)$
^(sudo )?networksetup -setdnsservers( |$)
^sudo .*start-container-root\.sh post
^sudo tee /etc/NetworkManager/'
IP_BUILD_PULL='^(podman (build|pull)|container (build|image pull))( |$)'

ip_entrypoints() {
  local e="${NICE_DNS_OPT_ENTRYPOINTS:-all}" x out=""
  [ "$e" = all ] && { printf '%s\n' "$IP_ALL"; return 0; }
  for x in $(printf '%s' "$e" | tr ',' ' '); do
    case " $IP_ALL " in *" $x "*) out="$out $x" ;; *) fail "unknown --entrypoints value '$x' (all, $(printf '%s' "$IP_ALL" | tr ' ' ','))" ;; esac
  done
  [ -n "$out" ] || fail "--entrypoints selected nothing"
  printf '%s\n' "$out"
}
# ip_select: IP_EPS, the selected entrypoints; an invalid selection fails the
# case (a failure inside $(...) alone would only end the substitution).
ip_select() { IP_EPS="$(ip_entrypoints)" || exit 1; }
ip_platform() { case "$1" in install-deb*) echo linux ;; *) echo macos ;; esac; }
ip_flavor() { case "$1" in *-hardened) echo hardened ;; *) echo standard ;; esac; }

# ip_write_stubs <bindir> <platform>: one POSIX sh fake behind every name.
ip_write_stubs() {
  local b="$1" plat="$2" s
  mkdir -p "$b"
  cat >"$b/fakecmd" <<'STUB'
#!/bin/sh
me="$(basename "$0")"
l="$me"; for a in "$@"; do l="$l $a"; done
# brew's offline mode is part of what an install asks for: log it.
[ "$me" = brew ] && [ "${HOMEBREW_NO_AUTO_UPDATE:-}" = 1 ] && l="HOMEBREW_NO_AUTO_UPDATE=1 $l"
printf '%s\n' "$l" >>"$FAKE_LOG"
# Switchable failure: a line of $FAKE/fail is an ERE matched against the call.
if [ -s "$FAKE/fail" ] && printf '%s\n' "$l" | grep -Eq -f "$FAKE/fail"; then
  echo "$me: injected failure" >&2; exit 1
fi
# Switchable interrupt: the installer gets SIGINT (Ctrl-C) at a matching call.
if [ -s "$FAKE/sigint" ] && printf '%s\n' "$l" | grep -Eq -f "$FAKE/sigint"; then
  echo "$me: injected interrupt" >&2; kill -INT "$PPID"; exit 1
fi
store="$FAKE/images"; touch "$store"
# unbound_start <how>: the route include Unbound reads when it starts
# ($FAKE/unbound-starts; Sub-plan 5 Task 1.2): its marker, or route-absent.
unbound_start() {
  rf="${XDG_STATE_HOME:-$HOME/.local/state}/nice-dns/unbound-route/forward-route.conf"
  if [ -f "$rf" ]; then m="$(sed -n 's/.*"\(route=[^"]*\)".*/\1/p' "$rf")"; else m=route-absent; fi
  printf '%s %s\n' "$1" "$m" >>"$FAKE/unbound-starts"
}
case "$l" in "container run -d --name unbound "*) unbound_start "container run" ;; esac
img_has() { awk -v r="$1" '$1 == r { f = 1 } END { exit !f }' "$store"; }
img_id() { awk -v r="$1" '$1 == r { print $2; exit }' "$store"; }
img_add() { awk -v r="$1" '$1 != r' "$store" >"$store.t"; printf '%s %s\n' "$1" "$2" >>"$store.t"; mv "$store.t" "$store"; }
img_del() { awk -v r="$1" '$1 != r' "$store" >"$store.t"; mv "$store.t" "$store"; }
new_id() { n="$(cat "$FAKE/idseq" 2>/dev/null || echo 0)"; n=$((n + 1)); echo "$n" >"$FAKE/idseq"; printf '%064x\n' "$n"; }
# build <args>: -t refs, --build-arg BASE_IMAGE=x must exist in the store.
do_build() {
  tags=""
  while [ $# -gt 0 ]; do
    case "$1" in
      -t|--tag) tags="$tags $2"; shift ;;
      --build-arg) case "$2" in BASE_IMAGE=*) img_has "${2#BASE_IMAGE=}" || { echo "base ${2#BASE_IMAGE=} not found" >&2; exit 1; } ;; esac; shift ;;
      -f|--file) shift ;;
    esac
    shift
  done
  printf '%s\n' "$PWD" >>"$FAKE/build-cwd"
  id="$(new_id)"
  for t in $tags; do img_add "$t" "$id"; done
  return 0
}
case "$me" in
  sudo)
    # In a world ($FAKE_ROOT), the DNS helpers and commands on paths under
    # the fake root run, as this user; nothing else ever does.
    if [ -n "${FAKE_ROOT:-}" ]; then
      # Only when every absolute path argument lies inside the test world.
      run=0 safe=1
      for a in "$@"; do
        case "$a" in "$FAKE_ROOT"/*|*/custom-dns-deb|*/start-container-root.sh) run=1 ;; esac
        case "$a" in /*) case "$a" in "${FAKE%/fake}"/*) ;; *) safe=0 ;; esac ;; esac
      done
      if [ "$run" = 1 ] && [ "$safe" = 1 ]; then ND_DNS_TEST_ROOT="$FAKE_ROOT"; export ND_DNS_TEST_ROOT; exec "$@"; fi
    fi
    # Otherwise never runs anything; a helper's status reads pinned. tee's
    # input and an install's source are kept for inspection.
    if [ "$1" = install ]; then
      n=$#; src="$(eval "printf '%s' \"\${$((n - 1))}\"")"; for a in "$@"; do p="$a"; done
      [ -f "$src" ] && cp "$src" "$FAKE/sudo-install$(printf '%s' "$p" | tr '/' '_')"
    fi
    case "$*" in *custom-dns-deb\ status|*start-container-root.sh\ status) echo pinned ;; esac
    if [ "$1" = tee ]; then
      for a in "$@"; do p="$a"; done
      cat >"$FAKE/sudo-tee$(printf '%s' "$p" | tr '/' '_')"
    fi
    exit 0 ;;
  podman)
    if [ -n "${FAKE_ROOT:-}" ]; then
      case "$1 $2" in "pod rm") rm -f "$FAKE/dns_up" ;; esac
    fi
    case "$1 $*" in exec*probe-route*)
      [ -f "$FAKE/probe_fail" ] && exit 1
      [ -n "${FAKE_ROOT:-}" ] && [ ! -f "$FAKE/dns_up" ] && exit 1
      exit 0 ;;
    esac
    case "$1" in
      ps) cat "$FAKE/podman_ps" 2>/dev/null ;;
      --version) echo "podman version 5.8.1" ;;
      info) echo "1.14.0" ;;
      build) shift; do_build "$@" ;;
      pull) img_has "$2" || img_add "$2" "$(new_id)" ;;
      tag) img_has "$2" || exit 125; img_add "$3" "$(img_id "$2")" ;;
      image)
        case "$2" in
          exists) img_has "$3" || exit 1 ;;
          inspect) for r in "$@"; do :; done; img_has "$r" || exit 125; img_id "$r" ;;
          rm) shift 2; for r in "$@"; do case "$r" in -*) ;; *) img_del "$r" ;; esac; done ;;
        esac ;;
      rmi) shift; for r in "$@"; do case "$r" in -*) ;; *) img_del "$r" ;; esac; done ;;
    esac
    exit 0 ;;
  container)
    # A stopped runtime ($FAKE/rt_down) answers no image call until it starts.
    if [ -f "$FAKE/rt_down" ]; then
      case "$1 $2" in "system start") rm -f "$FAKE/rt_down" ;; "image "*) echo "Error: the container system is not running" >&2; exit 1 ;; esac
    fi
    case "$1 $*" in exec*probe-route*)
      [ -f "$FAKE/probe_fail" ] && exit 1
      [ -n "${FAKE_ROOT:-}" ] && [ ! -f "$FAKE/dns_up" ] && exit 1
      exit 0 ;;
    esac
    if [ -n "${FAKE_ROOT:-}" ]; then
      case "$1" in
        stop) rm -f "$FAKE/dns_up" ;;
        run) case "$*" in *" --name tor-"*)
               if [ -f "$FAKE/never_ready" ]; then rm -f "$FAKE/never_ready"; else : >"$FAKE/dns_up"; fi ;;
             esac ;;
      esac
    fi
    case "$1" in
      build) shift; do_build "$@" ;;
      image)
        case "$2" in
          pull) img_has "$3" || img_add "$3" "$(new_id)" ;;
          tag) img_has "$3" || exit 1; img_add "$4" "$(img_id "$3")" ;;
          inspect) img_has "$3" || { echo "Error: image not found" >&2; exit 1; }
                   printf '[{"name":"%s","index":{"digest":"sha256:%s","mediaType":"x"}}]\n' "$3" "$(img_id "$3")" ;;
          rm|delete) shift 2; for r in "$@"; do case "$r" in -*) ;; *) img_del "$r" ;; esac; done ;;
        esac ;;
    esac
    exit 0 ;;
  git)
    case "$1" in
      clone) for a in "$@"; do d="$a"; done; mkdir -p "$d" && cp -R "$FAKE/upstream/." "$d" ;;
      -C)
        case "$3 $4" in
          "rev-parse HEAD") [ -f "$FAKE/git_head" ] || exit 128; cat "$FAKE/git_head" ;;
          "status --porcelain") cat "$FAKE/git_status" 2>/dev/null ;;
        esac ;;
    esac
    exit 0 ;;
  brew)
    case "$1 $2" in
      "list --formula") grep -qx "$3" "$FAKE/brew_installed" 2>/dev/null || exit 1 ;;
      "outdated --formula") cat "$FAKE/brew_outdated" 2>/dev/null ;;
    esac
    exit 0 ;;
  curl)
    o=""; u=""
    while [ $# -gt 0 ]; do case "$1" in -o) o="$2"; shift ;; https://*) u="$1" ;; esac; shift; done
    case "$u" in
      */mac/check-runtime.sh) cp "$FAKE/upstream/mac/check-runtime.sh" "$o" ;;
      *) exit 22 ;;
    esac
    exit 0 ;;
  shasum) shift 2; sha256sum "$@"; exit 0 ;;
  sw_vers) echo 26.0; exit 0 ;;
  uname) case "${1:-}" in -m) echo "$FAKE_ARCH" ;; *) echo "$FAKE_UNAME" ;; esac; exit 0 ;;
  crun) echo "crun version 1.19.1"; exit 0 ;;
  dig)
    # In a world the chain answers only while the stack is up ($FAKE/dns_up).
    if [ -n "${FAKE_ROOT:-}" ] && [ ! -f "$FAKE/dns_up" ]; then
      echo ';; connection timed out; no servers could be reached'; exit 9
    fi
    echo 104.16.132.229; exit 0 ;;
  whoami) echo tester; exit 0 ;;
  systemctl)
    if [ -n "${FAKE_ROOT:-}" ] && [ "$1" = --user ]; then
      case "$2 $3" in
        "start nice-dns-pod.service"|"restart nice-dns-pod.service")
          unbound_start "systemctl $2"
          if [ -f "$FAKE/never_ready" ]; then rm -f "$FAKE/never_ready"
          elif [ ! -f "$FAKE/rollback_never_ready" ]; then : >"$FAKE/dns_up"; fi ;;
      esac
      [ -f "$FAKE/fail_user_$2" ] && exit 1
      exit 0
    fi
    if [ -n "${FAKE_ROOT:-}" ]; then
      # System units keep <unit>.{unit,enabled,active} under $FAKE_ROOT/.systemd.
      sd="$FAKE_ROOT/.systemd"; mkdir -p "$sd"
      verb="$1"; shift
      now=0; quiet=0; units=""
      for a in "$@"; do case "$a" in --now) now=1 ;; --quiet|-q) quiet=1 ;; -*) ;; *) units="$units ${a%.service}" ;; esac; done
      rc=0
      for u in $units; do
        case "$verb" in
          cat) [ -f "$sd/$u.unit" ] || rc=1 ;;
          is-enabled) v="$(cat "$sd/$u.enabled" 2>/dev/null || echo disabled)"; [ "$quiet" = 1 ] || echo "$v"; [ "$v" = enabled ] || rc=1 ;;
          is-active) v="$(cat "$sd/$u.active" 2>/dev/null || echo inactive)"; [ "$quiet" = 1 ] || echo "$v"; [ "$v" = active ] || rc=3 ;;
          enable) echo enabled >"$sd/$u.enabled"; [ "$now" = 1 ] && echo active >"$sd/$u.active" ;;
          disable) echo disabled >"$sd/$u.enabled"; [ "$now" = 1 ] && echo inactive >"$sd/$u.active" ;;
          start|restart|reload) echo active >"$sd/$u.active" ;;
          stop) echo inactive >"$sd/$u.active" ;;
        esac
      done
      exit "$rc"
    fi
    case "$*" in "is-active --quiet NetworkManager") [ -f "$FAKE/nm_active" ] || exit 3 ;; esac
    exit 0 ;;
  pfctl)
    # The anchor's rules are kept in $FAKE/pf.rules; pf starts disabled.
    case "$*" in
      "-s info") echo "Status: Disabled" ;;
      -E) echo "Token : 4242" ;;
      *"-f -") cat >"$FAKE/pf.rules" ;;
    esac
    exit 0 ;;
  route)
    # The container bridge the stack's address routes through ($FAKE/bridge,
    # default bridge100; an empty file: no route).
    if [ "$*" = "-n get 172.31.240.250" ]; then
      if [ -f "$FAKE/bridge" ]; then b="$(cat "$FAKE/bridge")"; else b=bridge100; fi
      [ -z "$b" ] || echo "  interface: $b"
    fi
    exit 0 ;;
  networksetup)
    if [ -n "${FAKE_ROOT:-}" ]; then
      # Services in $FAKE_ROOT/.netsvc/list; DNS servers in .netsvc/dns/<name>.
      ns="$FAKE_ROOT/.netsvc"; mkdir -p "$ns/dns"
      case "$1" in
        -listallnetworkservices) echo 'An asterisk (*) denotes that a network service is disabled.'; cat "$ns/list" ;;
        -getdnsservers) if [ -s "$ns/dns/$2" ]; then cat "$ns/dns/$2"; else echo "There aren't any DNS Servers set on $2."; fi ;;
        -setdnsservers)
          svc="$2"; shift 2
          if [ "$*" = Empty ]; then rm -f "$ns/dns/$svc"; else : >"$ns/dns/$svc"; for a in "$@"; do echo "$a" >>"$ns/dns/$svc"; done; fi ;;
      esac
      exit 0
    fi
    [ "$1" = -listallnetworkservices ] && printf 'An asterisk (*) denotes that a network service is disabled.\nWi-Fi\n'
    exit 0 ;;
  launchctl)
    if [ -n "${FAKE_ROOT:-}" ] && [ "$1" = load ]; then
      case "$*" in *org.nice-dns.start-container.plist)
        if [ ! -f "$FAKE/rollback_never_ready" ]; then
          : >"$FAKE/dns_up"
          # The agent's first run: a healthy stack is pinned (start-container.sh fast path).
          if [ -s "$FAKE/agent_helper" ]; then
            echo 'agent: start-container-root.sh post' >>"$FAKE_LOG"
            ND_DNS_TEST_ROOT="$FAKE_ROOT" bash "$(cat "$FAKE/agent_helper")" post >/dev/null 2>&1
          fi
        fi ;;
      esac
    fi
    exit 0 ;;
  nmcli)
    # With profiles in $FAKE_ROOT/.nm/<uuid>/{dns,ignore,device} (a test made
    # them), the connection-profile calls the DNS helper makes are stateful.
    if [ -n "${FAKE_ROOT:-}" ] && [ -d "$FAKE_ROOT/.nm" ]; then
      nm="$FAKE_ROOT/.nm"
      case "$*" in
        "-t -f UUID con show") ls "$nm"; exit 0 ;;
        "-g ipv4.dns,ipv4.ignore-auto-dns con show "*) u="${*##* }"; [ -d "$nm/$u" ] || exit 10; cat "$nm/$u/dns" "$nm/$u/ignore"; exit 0 ;;
        "-g GENERAL.DEVICES con show "*) u="${*##* }"; cat "$nm/$u/device" 2>/dev/null; exit 0 ;;
        "con mod "*" ipv4.dns  ipv4.ignore-auto-dns no") u="$3"; [ -d "$nm/$u" ] || exit 10; : >"$nm/$u/dns"; printf 'no\n' >"$nm/$u/ignore"; exit 0 ;;
      esac
    fi
    exit 0 ;;
  cosign) [ -f "$FAKE/cosign_fail" ] && exit 1; exit 0 ;;
  dpkg) exit 1 ;;
  sysctl)
    if [ -n "${FAKE_ROOT:-}" ]; then
      sc="$FAKE_ROOT/.sysctl"; mkdir -p "$sc"
      case "$1" in
        -n) cat "$sc/$2" 2>/dev/null || echo 0 ;;
        -q|-w) for a in "$@"; do case "$a" in *=*) echo "${a#*=}" >"$sc/${a%%=*}" ;; esac; done ;;
      esac
    fi
    exit 0 ;;
esac
exit 0
STUB
  chmod 755 "$b/fakecmd"
  for s in sudo git curl shasum uname dig whoami systemctl sleep apt-get add-apt-repository dpkg dpkg-divert loginctl sysctl apparmor_parser usermod nmcli lsb_release update-grub; do
    ln -s fakecmd "$b/$s"
  done
  if [ "$plat" = linux ]; then
    for s in podman crun; do ln -s fakecmd "$b/$s"; done
  else
    for s in container brew softwareupdate sw_vers networksetup launchctl ifconfig dscacheutil killall pfctl route; do ln -s fakecmd "$b/$s"; done
  fi
  for s in $IP_TOOLS; do [ -e "$b/$s" ] || ln -s "$(type -P "$s")" "$b/$s"; done
}

# ip_tree <dir>: a copy of the checkout with the persistence scripts stubbed.
ip_tree() {
  local d="$1" f
  mkdir -p "$d"
  for f in install-deb.sh install-deb-hardened.sh install-mac.sh install-mac-hardened.sh lib deb mac scripts unbound pihole pihole-hardened health routes release; do
    cp -R "$NICE_DNS_ROOT/$f" "$d/"
  done
  # shellcheck disable=SC2016  # expanded by the stubs
  cat >"$d/deb/persistent-podman.sh" <<'STUB'
#!/bin/sh
l="persistent-podman.sh"; for a in "$@"; do l="$l $a"; done; printf '%s\n' "$l" >>"$FAKE_LOG"
if [ -n "${FAKE_ROOT:-}" ]; then
  # Like the real one: quadlets, then the pod restart, then the controller.
  m="deploy $(cat "$FAKE/git_head")"
  q="$HOME/.config/containers/systemd"; mkdir -p "$q"
  for f in nice-dns.network nice-dns.pod unbound.container pi-hole.container "tor-$1.container"; do printf '%s %s\n' "$f" "$m" >"$q/$f"; done
  rf="${XDG_STATE_HOME:-$HOME/.local/state}/nice-dns/unbound-route/forward-route.conf"
  if [ -f "$rf" ]; then r="$(sed -n 's/.*"\(route=[^"]*\)".*/\1/p' "$rf")"; else r=route-absent; fi
  printf 'persistent-podman.sh %s\n' "$r" >>"$FAKE/unbound-starts"
  if [ -f "$FAKE/never_ready" ]; then rm -f "$FAKE/never_ready"; else : >"$FAKE/dns_up"; fi
fi
[ -f "$FAKE/persist_fail" ] && exit 1
# The controller: its self-check, and an uninstall that removes it.
mkdir -p "$HOME/.local/bin"
printf '#!/bin/sh\n# controller deploy %s\nprintf "nice-dns-health %%s\\n" "$*" >>"$FAKE_LOG"\ncase "$1" in self-check) [ -f "$FAKE/selfcheck_fail" ] && exit 1; echo ok ;; uninstall) rm -f "$0" ;; esac\nexit 0\n' "$(cat "$FAKE/git_head")" >"$HOME/.local/bin/nice-dns-health"
exit 0
STUB
  # shellcheck disable=SC2016
  cat >"$d/mac/persist.sh" <<'STUB'
#!/bin/sh
l="persist.sh"; for a in "$@"; do l="$l $a"; done; printf '%s\n' "$l" >>"$FAKE_LOG"
if [ -n "${FAKE_ROOT:-}" ]; then
  # Like the real one: root helpers and sudoers, the controller, then the
  # start-container agent (whose first run pins DNS).
  m="deploy $(cat "$FAKE/git_head")"
  mkdir -p "$FAKE_ROOT/usr/local/sbin" "$FAKE_ROOT/etc/sudoers.d"
  for f in start-container.sh start-container-root.sh nice-dns-fetch-bridges.sh; do printf '%s %s\n' "$f" "$m" >"$FAKE_ROOT/usr/local/sbin/$f"; done
  printf 'sudoers %s\n' "$m" >"$FAKE_ROOT/etc/sudoers.d/start-container"
fi
[ -f "$FAKE/persist_fail" ] && exit 1
mkdir -p "$HOME/.local/bin"
printf '#!/bin/sh\n# controller deploy %s\nprintf "nice-dns-health %%s\\n" "$*" >>"$FAKE_LOG"\ncase "$1" in self-check) [ -f "$FAKE/selfcheck_fail" ] && exit 1; echo ok ;; uninstall) rm -f "$0" ;; esac\nexit 0\n' "$(cat "$FAKE/git_head")" >"$HOME/.local/bin/nice-dns-health"
sh "$HOME/.local/bin/nice-dns-health" self-check >/dev/null || exit 1
if [ -n "${FAKE_ROOT:-}" ]; then
  mkdir -p "$HOME/Library/LaunchAgents"
  printf 'controller agent %s\n' "$(cat "$FAKE/git_head")" >"$HOME/Library/LaunchAgents/org.nice-dns.health.plist"
  printf 'agent %s deploy %s\n' "$1" "$(cat "$FAKE/git_head")" >"$HOME/Library/LaunchAgents/org.nice-dns.start-container.plist"
  launchctl load "$HOME/Library/LaunchAgents/org.nice-dns.start-container.plist"
fi
exit 0
STUB
  chmod 755 "$d/deb/persistent-podman.sh" "$d/mac/persist.sh"
}

ip_bridges() {
  local f="$1" i
  mkdir -p "$(dirname "$f")"
  : >"$f"
  for i in 1 2 3 4 5; do
    printf 'BRIDGE%s=obfs4 192.0.2.%s:443 %040d cert=abc%s iat-mode=0\n' "$i" "$i" "$i" "$i" >>"$f"
  done
}

# ip_env <entrypoint>: a fresh world. Sets IP_W (world), IP_TREE (checkout
# copy), IP_HOME, IP_BIN, FAKE, FAKE_LOG, IP_STATE (the manifest dir).
ip_env() {
  local ep="$1" plat
  plat="$(ip_platform "$ep")"
  IP_W="$CASE_DIR/w-$ep" FAKE_ROOT=""
  rm -rf "$IP_W"
  mkdir -p "$IP_W"
  IP_TREE="$IP_W/src/nice-dns" IP_HOME="$IP_W/home" IP_BIN="$IP_W/bin"
  FAKE="$IP_W/fake" FAKE_LOG="$IP_W/fake/calls.log"
  mkdir -p "$FAKE" "$IP_HOME" "$IP_W/tmp"
  : >"$FAKE_LOG"
  ip_tree "$IP_TREE"
  ip_tree "$FAKE/upstream"
  if [ "${1%-hardened}" != "$1" ] && [ "${IP_NO_SIBLING:-0}" != 1 ]; then
    mkdir -p "$IP_W/src/pi-hole-hardened"
    printf 'FROM alpine:3.21.3\n' >"$IP_W/src/pi-hole-hardened/Dockerfile"
    : >"$IP_W/src/pi-hole-hardened/post-install.sh"
  fi
  ip_write_stubs "$IP_BIN" "$plat"
  printf '0123456789abcdef0123456789abcdef01234567\n' >"$FAKE/git_head"
  : >"$FAKE/nm_active"
  printf 'git\ncontainer\n' >"$FAKE/brew_installed"
  if [ "$plat" = linux ]; then
    IP_STATE="$IP_HOME/.local/state/nice-dns-install"
    IP_UNAME=Linux IP_ARCH=x86_64
    # The subordinate id files the lib reads (ND_INST_ETC): by default the
    # user already has ranges, as on any host that ran rootless podman.
    mkdir -p "$IP_W/etc"
    printf 'tester:100000:65536\n' >"$IP_W/etc/subuid"
    printf 'tester:100000:65536\n' >"$IP_W/etc/subgid"
  else
    IP_STATE="$IP_HOME/Library/Application Support/nice-dns-install"
    IP_UNAME=Darwin IP_ARCH=arm64
    ip_bridges "$IP_HOME/.config/nice-dns/bridges.env"
  fi
}

# ip_run <script> [args...]: run an entrypoint in the world; IP_RC, IP_OUT.
ip_run() {
  local cwd="${IP_CWD:-$IP_W}"
  IP_OUT="$(cd "$cwd" && env -i HOME="$IP_HOME" USER=tester LOGNAME=tester PATH="$IP_BIN" \
    TMPDIR="$IP_W/tmp" XDG_STATE_HOME="$IP_HOME/.local/state" XDG_CONFIG_HOME="$IP_HOME/.config" \
    XDG_RUNTIME_DIR="$IP_W/run" FAKE="$FAKE" FAKE_LOG="$FAKE_LOG" FAKE_UNAME="$IP_UNAME" FAKE_ARCH="$IP_ARCH" \
    ND_INST_ETC="$IP_W/etc" ND_INST_SUDO_KEEPALIVE=0 ND_INST_REQUIRE_SIGNATURES="${ND_INST_REQUIRE_SIGNATURES:-}" FAKE_ROOT="${FAKE_ROOT:-}" ND_INST_ROOT="${FAKE_ROOT:-}" ND_PERSIST_ROOT="${ND_PERSIST_ROOT:-}" bash "$@" 2>&1 </dev/null)"
  IP_RC=$?
}
ip_install() { ip_run "$IP_TREE/$1.sh" "${@:2}"; }

ip_lines() { grep -nE -f <(printf '%s\n' "$2") "$1" 2>/dev/null || true; }
ip_first() { ip_lines "$1" "$2" | head -n 1 | cut -d: -f1; }
ip_last() { ip_lines "$1" "$2" | tail -n 1 | cut -d: -f1; }
ip_gen_current() { cat "$IP_STATE/current" 2>/dev/null; }
ip_row() { awk -F '\t' -v k="$2" '$1 == k { $1 = ""; sub(/^\t/, ""); print; exit }' OFS='\t' "$1"; }
ip_manifest() { printf '%s/generations/%s/prepare.tsv\n' "$IP_STATE" "$1"; }
ip_refs() { awk -F '\t' '$1 == "image" { print $3 }' "$1"; }
ip_has_image() { awk -v r="$1" '$1 == r { f = 1 } END { exit !f }' "$FAKE/images"; }
ip_mode() { stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1"; }

ip_assert_untouched() {
  local what="$1"
  assert_eq "" "$(ip_lines "$FAKE_LOG" "$IP_DISRUPTIVE")" "$what: no disruptive call"
  assert_eq "" "$(ip_lines "$FAKE_LOG" "$IP_DNS_WRITE")" "$what: no DNS write"
}

# ─────────────────────────── worlds (dns-transaction, installers-interaction)

DT_PIN_MAC=172.31.240.250

dt_platforms() {
  local p="${NICE_DNS_OPT_PLATFORMS:-all}" x out=""
  [ "$p" = all ] && { printf 'linux macos\n'; return 0; }
  for x in $(printf '%s' "$p" | tr ',' ' '); do
    case "$x" in linux|macos) out="$out $x" ;; *) fail "unknown --platforms value '$x' (all, linux, macos)" ;; esac
  done
  printf '%s\n' "$out"
}
dt_select_platforms() { DT_PLATS="$(dt_platforms)" || exit 1; }
dt_ep_of() { if [ "$1" = linux ]; then echo install-deb; else echo install-mac; fi; }

# dt_world <entrypoint> <state>: ip_env plus a fake root in <state>.
#   linux: resolved (resolv.conf -> the systemd-resolved stub), file (a plain
#          DHCP resolv.conf), missing, legacy (an install from before records)
#   macos: fresh (Wi-Fi 192.168.1.1, Ethernet 9.9.9.9 149.112.112.112,
#          Thunderbolt Bridge empty), legacy (every service pinned)
dt_world() {
  local ep="$1" st="$2" r
  ip_env "$ep"
  FAKE_ROOT="$IP_W/root"; r="$FAKE_ROOT"
  mkdir -p "$r/etc" "$r/.systemd" "$r/.sysctl" "$r/run/systemd/resolve" "$r/usr/bin" "$r/usr/local/sbin"
  if [ "$(ip_platform "$ep")" = linux ]; then
    printf 'nameserver 127.0.0.53\noptions edns0 trust-ad\n' >"$r/run/systemd/resolve/stub-resolv.conf"
    : >"$r/.systemd/systemd-resolved.unit"; : >"$r/.systemd/NetworkManager.unit"
    echo enabled >"$r/.systemd/systemd-resolved.enabled"; echo active >"$r/.systemd/systemd-resolved.active"
    echo enabled >"$r/.systemd/NetworkManager.enabled"; echo active >"$r/.systemd/NetworkManager.active"
    printf '0\n' >"$r/.sysctl/net.ipv6.conf.all.disable_ipv6"
    printf '0\n' >"$r/.sysctl/net.ipv6.conf.default.disable_ipv6"
    printf '0\n' >"$r/.sysctl/net.ipv6.conf.lo.disable_ipv6"
    case "$st" in
      resolved) ln -s ../run/systemd/resolve/stub-resolv.conf "$r/etc/resolv.conf" ;;
      file) printf '# Generated by NetworkManager\nsearch lan\nnameserver 192.168.1.1\n' >"$r/etc/resolv.conf"; chmod 644 "$r/etc/resolv.conf" ;;
      missing) ;;
      legacy)
        printf 'nameserver 127.0.0.1\n' >"$r/etc/resolv.conf"
        echo disabled >"$r/.systemd/systemd-resolved.enabled"; echo inactive >"$r/.systemd/systemd-resolved.active"
        mkdir -p "$r/etc/NetworkManager/conf.d" "$r/etc/systemd/system"
        printf '[main]\ndns=none\n' >"$r/etc/NetworkManager/conf.d/90-nice-dns.conf"
        : >"$r/etc/systemd/system/custom-dns-deb.service" ;;
    esac
  else
    mkdir -p "$r/.netsvc/dns"
    printf '%s\n' "$IP_TREE/mac/start-container-root.sh" >"$FAKE/agent_helper"
    printf 'Wi-Fi\nEthernet\nThunderbolt Bridge\n' >"$r/.netsvc/list"
    case "$st" in
      fresh)
        printf '192.168.1.1\n' >"$r/.netsvc/dns/Wi-Fi"
        printf '9.9.9.9\n149.112.112.112\n' >"$r/.netsvc/dns/Ethernet" ;;
      legacy)
        for s in Wi-Fi Ethernet 'Thunderbolt Bridge'; do printf '%s\n' "$DT_PIN_MAC" >"$r/.netsvc/dns/$s"; done
        : >"$r/usr/local/sbin/start-container.sh" ;;
    esac
  fi
  export FAKE_ROOT
}

# dt_dns_state: the host DNS state the installers own, canonical, for exact
# comparison (the helpers' own record is not part of it).
dt_dns_state() {
  local r="$FAKE_ROOT" f k s
  if [ -f "$r/.netsvc/list" ]; then
    while IFS= read -r s; do printf 'service %s: %s\n' "$s" "$(cat "$r/.netsvc/dns/$s" 2>/dev/null | tr '\n' ' ' | sed 's/ $//')"; done <"$r/.netsvc/list"
    return 0
  fi
  if [ -L "$r/etc/resolv.conf" ]; then printf 'resolv symlink %s\n' "$(readlink "$r/etc/resolv.conf")"
  elif [ -f "$r/etc/resolv.conf" ]; then printf 'resolv file %s\n' "$(ip_mode "$r/etc/resolv.conf")"; sed 's/^/  /' "$r/etc/resolv.conf"
  else echo 'resolv missing'; fi
  for k in systemd-resolved.enabled systemd-resolved.active; do printf '%s %s\n' "$k" "$(cat "$r/.systemd/$k" 2>/dev/null)"; done
  for k in all default lo; do printf 'sysctl %s %s\n' "$k" "$(cat "$r/.sysctl/net.ipv6.conf.$k.disable_ipv6" 2>/dev/null)"; done
  for f in etc/NetworkManager/conf.d/90-nice-dns.conf etc/NetworkManager/dispatcher.d/90-nice-dns-pin \
           etc/systemd/system/custom-dns-deb.service etc/sysctl.d/99-nice-dns-disable-ipv6.conf \
           etc/systemd/system/NetworkManager-wait-online.service.d/10-wait-for-connectivity.conf usr/bin/custom-dns-deb; do
    [ -e "$r/$f" ] && printf 'owned %s\n' "$f"
  done
  return 0
}

# dt_pinned: every owned resolver setting points at the stack.
dt_pinned() {
  local s
  if [ -f "$FAKE_ROOT/.netsvc/list" ]; then
    while IFS= read -r s; do [ "$(cat "$FAKE_ROOT/.netsvc/dns/$s" 2>/dev/null)" = "$DT_PIN_MAC" ] || return 1; done <"$FAKE_ROOT/.netsvc/list"
    return 0
  fi
  [ -f "$FAKE_ROOT/etc/resolv.conf" ] && [ ! -L "$FAKE_ROOT/etc/resolv.conf" ] && [ "$(cat "$FAKE_ROOT/etc/resolv.conf")" = 'nameserver 127.0.0.1' ]
}

# dt_helper <platform> <verb>: one helper call as the installer makes it.
dt_helper() {
  local h
  if [ "$1" = linux ]; then h="$IP_TREE/deb/custom-dns-deb"; else h="$IP_TREE/mac/start-container-root.sh"; fi
  DT_OUT="$(env -i HOME="$IP_HOME" PATH="$IP_BIN" FAKE="$FAKE" FAKE_LOG="$FAKE_LOG" FAKE_ROOT="$FAKE_ROOT" \
    ND_DNS_TEST_ROOT="$FAKE_ROOT" bash "$h" "$2" 2>&1)"
  DT_RC=$?
}
dt_pin_verb() { if [ "$1" = linux ]; then echo pin; else echo post; fi; }
dt_receipt() { if [ "$1" = linux ]; then echo "$FAKE_ROOT/var/lib/nice-dns/dns-owned/receipt.tsv"; else echo "$FAKE_ROOT/var/db/nice-dns/dns-owned/receipt.tsv"; fi; }

# dt_deploy_state: the deployment an install replaces (marker files, the
# :latest images the stack runs, whether it answers).
dt_deploy_state() {
  local f
  for f in "$IP_HOME/.config/containers/systemd"/* "$IP_HOME/.local/bin/nice-dns-health" \
           "$IP_HOME/Library/LaunchAgents"/*.plist "$FAKE_ROOT/usr/local/sbin"/* "$FAKE_ROOT/etc/sudoers.d"/*; do
    [ -f "$f" ] && printf '%s: %s\n' "${f#"$IP_W"/}" "$(cat "$f")"
  done
  # The references the stack runs; pulled upstream bases are build inputs.
  awk '$1 ~ /^(localhost\/)?(unbound|pi-hole|pi-hole-hardened-base):latest$|^docker\.io\/sureserver\/tor-(haproxy|socat):latest$/' \
    "$FAKE/images" 2>/dev/null | sort
  [ -f "$FAKE/dns_up" ] && echo 'stack answers'
  return 0
}

# dt_installed <entrypoint>: a completed install at source A, log cleared,
# the next install at source B.
dt_installed() {
  ip_install "$1"
  assert_rc 0 "$IP_RC" "$1: the first install: $IP_OUT"
  : >"$FAKE_LOG"
  printf 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\n' >"$FAKE/git_head"
}

dt_linux_states() { printf 'resolved file missing\n'; }
dt_fresh_state() { if [ "$(ip_platform "$1")" = linux ]; then echo resolved; else echo fresh; fi; }

