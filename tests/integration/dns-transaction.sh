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
