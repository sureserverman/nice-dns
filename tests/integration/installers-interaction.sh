# shellcheck shell=bash
# Group integration/installers-interaction (Sub-plan 4, Stage 1 gate;
# ARCH-03, ARCH-05, ARCH-06, ARCH-08; WF-DNS-003).
#
# Sourced by tests/run.sh (assert_* helpers; NICE_DNS_ROOT, CASE_DIR). The
# Stage 1 outputs together, in the installer world (tests/fixtures/
# install-fakes.sh): shared preparation (Task 1.1), the owned-DNS transaction
# (Task 1.2) and the locked inputs (Task 1.3), across a lifecycle that
# switches flavour and proxy, fails, is interrupted and ends in an uninstall.
# Every platform runs; the standard and hardened entrypoints share one state.
#
# Scenarios: OP-OWNED-RESTORE, OP-NO-HOST-PUBLIC, OP-BOOTSTRAP.

. "$NICE_DNS_ROOT/tests/fixtures/install-fakes.sh"

II_BOOT="$NICE_DNS_ROOT/release/bootstrap.tsv"
# Calls that use the network (or run a step that does), whatever the tool.
II_NET='^(sudo )?(apt-get (update|install)|add-apt-repository)|^git clone|^podman (pull|build)|^container (image pull|build |builder start|system start)|^curl |^(HOMEBREW_NO_AUTO_UPDATE=1 )?brew (update|install|upgrade|fetch)|^sudo softwareupdate|^cosign |^persistent-podman\.sh '

ii_platforms() { printf 'linux macos\n'; }
ii_ep() { if [ "$2" = hardened ]; then echo "install-$1-hardened"; else echo "install-$1"; fi; }   # <deb|mac> <flavor>
ii_os() { if [ "$1" = linux ]; then echo deb; else echo mac; fi; }

# ii_step <what> <entrypoint> [args...]: one lifecycle step in the current
# world; after it the owned DNS state is the original or the pin, nothing else.
ii_step() {
  local what="$1" ep="$2" st
  shift 2
  ip_install "$ep" "$@"
  II_RC="$IP_RC"
  st="$(dt_dns_state)"
  if [ "$st" != "$II_DNS0" ] && ! dt_pinned; then
    fail "$what: host DNS is neither the recorded original nor the pin:
$st"
  fi
  assert_eq "" "$(grep -E '^sudo tee [^ ]*resolv\.conf' "$FAKE_LOG")" "$what: no installer writes resolv.conf"
  if [ -f "$FAKE_ROOT/.netsvc/list" ]; then
    ii_mac_writes_are_pin_or_recorded "$what"
  fi
}

# ii_mac_writes_are_pin_or_recorded <what>: every network-service DNS write of
# the step (the helpers', through the fake networksetup) sets the pin or the
# servers recorded for that service before nice-dns.
ii_mac_writes_are_pin_or_recorded() {
  local rest svc rec ok
  while IFS= read -r rest; do
    [ -n "$rest" ] || continue
    ok=0
    while IFS= read -r svc; do
      rec="$(printf '%s\n' "$II_DNS0" | awk -v s="$svc" 'index($0, "service " s ": ") == 1 { print substr($0, length("service " s ": ") + 1); exit }')"
      [ -n "$rec" ] || rec=Empty
      case "$rest" in "$svc 172.31.240.250"|"$svc $rec") ok=1 ;; esac
    done <"$FAKE_ROOT/.netsvc/list"
    [ "$ok" = 1 ] || fail "$1: a DNS write that is neither the pin nor the recorded servers: networksetup -setdnsservers $rest"
  done <<EOF
$(sed -n 's/^\(sudo \)\{0,1\}networksetup -setdnsservers //p' "$FAKE_LOG")
EOF
}

# One world per platform: standard haproxy, then hardened socat, then a
# failed standard reinstall (and an interrupted one), then uninstall.
t_lifecycle_restores_exactly_what_it_owns() {
  local plat
  for plat in $(ii_platforms); do
    (
      local os dep_b cur_b
      os="$(ii_os "$plat")"
      dt_world "$(ii_ep "$os" hardened)" "$(dt_fresh_state "$(ii_ep "$os" standard)")"
      II_DNS0="$(dt_dns_state)"
      ii_step "$plat: standard haproxy" "$(ii_ep "$os" standard)" haproxy
      assert_rc 0 "$II_RC" "$plat: first install: $IP_OUT"
      dt_pinned || fail "$plat: pinned after the first install"
      printf 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\n' >"$FAKE/git_head"
      ii_step "$plat: hardened socat" "$(ii_ep "$os" hardened)" socat
      assert_rc 0 "$II_RC" "$plat: flavour and proxy switch: $IP_OUT"
      dep_b="$(dt_deploy_state)"; cur_b="$(cat "$IP_STATE/current")"
      assert_match 'tor-socat' "$dep_b" "$plat: the socat deployment runs"
      printf 'cccccccccccccccccccccccccccccccccccccccc\n' >"$FAKE/git_head"
      : >"$FAKE/never_ready"
      ii_step "$plat: failed standard reinstall" "$(ii_ep "$os" standard)" haproxy
      rm -f "$FAKE/never_ready"
      assert_nonzero "$II_RC" "$plat: the failed reinstall fails"
      assert_eq "$dep_b" "$(dt_deploy_state)" "$plat: the hardened socat deployment is back"
      assert_eq "$cur_b" "$(cat "$IP_STATE/current")" "$plat: and still current"
      if [ "$plat" = linux ]; then printf '^podman system migrate\n' >"$FAKE/sigint"; else printf '^container build \n' >"$FAKE/sigint"; fi
      ii_step "$plat: interrupted standard reinstall" "$(ii_ep "$os" standard)" haproxy
      rm -f "$FAKE/sigint"
      assert_nonzero "$II_RC" "$plat: the interrupted reinstall fails"
      assert_eq "$dep_b" "$(dt_deploy_state)" "$plat: the hardened socat deployment is back again"
      ii_step "$plat: uninstall" "$(ii_ep "$os" hardened)" uninstall
      assert_rc 0 "$II_RC" "$plat: uninstall: $IP_OUT"
      assert_eq "$II_DNS0" "$(dt_dns_state)" "$plat: exactly the DNS state recorded before nice-dns"
      assert_no_path "$(dt_receipt "$plat")" "$plat: no record is left"
      assert_no_path "$IP_STATE/current" "$plat: nothing is current"
      assert_eq "" "$(awk '$1 ~ /:latest$/ && $1 ~ /(unbound|pi-hole|tor-(haproxy|socat))/' "$FAKE/images")" "$plat: no deployment image is left"
    ) || exit 1
  done
}

# The same lifecycle, watched for public DNS: every step leaves the owned
# state at the original or the pin, and no installer writes host DNS itself
# (ii_step); the helpers write only those two values
# (dns-transaction t_no_installer_writes_the_resolver_directly).
t_no_step_points_the_host_at_public_dns() {
  local plat
  for plat in $(ii_platforms); do
    (
      local os inj
      os="$(ii_os "$plat")"
      dt_world "$(ii_ep "$os" standard)" "$(dt_fresh_state "$(ii_ep "$os" standard)")"
      II_DNS0="$(dt_dns_state)"
      # A failed first install, then the real one, then failures of every
      # kind on the reinstall, then uninstall.
      : >"$FAKE/persist_fail"; ii_step "$plat: failed first install" "$(ii_ep "$os" standard)"; rm -f "$FAKE/persist_fail"
      assert_eq "$II_DNS0" "$(dt_dns_state)" "$plat: a failed first install leaves the original"
      # A new source commit: two generations in one (fake) second must not collide.
      printf 'dddddddddddddddddddddddddddddddddddddddd\n' >"$FAKE/git_head"
      ii_step "$plat: install" "$(ii_ep "$os" standard)"
      assert_rc 0 "$II_RC" "$plat: $IP_OUT"
      for inj in persist_fail never_ready selfcheck_fail probe_fail; do
        printf '%s\n' "$(printf '%s' "$inj" | od -An -tx1 | tr -d ' \n' | cut -c1-12)aaaaaaaaaaaaaaaaaaaaaaaaaaaa" >"$FAKE/git_head"
        : >"$FAKE/$inj"; ii_step "$plat: reinstall with $inj" "$(ii_ep "$os" standard)" socat; rm -f "$FAKE/$inj"
        assert_nonzero "$II_RC" "$plat: $inj fails the reinstall"
        dt_pinned || fail "$plat: after $inj the host stays pinned (fails closed): $(dt_dns_state)"
      done
      ii_step "$plat: uninstall" "$(ii_ep "$os" standard)" uninstall
      assert_eq "$II_DNS0" "$(dt_dns_state)" "$plat: uninstall gives back the original"
    ) || exit 1
  done
}

# ii_declared <platform> <call> <phase>: the call matches a declared
# exception of this platform and phase.
ii_declared() {
  local plat="$1" call="$2" phase="$3" kind p ere ph
  while IFS="$(printf '\t')" read -r kind _ p ere ph _; do
    [ "$kind" = exception ] || continue
    [ "$p" = all ] || [ "$p" = "$plat" ] || continue
    [ "$ph" = "$phase" ] || continue
    if printf '%s\n' "$call" | grep -Eq -- "$ere"; then return 0; fi
  done <"$II_BOOT"
  return 1
}

# Every network use of an install is a declared exception in its phase; after
# the interruption only calls that need no host resolver run.
t_bootstrap_use_is_declared() {
  local ep hits
  hits="$(grep -nE '(^|[[:space:];|&(])(wget|ncat|nc|rsync|scp|ssh) ' "$NICE_DNS_ROOT"/lib/install.sh "$NICE_DNS_ROOT"/install-*.sh \
    "$NICE_DNS_ROOT"/deb/persistent-podman.sh "$NICE_DNS_ROOT"/mac/persist.sh | grep -vE ':[0-9]+:[[:space:]]*#' || true)"
  assert_eq "" "$hits" "the installers use no network tool the inventory does not classify"
  assert_eq "$(printf 'schema\tnice-dns-bootstrap/1')" "$(head -n 1 "$II_BOOT")" "the inventory's schema"
  for ep in install-deb install-deb-hardened install-mac install-mac-hardened; do
    (
      local plat first n=0 line call ph
      plat="$(ip_platform "$ep")"
      dt_world "$ep" "$(dt_fresh_state "$ep")"
      ln -s fakecmd "$IP_BIN/cosign"
      [ "$plat" = macos ] && printf 'container\n' >"$FAKE/brew_outdated"
      dt_installed "$ep"
      [ "$plat" = macos ] && printf 'container\n' >"$FAKE/brew_outdated"
      ip_install "$ep" socat
      assert_rc 0 "$IP_RC" "$ep reinstall: $IP_OUT"
      first="$(ip_first "$FAKE_LOG" "$IP_DISRUPTIVE")"
      assert_ne "" "$first" "$ep: the reinstall interrupts"
      while IFS= read -r line; do
        n=$((n + 1))
        call="${line#*:}"
        if [ "${line%%:*}" -lt "$first" ]; then ph=preparation; else ph=interruption; fi
        ii_declared "$plat" "$call" "$ph" || fail "$ep: undeclared network use in $ph: $call"
      done <<EOF
$(ip_lines "$FAKE_LOG" "$II_NET")
EOF
      assert_ne 0 "$n" "$ep: the network uses were classified"
      if [ "$plat" = macos ]; then
        assert_match '^brew fetch --formula container$' "$(sed -n "1,${first}p" "$FAKE_LOG")" "$ep: the runtime upgrade is fetched in preparation"
        assert_match '^HOMEBREW_NO_AUTO_UPDATE=1 brew upgrade --formula container$' "$(sed -n "${first},\$p" "$FAKE_LOG")" "$ep: and applied offline in the interruption"
      fi
    ) || exit 1
  done
}
