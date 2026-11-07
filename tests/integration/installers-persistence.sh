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
      assert_match "^ExecCondition=/usr/bin/sh -c '! grep -qx \"TOR_BRIDGES=off\" %h/\\.config/nice-dns/bridges-mode\\.env 2>/dev/null \\|\\| exit 2; n=\\\$\\\$\\(grep -cE \"\\^BRIDGE\\[0-9\\]\\+=obfs4 \" %h/\\.config/nice-dns/bridges\\.env 2>/dev/null\\); \\[ \"\\\$\\\$\\{n:-0\\}\" -lt 3 \\] \\|\\| exit 2'\$" "$(cat "$unit")" "$v: ExecCondition keeps its escaping and skips with exit 2"
      assert_match "docker\\.io/sureserver/tor-$v:latest" "$(cat "$unit")" "$v: the bridge unit runs this proxy's image"
      assert_match '^ExecStart=/usr/bin/podman run --rm --user 0:0 ' "$(cat "$unit")" "$v: the bridge unit runs bridge-eval as the container's root"
      assert_eq "" "$(grep -v '^#' "$unit" | grep -- '--userns=keep-id')" "$v: the bridge unit does not use keep-id (podman 5.8 exit 125)"
      assert_match '^ExecStart=/usr/bin/nm-online -q$' "$(cat "$FAKE_ROOT/etc/systemd/system/NetworkManager-wait-online.service.d/10-wait-for-connectivity.conf")" "$v: the wait-online drop-in"
      assert_file "$IP_HOME/.local/share/nice-dns-health/install.tsv" "$v: the real controller installed"
      pod="$(ip_first "$FAKE_LOG" '^systemctl --user restart nice-dns-pod\.service$')"
      tmr="$(ip_first "$FAKE_LOG" '^systemctl --user enable --now nice-dns-health\.timer$')"
      assert_ne "" "$pod" "$v: the pod is started"; assert_ne "" "$tmr" "$v: the controller's timer is started"
      # podman's --env-file needs bridges.env; with bridges off the selection
      # is skipped, so a host with no set still starts its proxy (direct).
      assert_file "$IP_HOME/.config/nice-dns/bridges.env" "$v: the proxy's env file exists when no set was selected"
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

# One restart owner, back-off on crash (DEC-021, WF-DNS-002). On 2026-11-02 a
# VM out of memory aborted haproxy and its unit restarted every 3 s for 20
# hours: StartLimitBurst never trips at that cadence. Every unit backs off
# (RestartSteps=/RestartMaxDelaySec=, systemd 254), and Pi-hole, like the
# others, never restarts on health: the controller does. Checked on the
# units Podman's own generator writes.
t_quadlets_back_off_and_only_the_controller_restarts_on_health() {
  local q gen out u unit
  for gen in /usr/libexec/podman/quadlet /usr/lib/podman/quadlet; do [ -x "$gen" ] && break; done
  [ -x "$gen" ] || fail "no quadlet generator on this host"
  q="$CASE_DIR/quadlet"; mkdir -p "$q"
  cp "$NICE_DNS_ROOT"/deb/quadlet/{nice-dns.network,nice-dns.pod,unbound.container,pi-hole.container,tor-haproxy.container,tor-socat.container} "$q/"
  sed -i -e 's/__VARIANT__/haproxy/g' -e "s|__ROUTE_DIR__|$CASE_DIR/route|g" -e "s|__HEALTH_ROOT__|$CASE_DIR/health|g" "$q/unbound.container"
  out="$(QUADLET_UNIT_DIRS="$q" "$gen" -dryrun -user 2>/dev/null)" || fail "the quadlet generator rejects the units"
  for u in pi-hole unbound tor-haproxy tor-socat; do
    unit="$(printf '%s\n' "$out" | awk -v s="---$u.service---" '$0 == s { p = 1; next } /^---.*---$/ { p = 0 } p' | sed 's/\\x20/ /g')"
    assert_match '^ExecStart=' "$unit" "$u: the generator writes $u.service"
    assert_match '^RestartSteps=5$' "$unit" "$u: a crash loop backs off in 5 steps"
    assert_match '^RestartMaxDelaySec=300s$' "$unit" "$u: up to 5 minutes between restarts"
    assert_match '^RestartSec=3s$' "$unit" "$u: from a non-zero first delay (the back-off needs it)"
    assert_match '^ExecStart=.*--health-on-failure[= ]none' "$unit" "$u: its health check only reports"
    assert_not_match '^ExecStart=.*--health-on-failure[= ]restart' "$unit" "$u: it never restarts on health (the controller owns that)"
  done
}

# Sub-plan 4 Task 1.2 (OD-6): the proxy units read the optional mode file
# through systemd ([Service] EnvironmentFile=-, a missing file is ignored) and
# pass TOR_BRIDGES into the container (--env TOR_BRIDGES; unset stays unset,
# the image defaults to on). A [Container] EnvironmentFile= is podman's
# --env-file: it takes no `-` and would refuse to start on a missing file.
t_proxy_units_read_the_optional_bridges_mode() {
  local q gen out u unit
  for gen in /usr/libexec/podman/quadlet /usr/lib/podman/quadlet; do [ -x "$gen" ] && break; done
  [ -x "$gen" ] || fail "no quadlet generator on this host"
  q="$CASE_DIR/quadlet-mode"; mkdir -p "$q"
  cp "$NICE_DNS_ROOT"/deb/quadlet/{nice-dns.network,nice-dns.pod,tor-haproxy.container,tor-socat.container} "$q/"
  out="$(QUADLET_UNIT_DIRS="$q" "$gen" -dryrun -user 2>/dev/null)" || fail "the quadlet generator rejects the units"
  for u in tor-haproxy tor-socat; do
    unit="$(printf '%s\n' "$out" | awk -v s="---$u.service---" '$0 == s { p = 1; next } /^---.*---$/ { p = 0 } p' | sed 's/\\x20/ /g')"
    assert_match '^ExecStart=.* --env-file %h/\.config/nice-dns/bridges\.env ' "$unit" "$u: the bridge pool is the container's env file"
    assert_match '^ExecStart=.* --env TOR_BRIDGES ' "$unit" "$u: the mode passes into the container"
    assert_match '^EnvironmentFile=-%h/\.config/nice-dns/bridges-mode\.env$' "$unit" "$u: systemd reads the optional mode file"
    assert_not_match '^ExecStart=.*--env-file [^ ]*bridges-mode' "$unit" "$u: the mode file is never a required podman env file"
  done
}
