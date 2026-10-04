# shellcheck shell=bash
# Group integration/bridge-lifecycle (Sub-plan 3, Task 2.2; ARCH-07; BL-019).
#
# Sourced by tests/run.sh (assert_* helpers; NICE_DNS_ROOT, CASE_DIR). The
# daily bridge refresh (lib/recovery.sh nd_bridges_refresh / nd_bridges_apply)
# and its adoption by recovery, on both platform adapters, each in its own
# subshell, against the shared health fakes (tests/fixtures/health-fakes.sh):
# the runtime fake plays the image's bridge-eval (`run`), the proxy's control
# directory and the schedulers. Nothing on the host is touched.
#
# NICE_DNS_OPT_PLATFORMS (--platforms all|linux|macos) picks the adapters.

# Each platform runs in its own subshell on purpose: exports there are local.
# shellcheck disable=SC2030,SC2031
. "$NICE_DNS_ROOT/tests/fixtures/health-fakes.sh"

BL_TOOLS="awk basename bash cat chmod comm cp cut date dirname env expr find grep head id kill ln ls mkdir mktemp mv od ps readlink rm sed sh sha256sum sleep sort stat tail tee touch tr uniq wc xargs"

bl_platforms() {
  local p="${NICE_DNS_OPT_PLATFORMS:-all}" x out=""
  [ "$p" = all ] && { printf 'linux macos\n'; return 0; }
  for x in $(printf '%s' "$p" | tr ',' ' '); do
    case "$x" in linux|macos) out="$out $x" ;; *) fail "unknown --platforms value '$x' (all, linux, macos)" ;; esac
  done
  printf '%s\n' "$out"
}

# bl_set <file> <n> [first octet]: n valid bridge lines.
bl_set() {
  local i=1
  : >"$1"
  while [ "$i" -le "$2" ]; do
    printf 'BRIDGE%s=obfs4 192.0.%s.%s:443 %s cert=AAAAtest%s iat-mode=0\n' "$i" "${3:-2}" "$i" \
      "$(printf '%040d' "$i" | tr '0' 'A')" "$i" >>"$1"
    i=$((i + 1))
  done
}

bl_env() {
  local b="$CASE_DIR/bin-$1" t p
  export FAKE="$CASE_DIR/fake-$1" FAKE_LOG="$CASE_DIR/fake-$1/calls.log"
  rm -rf "$FAKE" "$b"
  ob_fake_data "$FAKE" "$1"
  ob_write_stubs "$b"
  for t in $BL_TOOLS; do p="$(command -v "$t")" && [ ! -e "$b/$t" ] && ln -s "$p" "$b/$t"; done
  export PATH="$b" HOME="$CASE_DIR/home-$1" TMPDIR="$CASE_DIR/tmp-$1"
  mkdir -p "$HOME" "$TMPDIR"
  export ND_PLATFORM="$1" ND_BOOT_ID=boot-a ND_STATE_DIR="$CASE_DIR/state-$1" ND_ROUTES_FILE="$NICE_DNS_ROOT/routes/providers.tsv"
  export ND_BRIDGE_CONFIG_DIR="$CASE_DIR/cfg-$1" ND_CONTAINER_FALLBACK=/nonexistent
  export ND_RECOVERY_ACK_S=3 ND_RECOVERY_SERVICE_S=4 ND_RECOVERY_CMD_DEADLINE=5 ND_BRIDGE_EVAL_S=30
  if [ "$1" = macos ]; then export FAKE_UNAME=Darwin; else export FAKE_UNAME=Linux; fi
  unset CONTAINER_BIN ND_PROXY_CONTAINER
  mkdir -p "$ND_BRIDGE_CONFIG_DIR"
  # shellcheck source=lib/recovery.sh
  . "$NICE_DNS_ROOT/lib/recovery.sh" || fail "cannot source lib/recovery.sh"
  assert_eq "$1" "$(nd_platform_name)" "the $1 adapter is loaded"
  nd_state_init || fail "state init"
  BL_LIVE="$ND_BRIDGE_CONFIG_DIR/bridges.env"
}

bl_journal() { awk -F '\t' 'NR > 1 && $3 == "bridges" { print $4 }' "$ND_STATE_DIR/recovery.tsv" 2>/dev/null; }
bl_restarts() { grep -E 'systemctl --user restart|launchctl kickstart| sh -c ' "$FAKE_LOG" 2>/dev/null; }
bl_get() { printf '%s\n' "$2" | awk -F '\t' -v k="$1" '$1 == k { print $2; exit }'; }

t_unchanged_set_writes_nothing_and_restarts_nothing() {
  local plat out before
  for plat in $(bl_platforms); do
    (
      bl_env "$plat"
      bl_set "$BL_LIVE" 5
      # The same set, reordered and renumbered: normalized, it is unchanged.
      tac "$BL_LIVE" 2>/dev/null >"$CASE_DIR/cand" || awk '{ l[NR] = $0 } END { for (i = NR; i > 0; i--) print l[i] }' "$BL_LIVE" >"$CASE_DIR/cand"
      printf 'set %s\n' "$CASE_DIR/cand" >"$FAKE/bridge_eval"
      before="$(cat "$BL_LIVE")"
      out="$(nd_bridges_refresh haproxy)"
      assert_rc 0 $? "$plat: refresh: $out"
      assert_eq unchanged "$(bl_get result "$out")" "$plat: an equal set is unchanged"
      assert_eq "$before" "$(cat "$BL_LIVE")" "$plat: bridges.env is untouched"
      assert_no_path "$BL_LIVE.prev" "$plat: nothing replaced"
      assert_eq "" "$(bl_restarts)" "$plat: nothing restarted"
      assert_eq "" "$(find "$ND_BRIDGE_CONFIG_DIR" -name '.bridges.env.candidate*')" "$plat: the candidate is removed"
    ) || exit 1
  done
}

t_changed_set_is_adopted_at_next_start_without_restart() {
  local plat out
  for plat in $(bl_platforms); do
    (
      bl_env "$plat"
      bl_set "$BL_LIVE" 5
      bl_set "$CASE_DIR/cand" 7 9
      printf 'set %s\n' "$CASE_DIR/cand" >"$FAKE/bridge_eval"
      out="$(nd_bridges_refresh haproxy)"
      assert_eq changed "$(bl_get result "$out")" "$plat: a new set is adopted: $out"
      assert_eq 7 "$(grep -cE '^BRIDGE[0-9]+=obfs4 192\.0\.9\.' "$BL_LIVE")" "$plat: bridges.env holds the new set"
      assert_eq 5 "$(grep -c '^BRIDGE' "$BL_LIVE.prev")" "$plat: the previous set is kept"
      assert_eq "" "$(find "$BL_LIVE" -perm -0004 -o -perm -0040)" "$plat: bridges.env is private"
      assert_eq "" "$(bl_restarts)" "$plat: no restart: the proxy reads it at its next start"
      assert_file "$ND_STATE_DIR/bridges.pending" "$plat: recorded as waiting for the proxy"
      assert_eq changed "$(bl_journal)" "$plat: journal"
    ) || exit 1
  done
}

t_failed_or_thin_evaluation_keeps_the_last_good_set() {
  local plat out before
  for plat in $(bl_platforms); do
    (
      bl_env "$plat"
      bl_set "$BL_LIVE" 5; before="$(cat "$BL_LIVE")"
      echo fail >"$FAKE/bridge_eval"
      out="$(nd_bridges_refresh haproxy)"
      assert_eq not-applied "$(bl_get result "$out")" "$plat: a failed evaluation applies nothing"
      assert_eq "$before" "$(cat "$BL_LIVE")" "$plat: the last good set stays"
      bl_set "$CASE_DIR/cand" 2 7
      printf 'BRIDGE3=obfs4 not-an-address cert=x iat-mode=0\nBRIDGE4=garbage\n' >>"$CASE_DIR/cand"
      printf 'set %s\n' "$CASE_DIR/cand" >"$FAKE/bridge_eval"
      out="$(nd_bridges_refresh haproxy)"
      assert_eq not-applied "$(bl_get result "$out")" "$plat: fewer than 3 valid bridges is not applied"
      assert_eq "$before" "$(cat "$BL_LIVE")" "$plat: the last good set still stays"
      assert_eq "$(printf 'not-applied\nnot-applied')" "$(bl_journal)" "$plat: both recorded"
    ) || exit 1
  done
}

t_slow_refresh_never_overwrites_a_newer_set() {
  local plat out a
  for plat in $(bl_platforms); do
    (
      bl_env "$plat"
      bl_set "$BL_LIVE" 5
      bl_set "$CASE_DIR/cand-a" 6 7; bl_set "$CASE_DIR/cand-b" 6 8
      printf 'slow 3 %s\n' "$CASE_DIR/cand-a" >"$FAKE/bridge_eval"
      ( nd_bridges_refresh haproxy >"$CASE_DIR/a.out" 2>&1 ) &
      a=$!
      sleep 1
      # A second refresh while A evaluates: the mutex keeps it off the pool.
      out="$(nd_bridges_refresh haproxy)"
      assert_eq skipped "$(bl_get result "$out")" "$plat: a concurrent refresh is skipped"
      # Meanwhile recovery (or anything under the state lock) adopts set B.
      out="$(nd_bridges_apply "$CASE_DIR/cand-b" "$(_nd_br_hash "$BL_LIVE")")"
      assert_eq changed "$(bl_get result "$out")" "$plat: set B adopted"
      wait "$a"
      assert_eq superseded "$(bl_get result "$(cat "$CASE_DIR/a.out")")" "$plat: the slow evaluation, started from the old set, is dropped"
      assert_eq 6 "$(grep -cE '^BRIDGE[0-9]+=obfs4 192\.0\.8\.' "$BL_LIVE")" "$plat: bridges.env still holds the newer set B"
    ) || exit 1
  done
}

t_recovery_adopts_a_pending_set_through_the_service_restart() {
  local plat out
  for plat in $(bl_platforms); do
    (
      bl_env "$plat"
      bl_set "$BL_LIVE" 5; bl_set "$CASE_DIR/cand" 7 9
      printf 'set %s\n' "$CASE_DIR/cand" >"$FAKE/bridge_eval"
      nd_bridges_refresh haproxy >/dev/null
      echo new >"$FAKE/ack"
      # The proxy has not been recreated since, so a restart must recreate it
      # (the fake service restart gives it a new start time).
      : >"$FAKE/restart_changes"
      out="$(nd_recovery_restart_tor ra-br-1)"
      assert_eq acknowledged "$(bl_get result "$out")" "$plat: the recreated proxy is acknowledged: $out"
      assert_no_path "$ND_STATE_DIR/bridges.pending" "$plat: the set is adopted, so nothing waits any more"
      assert_not_match 'exec tor-haproxy sh -c' "$(cat "$FAKE_LOG")" "$plat: no in-image restart, which would keep the old bridges"
      if [ "$plat" = macos ]; then
        assert_match '^launchctl kickstart -k ' "$(cat "$FAKE_LOG")" "$plat: the service restart recreates the proxy"
      else
        assert_match '^systemctl --user restart tor-haproxy.service$' "$(cat "$FAKE_LOG")" "$plat: the service restart recreates the proxy"
      fi
      assert_match 'tor	adopting' "$(cat "$ND_STATE_DIR/recovery.tsv")" "$plat: the journal says why"
    ) || exit 1
  done
}

t_a_proxy_restarted_since_has_adopted_the_set() {
  local plat out
  for plat in $(bl_platforms); do
    (
      bl_env "$plat"
      bl_set "$BL_LIVE" 5; bl_set "$CASE_DIR/cand" 7 9
      printf 'set %s\n' "$CASE_DIR/cand" >"$FAKE/bridge_eval"
      nd_bridges_refresh haproxy >/dev/null
      # A natural restart of the proxy since the set was written.
      echo "t-natural-restart" >"$FAKE/started"
      echo new >"$FAKE/ack"
      out="$(nd_recovery_restart_tor ra-br-2)"
      assert_eq acknowledged "$(bl_get result "$out")" "$plat: the in-image restart is used: $out"
      assert_match 'exec tor-haproxy sh -c' "$(cat "$FAKE_LOG")" "$plat: in-image request"
      assert_no_path "$ND_STATE_DIR/bridges.pending" "$plat: the stale marker is dropped"
    ) || exit 1
  done
}

t_macos_probe_uses_dnsnet_and_needs_the_stack() {
  local out
  bl_env macos
  bl_set "$BL_LIVE" 5; bl_set "$CASE_DIR/cand" 7 9
  printf 'set %s\n' "$CASE_DIR/cand" >"$FAKE/bridge_eval"
  nd_bridges_refresh haproxy >/dev/null
  assert_match '^container run --rm --network dnsnet -v ' "$(cat "$FAKE_LOG")" "every macOS probe container is on dnsnet"
  : >"$FAKE_LOG"; printf 'pi-hole\nunbound\n' >"$FAKE/running"
  out="$(nd_bridges_refresh haproxy)"
  assert_eq skipped "$(bl_get result "$out")" "without the stack on its addresses the probe does not run"
  assert_not_match ' run ' "$(cat "$FAKE_LOG")" "no probe container was started"
  # Running is not enough: each on its own address (a probe container would
  # otherwise take one; the 2026-09-21/23 incident), and not while the
  # start-container agent holds the stack lock (gate evaluator, Material 3).
  printf 'pi-hole\nunbound\ntor-haproxy\n' >"$FAKE/running"; echo 172.31.240.253 >"$FAKE/ip_tor-haproxy"
  : >"$FAKE_LOG"; out="$(nd_bridges_refresh haproxy)"
  assert_eq skipped "$(bl_get result "$out")" "a stack off its addresses is not probed"
  assert_not_match ' run ' "$(cat "$FAKE_LOG")" "no probe container on a misaddressed stack"
  rm -f "$FAKE/ip_tor-haproxy"
  mkdir -p "$HOME/.local/state/nice-dns/stack.lock"
  sleep 600 & lockpid=$!
  printf '%s\n' "$lockpid" >"$HOME/.local/state/nice-dns/stack.lock/pid"
  : >"$FAKE_LOG"; out="$(ND_BRIDGE_STACK_LOCK_S=2 nd_bridges_refresh haproxy)"
  # Reap it: an unreaped child is a zombie, which still answers kill -0.
  kill "$lockpid" 2>/dev/null; wait "$lockpid" 2>/dev/null
  assert_eq skipped "$(bl_get result "$out")" "the agent's stack lock held by a live process: no probe"
  assert_not_match ' run ' "$(cat "$FAKE_LOG")" "no probe container while the agent holds the stack"
  : >"$FAKE_LOG"; out="$(nd_bridges_refresh haproxy)"
  assert_match ' run --rm --network dnsnet ' "$(cat "$FAKE_LOG")" "a dead holder's lock is taken over and the probe runs"
  assert_no_path "$HOME/.local/state/nice-dns/stack.lock" "and the lock is released afterwards"
}

t_install_schedules_the_daily_refresh() {
  local plat tree
  for plat in $(bl_platforms); do
    (
      bl_env "$plat"
      export XDG_CONFIG_HOME="$HOME/.config" XDG_DATA_HOME="$HOME/.local/share" XDG_STATE_HOME="$HOME/.local/state"
      unset ND_PLATFORM ND_STATE_DIR
      tree="$CASE_DIR/tree-$plat"; mkdir -p "$tree"
      cp -R "$NICE_DNS_ROOT/health" "$NICE_DNS_ROOT/lib" "$NICE_DNS_ROOT/routes" "$tree/"; chmod -R go-w "$tree"
      out="$(bash "$tree/health/nice-dns-health" install 2>&1)"
      assert_rc 0 $? "$plat: install: $out"
      if [ "$plat" = linux ]; then
        assert_match '^OnCalendar=daily$' "$(cat "$XDG_CONFIG_HOME/systemd/user/nice-dns-health-bridges.timer")" "linux: daily"
        assert_match '^Persistent=true$' "$(cat "$XDG_CONFIG_HOME/systemd/user/nice-dns-health-bridges.timer")" "linux: a missed day runs on the next start"
        assert_match 'nice-dns-health bridges-refresh$' "$(cat "$XDG_CONFIG_HOME/systemd/user/nice-dns-health-bridges.service")" "linux: runs the refresh"
        assert_match '^systemctl --user enable --now nice-dns-health-bridges.timer$' "$(cat "$FAKE_LOG")" "linux: enabled"
      else
        assert_match '<string>bridges-refresh</string>' "$(cat "$HOME/Library/LaunchAgents/org.nice-dns.health-bridges.plist")" "macos: runs the refresh"
        assert_match '<key>Hour</key>' "$(cat "$HOME/Library/LaunchAgents/org.nice-dns.health-bridges.plist")" "macos: daily calendar interval (runs on wake)"
      fi
      out="$(bash "$HOME/.local/bin/nice-dns-health" uninstall 2>&1)"
      assert_eq "" "$(find "$HOME" -name 'nice-dns-health-bridges.*' -o -name 'org.nice-dns.health-bridges.plist')" "$plat: uninstall removes the refresh schedule"
    ) || exit 1
  done
}

t_boot_selection_is_skipped_when_a_usable_set_exists() {
  local cond h rc
  # The rendered ExecCondition of the Linux boot unit: \$\$ in the installer
  # heredoc is $$ in the unit, which systemd passes to sh as $.
  cond="$(grep '^ExecCondition=' "$NICE_DNS_ROOT/deb/persistent-podman.sh" | sed -e 's/^ExecCondition=\/usr\/bin\/sh -c //' -e 's/\\\$\\\$/$/g' -e "s/^'//" -e "s/'\$//")"
  assert_match '^n=\$\(grep' "$cond" "the condition renders"
  h="$CASE_DIR/home-cond"; mkdir -p "$h/.config/nice-dns"
  sh -c "$(printf '%s' "$cond" | sed "s#%h#$h#g")"; rc=$?
  assert_rc 0 "$rc" "no bridges.env: the boot selection runs"
  bl_set "$h/.config/nice-dns/bridges.env" 2
  sh -c "$(printf '%s' "$cond" | sed "s#%h#$h#g")"; rc=$?
  assert_rc 0 "$rc" "two bridges: the boot selection runs"
  bl_set "$h/.config/nice-dns/bridges.env" 3
  sh -c "$(printf '%s' "$cond" | sed "s#%h#$h#g")"; rc=$?
  assert_rc 1 "$rc" "a usable set: skipped (ExecCondition exit 1), out of startup's critical path"
}

# The patterns are literal installer text on purpose.
# shellcheck disable=SC2016
t_macos_installer_retires_the_legacy_bridge_agent_after_the_controller() {
  local f="$NICE_DNS_ROOT/mac/persist.sh" ci cr
  assert_not_match 'launchctl load "\$EVAL_DST"' "$(cat "$f")" "the legacy agent is no longer installed"
  ci="$(grep -n '"\$HERE/\.\./health/nice-dns-health" install' "$f" | cut -d: -f1)"
  cr="$(grep -n 'launchctl unload "\$EVAL_DST"' "$f" | cut -d: -f1)"
  [ -n "$ci" ] && [ -n "$cr" ] && [ "$cr" -gt "$ci" ] || fail "the legacy agent must be retired only after the controller installs (install line $ci, retire line $cr)"
}

t_outage_refresh_is_evaluated_and_rate_limited() {
  local plat tree tok now
  for plat in $(bl_platforms); do
    (
      bl_env "$plat"
      tree="$CASE_DIR/tree-$plat"; mkdir -p "$tree"
      cp -R "$NICE_DNS_ROOT/health" "$NICE_DNS_ROOT/lib" "$NICE_DNS_ROOT/routes" "$tree/"; chmod -R go-w "$tree"
      printf 'nameserver 127.0.0.1\n' >"$CASE_DIR/resolv-$plat.conf"; export ND_RESOLV_CONF="$CASE_DIR/resolv-$plat.conf"
      bl_set "$BL_LIVE" 5; bl_set "$CASE_DIR/cand" 7 9
      printf 'set %s\n' "$CASE_DIR/cand" >"$FAKE/bridge_eval"
      for p in 18531 18532 18533 853; do echo servfail >"$FAKE/probe/$p"; done
      # An observed outage an hour old: past the grace.
      now="$(date +%s)"
      printf 'schema\tnice-dns-controller-state/1\nboot_id\tboot-a\nupdated\t%s\nstarted\t%s\nroute\tcloudflare-exit\noutage_since\t%s\noutage_restarts\t0\nlast_action\t-\nlast_action_at\t-\nrecovery_at\t%s\n' \
        "$((now - 60))" "$((now - 7200))" "$((now - 3600))" "$((now - 60))" >"$CASE_DIR/seed"
      tok="$(nd_state_lock)" && nd_state_commit "$tok" 0 "$CASE_DIR/seed" >/dev/null && nd_state_unlock "$tok"
      # A raw fetcher must never be called: make one that would be noticed.
      mkdir -p "$HOME/.local/bin"; printf '#!/bin/sh\necho RAW >>"%s"\n' "$FAKE_LOG" >"$HOME/.local/bin/nice-dns-fetch-bridges"; chmod 755 "$HOME/.local/bin/nice-dns-fetch-bridges"
      bash "$tree/health/nice-dns-health" tick >"$CASE_DIR/t1" 2>&1
      assert_eq 1 "$(grep -c ' run --rm ' "$FAKE_LOG")" "$plat: the outage past the grace re-evaluates the bridges once: $(cat "$CASE_DIR/t1")"
      # The evaluation takes minutes: the pass decides on observations taken
      # after it, never on ones from before (gate evaluator, Material 1).
      assert_eq 1 "$(awk '/ run --rm / { r = NR } /nice-dns-route-probe/ { if (!p) p = NR } END { print (r && p && r < p) ? 1 : 0 }' "$FAKE_LOG")" \
        "$plat: the bridges are evaluated before the pass observes the routes"
      assert_eq 7 "$(grep -cE '^BRIDGE[0-9]+=obfs4 192\.0\.9\.' "$BL_LIVE")" "$plat: the evaluated set is applied under its rules"
      assert_not_match 'RAW' "$(cat "$FAKE_LOG")" "$plat: the raw Moat fetcher is never used"
      bash "$tree/health/nice-dns-health" tick >"$CASE_DIR/t2" 2>&1
      assert_eq 1 "$(grep -c ' run --rm ' "$FAKE_LOG")" "$plat: not again within the hour"
    ) || exit 1
  done
}

# Sub-plan 5 Task 2.1 (FQ-BRIDGE-DISTRIBUTOR-DOWN): a fetch that cannot reach
# the bridge distributor (Moat unreachable, no bootstrap resolver answers)
# fails and leaves the working candidate pool as it was, byte for byte.
t_unreachable_distributor_keeps_the_working_pool() {
  local h="$CASE_DIR/home" b="$CASE_DIR/bin" before i out rc
  mkdir -p "$h/.config/nice-dns" "$b"
  for i in 1 2 3; do
    printf 'BRIDGE%s=obfs4 192.0.2.%s:443 %s cert=AAAAtest%s iat-mode=0\n' "$i" "$i" \
      "$(printf '%040d' "$i")" "$i"
  done >"$h/.config/nice-dns/bridges.env"
  chmod 600 "$h/.config/nice-dns/bridges.env"
  before="$(sha256sum <"$h/.config/nice-dns/bridges.env")"
  printf '#!/bin/sh\necho "curl: (7) Failed to connect to bridges.torproject.org" >&2\nexit 7\n' >"$b/curl"
  printf '#!/bin/sh\nexit 9\n' >"$b/dig"
  chmod 755 "$b/curl" "$b/dig"
  out="$(HOME="$h" XDG_CONFIG_HOME="$h/.config" PATH="$b:$PATH" bash "$NICE_DNS_ROOT/scripts/fetch-bridges.sh" --force 2>&1)"
  rc=$?
  assert_ne 0 "$rc" "a fetch without the distributor fails: $out"
  assert_match 'Could not reach https://bridges\.torproject\.org' "$out" "and says why"
  assert_eq "$before" "$(sha256sum <"$h/.config/nice-dns/bridges.env")" "the working pool is unchanged"
  assert_eq "" "$(find "$h/.config/nice-dns" -name 'bridges.env.*')" "no partial file is left"
}

# Stream quality (Sub-plan 5, Task 2.2; the mac soak 20261002T205552Z-cbc82d85
# failed on bridges that bootstrap but carry onion streams badly). The running
# proxy's Tor state (/app/data/tor/state; the fake serves $FAKE/ctl/state)
# carries per-bridge path-bias use counters; listed=1 marks a bridge the
# running Tor is configured with.
bl_fp() { printf '%040d' "$1" | tr '0' 'A'; }

# bl_guard <i> <listed> <attempts> <successes>: one Guard line as Tor writes it.
bl_guard() {
  printf 'Guard in=bridges rsa_id=%s bridge_addr=192.0.2.%s:443 sampled_on=2026-09-22T05:19:40 sampled_by=0.4.9.13 listed=%s confirmed_on=2026-09-22T05:19:40 confirmed_idx=%s pb_use_attempts=%s pb_use_successes=%s pb_circ_attempts=99.000000 pb_circ_successes=98.000000\n' \
    "$(bl_fp "$1")" "$1" "$2" "$1" "$3" "$4"
}

# The state of the mac soak, in shape: bridge 2 at 80% after 70 uses (running),
# bridge 3 at 93% (kept), bridge 4 below the 20-use minimum (kept, not judged),
# bridge 6 weak but no longer configured; a default-guard line is ignored.
bl_soak_state() {
  {
    printf '# Tor state file last generated on 2026-10-03 21:05:41 local time\nTorVersion Tor 0.4.9.13\n'
    bl_guard 2 1 70.500000 56.500000
    bl_guard 3 1 69.500000 64.500000
    bl_guard 4 1 15.000000 9.000000
    bl_guard 6 0 44.000000 30.000000
    printf 'Guard in=default rsa_id=%s sampled_on=2026-09-22T05:19:40 listed=1 pb_use_attempts=50.000000 pb_use_successes=1.000000\n' "$(bl_fp 8)"
    bl_guard 1 1 20.000000 20.000000
    bl_guard 5 1 0.000000 0.000000
  } >"$FAKE/ctl/state"
}

t_weak_running_bridge_is_dropped_and_the_proxy_recreated() {
  local plat out
  for plat in $(bl_platforms); do
    (
      bl_env "$plat"
      bl_set "$BL_LIVE" 5
      bl_set "$CASE_DIR/cand" 7 9
      printf 'set %s\n' "$CASE_DIR/cand" >"$FAKE/bridge_eval"
      bl_soak_state
      : >"$FAKE/restart_changes"
      out="$(nd_bridges_refresh haproxy)"
      assert_eq changed "$(bl_get result "$out")" "$plat: the filtered set is applied: $out"
      assert_eq 5 "$(grep -cE '^BRIDGE[0-9]+=obfs4 192\.0\.9\.' "$BL_LIVE")" "$plat: 7 evaluated minus the 2 weak ones"
      assert_not_match "$(bl_fp 2)" "$(cat "$BL_LIVE")" "$plat: the 80% bridge is gone"
      assert_not_match "$(bl_fp 6)" "$(cat "$BL_LIVE")" "$plat: the weak unconfigured bridge is not re-added"
      assert_match "$(bl_fp 3)" "$(cat "$BL_LIVE")" "$plat: 93% stays"
      assert_match "$(bl_fp 4)" "$(cat "$BL_LIVE")" "$plat: under 20 uses is not judged"
      assert_eq 2 "$(bl_get dropped "$out")" "$plat: the output counts the dropped bridges"
      assert_eq restarted "$(bl_get adopted "$out")" "$plat: the running proxy used a dropped bridge, so it is recreated"
      if [ "$plat" = macos ]; then
        assert_match '^launchctl kickstart -k ' "$(cat "$FAKE_LOG")" "$plat: through the service restart"
      else
        assert_match '^systemctl --user restart tor-haproxy.service$' "$(cat "$FAKE_LOG")" "$plat: through the service restart"
      fi
      assert_no_path "$ND_STATE_DIR/bridges.pending" "$plat: adopted, nothing waits"
      assert_match 'bridges	weak' "$(cat "$ND_STATE_DIR/recovery.tsv")" "$plat: the journal names the weak bridges"
      assert_not_match 'cert=' "$(cat "$ND_STATE_DIR/recovery.tsv")" "$plat: the journal carries no bridge secrets"
    ) || exit 1
  done
}

t_weak_bridge_not_running_is_filtered_without_restart() {
  local plat out
  for plat in $(bl_platforms); do
    (
      bl_env "$plat"
      bl_set "$BL_LIVE" 5
      bl_set "$CASE_DIR/cand" 7 9
      printf 'set %s\n' "$CASE_DIR/cand" >"$FAKE/bridge_eval"
      { bl_guard 6 0 44.000000 30.000000; bl_guard 3 1 69.500000 64.500000; } >"$FAKE/ctl/state"
      : >"$FAKE/restart_changes"
      out="$(nd_bridges_refresh haproxy)"
      assert_eq changed "$(bl_get result "$out")" "$plat: applied: $out"
      assert_eq 6 "$(grep -cE '^BRIDGE[0-9]+=obfs4 192\.0\.9\.' "$BL_LIVE")" "$plat: only the weak one is left out"
      assert_eq 1 "$(bl_get dropped "$out")" "$plat: one dropped"
      assert_eq - "$(bl_get adopted "$out")" "$plat: the running proxy does not use it"
      assert_eq "" "$(bl_restarts)" "$plat: no restart"
      assert_file "$ND_STATE_DIR/bridges.pending" "$plat: adopted at the next start as before"
    ) || exit 1
  done
}

t_filter_never_leaves_fewer_than_three_bridges() {
  local plat out before
  for plat in $(bl_platforms); do
    (
      bl_env "$plat"
      bl_set "$BL_LIVE" 5; before="$(cat "$BL_LIVE")"
      bl_set "$CASE_DIR/cand" 4 9
      printf 'set %s\n' "$CASE_DIR/cand" >"$FAKE/bridge_eval"
      { bl_guard 1 1 40 10; bl_guard 2 1 40 10; bl_guard 3 1 40 35; } >"$FAKE/ctl/state"
      : >"$FAKE/restart_changes"
      out="$(nd_bridges_refresh haproxy)"
      assert_eq not-applied "$(bl_get result "$out")" "$plat: 2 left after the filter is not applied: $out"
      assert_eq "$before" "$(cat "$BL_LIVE")" "$plat: the last good set stays"
      assert_eq "" "$(bl_restarts)" "$plat: nothing restarted"
    ) || exit 1
  done
}

t_unreadable_tor_state_changes_nothing() {
  local plat out
  for plat in $(bl_platforms); do
    (
      bl_env "$plat"
      bl_set "$BL_LIVE" 5
      bl_set "$CASE_DIR/cand" 7 9
      printf 'set %s\n' "$CASE_DIR/cand" >"$FAKE/bridge_eval"
      rm -f "$FAKE/ctl/state"
      out="$(nd_bridges_refresh haproxy)"
      assert_eq changed "$(bl_get result "$out")" "$plat: refresh as before: $out"
      assert_eq 7 "$(grep -cE '^BRIDGE[0-9]+=obfs4 192\.0\.9\.' "$BL_LIVE")" "$plat: nothing filtered without counters"
      assert_eq 0 "$(bl_get dropped "$out")" "$plat: none dropped"
      assert_eq "" "$(bl_restarts)" "$plat: no restart"
    ) || exit 1
  done
}
