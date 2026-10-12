# shellcheck shell=bash
# Group integration/controller-interaction (Sub-plan 3, Stage 1 gate; ARCH-02,
# ARCH-03, ARCH-04, ARCH-07). Interactions across the Stage 1 outputs: the
# real lib/health.sh observations feed lib/policy.sh through
# nd_recovery_tick, whose actions go through lib/recovery.sh and whose state
# goes through lib/state.sh. Only the outside world is faked
# (tests/fixtures/health-fakes.sh: dig, the runtime CLI with the proxy
# image's control directory, networksetup, scutil, schedulers), on both
# platform adapters, each in its own subshell. No host runtime, resolver or
# scheduler is touched.

# Each platform runs in its own subshell on purpose: exports there are local.
# shellcheck disable=SC2030,SC2031
. "$NICE_DNS_ROOT/tests/fixtures/health-fakes.sh"

# sha256sum (Linux) / shasum (macOS): the bridge-set hash (lib/recovery.sh)
# and the proxy generation (lib/health.sh) use whichever exists.
CI_TOOLS="awk basename bash cat chmod comm cp cut date dirname env expr find grep head id kill ln ls mkdir mktemp mv od ps readlink rm sed sh sha256sum shasum sleep sort stat tail tee touch tr uniq wc xargs"

# ci_env <linux|macos>: fakes for a healthy stack, reduced PATH, private
# HOME and state, and the libraries sourced into this (sub)shell.
ci_env() {
  local b="$CASE_DIR/bin-$1" t p
  export FAKE="$CASE_DIR/fake-$1" FAKE_LOG="$CASE_DIR/fake-$1/calls.log"
  rm -rf "$FAKE" "$b"
  ob_fake_data "$FAKE" "$1"
  ob_write_stubs "$b"
  for t in $CI_TOOLS; do p="$(command -v "$t")" && [ ! -e "$b/$t" ] && ln -s "$p" "$b/$t"; done
  export PATH="$b" HOME="$CASE_DIR/home-$1" TMPDIR="$CASE_DIR/tmp-$1"
  mkdir -p "$HOME" "$TMPDIR"
  export ND_PLATFORM="$1" ND_BOOT_ID=boot-a ND_STATE_DIR="$CASE_DIR/state-$1" ND_ROUTES_FILE="$NICE_DNS_ROOT/routes/providers.tsv"
  export ND_RESOLV_CONF="$CASE_DIR/resolv-$1.conf" ND_CONTAINER_FALLBACK=/nonexistent ND_ROUTE_DIR="$CASE_DIR/route-$1"
  export ND_RECOVERY_ACK_S=3 ND_RECOVERY_SERVICE_S=4 ND_RECOVERY_CMD_DEADLINE=5
  if [ "$1" = macos ]; then export FAKE_UNAME=Darwin; else export FAKE_UNAME=Linux; fi
  unset CONTAINER_BIN ND_PROXY_CONTAINER ND_TOR_VARIANT
  printf 'nameserver 127.0.0.1\n' >"$ND_RESOLV_CONF"
  # shellcheck source=lib/recovery.sh
  # The controller's shell options (health/nice-dns-health:27).
  set -uo pipefail
  . "$NICE_DNS_ROOT/lib/recovery.sh" || fail "cannot source lib/recovery.sh"
  assert_eq "$1" "$(nd_platform_name)" "the $1 adapter is loaded"
  nd_state_init || fail "state init"
}


# ci_routes <mode> [port...]: route probe behaviour (ok, servfail, hang);
# with no ports, every route.
ci_routes() {
  local m="$1" p
  shift
  [ $# -gt 0 ] || set -- 18531 18532 18533 853
  for p in "$@"; do printf '%s\n' "$m" >"$FAKE/probe/$p"; done
}

# ci_seed <route> <outage_since|-> [streak rows]: a committed state with the
# controller started two hours ago.
ci_seed() {
  local tok now
  now="$(date +%s)"
  { printf 'schema\tnice-dns-controller-state/1\nboot_id\tboot-a\nupdated\t%s\nstarted\t%s\nroute\t%s\n' "$((now - 60))" "$((now - 7200))" "$1"
    printf 'outage_since\t%s\noutage_restarts\t0\nlast_action\t-\nlast_action_at\t-\nrecovery_at\t-\n' "$2"
    shift 2
    for r in "$@"; do printf '%s\n' "$r"; done; } >"$CASE_DIR/seed"
  tok="$(nd_state_lock)" || fail "lock for seeding"
  nd_state_commit "$tok" 0 "$CASE_DIR/seed" >/dev/null || fail "seed commit"
  nd_state_unlock "$tok"
}

# ci_tick [active|shadow]: one real pass: observe, validate, tick. CI_OBS and
# CI_OUT hold the observations and the tick's output.
ci_tick() {
  CI_OBS="$(nd_health_observe 60)"
  printf '%s\n' "$CI_OBS" | nd_health_validate || fail "observations invalid: $CI_OBS"
  printf '%s\n' "$CI_OBS" >"$CASE_DIR/obs"
  CI_OUT="$(nd_recovery_tick "${1:-active}" "$CASE_DIR/obs")"
  assert_rc 0 $? "tick: $CI_OUT"
}

ci_get() { printf '%s\n' "$2" | awk -F '\t' -v k="$1" '$1 == k { print $2; exit }'; }
ci_obs() { printf '%s\n' "$CI_OBS" | awk -F '\t' -v n="$1" '$1 == "obs" && $2 == n { print $3; exit }'; }
ci_state() { nd_state_load | awk -F '\t' -v k="$1" '$1 == k { print $2; exit }'; }
ci_journal() { awk -F '\t' 'NR > 1 { print $3 " " $4 }' "$ND_STATE_DIR/recovery.tsv" 2>/dev/null; }

t_cached_answer_never_hides_an_upstream_outage() {
  local plat
  for plat in linux macos; do
    (
      ci_env "$plat"
      ci_seed cloudflare-exit -
      ci_routes servfail
      ci_tick
      assert_eq healthy "$(ci_obs local-cache)" "$plat: Pi-hole still answers from its cache"
      assert_eq unhealthy "$(ci_obs route:cloudflare-exit)" "$plat: the route probe sees the outage"
      assert_ne - "$(ci_state outage_since)" "$plat: the cached answer does not stop the outage clock"
      assert_eq no-op "$(ci_get action "$CI_OUT")" "$plat: inside the grace nothing acts yet"
    ) || exit 1
  done
}

t_observed_outage_restart_is_acknowledged_then_ready() {
  local plat
  for plat in linux macos; do
    (
      ci_env "$plat"
      ci_seed cloudflare-exit "$(( $(date +%s) - 3600 ))"
      ci_routes servfail
      echo new >"$FAKE/ack"
      ci_tick
      assert_eq restart-component "$(ci_get action "$CI_OUT")" "$plat: a sustained observed outage restarts Tor"
      assert_eq acknowledged "$(ci_get result "$CI_OUT")" "$plat: acknowledged by the image with a new generation"
      assert_eq 2 "$(awk -F '\t' '$1 == "generation" { print $2 }' "$FAKE/ctl/tor-generation")" "$plat: the image moved to generation 2"
      assert_eq "$(printf 'tor requested\ntor acknowledged')" "$(ci_journal)" "$plat: no readiness in the acknowledging pass"
      ci_routes ok
      ci_tick
      assert_eq "$(printf 'tor requested\ntor acknowledged\ntor ready')" "$(ci_journal)" "$plat: the next observed pass records readiness"
      assert_eq - "$(ci_state outage_since)" "$plat: the outage is over"
    ) || exit 1
  done
}

t_observed_onion_failure_switches_route_not_tor() {
  local plat
  for plat in linux macos; do
    (
      ci_env "$plat"
      ci_seed cloudflare-onion - "$(printf 'streak\tcloudflare-onion\t9\t1\t1')"
      mkdir -m 700 "$ND_ROUTE_DIR"
      apply_route() { printf 'result\tapplied\nroute\t%s\ngeneration\t%s\n' "$1" "$2"; printf '%s\n' "$1" >>"$CASE_DIR/applied-$plat"; }
      ci_routes servfail 18531
      ci_tick
      assert_eq switch-route "$(ci_get action "$CI_OUT")" "$plat: a failing onion with a working exit switches route"
      assert_eq cloudflare-exit "$(cat "$CASE_DIR/applied-$plat")" "$plat: to the exit, through apply_route"
      assert_not_match 'tor-restart-request|exec tor-[a-z]+ sh ' "$(cat "$FAKE_LOG")" "$plat: Tor is not restarted"
      assert_eq cloudflare-exit "$(ci_state route)" "$plat: the committed state selects the exit"
    ) || exit 1
  done
}

t_unanswerable_probes_never_act() {
  local plat i
  for plat in linux macos; do
    (
      ci_env "$plat"
      ci_seed cloudflare-exit -
      ci_routes hang
      export ND_HEALTH_PROBE_DEADLINE=1
      echo new >"$FAKE/ack"
      for i in 1 2 3; do
        ci_tick
        assert_eq indeterminate "$(ci_obs route:cloudflare-exit)" "$plat: a probe past its deadline is indeterminate (pass $i)"
        assert_eq no-op "$(ci_get action "$CI_OUT")" "$plat: unknown is neither health nor outage (pass $i)"
      done
      assert_eq - "$(ci_state outage_since)" "$plat: no outage clock from unknowns"
      [ ! -e "$FAKE/ctl/tor-restart-request" ] || fail "$plat: a restart was requested on indeterminate observations"
    ) || exit 1
  done
}

t_held_outage_clock_with_unanswerable_probes_never_acts() {
  local plat
  for plat in linux macos; do
    (
      ci_env "$plat"
      # An outage seen an hour ago; now every probe misses its deadline.
      ci_seed cloudflare-exit "$(( $(date +%s) - 3600 ))"
      ci_routes hang
      export ND_HEALTH_PROBE_DEADLINE=1
      echo new >"$FAKE/ack"
      ci_tick
      assert_eq no-op "$(ci_get action "$CI_OUT")" "$plat: no restart on a pass that observed nothing"
      [ ! -e "$FAKE/ctl/tor-restart-request" ] || fail "$plat: a restart was requested without current evidence"
      assert_ne - "$(ci_state outage_since)" "$plat: the clock is held for the next observed pass"
    ) || exit 1
  done
}

t_shadow_pass_observes_and_decides_but_never_acts() {
  local plat
  for plat in linux macos; do
    (
      ci_env "$plat"
      ND_STATE_DIR="$ND_STATE_DIR/shadow" nd_state_init
      ND_STATE_DIR="$ND_STATE_DIR/shadow" ci_seed cloudflare-exit "$(( $(date +%s) - 3600 ))"
      ci_routes servfail
      echo new >"$FAKE/ack"
      : >"$FAKE_LOG"
      ci_tick shadow
      assert_eq restart-component "$(ci_get action "$CI_OUT")" "$plat: the shadow pass reaches the same decision"
      assert_eq shadow "$(ci_get result "$CI_OUT")" "$plat: and only records it"
      [ ! -e "$FAKE/ctl/tor-restart-request" ] || fail "$plat: the shadow pass wrote a restart request"
      assert_not_match 'systemctl|launchctl|kickstart' "$(cat "$FAKE_LOG")" "$plat: no scheduler command"
    ) || exit 1
  done
}

# ─────────────────────────── install drift (BL-045) ──────────────────────────
#
# The installed generation is reported, never re-rendered: `status` shows it
# with each running image against the generation's recorded one and the :53
# publishes; `drift` exits 0 current, 1 drift (an image off the generation),
# 2 security drift; a tick logs security drift at err once a day.

# ci_drift_env: the Linux world with an installed generation; CI_CLI runs the
# checkout's controller.
ci_drift_env() {
  ci_env linux
  export XDG_STATE_HOME="$HOME/.local/state" XDG_CONFIG_HOME="$HOME/.config"
  ob_install_state "$@"
}
# ci_cli <cmd...>: the controller from a private checkout-shaped copy (the
# controller refuses a library directory others can write).
ci_cli() {
  local t="$CASE_DIR/tree"
  if [ ! -d "$t" ]; then
    mkdir -p "$t" && cp -R "$NICE_DNS_ROOT/health" "$NICE_DNS_ROOT/lib" "$NICE_DNS_ROOT/routes" "$t/" && chmod -R go-w "$t"
    chmod go-w "$CASE_DIR"
  fi
  CI_OUT="$(bash "$t/health/nice-dns-health" "$@" 2>&1)"; CI_RC=$?
}

t_status_shows_the_generation_and_lock_match() {
  (
    ci_drift_env
    ci_cli status
    assert_match "Generation: *$OB_GEN" "$CI_OUT" "the generation"
    assert_match "Source commit: *0123456789abcdef0123456789abcdef01234567" "$CI_OUT" "its source commit"
    assert_match "Lock: *sha256:0{63}7" "$CI_OUT" "the lock it was installed from"
    assert_match "unbound +on the generation's image" "$CI_OUT" "unbound runs the recorded image"
    assert_match "pi-hole +on the generation's image" "$CI_OUT" "pi-hole too"
    assert_match "tor-haproxy +on the generation's image" "$CI_OUT" "and the proxy"
    assert_match "127\.0\.0\.1:53:53/udp" "$CI_OUT" "the :53 publishes"
    assert_match "Drift: *none" "$CI_OUT" "no drift"
    printf 'lock\tsha256:\033[31mred\n' >>"$XDG_STATE_HOME/nice-dns-install/generations/$OB_GEN/prepare.tsv"
    sed -i '/^lock\tsha256:0/d' "$XDG_STATE_HOME/nice-dns-install/generations/$OB_GEN/prepare.tsv"
    ci_cli status
    assert_not_match "$(printf '\033')" "$CI_OUT" "no control character from a file reaches the terminal"
    ci_cli drift
    assert_rc 0 "$CI_RC" "drift: current: $CI_OUT"
  ) || exit 1
}

t_drift_reports_an_image_off_the_lock() {
  (
    ci_drift_env
    printf '%064d\n' 9 >"$FAKE/image_unbound"
    ci_cli drift
    assert_rc 1 "$CI_RC" "an image off the generation is drift: $CI_OUT"
    assert_match "unbound +OFF the generation's image" "$CI_OUT" "names the container"
    rm -f "$FAKE/image_pi-hole"
    ci_cli drift
    assert_rc 1 "$CI_RC" "a container that does not run is drift too: $CI_OUT"
    assert_match "pi-hole +not running" "$CI_OUT" "and says so"
  ) || exit 1
}

t_security_drift_logs_once_per_day() {
  (
    ci_drift_env 0.0.0.0:53:53/tcp
    ci_cli drift
    assert_rc 2 "$CI_RC" "a wildcard :53 publish is security drift: $CI_OUT"
    printf '%064d\n' 9 >"$FAKE/image_unbound"
    ci_cli drift
    assert_rc 2 "$CI_RC" "security drift outranks image drift"
    ci_cli tick
    ci_cli tick
    assert_eq 1 "$(grep -c 'ERR install-security-drift' "$HOME/.local/state/nice-dns-health/health.log")" "two ticks, one err line:
$(cat "$HOME/.local/state/nice-dns-health/health.log")"
    printf '2000-01-01\n' >"$HOME/.local/state/nice-dns-health/install-security-drift.day"
    ci_cli tick
    assert_eq 2 "$(grep -c 'ERR install-security-drift' "$HOME/.local/state/nice-dns-health/health.log")" "a new day logs again"
    ob_install_state 192.168.1.5:53:53/udp
    ci_cli tick
    assert_eq 3 "$(grep -c 'ERR install-security-drift' "$HOME/.local/state/nice-dns-health/health.log")" "a different drift the same day logs once more"
    ci_cli tick
    assert_eq 3 "$(grep -c 'ERR install-security-drift' "$HOME/.local/state/nice-dns-health/health.log")" "and only once"
    ob_install_state
    ci_cli tick
    assert_eq 3 "$(grep -c 'ERR install-security-drift' "$HOME/.local/state/nice-dns-health/health.log")" "no drift, no err line"
    # A stamp that cannot be written logs nothing (it would repeat every pass).
    ob_install_state 0.0.0.0:53:53/udp
    rm -f "$HOME/.local/state/nice-dns-health/install-security-drift.day"
    mkdir "$HOME/.local/state/nice-dns-health/install-security-drift.day.new"
    ci_cli tick; ci_cli tick
    assert_eq 3 "$(grep -c 'ERR install-security-drift' "$HOME/.local/state/nice-dns-health/health.log")" "no stamp, no err line"
  ) || exit 1
}

t_drift_never_re_renders() {
  (
    local pod
    ci_drift_env 0.0.0.0:53:53/tcp
    rm -f "$XDG_STATE_HOME/nice-dns-install/current"
    pod="$(cat "$XDG_CONFIG_HOME/containers/systemd/nice-dns.pod")"
    # A settled controller state: a healthy pass on it takes no action.
    ci_seed cloudflare-exit -
    : >"$FAKE_LOG"
    ci_cli status; ci_cli drift; ci_cli tick
    assert_eq no-op "$(ci_get action "$CI_OUT")" "the tick takes no action for drift"
    assert_eq "" "$(grep -E '^(podman|container) (run|rm|create|start|stop|restart|kill|pod|play|generate|pull|build|tag|rmi|image (rm|tag|pull))( |$)' "$FAKE_LOG")" "no runtime write:
$(cat "$FAKE_LOG")"
    assert_eq "" "$(grep -E '^systemctl .*(start|stop|restart|enable|disable|daemon-reload|reload)( |$)' "$FAKE_LOG")" "no unit change"
    assert_eq "$pod" "$(cat "$XDG_CONFIG_HOME/containers/systemd/nice-dns.pod")" "the quadlet is as it was"
    assert_no_path "$XDG_STATE_HOME/nice-dns-install/current" "no generation is invented"
  ) || exit 1
}
