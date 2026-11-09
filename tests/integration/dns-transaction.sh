# shellcheck shell=bash
# Group integration/dns-transaction (Sub-plan 4, Task 1.2; ARCH-03, ARCH-06;
# WF-DNS-003).
#
# Sourced by tests/run.sh (assert_* helpers; NICE_DNS_ROOT, CASE_DIR). The
# DNS helpers (deb/custom-dns-deb, mac/start-container-root.sh) and the four
# public entrypoints run in a world: a private HOME, a copy of the checkout,
# PATH stubs, and a fake root ($FAKE_ROOT) that holds /etc/resolv.conf,
# systemd unit state, sysctl values and the macOS network services
# (tests/fixtures/install-fakes.sh). The helpers honour that root through
# ND_DNS_TEST_ROOT only when not run as root. Nothing on the host is touched.
#
# NICE_DNS_OPT_PLATFORMS (--platforms all|linux|macos) picks the helper
# platforms; NICE_DNS_OPT_ENTRYPOINTS (--entrypoints ...) the entrypoints.

. "$NICE_DNS_ROOT/tests/fixtures/install-fakes.sh"

# ─────────────────────────── helper cases ───────────────────────────────

t_helper_snapshot_and_restore_are_exact() {
  local plat st sts
  dt_select_platforms
  for plat in $DT_PLATS; do
    if [ "$plat" = linux ]; then sts="$(dt_linux_states)"; else sts=fresh; fi
    for st in $sts; do
      (
        local before rec
        dt_world "$(dt_ep_of "$plat")" "$st"
        before="$(dt_dns_state)"
        dt_helper "$plat" snapshot
        assert_rc 0 "$DT_RC" "$plat/$st: snapshot: $DT_OUT"
        rec="$(dt_receipt "$plat")"
        assert_file "$rec" "$plat/$st: the record"
        assert_eq 600 "$(ip_mode "$rec")" "$plat/$st: the record is 0600"
        assert_eq 700 "$(ip_mode "$(dirname "$rec")")" "$plat/$st: its directory is 0700"
        assert_eq "$(printf 'schema\tnice-dns-dns-owned/1')" "$(head -n 1 "$rec")" "$plat/$st: schema"
        assert_eq fresh "$(awk -F '\t' '$1 == "origin" { print $2 }' "$rec")" "$plat/$st: origin"
        dt_helper "$plat" "$(dt_pin_verb "$plat")"
        assert_rc 0 "$DT_RC" "$plat/$st: pin: $DT_OUT"
        dt_pinned || fail "$plat/$st: pinned after the pin: $(dt_dns_state)"
        dt_helper "$plat" snapshot
        assert_eq fresh "$(awk -F '\t' '$1 == "origin" { print $2 }' "$rec")" "$plat/$st: a second snapshot keeps the first record"
        dt_helper "$plat" check
        assert_rc 0 "$DT_RC" "$plat/$st: the pinned state passes the check: $DT_OUT"
        dt_helper "$plat" restore
        assert_rc 0 "$DT_RC" "$plat/$st: restore: $DT_OUT"
        assert_eq "$before" "$(dt_dns_state)" "$plat/$st: restore gives back exactly the recorded state"
        assert_no_path "$rec" "$plat/$st: the record is gone after restore"
      ) || exit 1
    done
  done
}

# macOS keeps what it cached while the stack was down (live 2026-09-28:
# getaddrinfo failed github.com for 80 s after the stack answered it), so
# every change of the host resolver ends with a cache flush.
t_helper_flushes_the_macos_cache_after_each_change() {
  dt_select_platforms
  case " $DT_PLATS " in *" macos "*) ;; *) echo "macos not selected (--platforms)"; return 0 ;; esac
  (
    local set flush v
    dt_world "$(dt_ep_of macos)" fresh
    # post; restore; then a restore that fails on one service after it
    # changed another (the record stays; the changed service is flushed too).
    for v in post restore post partial-restore; do
      : >"$FAKE_LOG"
      if [ "$v" = partial-restore ]; then
        printf '^networksetup -setdnsservers Ethernet\n' >"$FAKE/fail"
        dt_helper macos restore
        rm -f "$FAKE/fail"
        assert_nonzero "$DT_RC" "the partial restore fails: $DT_OUT"
      else
        # The record is taken before a pin (a second snapshot keeps it).
        [ "$v" = post ] && dt_helper macos snapshot
        dt_helper macos "$v"
        assert_rc 0 "$DT_RC" "$v: $DT_OUT"
      fi
      set="$(ip_last "$FAKE_LOG" '^networksetup -setdnsservers ')"
      flush="$(ip_first "$FAKE_LOG" '^dscacheutil -flushcache$')"
      assert_ne "" "$set" "$v changes the resolver"
      assert_ne "" "$flush" "$v flushes the directory service cache: $(cat "$FAKE_LOG")"
      assert_eq 1 "$((flush > set))" "$v flushes after its last change"
      assert_ne "" "$(ip_first "$FAKE_LOG" '^killall -HUP mDNSResponder$')" "$v resets mDNSResponder"
    done
  ) || exit 1
}

# Sub-plan 5 Task 2.1 (PRIV-NO-DIRECT; live no-direct on the mac,
# 2026-10-02): every network service carrying the pin gets its own scoped
# resolver, and a query scoped to Wi-Fi or Ethernet leaves through it, to the
# LAN gateway in cleartext, for an address only the container bridge reaches.
# post makes pf pass DNS to the stack's subnet on its bridge and drop it
# elsewhere, then kills the states such queries hold (a packet that matches a
# state skips the rules); restore lifts it. Without a bridge to the stack it
# loads nothing (a block could then cut the stack off) and says so.
t_helper_blocks_scoped_dns_off_the_container_bridge() {
  dt_select_platforms
  case " $DT_PLATS " in *" macos "*) ;; *) echo "macos not selected (--platforms)"; return 0 ;; esac
  (
    local load kill set
    dt_world "$(dt_ep_of macos)" fresh
    dt_helper macos snapshot
    : >"$FAKE_LOG"
    dt_helper macos post
    assert_rc 0 "$DT_RC" "post: $DT_OUT"
    assert_eq "$(printf 'pass out quick on bridge100 proto { udp, tcp } to 172.31.240.248/29 port { 53, 853 }\nblock drop out quick proto { udp, tcp } to 172.31.240.248/29 port { 53, 853 }')" \
      "$(cat "$FAKE/pf.rules" 2>/dev/null)" "DNS to the stack passes on its bridge only"
    load="$(ip_first "$FAKE_LOG" '^pfctl -a com\.apple/260\.nice-dns-scoped -f -$')"
    kill="$(ip_first "$FAKE_LOG" '^pfctl -k 0\.0\.0\.0/0 -k 172\.31\.240\.248/29$')"
    set="$(ip_last "$FAKE_LOG" '^networksetup -setdnsservers ')"
    assert_ne "" "$load" "the anchor is loaded: $(cat "$FAKE_LOG")"
    assert_ne "" "$kill" "the states toward the stack are killed"
    assert_eq 1 "$((kill > load && load > set))" "after the pin: pin, load, then kill"
    assert_ne "" "$(ip_first "$FAKE_LOG" '^pfctl -E$')" "pf is enabled when it is off"
    : >"$FAKE_LOG"
    dt_helper macos restore
    assert_rc 0 "$DT_RC" "restore: $DT_OUT"
    assert_ne "" "$(ip_first "$FAKE_LOG" '^pfctl -a com\.apple/260\.nice-dns-scoped -F all$')" "restore lifts the anchor"
    assert_ne "" "$(ip_first "$FAKE_LOG" '^pfctl -X 4242$')" "and releases its pf reference"
    rm -f "$FAKE/pf.rules"; : >"$FAKE/bridge"; : >"$FAKE_LOG"
    dt_helper macos post
    assert_rc 0 "$DT_RC" "post without a bridge still pins: $DT_OUT"
    assert_ne "" "$(ip_last "$FAKE_LOG" '^networksetup -setdnsservers ')" "the pin is made"
    assert_eq "" "$(ip_first "$FAKE_LOG" '^pfctl -a ')" "no block is loaded without the bridge"
    assert_match 'no container bridge' "$DT_OUT" "and it says so"
  ) || exit 1
}

t_helper_refuses_external_changes() {
  local plat
  dt_select_platforms
  for plat in $DT_PLATS; do
    (
      dt_world "$(dt_ep_of "$plat")" "$( [ "$plat" = linux ] && echo file || echo fresh)"
      dt_helper "$plat" snapshot; dt_helper "$plat" "$(dt_pin_verb "$plat")"
      if [ "$plat" = linux ]; then
        rm -f "$FAKE_ROOT/etc/resolv.conf"; printf 'nameserver 10.64.0.1\n' >"$FAKE_ROOT/etc/resolv.conf"
      else
        printf '10.64.0.1\n' >"$FAKE_ROOT/.netsvc/dns/Wi-Fi"
      fi
      dt_helper "$plat" check
      assert_rc 3 "$DT_RC" "$plat: another owner's change is refused: $DT_OUT"
      assert_match 'another owner' "$DT_OUT" "$plat: and named"
      dt_helper "$plat" restore
      assert_rc 0 "$DT_RC" "$plat: restore: $DT_OUT"
      if [ "$plat" = linux ]; then
        assert_eq 'nameserver 10.64.0.1' "$(cat "$FAKE_ROOT/etc/resolv.conf")" "$plat: restore leaves another owner's resolv.conf"
      else
        assert_eq 10.64.0.1 "$(cat "$FAKE_ROOT/.netsvc/dns/Wi-Fi")" "$plat: restore leaves another owner's service"
        assert_eq '9.9.9.9 149.112.112.112' "$(tr '\n' ' ' <"$FAKE_ROOT/.netsvc/dns/Ethernet" | sed 's/ $//')" "$plat: and restores the others"
      fi
    ) || exit 1
  done
}

t_legacy_install_is_recorded_as_legacy() {
  local plat
  dt_select_platforms
  for plat in $DT_PLATS; do
    (
      dt_world "$(dt_ep_of "$plat")" legacy
      dt_helper "$plat" snapshot
      assert_eq legacy "$(awk -F '\t' '$1 == "origin" { print $2 }' "$(dt_receipt "$plat")")" "$plat: an install from before records is legacy"
      dt_helper "$plat" restore
      assert_rc 0 "$DT_RC" "$plat: restore: $DT_OUT"
      if [ "$plat" = linux ]; then
        # The state before nice-dns is unknown: the distribution default.
        assert_eq ../run/systemd/resolve/stub-resolv.conf "$(readlink "$FAKE_ROOT/etc/resolv.conf")" "$plat: resolv.conf is the systemd-resolved stub again"
        assert_eq enabled "$(cat "$FAKE_ROOT/.systemd/systemd-resolved.enabled")" "$plat: systemd-resolved enabled"
        assert_eq active "$(cat "$FAKE_ROOT/.systemd/systemd-resolved.active")" "$plat: and running"
        assert_no_path "$FAKE_ROOT/etc/NetworkManager/conf.d/90-nice-dns.conf" "$plat: the NetworkManager override goes"
      else
        assert_eq "$(printf 'service Wi-Fi: \nservice Ethernet: \nservice Thunderbolt Bridge: ')" "$(dt_dns_state)" "$plat: every pinned service goes back to Empty (DHCP)"
      fi
    ) || exit 1
  done
}

# ─────────────────────────── entrypoint cases ───────────────────────────

t_fresh_install_pins_after_controller_and_readiness() {
  local ep
  ip_select
  for ep in $IP_EPS; do
    (
      local snap pers ready pin start chk
      dt_world "$ep" "$(dt_fresh_state "$ep")"
      ip_install "$ep"
      assert_rc 0 "$IP_RC" "$ep: $IP_OUT"
      dt_pinned || fail "$ep: the host resolver is pinned at the end: $(dt_dns_state)"
      snap="$(ip_first "$FAKE_LOG" '(custom-dns-deb|start-container-root\.sh) snapshot$')"
      pers="$(ip_last "$FAKE_LOG" '^(persistent-podman|persist)\.sh ')"
      pin="$(ip_first "$FAKE_LOG" '^sudo ([^ ]*/)?(usr/bin/custom-dns-deb|bash [^ ]*/custom-dns-deb) pin$|^sudo bash [^ ]*/start-container-root\.sh post$|^agent: start-container-root\.sh post$')"
      assert_ne "" "$snap" "$ep: the owned state is recorded"
      assert_ne "" "$pin" "$ep: the resolver is pinned"
      # The chain answers after the new stack started (Linux: the pod
      # restart in persistent-podman.sh; macOS: the proxy container) and
      # before the pin.
      start="$(ip_last "$FAKE_LOG" '^(persistent-podman\.sh |container run -d --name tor-)')"
      ready="$(ip_lines "$FAKE_LOG" '^dig @(127\.0\.0\.1|172\.31\.240\.250) ' | awk -F: -v a="$start" -v b="$pin" '$1 > a && $1 < b' | head -n 1)"
      assert_eq 1 "$((snap < $(ip_first "$FAKE_LOG" "$IP_DISRUPTIVE")))" "$ep: the record precedes every disruptive call:
$(cat -n "$FAKE_LOG")"
      chk="$(ip_first "$FAKE_LOG" '^nice-dns-health self-check$')"
      assert_ne "" "$chk" "$ep: the installed controller's self-check ran"
      assert_eq 1 "$((chk < pin))" "$ep: the installed controller passed its self-check (line $chk) before the first pin (line $pin), the agent's included:
$(cat -n "$FAKE_LOG")"
      assert_eq 1 "$((pers < pin))" "$ep: the controller is installed (line $pers) before the pin (line $pin):
$(cat -n "$FAKE_LOG")"
      assert_ne "" "$ready" "$ep: the chain answers after the stack starts (line $start) and before the pin:
$(cat -n "$FAKE_LOG")"
      assert_file "$IP_STATE/current" "$ep: the generation is current"
    ) || exit 1
  done
}

# dt_rollback_case <entrypoint> <fresh|reinstall> <injection>: an install
# that fails after the interruption leaves DNS and the deployment as they were.
dt_rollback_case() {
  local ep="$1" mode="$2" inj="$3" dns0 dep0 cur0
  dt_world "$ep" "$(dt_fresh_state "$ep")"
  [ "$mode" = reinstall ] && dt_installed "$ep"
  dns0="$(dt_dns_state)"; dep0="$(dt_deploy_state)"; cur0="$(cat "$IP_STATE/current" 2>/dev/null)"
  case "$inj" in
    persist_fail|never_ready|selfcheck_fail|probe_fail) : >"$FAKE/$inj" ;;
    sigint:*) printf '%s\n' "${inj#sigint:}" >"$FAKE/sigint" ;;
    *) printf '%s\n' "$inj" >"$FAKE/fail" ;;
  esac
  ip_install "$ep" socat
  assert_nonzero "$IP_RC" "$ep/$mode/$inj: the install fails: $IP_OUT"
  rm -f "$FAKE/fail" "$FAKE/sigint" "$FAKE/persist_fail" "$FAKE/never_ready" "$FAKE/selfcheck_fail" "$FAKE/probe_fail"
  assert_eq "$dns0" "$(dt_dns_state)" "$ep/$mode/$inj: host DNS is exactly as before:
$(cat -n "$FAKE_LOG")"
  assert_eq "$dep0" "$(dt_deploy_state)" "$ep/$mode/$inj: the prior deployment is back:
$(cat -n "$FAKE_LOG")"
  assert_eq "$cur0" "$(cat "$IP_STATE/current" 2>/dev/null)" "$ep/$mode/$inj: the current generation is unchanged"
  if [ "$mode" = fresh ]; then
    assert_eq "" "$(ip_lines "$FAKE_LOG" '^sudo ([^ ]*/)?(usr/bin/custom-dns-deb|bash [^ ]*/custom-dns-deb) pin$|^sudo bash [^ ]*/start-container-root\.sh post$|^agent: start-container-root\.sh post$')" "$ep/$mode/$inj: nothing was pinned"
    assert_no_path "$(dt_receipt "$(ip_platform "$ep")")" "$ep/$mode/$inj: the unused record is discarded"
  fi
  assert_match 'rolled back|rolling back|Rolling back' "$IP_OUT" "$ep/$mode/$inj: the rollback is reported"
  assert_not_match 'another owner' "$IP_OUT" "$ep/$mode/$inj: no false ownership warning"
  # A builder the install started is stopped again, and the runtime is
  # restarted after it (the builder wedges dnsnet; a restart heals it).
  local bs st rs
  bs="$(ip_last "$FAKE_LOG" '^container builder start')"
  if [ -n "$bs" ]; then
    st="$(ip_last "$FAKE_LOG" '^container builder stop')"
    rs="$(ip_last "$FAKE_LOG" '^container system stop')"
    assert_ne "" "$st" "$ep/$mode/$inj: the builder started at line $bs is stopped"
    assert_ne "" "$rs" "$ep/$mode/$inj: the runtime is restarted"
    assert_eq 1 "$(( ${st:-0} > bs ))" "$ep/$mode/$inj: the builder is stopped after it started (line $bs):
$(cat -n "$FAKE_LOG")"
    assert_eq 1 "$(( ${rs:-0} > bs ))" "$ep/$mode/$inj: the runtime restarts after the builder ran (line $bs):
$(cat -n "$FAKE_LOG")"
  fi
}

dt_injections() {
  if [ "$(ip_platform "$1")" = linux ]; then
    printf '%s\n' persist_fail never_ready selfcheck_fail probe_fail '^podman system migrate' '^podman tag localhost/unbound:[0-9]' \
      'sigint:^podman system migrate' 'sigint:^podman pod rm -f nice-dns$'
  else
    printf '%s\n' persist_fail never_ready selfcheck_fail probe_fail '^container build ' '^container network create ' \
      'sigint:^container build ' 'sigint:^container stop pi-hole$'
  fi
}

t_failed_controller_install_leaves_dns_as_it_was() {
  local ep mode
  ip_select
  for ep in $IP_EPS; do
    for mode in fresh reinstall; do
      ( dt_rollback_case "$ep" "$mode" persist_fail ) || exit 1
    done
  done
}

t_failed_activation_rolls_back_the_deployment() {
  local ep inj
  ip_select
  for ep in $IP_EPS; do
    while IFS= read -r inj; do
      [ "$inj" = persist_fail ] && continue
      ( dt_rollback_case "$ep" reinstall "$inj" ) || exit 1
      ( dt_rollback_case "$ep" fresh "$inj" ) || exit 1
    done <<EOF
$(dt_injections "$ep")
EOF
  done
}

t_reinstall_holds_the_controller() {
  local ep
  ip_select
  for ep in $IP_EPS; do
    (
      local hold first
      dt_world "$ep" "$(dt_fresh_state "$ep")"
      dt_installed "$ep"
      : >"$FAKE/never_ready"
      ip_install "$ep"
      assert_nonzero "$IP_RC" "$ep: $IP_OUT"
      if [ "$(ip_platform "$ep")" = linux ]; then
        hold="$(ip_first "$FAKE_LOG" '^systemctl --user stop nice-dns-health\.timer')"
        first="$(ip_first "$FAKE_LOG" '^podman pod rm')"
        assert_match '^systemctl --user start nice-dns-health\.timer' "$(sed -n "$first,\$p" "$FAKE_LOG")" "$ep: the rollback restarts the controller"
      else
        hold="$(ip_first "$FAKE_LOG" '^launchctl unload .*org\.nice-dns\.health\.plist')"
        first="$(ip_first "$FAKE_LOG" '^container stop ')"
        assert_match '^launchctl load .*org\.nice-dns\.health\.plist' "$(sed -n "$first,\$p" "$FAKE_LOG")" "$ep: the rollback restarts the controller"
      fi
      assert_ne "" "$hold" "$ep: the controller is held:
$(cat -n "$FAKE_LOG")"
      assert_eq 1 "$((hold < first))" "$ep: before the stack stops"
    ) || exit 1
  done
}

t_uninstall_restores_the_recorded_state() {
  local ep
  ip_select
  for ep in $IP_EPS; do
    (
      local before
      dt_world "$ep" "$(dt_fresh_state "$ep")"
      before="$(dt_dns_state)"
      ip_install "$ep"
      assert_rc 0 "$IP_RC" "$ep: install: $IP_OUT"
      ip_install "$ep" uninstall
      assert_rc 0 "$IP_RC" "$ep: uninstall: $IP_OUT"
      assert_eq "$before" "$(dt_dns_state)" "$ep: uninstall restores the recorded state exactly"
      assert_no_path "$(dt_receipt "$(ip_platform "$ep")")" "$ep: and drops the record"
      assert_no_path "$IP_HOME/.local/bin/nice-dns-health" "$ep: the controller is uninstalled"
    ) || exit 1
  done
}

t_external_change_refuses_the_install() {
  local ep
  ip_select
  for ep in $IP_EPS; do
    (
      local before
      dt_world "$ep" "$(dt_fresh_state "$ep")"
      dt_installed "$ep"
      if [ "$(ip_platform "$ep")" = linux ]; then
        rm -f "$FAKE_ROOT/etc/resolv.conf"; printf 'nameserver 10.64.0.1\n' >"$FAKE_ROOT/etc/resolv.conf"
      else
        printf '10.64.0.1\n' >"$FAKE_ROOT/.netsvc/dns/Wi-Fi"
      fi
      before="$(dt_dns_state)"
      ip_install "$ep"
      assert_nonzero "$IP_RC" "$ep: the reinstall refuses: $IP_OUT"
      assert_match 'another owner' "$IP_OUT" "$ep: and says why"
      ip_assert_untouched "$ep"
      assert_eq "$before" "$(dt_dns_state)" "$ep: DNS unchanged"
    ) || exit 1
  done
}

# Public DNS is never written by an installer: only the helpers write the
# host resolver, and they write the pin or the recorded state.
t_no_installer_writes_the_resolver_directly() {
  local f hits
  hits="$(grep -nE 'resolv\.conf|nameserver [0-9]|setdnsservers' \
    "$NICE_DNS_ROOT"/install-deb.sh "$NICE_DNS_ROOT"/install-deb-hardened.sh \
    "$NICE_DNS_ROOT"/install-mac.sh "$NICE_DNS_ROOT"/install-mac-hardened.sh \
    "$NICE_DNS_ROOT"/lib/install.sh "$NICE_DNS_ROOT"/deb/persistent-podman.sh "$NICE_DNS_ROOT"/mac/persist.sh \
    | grep -vE '^[^:]+:[0-9]+:[[:space:]]*#' || true)"
  assert_eq "" "$hits" "no installer code writes resolv.conf or network-service DNS itself"
  for f in 9.9.9.9 1.1.1.1 1.0.0.1; do
    assert_eq "" "$(grep -nF "$f" "$NICE_DNS_ROOT"/deb/custom-dns-deb "$NICE_DNS_ROOT"/mac/start-container-root.sh || true)" "the helpers name no public resolver ($f)"
  done
}

# The installer verbs run under the operator's own sudo; the LaunchAgent's
# passwordless rule stays bounded to the three it needs.
t_agent_sudo_rule_excludes_installer_verbs() {
  local rule
  rule="$(grep -v '^#' "$NICE_DNS_ROOT/mac/start-container.sudoers" | grep -v '^[[:space:]]*$')"
  assert_eq '__USERNAME__ ALL=(root) NOPASSWD: /usr/local/sbin/start-container-root.sh pre, /usr/local/sbin/start-container-root.sh repair-dnsnet, /usr/local/sbin/start-container-root.sh post' "$rule" "the NOPASSWD rule names exactly pre, repair-dnsnet and post"
}

# macOS sudo keeps the caller's PATH (no secure_path; live on the mac,
# 2026-10-06), so through that rule a planted binary ran as root. The helper
# names its shell and, as root, resolves tools from the system directories
# before its first command.
t_root_helper_ignores_the_callers_path() {
  local f="$NICE_DNS_ROOT/mac/start-container-root.sh" set first
  assert_eq '#!/bin/bash' "$(head -n 1 "$f")" "the helper's shell is not looked up on PATH"
  set="$(grep -n '^  PATH=/usr/bin:/bin:/usr/sbin:/sbin$' "$f" | cut -d: -f1)"
  first="$(grep -n '^MULLVAD_PLIST=' "$f" | cut -d: -f1)"
  assert_ne "" "$set" "a root run sets a system-only PATH"
  assert_eq 1 "$(( ${set:-99999} < ${first:-0} ))" "the PATH is set (line $set) before anything runs (line $first)"
  assert_match 'export PATH' "$(sed -n "${set:-1},$((${set:-1} + 1))p" "$f")" "and exported to what the helper runs"
}

# persist.sh (the real one) loads the start-container agent, whose first run
# pins DNS, only after the controller installed and its installed copy passed
# its self-check.
t_persist_gates_the_agent_on_the_controller() {
  local f="$NICE_DNS_ROOT/mac/persist.sh" inst chk load
  inst="$(grep -n 'nice-dns-health" install' "$f" | head -n 1 | cut -d: -f1)"
  chk="$(grep -n 'self-check' "$f" | grep -v '^[0-9]*:[[:space:]]*#' | head -n 1 | cut -d: -f1)"
  # shellcheck disable=SC2016  # literal $ in patterns
  load="$(grep -n '^launchctl load "\$AGENT_DST"' "$f" | cut -d: -f1)"
  assert_ne "" "$inst" "persist.sh installs the controller"
  assert_ne "" "$chk" "persist.sh runs the installed controller's self-check"
  assert_ne "" "$load" "persist.sh loads the start-container agent"
  assert_eq 1 "$((inst < chk && chk < load))" "install (line $inst), then self-check (line $chk), then the agent load (line $load)"
  assert_match 'exit 1' "$(sed -n "${chk},$((chk + 3))p" "$f")" "a failed self-check exits before the agent load"
}

# A rolled-back deployment that does not answer is reported as such, and DNS
# stays pinned to it (fail closed), never public.
t_rollback_reports_a_previous_stack_that_does_not_answer() {
  local ep
  ip_select
  for ep in $IP_EPS; do
    (
      local dns0
      dt_world "$ep" "$(dt_fresh_state "$ep")"
      dt_installed "$ep"
      dns0="$(dt_dns_state)"
      : >"$FAKE/persist_fail"; : >"$FAKE/rollback_never_ready"
      ip_install "$ep"
      assert_nonzero "$IP_RC" "$ep: $IP_OUT"
      assert_match 'does not answer' "$IP_OUT" "$ep: the rollback says the previous stack does not answer"
      assert_not_match 'which answers again' "$IP_OUT" "$ep: and does not claim it came back"
      assert_eq "$dns0" "$(dt_dns_state)" "$ep: host DNS stays pinned to it"
      assert_match 'rolled-back-not-answering' "$(cat "$IP_STATE"/generations/*-bbbbbbbbbbbb/prepare.tsv)" "$ep: the manifest records it"
    ) || exit 1
  done
}

# A network service that appeared after the install carries DHCP servers,
# not another owner's change; a partly pinned install from before records
# gives each service back what it had.
t_helper_mac_new_and_partly_pinned_services() {
  (
    dt_world install-mac fresh
    dt_helper macos snapshot; dt_helper macos post
    printf 'USB LAN\n' >>"$FAKE_ROOT/.netsvc/list"; printf '10.1.1.1\n' >"$FAKE_ROOT/.netsvc/dns/USB LAN"
    dt_helper macos check
    assert_rc 0 "$DT_RC" "a new service is not a refusal: $DT_OUT"
    dt_helper macos restore
    assert_eq 10.1.1.1 "$(cat "$FAKE_ROOT/.netsvc/dns/USB LAN")" "the new service keeps its servers"
  ) || exit 1
  (
    dt_world install-mac legacy
    printf '192.168.7.1\n' >"$FAKE_ROOT/.netsvc/dns/Ethernet"   # one service reset by hand
    dt_helper macos snapshot
    assert_eq legacy "$(awk -F '\t' '$1 == "origin" { print $2 }' "$(dt_receipt macos)")" "a partly pinned earlier install is legacy"
    dt_helper macos restore
    assert_eq "$(printf 'service Wi-Fi: \nservice Ethernet: 192.168.7.1\nservice Thunderbolt Bridge: ')" "$(dt_dns_state)" "pinned services go back to Empty, the reset one keeps its servers"
  ) || exit 1
}

# The owned files the Linux helper removes are the ones an install saves for
# its rollback (two lists; they must not drift).
t_owned_file_lists_agree() {
  local f missing=""
  # shellcheck disable=SC2016  # literal $ in patterns
  for f in $(sed -n '/^OWNED_FILES=(/,/^)/p' "$NICE_DNS_ROOT/deb/custom-dns-deb" | grep -o '"\$R/[^"]*"' | tr -d '"' | sed 's/^\$R//'); do
    grep -qF "\$R$f\"" "$NICE_DNS_ROOT/lib/install.sh" || missing="$missing $f"
  done
  assert_eq "" "$missing" "every OWNED_FILES path of deb/custom-dns-deb is saved by _nd_inst_owned_paths"
  # shellcheck disable=SC2016  # literal $ in patterns
  assert_ne "" "$(sed -n '/^OWNED_FILES=(/,/^)/p' "$NICE_DNS_ROOT/deb/custom-dns-deb" | grep -c '\$R/')" "the list is read"
}

# ─────────────────────────── Stage 1 gate, round 1 ─────────────────────────

# A restore that cannot finish changes nothing it has not finished: Linux
# puts resolv.conf back first (while NetworkManager is still held off it) or
# stops with the host still coherently pinned; macOS attempts every service.
# The record stays for a retry either way.
t_restore_is_all_or_nothing() {
  (
    local rec
    dt_world install-deb file
    dt_helper linux snapshot; dt_helper linux pin
    mkdir -p "$FAKE_ROOT/etc/NetworkManager/conf.d"; printf '[main]\ndns=none\n' >"$FAKE_ROOT/etc/NetworkManager/conf.d/90-nice-dns.conf"
    rec="$(dt_receipt linux)"
    rm -f "$(dirname "$rec")/resolv.conf.orig"
    dt_helper linux restore
    assert_nonzero "$DT_RC" "linux: a restore without the recorded copy fails: $DT_OUT"
    assert_eq 'nameserver 127.0.0.1' "$(cat "$FAKE_ROOT/etc/resolv.conf")" "linux: resolv.conf stays pinned, never missing"
    assert_file "$FAKE_ROOT/etc/NetworkManager/conf.d/90-nice-dns.conf" "linux: the NetworkManager hold stays with it"
    assert_file "$rec" "linux: the record stays"
    assert_no_path "$FAKE_ROOT/etc/resolv.conf.nice-dns-new" "linux: no half-written file is left"
  ) || exit 1
  (
    dt_world install-deb resolved
    dt_helper linux snapshot; dt_helper linux pin
    chmod 555 "$FAKE_ROOT/etc"
    dt_helper linux restore
    chmod 755 "$FAKE_ROOT/etc"
    assert_nonzero "$DT_RC" "linux: an unwritable /etc fails the restore: $DT_OUT"
    assert_eq 'nameserver 127.0.0.1' "$(cat "$FAKE_ROOT/etc/resolv.conf")" "linux: resolv.conf stays pinned, never missing"
    assert_file "$(dt_receipt linux)" "linux: the record stays"
    dt_helper linux restore
    assert_rc 0 "$DT_RC" "linux: the retry restores: $DT_OUT"
    assert_eq ../run/systemd/resolve/stub-resolv.conf "$(readlink "$FAKE_ROOT/etc/resolv.conf")" "linux: the symlink is back"
  ) || exit 1
  (
    dt_world install-mac fresh
    dt_helper macos snapshot; dt_helper macos post
    printf '^networksetup -setdnsservers Ethernet\n' >"$FAKE/fail"
    dt_helper macos restore
    rm -f "$FAKE/fail"
    assert_nonzero "$DT_RC" "macos: a failing service fails the restore: $DT_OUT"
    assert_eq 192.168.1.1 "$(cat "$FAKE_ROOT/.netsvc/dns/Wi-Fi")" "macos: the other services are still restored"
    assert_eq "$DT_PIN_MAC" "$(cat "$FAKE_ROOT/.netsvc/dns/Ethernet")" "macos: the failed one still carries the pin"
    assert_file "$(dt_receipt macos)" "macos: the record stays"
    dt_helper macos restore
    assert_rc 0 "$DT_RC" "macos: the retry restores: $DT_OUT"
    assert_eq '9.9.9.9 149.112.112.112' "$(tr '\n' ' ' <"$FAKE_ROOT/.netsvc/dns/Ethernet" | sed 's/ $//')" "macos: and the failed service is back"
  ) || exit 1
}

# An install or uninstall whose DNS restore failed says so and fails; it never
# reports host DNS as given back. The uninstall still removes the rest.
t_incomplete_dns_restore_is_reported() {
  local ep
  ip_select
  for ep in $IP_EPS; do
    (
      local plat
      plat="$(ip_platform "$ep")"
      # Linux: a plain resolv.conf, whose recorded copy the restore needs.
      if [ "$plat" = linux ]; then dt_world "$ep" file; else dt_world "$ep" fresh; fi
      ip_install "$ep"
      assert_rc 0 "$IP_RC" "$ep: $IP_OUT"
      if [ "$plat" = linux ]; then rm -f "$(dirname "$(dt_receipt linux)")/resolv.conf.orig"
      else printf '^networksetup -setdnsservers Ethernet\n' >"$FAKE/fail"; fi
      ip_install "$ep" uninstall
      assert_nonzero "$IP_RC" "$ep: the uninstall fails: $IP_OUT"
      assert_match 'NOT given back' "$IP_OUT" "$ep: and says host DNS was not given back"
      assert_not_match 'nice-dns uninstalled' "$IP_OUT" "$ep: it does not claim success"
      assert_no_path "$IP_HOME/.local/bin/nice-dns-health" "$ep: the rest of the uninstall still ran"
      assert_file "$(dt_receipt "$plat")" "$ep: the record stays for the retry"
      # The instance state and the password stay until DNS is given back.
      assert_eq "" "$(grep -E '^(podman|container) volume rm ' "$FAKE_LOG" || true)" "$ep: no state volume was removed"
      assert_file "$IP_HOME/.local/state/nice-dns/secrets/pihole/pihole_webpassword" "$ep: the admin password is kept"
      assert_match 'Tor state, root anchor, Pi-hole lists and admin password' "$IP_OUT" "$ep: and says so"
      assert_file "$IP_STATE/current" "$ep: the current generation stays named, for a reinstall's rollback"
      # The retry, with the cause fixed, removes them. Linux: only the
      # record's copy is put back (restore content is t_helper_snapshot_and_
      # restore_are_exact's); macOS: the failing service works again.
      if [ "$plat" = linux ]; then dt_helper linux snapshot >/dev/null 2>&1 || true; cp "$FAKE_ROOT/etc/resolv.conf" "$(dirname "$(dt_receipt linux)")/resolv.conf.orig" 2>/dev/null || true
      else rm -f "$FAKE/fail"; fi
      : >"$FAKE_LOG"
      ip_install "$ep" uninstall
      assert_rc 0 "$IP_RC" "$ep: the retry succeeds: $IP_OUT"
      assert_match '(podman|container) volume rm ' "$(cat "$FAKE_LOG")" "$ep: the retry removes the state volumes"
      assert_no_path "$IP_HOME/.local/state/nice-dns/secrets/pihole/pihole_webpassword" "$ep: and the admin password"
      assert_no_path "$IP_STATE/current" "$ep: and the current-generation marker"
    ) || exit 1
    (
      local plat h
      plat="$(ip_platform "$ep")"
      dt_world "$ep" "$(dt_fresh_state "$ep")"
      # A first install that fails after its pin (the pin check), whose
      # DNS restore then fails too (the helper call itself fails).
      if [ "$plat" = linux ]; then h=custom-dns-deb; else h='start-container-root\.sh'; fi
      printf '^sudo bash [^ ]*/%s status$\n^sudo bash [^ ]*/%s restore$\n' "$h" "$h" >"$FAKE/fail"
      ip_install "$ep"
      rm -f "$FAKE/fail"
      assert_nonzero "$IP_RC" "$ep: $IP_OUT"
      assert_match 'host DNS was NOT given back' "$IP_OUT" "$ep: the rollback says DNS was not given back"
      assert_not_match 'host DNS is as it was' "$IP_OUT" "$ep: and does not claim it"
      assert_match "$(printf 'status\trolled-back-dns-not-restored')" "$(cat "$IP_STATE"/generations/*/prepare.tsv)" "$ep: the manifest records it"
    ) || exit 1
  done
}

# The record is taken inside the rollback window: an interrupt right after it
# is rolled back (the unused record discarded), never a false "another owner".
t_record_is_taken_inside_the_rollback_window() {
  local f
  for f in nd_install_linux_activate nd_install_macos_activate; do
    assert_eq 1 "$(sed -n "/^$f() {/,/^}/p" "$NICE_DNS_ROOT/lib/install.sh" | awk '/_nd_inst_begin_interruption/ && !b { b = NR } /_nd_inst_dns_helper snapshot/ && !s { s = NR } END { print (b && s && b < s) ? 1 : 0 }')" "$f: the rollback is armed before the record is taken"
  done
}

# NetworkManager's dns=dnsmasq is overridden by the owned drop-in, never by
# editing NetworkManager.conf; a failed install and an uninstall remove it.
t_dnsmasq_is_overridden_by_an_owned_drop_in() {
  local ep
  ip_select
  assert_ne "" "$IP_EPS" "an entrypoint is selected (the case applies to some of them only)"
  for ep in $IP_EPS; do
    [ "$(ip_platform "$ep")" = linux ] || continue
    (
      local conf
      dt_world "$ep" resolved
      mkdir -p "$FAKE_ROOT/etc/NetworkManager"
      printf '[main]\nplugins=ifupdown,keyfile\ndns=dnsmasq\n' >"$FAKE_ROOT/etc/NetworkManager/NetworkManager.conf"
      conf="$(cat "$FAKE_ROOT/etc/NetworkManager/NetworkManager.conf")"
      : >"$FAKE/never_ready"
      ip_install "$ep"
      assert_nonzero "$IP_RC" "$ep: the failed first install: $IP_OUT"
      assert_eq 1 "$(( $(ip_first "$FAKE_LOG" '^sudo tee [^ ]*/etc/NetworkManager/conf\.d/90-nice-dns\.conf$') < $(ip_first "$FAKE_LOG" '^persistent-podman\.sh ') ))" "$ep: dnsmasq is held off by the drop-in before the stack starts:
$(cat -n "$FAKE_LOG")"
      assert_eq "" "$(grep -E '^sudo sed .*NetworkManager\.conf' "$FAKE_LOG")" "$ep: no edit of NetworkManager.conf is attempted"
      assert_eq "$conf" "$(cat "$FAKE_ROOT/etc/NetworkManager/NetworkManager.conf")" "$ep: NetworkManager.conf is never edited"
      assert_no_path "$FAKE_ROOT/etc/NetworkManager/conf.d/90-nice-dns.conf" "$ep: the rollback removes the drop-in"
      ip_install "$ep"
      assert_rc 0 "$IP_RC" "$ep: install: $IP_OUT"
      assert_eq '[main]
dns=none' "$(cat "$FAKE_ROOT/etc/NetworkManager/conf.d/90-nice-dns.conf")" "$ep: the owned drop-in overrides dnsmasq"
      assert_eq "$conf" "$(cat "$FAKE_ROOT/etc/NetworkManager/NetworkManager.conf")" "$ep: NetworkManager.conf untouched"
      ip_install "$ep" uninstall
      assert_rc 0 "$IP_RC" "$ep: uninstall: $IP_OUT"
      assert_no_path "$FAKE_ROOT/etc/NetworkManager/conf.d/90-nice-dns.conf" "$ep: uninstall removes it"
      assert_eq "$conf" "$(cat "$FAKE_ROOT/etc/NetworkManager/NetworkManager.conf")" "$ep: and NetworkManager.conf is as it was"
    ) || exit 1
  done
}

# macOS: the previous deployment's images are kept after the runtime starts;
# a deployment whose images cannot be found is refused before any change.
t_previous_images_are_kept_with_the_runtime_up() {
  local ep
  ip_select
  assert_ne "" "$IP_EPS" "an entrypoint is selected (the case applies to some of them only)"
  for ep in $IP_EPS; do
    [ "$(ip_platform "$ep")" = macos ] || continue
    (
      local dep0
      dt_world "$ep" fresh
      dt_installed "$ep"
      dep0="$(dt_deploy_state)"
      : >"$FAKE/rt_down"             # the runtime is stopped when the reinstall starts
      : >"$FAKE/never_ready"
      ip_install "$ep" socat
      assert_nonzero "$IP_RC" "$ep: $IP_OUT"
      assert_eq "$dep0" "$(dt_deploy_state)" "$ep: the previous images come back after the rollback"
    ) || exit 1
    (
      dt_world "$ep" fresh
      dt_installed "$ep"
      awk '$1 !~ /^(unbound|pi-hole):latest$/' "$FAKE/images" >"$FAKE/images.t" && mv "$FAKE/images.t" "$FAKE/images"
      ip_install "$ep"
      assert_nonzero "$IP_RC" "$ep: a deployment without its images is refused: $IP_OUT"
      assert_match 'could not be rolled back to' "$IP_OUT" "$ep: and says why"
      ip_assert_untouched "$ep"
    ) || exit 1
  done
}

# The sudo keepalive refreshes the credential without prompting and stops
# with the install.
t_sudo_keepalive_refreshes_and_stops() {
  local w="$CASE_DIR/ka" out n1 n2
  mkdir -p "$w/bin"
  printf '#!/bin/sh\nprintf "sudo %%s\\n" "$*" >>"%s/log"\n' "$w" >"$w/bin/sudo"; chmod 755 "$w/bin/sudo"
  : >"$w/log"
  out="$(PATH="$w/bin:$PATH" ND_INST_SUDO_KEEPALIVE=0.1 bash -c '
    . "$1/lib/install.sh"
    _nd_inst_sudo_keepalive
    sleep 0.45
    _nd_inst_sudo_keepalive_stop
    sleep 0.3
    echo stopped' _ "$NICE_DNS_ROOT" 2>&1)"
  assert_match stopped "$out" "the loop ran and stopped: $out"
  n1="$(grep -c '^sudo -n -v$' "$w/log")"
  assert_eq 1 "$(( n1 >= 2 ))" "it refreshed with sudo -n -v (never prompting): $n1 times"
  sleep 0.3; n2="$(grep -c '^sudo -n -v$' "$w/log")"
  assert_eq "$n1" "$n2" "no refresh after it stopped"
  assert_eq 0 "$(ND_INST_SUDO_KEEPALIVE=0 bash -c '. "$1/lib/install.sh"; _nd_inst_sudo_keepalive; echo "${ND_INST_KEEPALIVE_PID:-0}"' _ "$NICE_DNS_ROOT")" "0 disables it"
}

# With root steps going through nice-dns-helper there is no sudo ticket, so
# the keepalive does not start (a refresh would only log a failed sudo).
t_sudo_keepalive_skipped_when_the_helper_runs_root_steps() {
  local w="$CASE_DIR/kah" plat fn pid
  mkdir -p "$w/bin"
  printf '#!/bin/sh\nprintf "sudo %%s\\n" "$*" >>"%s/log"\n' "$w" >"$w/bin/sudo"; chmod 755 "$w/bin/sudo"
  for plat in linux macos; do
    if [ "$plat" = linux ]; then fn=_nd_root_helper_deb; else fn=_nd_root_helper_mac; fi
    : >"$w/log"
    pid="$(PATH="$w/bin:$PATH" ND_INST_SUDO_KEEPALIVE=0.1 ND_INST_PLATFORM="$plat" bash -c '
      . "$1/lib/install.sh"
      eval "$2() { echo /usr/libexec/nice-dns-helper; }"
      _nd_inst_sudo_keepalive
      echo "${ND_INST_KEEPALIVE_PID:-none}"
      sleep 0.35
      _nd_inst_sudo_keepalive_stop' _ "$NICE_DNS_ROOT" "$fn" 2>&1)"
    assert_eq none "$pid" "$plat, helper in use: no keepalive"
    assert_eq "" "$(cat "$w/log")" "$plat, helper in use: no sudo refresh"
    : >"$w/log"
    pid="$(PATH="$w/bin:$PATH" ND_INST_SUDO_KEEPALIVE=0.1 ND_INST_PLATFORM="$plat" bash -c '
      . "$1/lib/install.sh"
      eval "$2() { return 1; }"
      _nd_inst_sudo_keepalive
      echo "${ND_INST_KEEPALIVE_PID:-none}"
      sleep 0.35
      _nd_inst_sudo_keepalive_stop' _ "$NICE_DNS_ROOT" "$fn" 2>&1)"
    assert_eq 1 "$(case "$pid" in none|'') echo 0 ;; *) echo 1 ;; esac)" "$plat, no helper: the keepalive starts: $pid"
    assert_match 'sudo -n -v' "$(cat "$w/log")" "$plat, no helper: it refreshes sudo"
  done
}

# Live finding 2026-09-28 (mint): an older installer had pinned the Wi-Fi
# profile to 127.0.0.1 with automatic DNS ignored and never recorded it, so a
# legacy uninstall left the host without DNS. The helper now records those
# pins on a legacy host and gives them automatic DNS back; an unrelated
# profile, a fresh host's profile and a pin changed since are left alone.
dt_nm_profile() { mkdir -p "$FAKE_ROOT/.nm/$1"; printf '%s\n' "$2" >"$FAKE_ROOT/.nm/$1/dns"; printf '%s\n' "$3" >"$FAKE_ROOT/.nm/$1/ignore"; printf '%s' "$4" >"$FAKE_ROOT/.nm/$1/device"; }
dt_nm_state() { local p; for p in "$FAKE_ROOT"/.nm/*; do printf '%s dns=%s ignore=%s\n' "${p##*/}" "$(cat "$p/dns")" "$(cat "$p/ignore")"; done; }
t_legacy_profile_pins_get_automatic_dns_back() {
  (
    dt_world install-deb legacy
    dt_nm_profile wifi-1 127.0.0.1 yes wlp1
    dt_nm_profile vpn-2 10.8.0.1 yes tun0
    dt_nm_profile eth-3 '' no ''
    # Listed after the pin, as on mint (Tier-1 review: a last profile that is
    # not a pin must not end the snapshot).
    dt_nm_profile zt-4 '' no zt0
    ip_install install-deb socat
    assert_rc 0 "$IP_RC" "legacy upgrade: $IP_OUT"
    assert_match "$(printf 'nm_pin\twifi-1')" "$(cat "$(dt_receipt linux)")" "the record names the legacy profile pin"
    assert_not_match 'nm_pin.(vpn-2|eth-3)' "$(cat "$(dt_receipt linux)")" "and only it"
    : >"$FAKE_LOG"
    ip_install install-deb uninstall
    assert_rc 0 "$IP_RC" "uninstall: $IP_OUT"
    assert_eq "$(printf 'eth-3 dns= ignore=no\nvpn-2 dns=10.8.0.1 ignore=yes\nwifi-1 dns= ignore=no\nzt-4 dns= ignore=no')" "$(dt_nm_state)" "the pinned profile uses automatic DNS again; the others are as they were"
    assert_eq 1 "$(( $(ip_last "$FAKE_LOG" '^nmcli con mod ') < $(ip_first "$FAKE_LOG" '^systemctl reload NetworkManager') ))" "the profile is reset before NetworkManager is reloaded"
    assert_match '^nmcli dev reapply wlp1$' "$(cat "$FAKE_LOG")" "and is reapplied on its device"
    assert_eq 1 "$(grep -c '^nmcli con mod ' "$FAKE_LOG")" "one profile changed"
  ) || exit 1
  (
    dt_world install-deb resolved
    dt_nm_profile own-1 127.0.0.1 yes eth0
    ip_install install-deb socat
    assert_rc 0 "$IP_RC" "fresh install: $IP_OUT"
    assert_not_match 'nm_pin' "$(cat "$(dt_receipt linux)")" "a fresh host's profile is not claimed"
    ip_install install-deb uninstall
    assert_eq 'own-1 dns=127.0.0.1 ignore=yes' "$(dt_nm_state)" "and uninstall leaves it alone"
  ) || exit 1
  (
    dt_world install-deb legacy
    dt_nm_profile wifi-1 127.0.0.1 yes wlp1
    ip_install install-deb socat
    printf '9.9.9.9\n' >"$FAKE_ROOT/.nm/wifi-1/dns"
    ip_install install-deb uninstall
    assert_rc 0 "$IP_RC" "uninstall: $IP_OUT"
    assert_eq 'wifi-1 dns=9.9.9.9 ignore=yes' "$(dt_nm_state)" "a pin another owner changed since is left alone"
    assert_match 'changed since the record' "$IP_OUT" "and says so"
  ) || exit 1
  (
    # NetworkManager does not answer at the uninstall: the pins are not read
    # as "changed since" and dropped; the restore fails and keeps the record,
    # and a retry resets them (Stage 3 gate class sweep, 2026-10-12).
    dt_world install-deb legacy
    dt_nm_profile wifi-1 127.0.0.1 yes wlp1
    ip_install install-deb socat
    assert_rc 0 "$IP_RC" "nm-down: install: $IP_OUT"
    printf '%s\n' '^nmcli -t -f UUID con show$' >"$FAKE/fail"
    ip_install install-deb uninstall
    rm -f "$FAKE/fail"
    assert_nonzero "$IP_RC" "nm-down: the uninstall fails: $IP_OUT"
    assert_match 'NetworkManager did not answer' "$IP_OUT" "nm-down: and says why"
    assert_eq 'wifi-1 dns=127.0.0.1 ignore=yes' "$(dt_nm_state)" "nm-down: the pin is still there"
    assert_match "$(printf 'nm_pin\twifi-1')" "$(cat "$(dt_receipt linux)" 2>/dev/null)" "nm-down: and the record keeps it"
    ip_install install-deb uninstall
    assert_rc 0 "$IP_RC" "nm-down: the retry: $IP_OUT"
    assert_eq 'wifi-1 dns= ignore=no' "$(dt_nm_state)" "nm-down: the retry resets the pin"
  ) || exit 1
  (
    # NetworkManager removed after the install: its profiles are gone with
    # it, so the uninstall completes and names the pins (round-3 sweep).
    dt_world install-deb legacy
    dt_nm_profile wifi-1 127.0.0.1 yes wlp1
    ip_install install-deb socat
    assert_rc 0 "$IP_RC" "no-nm: install: $IP_OUT"
    rm -f "$IP_BIN/nmcli"
    ip_install install-deb uninstall
    assert_rc 0 "$IP_RC" "no-nm: the uninstall completes: $IP_OUT"
    assert_match 'nmcli is missing.*wifi-1' "$IP_OUT" "no-nm: and names the pin"
  ) || exit 1
  (
    # NetworkManager does not answer when a legacy host's record is taken:
    # the pins could not be listed, so the snapshot refuses.
    dt_world install-deb legacy
    dt_nm_profile wifi-1 127.0.0.1 yes wlp1
    printf '%s\n' '^nmcli -t -f UUID con show$' >"$FAKE/fail"
    dt_helper linux snapshot
    rm -f "$FAKE/fail"
    assert_nonzero "$DT_RC" "nm-down snapshot: refuses: $DT_OUT"
    assert_match 'NetworkManager did not answer' "$DT_OUT" "nm-down snapshot: and says why"
    assert_eq "" "$(cat "$(dt_receipt linux)" 2>/dev/null)" "nm-down snapshot: no record is written"
  ) || exit 1
  (
    dt_world install-deb legacy
    dt_nm_profile wifi-1 127.0.0.1 yes wlp1
    dt_helper linux restore
    assert_rc 0 "$DT_RC" "a legacy restore with no record: $DT_OUT"
    assert_eq 'wifi-1 dns= ignore=no' "$(dt_nm_state)" "finds the pin as it is now and resets it"
  ) || exit 1
}

t_a_profile_that_cannot_be_reset_fails_the_restore() {
  (
    dt_world install-deb legacy
    dt_nm_profile wifi-1 127.0.0.1 yes wlp1
    ip_install install-deb socat
    assert_rc 0 "$IP_RC" "legacy upgrade: $IP_OUT"
    printf '^nmcli con mod \n' >"$FAKE/fail"
    ip_install install-deb uninstall
    assert_nonzero "$IP_RC" "the uninstall reports it: $IP_OUT"
    assert_match 'still points at 127\.0\.0\.1' "$IP_OUT" "names the profile problem"
    assert_file "$(dt_receipt linux)" "and keeps the record for a retry"
    rm -f "$FAKE/fail"
    dt_helper linux restore
    assert_rc 0 "$DT_RC" "the retry: $DT_OUT"
    assert_eq 'wifi-1 dns= ignore=no' "$(dt_nm_state)" "resets the profile"
  ) || exit 1
}

# ─────────────────────────── Mullvad's DNS setting (BL-048) ─────────────────
#
# Mullvad VPN, connected, writes its own servers into /etc/resolv.conf and
# overwrites a pin within milliseconds unless its setting is custom 127.0.0.1
# (measured 2026-10-12, Mullvad 2026.3). The Linux installer records the
# setting it finds, switches to Mullvad's default DNS only when no nice-dns
# stack runs and none of a loopback-only custom setting's servers answers,
# sets custom 127.0.0.1 after the pin, and puts a recorded setting back on a
# rollback, a failed preparation or an uninstall.

# dt_mullvad <setting>: Mullvad on the host, its setting as `mullvad dns get`
# prints it: "custom <ip>..." or "default [<block>...]" (ads, malware, ...).
dt_mullvad() {
  local m="$1" k v
  ln -sf fakecmd "$IP_BIN/mullvad"
  # shellcheck disable=SC2086  # the setting's words
  set -- $1
  shift
  if [ "$m" = "${m#custom}" ]; then
    {
      echo "Custom DNS: no"
      for k in ads trackers malware adult-content gambling social-media; do
        v=false; case " $* " in *" $k "*) v=true ;; esac
        printf 'Block %s: %s\n' "$(printf '%s' "$k" | tr '-' ' ')" "$v"
      done
    } >"$FAKE/mullvad_dns"
  else
    { echo "Custom DNS: yes"; echo "Servers:"; for k in "$@"; do echo "$k"; done; } >"$FAKE/mullvad_dns"
  fi
}
dt_mullvad_calls() { grep -E '^mullvad ' "$FAKE_LOG" || true; }
dt_mullvad_now() { tr '\n' ' ' <"$FAKE/mullvad_dns" | sed 's/ $//'; }
# dt_newest_gen: the generation the last install allocated (activated or not).
dt_newest_gen() { find "$IP_STATE/generations" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' | sort | tail -n 1; }
dt_mullvad_receipt() { cat "$IP_STATE/generations/$(dt_newest_gen)/mullvad-dns.tsv" 2>/dev/null; }
dt_mv_rows() { printf 'schema\tnice-dns-mullvad-dns/1'; printf '\n%s' "$@" | tr '|' '\t'; }

dt_linux_eps() {
  local ep out=""
  ip_select
  for ep in $IP_EPS; do [ "$(ip_platform "$ep")" = linux ] && out="$out $ep"; done
  printf '%s\n' "$out"
}

t_mullvad_setting_is_recorded_switched_and_set_to_loopback() {
  local ep
  for ep in $(dt_linux_eps); do
    (
      local sw pre pin set
      # A first install with Mullvad's custom DNS at 127.0.0.1, nothing
      # answering there and no stack: the host has no DNS until Mullvad's
      # default is used. custom 127.0.0.1 with no earlier record is nice-dns's
      # own address: the setting from before nice-dns stands as the default.
      dt_world "$ep" resolved
      dt_mullvad "custom 127.0.0.1"
      ip_install "$ep"
      assert_rc 0 "$IP_RC" "$ep: the install succeeds: $IP_OUT"
      assert_eq "$(printf 'mullvad dns get\nmullvad dns set default\nmullvad dns set custom 127.0.0.1')" "$(dt_mullvad_calls)" "$ep: the exact Mullvad calls"
      assert_eq "$(dt_mv_rows 'before_install|custom|127.0.0.1' 'before_nicedns|default' 'switched|default')" \
        "$(dt_mullvad_receipt)" "$ep: the receipt"
      assert_eq 600 "$(ip_mode "$IP_STATE/generations/$(dt_newest_gen)/mullvad-dns.tsv")" "$ep: the receipt is 0600"
      sw="$(ip_first "$FAKE_LOG" '^mullvad dns set default$')"
      pre="$(ip_first "$FAKE_LOG" '^(sudo apt-get|podman (pull|build)|cosign) ')"
      pin="$(ip_first "$FAKE_LOG" '^sudo ([^ ]*/)?usr/bin/custom-dns-deb pin$')"
      set="$(ip_first "$FAKE_LOG" '^mullvad dns set custom 127\.0\.0\.1$')"
      assert_eq 1 "$((sw < pre))" "$ep: the switch (line $sw) precedes every network-using preparation call (line $pre):
$(cat -n "$FAKE_LOG")"
      assert_eq 1 "$((pin < set))" "$ep: custom 127.0.0.1 is set (line $set) after the pin (line $pin)"
      assert_eq "Custom DNS: yes Servers: 127.0.0.1" "$(dt_mullvad_now)" "$ep: Mullvad ends at custom 127.0.0.1"
      dt_pinned || fail "$ep: pinned at the end: $(dt_dns_state)"
    ) || exit 1
    (
      # Default DNS with content blocking before nice-dns, Mullvad connected
      # and slow to write custom 127.0.0.1 (two sleeps): no switch, the pin
      # check waits for Mullvad's write, and a reinstall carries the setting
      # from before nice-dns.
      dt_world "$ep" resolved
      dt_mullvad "default ads malware"
      : >"$FAKE/mullvad_connected"; echo 2 >"$FAKE/mullvad_settle"
      ip_install "$ep"
      assert_rc 0 "$IP_RC" "$ep: first install: $IP_OUT"
      assert_eq "$(printf 'mullvad dns get\nmullvad dns set custom 127.0.0.1')" "$(dt_mullvad_calls)" "$ep: no switch when Mullvad's DNS answers"
      assert_eq "$(dt_mv_rows 'before_install|default|ads|malware' 'before_nicedns|default|ads|malware')" \
        "$(dt_mullvad_receipt)" "$ep: the first receipt"
      dt_pinned || fail "$ep: pinned once Mullvad's write settled: $(dt_dns_state)"
      rm -f "$FAKE/mullvad_settle"
      : >"$FAKE_LOG"
      printf 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\n' >"$FAKE/git_head"
      # A stack slow through Tor fails the probe, but it runs: no switch.
      : >"$FAKE/dig_fail_probe"
      ip_install "$ep"
      assert_rc 0 "$IP_RC" "$ep: reinstall: $IP_OUT"
      assert_eq "$(printf 'mullvad dns get\nmullvad dns set custom 127.0.0.1')" "$(dt_mullvad_calls)" "$ep: the reinstall's calls (a stack runs: no switch)"
      assert_eq "$(dt_mv_rows 'before_install|custom|127.0.0.1' 'before_nicedns|default|ads|malware')" \
        "$(dt_mullvad_receipt)" "$ep: the reinstall carries the setting from before nice-dns"
    ) || exit 1
    (
      # The owner's own loopback resolver (a stub at 127.0.0.53) answers: no
      # switch, and it is the setting from before nice-dns.
      dt_world "$ep" resolved
      dt_mullvad "custom 127.0.0.53"; : >"$FAKE/stub_answers"
      ip_install "$ep"
      assert_rc 0 "$IP_RC" "$ep: install: $IP_OUT"
      assert_eq "$(printf 'mullvad dns get\nmullvad dns set custom 127.0.0.1')" "$(dt_mullvad_calls)" "$ep: the owner's answering stub is not switched"
      assert_eq "$(dt_mv_rows 'before_install|custom|127.0.0.53' 'before_nicedns|custom|127.0.0.53')" \
        "$(dt_mullvad_receipt)" "$ep: the receipt keeps the owner's resolver"
    ) || exit 1
  done
}

t_failed_activation_restores_the_recorded_mullvad_setting() {
  local ep
  for ep in $(dt_linux_eps); do
    (
      local dns0
      # Fails in the interruption, after the switch and before the pin.
      dt_world "$ep" resolved; dt_mullvad "custom 127.0.0.1"; dns0="$(dt_dns_state)"
      : >"$FAKE/never_ready"
      ip_install "$ep"
      assert_nonzero "$IP_RC" "$ep/never_ready: fails: $IP_OUT"
      assert_eq "$(printf 'mullvad dns get\nmullvad dns set default\nmullvad dns set custom 127.0.0.1')" "$(dt_mullvad_calls)" "$ep/never_ready: switched, then put back"
      assert_eq "Custom DNS: yes Servers: 127.0.0.1" "$(dt_mullvad_now)" "$ep/never_ready: Mullvad is as recorded"
      assert_eq "$dns0" "$(dt_dns_state)" "$ep/never_ready: host DNS as before"
    ) || exit 1
    local inj
    for inj in '^podman build ' 'sigint:^podman build ' 'sigint_group:^podman build ' '^mullvad dns set default$'; do
      (
        local dns0
        # Fails in preparation (a build, a Ctrl-C during a build, or the
        # switch itself): nothing is interrupted, and the setting goes back.
        dt_world "$ep" resolved; dt_mullvad "custom 127.0.0.1"; dns0="$(dt_dns_state)"
        case "$inj" in
          sigint:*) printf '%s\n' "${inj#sigint:}" >"$FAKE/sigint" ;;
          sigint_group:*) printf '%s\n' "${inj#sigint_group:}" >"$FAKE/sigint_group" ;;
          *) printf '%s\n' "$inj" >"$FAKE/fail" ;;
        esac
        ip_install "$ep"
        assert_nonzero "$IP_RC" "$ep/$inj: fails: $IP_OUT"
        rm -f "$FAKE/fail" "$FAKE/sigint" "$FAKE/sigint_group"
        assert_eq "$(printf 'mullvad dns get\nmullvad dns set default\nmullvad dns set custom 127.0.0.1')" "$(dt_mullvad_calls)" "$ep/$inj: switched (or tried to), then put back"
        assert_eq "Custom DNS: yes Servers: 127.0.0.1" "$(dt_mullvad_now)" "$ep/$inj: Mullvad is as recorded"
        assert_eq "$dns0" "$(dt_dns_state)" "$ep/$inj: host DNS as before"
        assert_eq "" "$(ip_lines "$FAKE_LOG" "$IP_DISRUPTIVE")" "$ep/$inj: nothing was interrupted"
      ) || exit 1
    done
    (
      local dns0 dep0
      # A reinstall whose `set custom 127.0.0.1` fails after the pin: the
      # rollback gives the previous deployment back and Mullvad the setting
      # this install found.
      dt_world "$ep" resolved; dt_mullvad "default ads"
      dt_installed "$ep"
      dns0="$(dt_dns_state)"; dep0="$(dt_deploy_state)"
      printf '%s\n' '^mullvad dns set custom 127\.0\.0\.1$' >"$FAKE/fail"
      ip_install "$ep"
      assert_nonzero "$IP_RC" "$ep/set: fails: $IP_OUT"
      rm -f "$FAKE/fail"
      assert_eq "$(printf 'mullvad dns get\nmullvad dns set custom 127.0.0.1\nmullvad dns set custom 127.0.0.1')" "$(dt_mullvad_calls)" "$ep/set: the failed set, then the recorded setting (custom 127.0.0.1) again"
      assert_eq "Custom DNS: yes Servers: 127.0.0.1" "$(dt_mullvad_now)" "$ep/set: Mullvad as this install found it"
      assert_eq "$dns0" "$(dt_dns_state)" "$ep/set: host DNS as before"
      assert_eq "$dep0" "$(dt_deploy_state)" "$ep/set: the previous deployment is back"
    ) || exit 1
    (
      local checks
      # Mullvad, connected, never writes custom 127.0.0.1 back: the pin check
      # gives up after ND_INST_PIN_SETTLE_TRIES (5) checks and rolls back.
      dt_world "$ep" resolved; dt_mullvad "default ads"
      : >"$FAKE/mullvad_connected"; echo 99 >"$FAKE/mullvad_settle"
      ip_install "$ep"
      assert_nonzero "$IP_RC" "$ep/settle: fails: $IP_OUT"
      assert_match 'not pinned after the pin' "$IP_OUT" "$ep/settle: and says why"
      checks="$(sed -n "$(ip_first "$FAKE_LOG" '^mullvad dns set custom 127\.0\.0\.1$'),\$p" "$FAKE_LOG" | grep -cE 'custom-dns-deb status$')"
      assert_eq 5 "$checks" "$ep/settle: five checks, then the rollback:
$(cat -n "$FAKE_LOG")"
      assert_eq "$(printf 'mullvad dns get\nmullvad dns set custom 127.0.0.1\nmullvad dns set default --block-ads')" "$(dt_mullvad_calls)" "$ep/settle: Mullvad gets the setting this install found"
    ) || exit 1
  done
}

t_uninstall_restores_the_recorded_mullvad_setting() {
  local ep
  for ep in $(dt_linux_eps); do
    (
      local dns0
      dt_world "$ep" resolved; dt_mullvad "default ads malware"; dns0="$(dt_dns_state)"
      dt_installed "$ep"
      ip_install "$ep"
      assert_rc 0 "$IP_RC" "$ep: reinstall: $IP_OUT"
      : >"$FAKE_LOG"
      ip_install "$ep" uninstall
      assert_rc 0 "$IP_RC" "$ep: uninstall: $IP_OUT"
      assert_eq "$(printf 'mullvad dns get\nmullvad dns set default --block-ads --block-malware')" "$(dt_mullvad_calls)" "$ep: the uninstall puts back the setting from before nice-dns"
      assert_eq "$dns0" "$(dt_dns_state)" "$ep: host DNS as before"
      assert_match "Mullvad's DNS setting is back to: default ads malware" "$IP_OUT" "$ep: and says so"
    ) || exit 1
    (
      # custom 127.0.0.1 found at the first install stands for Mullvad's
      # default: the uninstall never leaves Mullvad pointing at a removed stack.
      dt_world "$ep" resolved; dt_mullvad "custom 127.0.0.1"
      dt_installed "$ep"
      ip_install "$ep" uninstall
      assert_rc 0 "$IP_RC" "$ep/loopback: uninstall: $IP_OUT"
      assert_eq "$(printf 'mullvad dns get\nmullvad dns set default')" "$(dt_mullvad_calls)" "$ep/loopback: Mullvad's default"
    ) || exit 1
    (
      # The owner changed the setting since the install: left as it is.
      dt_world "$ep" resolved; dt_mullvad "default ads"
      dt_installed "$ep"
      dt_mullvad "default trackers"
      ip_install "$ep" uninstall
      assert_rc 0 "$IP_RC" "$ep/changed: uninstall: $IP_OUT"
      assert_eq "mullvad dns get" "$(dt_mullvad_calls)" "$ep/changed: no Mullvad change"
      assert_match 'changed since the install' "$IP_OUT" "$ep/changed: and says so"
    ) || exit 1
    (
      # An install from before records (no receipt) with Mullvad at custom
      # 127.0.0.1: Mullvad's default.
      dt_world "$ep" resolved
      dt_installed "$ep"
      dt_mullvad "custom 127.0.0.1"
      ip_install "$ep" uninstall
      assert_rc 0 "$IP_RC" "$ep/legacy: uninstall: $IP_OUT"
      assert_eq "$(printf 'mullvad dns get\nmullvad dns set default')" "$(dt_mullvad_calls)" "$ep/legacy: Mullvad's default"
    ) || exit 1
    (
      # The daemon is down: the uninstall says so and fails, keeping the
      # record for a retry.
      dt_world "$ep" resolved; dt_mullvad "default ads"
      dt_installed "$ep"
      : >"$FAKE/mullvad_unreadable"
      ip_install "$ep" uninstall
      assert_nonzero "$IP_RC" "$ep/daemon-down: the uninstall fails: $IP_OUT"
      assert_match 'mullvad-daemon' "$IP_OUT" "$ep/daemon-down: and says why"
      assert_eq "mullvad dns get" "$(dt_mullvad_calls)" "$ep/daemon-down: no change"
      assert_file "$IP_STATE/current" "$ep/daemon-down: the state is kept for a retry"
    ) || exit 1
  done
}

# Connected, Mullvad rewrites the pin when its setting changes: the
# ownership check refuses a reinstall then, and names Mullvad's way back.
t_mullvad_rewrite_refusal_names_the_way_back() {
  local ep
  for ep in $(dt_linux_eps); do
    (
      dt_world "$ep" resolved; dt_mullvad "default ads"
      dt_installed "$ep"
      : >"$FAKE/mullvad_connected"
      env FAKE_ROOT="$FAKE_ROOT" FAKE="$FAKE" FAKE_LOG="$FAKE_LOG" "$IP_BIN/mullvad" dns set default --block-ads >/dev/null
      : >"$FAKE_LOG"
      ip_install "$ep"
      assert_nonzero "$IP_RC" "$ep: refuses: $IP_OUT"
      assert_match "mullvad dns set custom 127.0.0.1" "$IP_OUT" "$ep: names Mullvad's way back"
      assert_eq "" "$(dt_mullvad_calls)" "$ep: no Mullvad call"
      ip_assert_untouched "$ep"
    ) || exit 1
  done
}

# Live 2026-11-05 (restart-policy Task 3.3): Ubuntu's and Mint's awk is mawk
# 1.3.4, which never matched an IPv4 server with ([0-9]{1,3}\.){3}: Mullvad's
# custom 127.0.0.1, the setting the install itself writes, read as unknown.
# The readers run under each awk the Linux hosts ship.
t_mullvad_readers_accept_an_ipv4_server_under_every_awk() {
  local impl d n=0 out
  for impl in mawk gawk "busybox awk"; do
    command -v "${impl%% *}" >/dev/null 2>&1 || continue
    [ "$impl" != "busybox awk" ] || busybox awk 'BEGIN { exit 0 }' 2>/dev/null || continue
    n=$((n + 1)); d="$CASE_DIR/awk-$n"; mkdir -p "$d"
    printf '#!/bin/sh\nexec %s "$@"\n' "$impl" >"$d/awk"
    printf '#!/bin/sh\nprintf "Custom DNS: yes\\nServers:\\n127.0.0.1\\nfe80::1\\n"\n' >"$d/mullvad"
    chmod +x "$d/awk" "$d/mullvad"
    printf 'schema\tnice-dns-mullvad-dns/1\nbefore_install\tcustom\t10.64.0.1\t::1\n' >"$d/rec.tsv"
    out="$(PATH="$d:$PATH" bash -c '. "$1/lib/install.sh" && _nd_inst_mullvad_read && _nd_inst_mullvad_record_get "$2" before_install' _ "$NICE_DNS_ROOT" "$d/rec.tsv" 2>&1)"
    assert_eq "$(printf 'custom 127.0.0.1 fe80::1\ncustom 10.64.0.1 ::1')" "$out" "$impl: both readers take IPv4 and IPv6 servers"
    out="$(PATH="$d:$PATH" bash -c '. "$1/lib/install.sh" && printf "schema\tnice-dns-mullvad-dns/1\nx\tcustom\t1.2.3.4.5\n" >"$2" && _nd_inst_mullvad_record_get "$2" x' _ "$NICE_DNS_ROOT" "$d/bad.tsv" 2>&1)"
    assert_nonzero $? "$impl: a five-part address is refused ($out)"
  done
  assert_ne 0 "$n" "at least one awk was tried"
}

t_no_mullvad_means_no_mullvad_calls() {
  local ep
  for ep in $(dt_linux_eps); do
    (
      dt_world "$ep" resolved
      ip_install "$ep"
      assert_rc 0 "$IP_RC" "$ep: install: $IP_OUT"
      : >"$FAKE/never_ready"
      ip_install "$ep"
      assert_nonzero "$IP_RC" "$ep: a failed reinstall: $IP_OUT"
      ip_install "$ep" uninstall
      assert_rc 0 "$IP_RC" "$ep: uninstall: $IP_OUT"
      assert_eq "" "$(dt_mullvad_calls)" "$ep: no Mullvad call"
      assert_eq "" "$(find "$IP_STATE" -name mullvad-dns.tsv)" "$ep: no Mullvad receipt"
    ) || exit 1
  done
}

t_unreadable_mullvad_setting_refuses_before_any_change() {
  local ep how
  for ep in $(dt_linux_eps); do
    for how in daemon-down malformed bad-server; do
      (
        local dns0
        dt_world "$ep" resolved; dt_mullvad "custom 127.0.0.1"; dns0="$(dt_dns_state)"
        case "$how" in
          daemon-down) : >"$FAKE/mullvad_unreadable" ;;
          malformed) printf 'Custom DNS: maybe\n' >"$FAKE/mullvad_dns" ;;
          bad-server) printf 'Custom DNS: yes\nServers:\nabc\n' >"$FAKE/mullvad_dns" ;;
        esac
        ip_install "$ep"
        assert_nonzero "$IP_RC" "$ep/$how: refuses: $IP_OUT"
        assert_match 'Mullvad' "$IP_OUT" "$ep/$how: and says why"
        assert_eq "mullvad dns get" "$(dt_mullvad_calls)" "$ep/$how: no Mullvad change"
        assert_eq "" "$(ip_lines "$FAKE_LOG" "$IP_BUILD_PULL")" "$ep/$how: no build or pull"
        assert_eq "" "$(ip_lines "$FAKE_LOG" '^sudo apt-get ')" "$ep/$how: no package change"
        ip_assert_untouched "$ep/$how"
        assert_eq "$dns0" "$(dt_dns_state)" "$ep/$how: host DNS unchanged"
      ) || exit 1
    done
  done
}

# ─────────────────────────── IPv6 per device (BL-050) ───────────────────────
#
# NetworkManager's activation of a profile with ipv6.method auto turns the
# device's disable_ipv6 back to 0 after systemd-sysctl set every switch to 1
# (measured 2026-10-12, Task 2.1). An owned dispatcher hook sets it to 1
# again on pre-up/up/reapply and never touches Mullvad's tunnel; a first
# install records each device's value from before nice-dns for the uninstall. The address family stays: no kernel
# ipv6.disable flag (the 2026-07-10 incident).

dt_dev() { cat "$FAKE_ROOT/proc/sys/net/ipv6/conf/$1/disable_ipv6"; }
dt_hook() { # <iface> <action>: the hook as NetworkManager runs it
  DT_OUT="$(env -i PATH="$IP_BIN" ND_DNS_TEST_ROOT="$FAKE_ROOT" bash "$IP_TREE/deb/91-nice-dns-ipv6" "$1" "$2" 2>&1)"
  DT_RC=$?
}
dt_ipv6_rec() { cat "$FAKE_ROOT/var/lib/nice-dns/dns-owned/ipv6-devices.tsv" 2>/dev/null; }

t_ipv6_hook_disables_the_activating_device() {
  local ep
  (
    local bad
    dt_world install-deb resolved
    dt_helper linux snapshot
    dt_hook enp1s0 up
    assert_rc 0 "$DT_RC" "up: $DT_OUT"
    assert_eq 1 "$(dt_dev enp1s0)" "up: the device's IPv6 is off"
    assert_eq "" "$(dt_ipv6_rec)" "up: NetworkManager's events never record (the value may be nice-dns's already)"
    for act in pre-up reapply; do
      printf '0\n' >"$FAKE_ROOT/proc/sys/net/ipv6/conf/enp1s0/disable_ipv6"
      dt_hook enp1s0 "$act"
      assert_eq 1 "$(dt_dev enp1s0)" "$act: off again"
    done
    printf '0\n' >"$FAKE_ROOT/proc/sys/net/ipv6/conf/enp1s0/disable_ipv6"
    dt_hook enp1s0 down
    assert_eq 0 "$(dt_dev enp1s0)" "down: nothing is written"
    dt_hook enp1s0 record
    assert_eq 0 "$(dt_dev enp1s0)" "record: the switch is not written"
    assert_eq "$(printf 'enp1s0\t0')" "$(dt_ipv6_rec)" "record: the value is recorded"
    assert_eq 600 "$(ip_mode "$FAKE_ROOT/var/lib/nice-dns/dns-owned/ipv6-devices.tsv")" "the record is 0600"
    printf '1\n' >"$FAKE_ROOT/proc/sys/net/ipv6/conf/enp1s0/disable_ipv6"
    dt_hook enp1s0 record
    assert_eq "$(printf 'enp1s0\t0')" "$(dt_ipv6_rec)" "record: the first value is kept"
    for bad in '../all' 'a/b' '' 'x;y'; do
      dt_hook "$bad" up
      assert_rc 0 "$DT_RC" "a bad name ($bad) is ignored"
    done
  ) || exit 1
  ip_select
  for ep in $IP_EPS; do
    [ "$(ip_platform "$ep")" = linux ] || continue
    (
      local before
      # A first install records each device, then turns the NIC's IPv6 off
      # and installs the hook; the uninstall gives every switch back.
      dt_world "$ep" resolved; before="$(dt_dns_state)"
      ip_install "$ep"
      assert_rc 0 "$IP_RC" "$ep: install: $IP_OUT"
      assert_eq 1 "$(dt_dev enp1s0)" "$ep: the NIC's IPv6 is off after the install"
      assert_eq "$(printf 'enp1s0\t0')" "$(dt_ipv6_rec)" "$ep: its value from before nice-dns is recorded"
      assert_file "$FAKE_ROOT/etc/NetworkManager/dispatcher.d/91-nice-dns-ipv6" "$ep: the hook"
      assert_file "$FAKE_ROOT/etc/NetworkManager/dispatcher.d/pre-up.d/91-nice-dns-ipv6" "$ep: its pre-up copy"
      assert_eq 755 "$(ip_mode "$FAKE_ROOT/etc/NetworkManager/dispatcher.d/91-nice-dns-ipv6")" "$ep: executable"
      # A reinstall keeps the record; NetworkManager turned the NIC on again.
      printf '0\n' >"$FAKE_ROOT/proc/sys/net/ipv6/conf/enp1s0/disable_ipv6"
      printf 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\n' >"$FAKE/git_head"
      ip_install "$ep"
      assert_rc 0 "$IP_RC" "$ep: reinstall: $IP_OUT"
      assert_eq 1 "$(dt_dev enp1s0)" "$ep: off after the reinstall"
      assert_eq "$(printf 'enp1s0\t0')" "$(dt_ipv6_rec)" "$ep: the record is the first one"
      ip_install "$ep" uninstall
      assert_rc 0 "$IP_RC" "$ep: uninstall: $IP_OUT"
      assert_eq "$before" "$(dt_dns_state)" "$ep: the uninstall gives every switch and file back"
    ) || exit 1
    (
      local before
      # An install from before this change: its switches are in force and it
      # recorded no device. The reinstall records nothing (the value it would
      # read is nice-dns's), and the uninstall's all=0 gives the NIC back.
      dt_world "$ep" resolved; before="$(dt_dns_state)"
      ip_install "$ep"
      assert_rc 0 "$IP_RC" "$ep/upgrade: install: $IP_OUT"
      rm -f "$FAKE_ROOT/var/lib/nice-dns/dns-owned/ipv6-devices.tsv"
      printf 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\n' >"$FAKE/git_head"
      ip_install "$ep"
      assert_rc 0 "$IP_RC" "$ep/upgrade: reinstall: $IP_OUT"
      assert_eq "" "$(dt_ipv6_rec)" "$ep/upgrade: nothing is recorded over switches already in force"
      ip_install "$ep" uninstall
      assert_rc 0 "$IP_RC" "$ep/upgrade: uninstall: $IP_OUT"
      assert_eq "$before" "$(dt_dns_state)" "$ep/upgrade: every switch is back"
    ) || exit 1
  done
}

t_ipv6_hook_ignores_the_mullvad_tunnel() {
  (
    dt_world install-deb resolved
    dt_helper linux snapshot
    dt_hook wg0-mullvad up
    assert_rc 0 "$DT_RC" "$DT_OUT"
    assert_eq 0 "$(dt_dev wg0-mullvad)" "Mullvad's tunnel is never written"
    assert_eq "" "$(dt_ipv6_rec)" "nor recorded"
  ) || exit 1
  (
    local before
    # The record step never takes the tunnel either. (Writing
    # net.ipv6.conf.all=1, as the install always has, sets every existing
    # device, the tunnel too, like its default=1; Mullvad runs so, measured
    # 2026-10-12. The uninstall's all=0 gives it back.)
    dt_world install-deb resolved; before="$(dt_dns_state)"
    dt_mullvad "custom 127.0.0.1"
    ip_install install-deb
    assert_rc 0 "$IP_RC" "install: $IP_OUT"
    assert_not_match 'wg0-mullvad' "$(dt_ipv6_rec)" "no record row for Mullvad's tunnel"
    ip_install install-deb uninstall
    assert_rc 0 "$IP_RC" "uninstall: $IP_OUT"
    assert_eq "$before" "$(dt_dns_state)" "every switch, the tunnel's too, is back"
  ) || exit 1
  (
    # A record written twice (overlapping pre-up and up) restores the first.
    dt_world install-deb resolved
    dt_helper linux snapshot
    printf 'enp1s0\t0\nenp1s0\t1\n' >"$FAKE_ROOT/var/lib/nice-dns/dns-owned/ipv6-devices.tsv"
    printf '1\n' >"$FAKE_ROOT/proc/sys/net/ipv6/conf/enp1s0/disable_ipv6"
    dt_helper linux pin
    dt_helper linux restore
    assert_rc 0 "$DT_RC" "restore: $DT_OUT"
    assert_eq 0 "$(dt_dev enp1s0)" "the first recorded value wins"
  ) || exit 1
}

# The hook leaves a window: NetworkManager sends pre-up only after it set up
# IP, so the NIC sent MLD and a duplicate-address check from :: at every
# activation (Stage 3 gate capture, 2026-10-12: 5 frames over a boot, a
# `nmcli connection up` and a NetworkManager restart). So an install also sets
# ipv6.method disabled on each Ethernet and Wi-Fi profile stored on disk
# (keyfile or netplan), recording the method it found once; the uninstall puts
# back each one still disabled (user decision 2026-10-12, DEC-020 amended).
# Other types (Mullvad's WireGuard, VPNs, bridges, loopback, which nmcli
# refuses) and NetworkManager's in-memory external profiles are left alone.
dt_nm_v6() { # <uuid> <type> <method> <device> [file]
  dt_nm_profile "$1" '' no "$4"
  printf '%s\n' "$2" >"$FAKE_ROOT/.nm/$1/type"; printf '%s\n' "$3" >"$FAKE_ROOT/.nm/$1/ipv6"
  [ -z "${5:-}" ] || printf '%s\n' "$5" >"$FAKE_ROOT/.nm/$1/file"
}
dt_nm_v6_state() { local p; for p in "$FAKE_ROOT"/.nm/*; do printf '%s %s\n' "${p##*/}" "$(cat "$p/ipv6" 2>/dev/null || echo auto)"; done; }
dt_nm_v6_world() {
  dt_nm_v6 eth-1 802-3-ethernet auto enp1s0
  dt_nm_v6 wifi-2 802-11-wireless dhcp wlp1 /run/NetworkManager/system-connections/netplan-NM-wifi-2-Home.nmconnection
  dt_nm_v6 lo-3 loopback auto lo /run/NetworkManager/system-connections/lo.nmconnection
  dt_nm_v6 wg-4 wireguard auto wg0-mullvad /run/NetworkManager/system-connections/wg0-mullvad.nmconnection
  dt_nm_v6 ext-5 802-3-ethernet auto enp2s0 /run/NetworkManager/system-connections/enp2s0.nmconnection
  dt_nm_v6 ign-6 802-3-ethernet ignore enp3s0
  dt_nm_v6 vpn-7 vpn auto tun0
}
dt_ipv6_prof_rec() { cat "$FAKE_ROOT/var/lib/nice-dns/dns-owned/ipv6-profiles.tsv" 2>/dev/null; }

t_ipv6_profiles_are_disabled_and_given_back() {
  local ep
  ip_select
  for ep in $IP_EPS; do
    [ "$(ip_platform "$ep")" = linux ] || continue
    (
      local before
      dt_world "$ep" resolved; dt_nm_v6_world; before="$(dt_dns_state)"
      ip_install "$ep"
      assert_rc 0 "$IP_RC" "$ep: install: $IP_OUT"
      assert_eq "$(printf 'eth-1 disabled\next-5 auto\nign-6 ignore\nlo-3 auto\nvpn-7 auto\nwg-4 auto\nwifi-2 disabled')" "$(dt_nm_v6_state)" \
        "$ep: the Ethernet and Wi-Fi profiles on disk lose IPv6; external, ignore, loopback, VPN and Mullvad's are untouched"
      assert_eq "$(printf 'eth-1\tauto\nwifi-2\tdhcp')" "$(dt_ipv6_prof_rec)" "$ep: the methods they had are recorded"
      assert_eq 600 "$(ip_mode "$FAKE_ROOT/var/lib/nice-dns/dns-owned/ipv6-profiles.tsv")" "$ep: the record is 0600"
      assert_match '^nmcli dev reapply enp1s0$' "$(cat "$FAKE_LOG")" "$ep: the changed profile is reapplied on its device"
      assert_not_match 'nmcli con mod (lo-3|wg-4|ext-5|ign-6|vpn-7) ' "$(cat "$FAKE_LOG")" "$ep: no other profile is modified"
      # A reinstall: the owner turned eth-1 back to auto; it is disabled
      # again, and the record keeps the first method.
      printf 'auto\n' >"$FAKE_ROOT/.nm/eth-1/ipv6"
      printf 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\n' >"$FAKE/git_head"
      ip_install "$ep"
      assert_rc 0 "$IP_RC" "$ep: reinstall: $IP_OUT"
      assert_eq disabled "$(cat "$FAKE_ROOT/.nm/eth-1/ipv6")" "$ep: disabled again"
      assert_eq "$(printf 'eth-1\tauto\nwifi-2\tdhcp')" "$(dt_ipv6_prof_rec)" "$ep: the record is the first one"
      ip_install "$ep" uninstall
      assert_rc 0 "$IP_RC" "$ep: uninstall: $IP_OUT"
      assert_eq "$before" "$(dt_dns_state)" "$ep: every profile, switch and file is back"
      assert_eq "" "$(dt_ipv6_prof_rec)" "$ep: the record is gone"
    ) || exit 1
    (
      # A profile another owner changed since is left as it is; a profile
      # whose change failed is left as it was, and the install still works
      # (the hook remains the fallback).
      dt_world "$ep" resolved; dt_nm_v6_world
      printf '%s\n' '^nmcli con mod wifi-2 ipv6\.method disabled$' >"$FAKE/fail"
      ip_install "$ep"
      rm -f "$FAKE/fail"
      assert_rc 0 "$IP_RC" "$ep/changed: install: $IP_OUT"
      assert_eq dhcp "$(cat "$FAKE_ROOT/.nm/wifi-2/ipv6")" "$ep/changed: the failed profile keeps its method"
      assert_match 'could not set ipv6\.method disabled in NetworkManager profile wifi-2' "$IP_OUT" "$ep/changed: and the install says which"
      printf 'manual\n' >"$FAKE_ROOT/.nm/eth-1/ipv6"
      ip_install "$ep" uninstall
      assert_rc 0 "$IP_RC" "$ep/changed: uninstall: $IP_OUT"
      assert_eq manual "$(cat "$FAKE_ROOT/.nm/eth-1/ipv6")" "$ep/changed: a method changed since is left alone"
      assert_eq dhcp "$(cat "$FAKE_ROOT/.nm/wifi-2/ipv6")" "$ep/changed: the unchanged one too"
      assert_match 'eth-1.*changed since' "$IP_OUT" "$ep/changed: and the uninstall says so"
      assert_not_match 'wifi-2.*changed since' "$IP_OUT" "$ep/changed: a profile whose change failed is not reported as changed"
    ) || exit 1
    (
      # The owner sets another method after the install; a reinstall
      # records it, so the uninstall gives back the owner's latest setting.
      dt_world "$ep" resolved; dt_nm_v6_world
      ip_install "$ep"
      assert_rc 0 "$IP_RC" "$ep/owner: install: $IP_OUT"
      printf 'manual\n' >"$FAKE_ROOT/.nm/wifi-2/ipv6"
      printf 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\n' >"$FAKE/git_head"
      ip_install "$ep"
      assert_rc 0 "$IP_RC" "$ep/owner: reinstall: $IP_OUT"
      assert_eq disabled "$(cat "$FAKE_ROOT/.nm/wifi-2/ipv6")" "$ep/owner: disabled again"
      assert_eq "$(printf 'eth-1\tauto\nwifi-2\tmanual')" "$(dt_ipv6_prof_rec)" "$ep/owner: the record holds the owner's new method"
      ip_install "$ep" uninstall
      assert_rc 0 "$IP_RC" "$ep/owner: uninstall: $IP_OUT"
      assert_eq manual "$(cat "$FAKE_ROOT/.nm/wifi-2/ipv6")" "$ep/owner: the owner's method is back"
    ) || exit 1
    (
      # NetworkManager does not answer at the uninstall: the profile is not
      # skipped in silence; the restore fails and keeps the record, and a
      # retry gives it back. A profile that is gone needs nothing.
      dt_world "$ep" resolved; dt_nm_v6_world
      ip_install "$ep"
      assert_rc 0 "$IP_RC" "$ep/nm-down: install: $IP_OUT"
      printf '%s\n' '^nmcli -g ipv6\.method con show eth-1$' >"$FAKE/fail"
      ip_install "$ep" uninstall
      rm -f "$FAKE/fail"
      assert_nonzero "$IP_RC" "$ep/nm-down: the uninstall fails: $IP_OUT"
      assert_match 'could not read NetworkManager profile eth-1' "$IP_OUT" "$ep/nm-down: and names the profile"
      assert_eq "$(printf 'eth-1\tauto\nwifi-2\tdhcp')" "$(dt_ipv6_prof_rec)" "$ep/nm-down: the record is kept"
      rm -rf "$FAKE_ROOT/.nm/wifi-2"
      ip_install "$ep" uninstall
      assert_rc 0 "$IP_RC" "$ep/nm-down: the retry: $IP_OUT"
      assert_eq auto "$(cat "$FAKE_ROOT/.nm/eth-1/ipv6")" "$ep/nm-down: the profile is given back"
      assert_match 'wifi-2 no longer exists' "$IP_OUT" "$ep/nm-down: a profile that is gone is named, not an error"
      assert_eq "" "$(dt_ipv6_prof_rec)" "$ep/nm-down: the record is gone"
    ) || exit 1
    (
      local rec0
      # A reinstall over a deployment from before this change (profiles as
      # the owner set them, no profile record) fails after the pin: the
      # rollback gives back what its profile step changed, and the record is
      # what it was.
      dt_world "$ep" resolved; dt_nm_v6_world
      ip_install "$ep"
      assert_rc 0 "$IP_RC" "$ep/re-rollback: install: $IP_OUT"
      printf 'auto\n' >"$FAKE_ROOT/.nm/eth-1/ipv6"; printf 'dhcp\n' >"$FAKE_ROOT/.nm/wifi-2/ipv6"
      rm -f "$FAKE_ROOT/var/lib/nice-dns/dns-owned/ipv6-profiles.tsv"
      dt_mullvad "default"
      printf 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\n' >"$FAKE/git_head"
      printf '%s\n' '^mullvad dns set custom 127\.0\.0\.1$' >"$FAKE/fail"
      ip_install "$ep"
      rm -f "$FAKE/fail"
      assert_nonzero "$IP_RC" "$ep/re-rollback: fails: $IP_OUT"
      assert_eq "$(printf 'eth-1 auto\next-5 auto\nign-6 ignore\nlo-3 auto\nvpn-7 auto\nwg-4 auto\nwifi-2 dhcp')" "$(dt_nm_v6_state)" "$ep/re-rollback: every profile as the previous deployment had it"
      assert_eq "" "$(dt_ipv6_prof_rec)" "$ep/re-rollback: and no profile record"
      # A reinstall over this change's own deployment rolls back to it: the
      # profiles it had disabled stay disabled, its record as it was.
      ip_install "$ep"
      assert_rc 0 "$IP_RC" "$ep/re-rollback: reinstall: $IP_OUT"
      rec0="$(dt_ipv6_prof_rec)"
      dt_mullvad "default"
      printf 'cccccccccccccccccccccccccccccccccccccccc\n' >"$FAKE/git_head"
      printf '%s\n' '^mullvad dns set custom 127\.0\.0\.1$' >"$FAKE/fail"
      ip_install "$ep"
      rm -f "$FAKE/fail"
      assert_nonzero "$IP_RC" "$ep/re-rollback 2: fails: $IP_OUT"
      assert_eq disabled "$(cat "$FAKE_ROOT/.nm/eth-1/ipv6")" "$ep/re-rollback 2: the previous deployment's disabled profile stays so"
      assert_eq "$rec0" "$(dt_ipv6_prof_rec)" "$ep/re-rollback 2: and its record is kept"
    ) || exit 1
    (
      # A first install that fails after the pin gives the profiles back.
      dt_world "$ep" resolved; dt_nm_v6_world; dt_mullvad "default"
      printf '%s\n' '^mullvad dns set custom 127\.0\.0\.1$' >"$FAKE/fail"
      ip_install "$ep"
      rm -f "$FAKE/fail"
      assert_nonzero "$IP_RC" "$ep/rollback: fails: $IP_OUT"
      assert_eq "$(printf 'eth-1 auto\next-5 auto\nign-6 ignore\nlo-3 auto\nvpn-7 auto\nwg-4 auto\nwifi-2 dhcp')" "$(dt_nm_v6_state)" "$ep/rollback: every profile as it was"
    ) || exit 1
  done
  (
    # nmcli -t escapes ':' in a file name as '\:'; a profile listed after
    # the last candidate is not one (the loop must still end well).
    dt_world install-deb resolved
    dt_nm_v6 odd-8 802-3-ethernet auto enp8s0 '/etc/NetworkManager/system-connections/a\:b.nmconnection'
    dt_nm_v6 zz-9 vpn auto tun9
    dt_helper linux snapshot
    dt_helper linux ipv6-profiles
    assert_rc 0 "$DT_RC" "escaped name: $DT_OUT"
    assert_eq "$(printf 'odd-8 disabled\nzz-9 auto')" "$(dt_nm_v6_state)" "escaped name: the profile on disk is changed, the VPN after it is not"
  ) || exit 1
  (
    # The undo cannot read a profile it changed (NetworkManager not
    # answering): it fails and keeps its list and the record; a retry works.
    dt_world install-deb resolved; dt_nm_v6_world
    dt_helper linux snapshot
    dt_helper linux ipv6-profiles
    assert_eq disabled "$(cat "$FAKE_ROOT/.nm/eth-1/ipv6")" "undo: eth-1 was disabled by the run"
    printf '%s\n' '^nmcli -g ipv6\.method con show eth-1$' >"$FAKE/fail"
    dt_helper linux ipv6-profiles-undo
    rm -f "$FAKE/fail"
    assert_nonzero "$DT_RC" "undo: fails: $DT_OUT"
    assert_match 'could not read NetworkManager profile eth-1' "$DT_OUT" "undo: and names the profile"
    assert_eq disabled "$(cat "$FAKE_ROOT/.nm/eth-1/ipv6")" "undo: eth-1 is not given up on"
    assert_file "$FAKE_ROOT/var/lib/nice-dns/dns-owned/ipv6-profiles.run" "undo: the run's list is kept"
    dt_helper linux ipv6-profiles-undo
    assert_rc 0 "$DT_RC" "undo retry: $DT_OUT"
    assert_eq "$(printf 'eth-1 auto\next-5 auto\nign-6 ignore\nlo-3 auto\nvpn-7 auto\nwg-4 auto\nwifi-2 dhcp')" "$(dt_nm_v6_state)" "undo retry: every profile as before the run"
    assert_eq "" "$(dt_ipv6_prof_rec)" "undo retry: and no profile record"
  ) || exit 1
  (
    # A profile id with a leading '-' would read as an nmcli option: skipped.
    dt_world install-deb resolved
    dt_nm_v6 -x 802-3-ethernet auto enp9s0
    dt_helper linux snapshot
    dt_helper linux ipv6-profiles
    assert_rc 0 "$DT_RC" "leading dash: $DT_OUT"
    assert_not_match 'nmcli con mod -x' "$(cat "$FAKE_LOG")" "leading dash: not modified"
  ) || exit 1
  (
    # Without the record (no snapshot), the helper changes no profile.
    dt_world install-deb resolved; dt_nm_v6_world
    dt_helper linux ipv6-profiles
    assert_rc 0 "$DT_RC" "no record: $DT_OUT"
    assert_eq auto "$(cat "$FAKE_ROOT/.nm/eth-1/ipv6")" "no record: nothing is changed"
  ) || exit 1
}

t_ipv6_profiles_stale_undo_list_is_never_used() {
  local ep
  ip_select
  for ep in $IP_EPS; do
    [ "$(ip_platform "$ep")" = linux ] || continue
    (
      # NetworkManager does not answer at a reinstall's profile step, and the
      # reinstall then fails: the rollback must not undo the earlier
      # install's change from its leftover list (round-2 redesign review).
      dt_world "$ep" resolved; dt_nm_v6_world
      ip_install "$ep"
      assert_rc 0 "$IP_RC" "$ep/stale: install: $IP_OUT"
      dt_mullvad "default"
      printf 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\n' >"$FAKE/git_head"
      printf '%s\n' '^nmcli -t -f UUID con show$' '^mullvad dns set custom 127\.0\.0\.1$' >"$FAKE/fail"
      ip_install "$ep"
      rm -f "$FAKE/fail"
      assert_nonzero "$IP_RC" "$ep/stale: the reinstall fails: $IP_OUT"
      assert_eq disabled "$(cat "$FAKE_ROOT/.nm/eth-1/ipv6")" "$ep/stale: the earlier install's change stays"
      assert_eq "$(printf 'eth-1\tauto\nwifi-2\tdhcp')" "$(dt_ipv6_prof_rec)" "$ep/stale: and its record"
      ip_install "$ep"
      assert_rc 0 "$IP_RC" "$ep/stale: reinstall: $IP_OUT"
      assert_eq "no no" "$([ -e "$FAKE_ROOT/var/lib/nice-dns/dns-owned/ipv6-profiles.run" ] && echo yes || echo no) $([ -e "$FAKE_ROOT/var/lib/nice-dns/dns-owned/ipv6-profiles.prev" ] && echo yes || echo no)" "$ep/stale: a successful install leaves no undo list"
    ) || exit 1
  done
}

# A reinstall whose pin fails before the profile step (here at the boot-time
# service) rolls back without the profile undo: a list an earlier run left
# is never used (Stage 1 gate review, 2026-11-08: the undo flag is set at the
# profile step, after root-ops pin-setup, as before root-ops).
t_ipv6_profiles_early_pin_failure_never_undoes() {
  local ep
  ip_select
  for ep in $IP_EPS; do
    [ "$(ip_platform "$ep")" = linux ] || continue
    (
      dt_world "$ep" resolved; dt_nm_v6_world
      ip_install "$ep"
      assert_rc 0 "$IP_RC" "$ep/early: install: $IP_OUT"
      printf 'eth-1\tauto\n' >"$FAKE_ROOT/var/lib/nice-dns/dns-owned/ipv6-profiles.run"
      printf 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\n' >"$FAKE/git_head"
      : >"$FAKE_LOG"
      printf '%s\n' '^sudo systemctl enable custom-dns-deb\.service$' >"$FAKE/fail"
      ip_install "$ep"
      rm -f "$FAKE/fail"
      assert_nonzero "$IP_RC" "$ep/early: the reinstall fails at the pin: $IP_OUT"
      assert_eq "" "$(grep -E 'profiles-undo|ipv6-profiles-undo' "$FAKE_LOG")" "$ep/early: the rollback runs no profile undo"
      assert_eq disabled "$(cat "$FAKE_ROOT/.nm/eth-1/ipv6")" "$ep/early: the earlier install's change stays"
    ) || exit 1
  done
}

t_ipv6_profiles_uninstall_completes_without_nmcli() {
  local ep
  ip_select
  for ep in $IP_EPS; do
    [ "$(ip_platform "$ep")" = linux ] || continue
    (
      # NetworkManager removed after the install: no profile can exist, so
      # the uninstall completes and names what it could not give back.
      dt_world "$ep" resolved; dt_nm_v6_world
      ip_install "$ep"
      assert_rc 0 "$IP_RC" "$ep/no-nm: install: $IP_OUT"
      printf '\n' >>"$FAKE_ROOT/var/lib/nice-dns/dns-owned/ipv6-profiles.tsv"
      rm -f "$IP_BIN/nmcli"
      ip_install "$ep" uninstall
      assert_rc 0 "$IP_RC" "$ep/no-nm: the uninstall completes: $IP_OUT"
      assert_match 'nmcli is missing.*eth-1' "$IP_OUT" "$ep/no-nm: and names the profiles"
      assert_not_match 'malformed' "$IP_OUT" "$ep/no-nm: a blank row is not malformed"
      assert_eq "" "$(dt_ipv6_prof_rec)" "$ep/no-nm: the record is gone"
    ) || exit 1
  done
}

# ipv6.disable=1 on the kernel command line removes AF_INET6, and Mullvad's
# userspace WireGuard then cannot bind and blocks the host on every boot
# (incident 2026-07-10). No install path may write it; comments may name it.
t_no_install_path_writes_a_kernel_ipv6_flag() {
  local hits
  hits="$(cd "$NICE_DNS_ROOT" && grep -rnE 'ipv6\.disable' lib deb install-*.sh | grep -vE '^[^:]+:[0-9]+:[[:space:]]*#' || true)"
  assert_eq "" "$hits" "no install code writes ipv6.disable"
}
