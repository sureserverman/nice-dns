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
^brew upgrade( --formula)? container
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
l="$me"; for a in "$@"; do l="$l $a"; done; printf '%s\n' "$l" >>"$FAKE_LOG"
# Switchable failure: a line of $FAKE/fail is an ERE matched against the call.
if [ -s "$FAKE/fail" ] && printf '%s\n' "$l" | grep -Eq -f "$FAKE/fail"; then
  echo "$me: injected failure" >&2; exit 1
fi
# Switchable interrupt: the installer gets SIGINT (Ctrl-C) at a matching call.
if [ -s "$FAKE/sigint" ] && printf '%s\n' "$l" | grep -Eq -f "$FAKE/sigint"; then
  echo "$me: injected interrupt" >&2; kill -INT "$PPID"; exit 1
fi
store="$FAKE/images"; touch "$store"
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
    # input is kept for inspection.
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
    for s in container brew softwareupdate sw_vers networksetup launchctl ifconfig; do ln -s fakecmd "$b/$s"; done
  fi
  for s in $IP_TOOLS; do [ -e "$b/$s" ] || ln -s "$(type -P "$s")" "$b/$s"; done
}

# ip_tree <dir>: a copy of the checkout with the persistence scripts stubbed.
ip_tree() {
  local d="$1" f
  mkdir -p "$d"
  for f in install-deb.sh install-deb-hardened.sh install-mac.sh install-mac-hardened.sh lib deb mac scripts unbound pihole pihole-hardened health routes; do
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
    ND_INST_ETC="$IP_W/etc" FAKE_ROOT="${FAKE_ROOT:-}" ND_INST_ROOT="${FAKE_ROOT:-}" bash "$@" 2>&1 </dev/null)"
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

