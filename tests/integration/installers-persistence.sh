# shellcheck shell=bash
# Group integration/installers-persistence (Sub-plan 4, Stage 1 gate round 1).
#
# Sourced by tests/run.sh (assert_* helpers; NICE_DNS_ROOT, CASE_DIR). The
# other installer groups stub deb/persistent-podman.sh and mac/persist.sh;
# here their real bodies run, against the installer fixture's PATH stubs and
# a private HOME (tests/fixtures/install-fakes.sh), with the real controller
# CLI behind them. What they generate is checked: the quadlets and the bridge
# unit (systemd specifier escaping), the NetworkManager wait-online drop-in,
# the sudoers rule and the LaunchAgent plist (templating), and the order the
# macOS agent is loaded in. Nothing touches the host.

. "$NICE_DNS_ROOT/tests/fixtures/install-fakes.sh"

# ps_tree <dir>: a copy of the real checkout (persistence scripts included).
ps_tree() {
  local d="$1" f
  mkdir -p "$d"
  for f in deb mac scripts health lib routes; do cp -R "$NICE_DNS_ROOT/$f" "$d/"; done
}

t_real_persistent_podman_renders_its_units() {
  local v
  for v in haproxy socat; do
    (
      local q u unit pod tmr out rc
      dt_world install-deb resolved
      ps_tree "$IP_W/real"
      mkdir -p "$IP_W/run/systemd/generator" && : >"$IP_W/run/systemd/generator/nice-dns-pod.service"
      : >"$FAKE_ROOT/.systemd/NetworkManager-wait-online.unit"
      ip_run "$IP_W/real/deb/persistent-podman.sh" "$v"
      assert_rc 0 "$IP_RC" "persistent-podman.sh $v: $IP_OUT"
      q="$IP_HOME/.config/containers/systemd" u="$IP_HOME/.config/systemd/user"
      for f in nice-dns.network nice-dns.pod unbound.container pi-hole.container "tor-$v.container"; do
        assert_file "$q/$f" "$v: quadlet $f"
      done
      assert_no_path "$q/tor-$([ "$v" = haproxy ] && echo socat || echo haproxy).container" "$v: not the other proxy's"
      assert_eq "" "$(grep -n '__VARIANT__' "$q/unbound.container")" "$v: the variant is substituted"
      assert_match "^Wants=tor-$v\\.service$" "$(cat "$q/unbound.container")" "$v: unbound wants this proxy"
      unit="$u/nice-dns-fetch-bridges.service"
      assert_file "$unit" "$v: the bridge unit"
      # systemd sees $$ as a literal $ (systemd.service(5), Command lines).
      assert_match "^ExecCondition=/usr/bin/sh -c 'n=\\\$\\\$\\(grep -cE \"\\^BRIDGE\\[0-9\\]\\+=obfs4 \" %h/\\.config/nice-dns/bridges\\.env 2>/dev/null\\); \\[ \"\\\$\\\$\\{n:-0\\}\" -lt 3 \\] \\|\\| exit 2'\$" "$(cat "$unit")" "$v: ExecCondition keeps its escaping and skips with exit 2"
      assert_match "docker\\.io/sureserver/tor-$v:latest" "$(cat "$unit")" "$v: the bridge unit runs this proxy's image"
      assert_match '^ExecStart=/usr/bin/nm-online -q$' "$(cat "$FAKE_ROOT/etc/systemd/system/NetworkManager-wait-online.service.d/10-wait-for-connectivity.conf")" "$v: the wait-online drop-in"
      assert_file "$IP_HOME/.local/share/nice-dns-health/install.tsv" "$v: the real controller installed"
      pod="$(ip_first "$FAKE_LOG" '^systemctl --user restart nice-dns-pod\.service$')"
      tmr="$(ip_first "$FAKE_LOG" '^systemctl --user enable --now nice-dns-health\.timer$')"
      assert_ne "" "$pod" "$v: the pod is started"; assert_ne "" "$tmr" "$v: the controller's timer is started"
      assert_eq 1 "$((pod < tmr))" "$v: the pod (line $pod) starts before the controller's schedule (line $tmr)"
      if command -v systemd-analyze >/dev/null 2>&1; then
        mkdir -p "$IP_W/sa"; cp "$unit" "$IP_W/sa/"
        out="$(systemd-analyze verify --man=no "$IP_W/sa/nice-dns-fetch-bridges.service" 2>&1)"; rc=$?
        assert_rc 0 "$rc" "$v: systemd-analyze verify accepts the bridge unit: $out"
      fi
    ) || exit 1
  done
}

t_real_persist_templates_and_orders_the_agent() {
  (
    local sud plist load ctl
    dt_world install-mac fresh
    ps_tree "$IP_W/real"
    ip_run "$IP_W/real/mac/persist.sh" socat
    assert_rc 0 "$IP_RC" "persist.sh socat: $IP_OUT"
    sud="$FAKE/sudo-install_etc_sudoers.d_start-container"
    assert_file "$sud" "the sudoers rule is installed"
    assert_eq 'tester ALL=(root) NOPASSWD: /usr/local/sbin/start-container-root.sh pre, /usr/local/sbin/start-container-root.sh repair-dnsnet, /usr/local/sbin/start-container-root.sh post' \
      "$(grep -v '^#' "$sud" | grep -v '^[[:space:]]*$')" "the rule names this user and the three agent verbs only"
    assert_match '^sudo visudo -cf /etc/sudoers\.d/start-container$' "$(cat "$FAKE_LOG")" "it is checked with visudo"
    # A rule sudo cannot parse breaks sudo for everyone: it is checked
    # before it goes live.
    local pre inst
    pre="$(ip_first "$FAKE_LOG" '^sudo visudo -cf /.*tmp')"
    inst="$(ip_first "$FAKE_LOG" '^sudo install -m 440 .* /etc/sudoers\.d/start-container$')"
    assert_ne "" "$pre" "the temporary rule is checked with visudo"
    assert_ne "" "$inst" "the rule is installed"
    assert_eq 1 "$((${pre:-99999} < ${inst:-0}))" "visudo (line $pre) runs before the rule goes live (line $inst)"
    plist="$IP_HOME/Library/LaunchAgents/org.nice-dns.start-container.plist"
    assert_file "$plist" "the start-container agent"
    assert_eq "" "$(grep -nE '__USERNAME__|__VARIANT__' "$plist")" "the plist is fully templated"
    assert_match '<string>socat</string>' "$(cat "$plist")" "the variant reaches the agent"
    assert_match '/Users/tester|tester' "$(cat "$plist")" "the user reaches the agent"
    ctl="$(ip_first "$FAKE_LOG" '^launchctl load( -w)? .*org\.nice-dns\.health\.plist$')"
    load="$(ip_first "$FAKE_LOG" '^launchctl load .*org\.nice-dns\.start-container\.plist$')"
    assert_ne "" "$ctl" "the real controller installed its agent"
    assert_ne "" "$load" "the start-container agent is loaded"
    assert_eq 1 "$((ctl < load))" "the controller (line $ctl) before the pinning agent (line $load):
$(cat -n "$FAKE_LOG")"
  ) || exit 1
  (
    # The controller does not install: the pinning agent is never loaded.
    dt_world install-mac fresh
    ps_tree "$IP_W/real"
    printf 'exit 1\n' >"$IP_W/real/health/nice-dns-health"
    ip_run "$IP_W/real/mac/persist.sh" socat
    assert_nonzero "$IP_RC" "a failed controller install fails persist.sh: $IP_OUT"
    assert_eq "" "$(grep -E '^launchctl load .*org\.nice-dns\.start-container\.plist$' "$FAKE_LOG")" "and the agent that pins DNS is never loaded"
  ) || exit 1
  (
    # /usr/local/sbin is not root's: the passwordless rule would let this
    # user swap the root helper, so nothing is installed.
    dt_world install-mac fresh
    ps_tree "$IP_W/real"
    mkdir -p "$IP_W/unsafe/usr/local/sbin"
    ND_PERSIST_ROOT="$IP_W/unsafe" ip_run "$IP_W/real/mac/persist.sh" socat
    assert_nonzero "$IP_RC" "persist.sh refuses a /usr/local/sbin it does not trust: $IP_OUT"
    assert_match 'must be a directory owned by root' "$IP_OUT" "and says why"
    assert_eq "" "$(grep -E '^sudo ' "$FAKE_LOG")" "before any sudo: no sudoers rule, no helper"
  ) || exit 1
}
