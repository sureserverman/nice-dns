# shellcheck shell=bash
# Group integration/scheduling (Sub-plan 3, Task 2.1; ARCH-01, ARCH-07).
#
# Sourced by tests/run.sh (assert_* helpers; NICE_DNS_ROOT, CASE_DIR). The
# health CLI's install / self-check / uninstall run against a private HOME,
# a copy of the checkout, and PATH stubs for systemctl and launchctl
# (tests/fixtures/health-fakes.sh), on both platform layouts. The host's own
# units, agents and installed controller are never touched.
# t_bash32_installs_and_uninstalls runs the macOS layout under
# docker.io/library/bash:3.2 (--rm, no name, no network).
#
# NICE_DNS_OPT_PLATFORMS (--platforms all|linux|macos) picks the layouts.

. "$NICE_DNS_ROOT/tests/fixtures/health-fakes.sh"

SC_TOOLS="awk basename bash cat chmod cp cut date dirname env find grep head id kill ln ls mkdir mktemp mv od readlink rm sed sh sha256sum sleep sort stat tail tee touch tr uniq wc xargs"
SC_PY="$(command -v python3)"

sc_platforms() {
  local p="${NICE_DNS_OPT_PLATFORMS:-all}" x out=""
  [ "$p" = all ] && { printf 'linux macos\n'; return 0; }
  for x in $(printf '%s' "$p" | tr ',' ' '); do
    case "$x" in linux|macos) out="$out $x" ;; *) fail "unknown --platforms value '$x' (all, linux, macos)" ;; esac
  done
  printf '%s\n' "$out"
}

# sc_env <linux|macos>: private HOME, a clean checkout copy ($SC_TREE), stubs.
sc_env() {
  local b="$CASE_DIR/bin-$1" t p
  export FAKE="$CASE_DIR/fake-$1" FAKE_LOG="$CASE_DIR/fake-$1/calls.log"
  rm -rf "$FAKE" "$b" "$CASE_DIR/home-$1" "$CASE_DIR/tree-$1"
  ob_fake_data "$FAKE" "$1"
  ob_write_stubs "$b"
  for t in $SC_TOOLS; do p="$(command -v "$t")" && [ ! -e "$b/$t" ] && ln -s "$p" "$b/$t"; done
  export PATH="$b" HOME="$CASE_DIR/home-$1"
  export XDG_STATE_HOME="$HOME/.local/state" XDG_CONFIG_HOME="$HOME/.config" XDG_DATA_HOME="$HOME/.local/share"
  if [ "$1" = macos ]; then export FAKE_UNAME=Darwin; else export FAKE_UNAME=Linux; fi
  unset ND_HEALTH_INTERPRETER ND_STATE_DIR ND_PLATFORM
  mkdir -p "$HOME"
  SC_TREE="$CASE_DIR/tree-$1"
  mkdir -p "$SC_TREE" && cp -R "$NICE_DNS_ROOT/health" "$NICE_DNS_ROOT/lib" "$NICE_DNS_ROOT/routes" "$SC_TREE/" && chmod -R go-w "$SC_TREE"
  SC_BIN="$HOME/.local/bin/nice-dns-health"
  if [ "$1" = macos ]; then
    SC_ROOT="$HOME/Library/Application Support/nice-dns-health"; SC_UNIT="$HOME/Library/LaunchAgents/org.nice-dns.health.plist"
  else
    SC_ROOT="$XDG_DATA_HOME/nice-dns-health"; SC_UNIT="$XDG_CONFIG_HOME/systemd/user/nice-dns-health.service"
  fi
}

sc_cli() { SC_OUT="$(bash "$@" 2>&1)"; SC_RC=$?; }
sc_receipt() { awk -F '\t' -v k="$1" '$1 == k { print $2 }' "$SC_ROOT/install.tsv"; }
sc_bundles() { find "$SC_ROOT/bundles" -mindepth 1 -maxdepth 1 -type d ! -name '.*' -exec basename {} \; | LC_ALL=C sort | tr '\n' ' '; }

t_install_schedules_tick_every_minute_and_on_wake() {
  local plat interp
  for plat in $(sc_platforms); do
    (
      sc_env "$plat"
      sc_cli "$SC_TREE/health/nice-dns-health" install
      assert_rc 0 "$SC_RC" "$plat: install: $SC_OUT"
      interp="$(sc_receipt interpreter)"
      if [ "$plat" = linux ]; then
        assert_eq "$(command -v bash)" "$interp" "linux: the interpreter is the resolved absolute bash"
        assert_match "^ExecStart=$interp $SC_BIN tick\$" "$(cat "$SC_UNIT")" "linux: the service runs tick through the installed entrypoint"
        assert_match '^TimeoutStartSec=([1-9][0-9]?|[1-5][0-9][0-9])$' "$(cat "$SC_UNIT")" "linux: one pass is bounded under the 600 s lock lease"
        assert_match '^OnCalendar=minutely$' "$(cat "$XDG_CONFIG_HOME/systemd/user/nice-dns-health.timer")" "linux: every minute, on the wall clock"
        assert_match '^AccuracySec=5s$' "$(cat "$XDG_CONFIG_HOME/systemd/user/nice-dns-health.timer")" "linux: not coalesced to the 1 min default"
        assert_match '^Persistent=true$' "$(cat "$XDG_CONFIG_HOME/systemd/user/nice-dns-health.timer")" "linux: catches up after an inactive period"
        assert_not_match '^(OnUnitActiveSec|OnBootSec)=' "$(cat "$XDG_CONFIG_HOME/systemd/user/nice-dns-health.timer")" "linux: no monotonic timer, which pauses in suspend"
        assert_match '^systemctl --user enable --now nice-dns-health.timer$' "$(cat "$FAKE_LOG")" "linux: the timer is enabled"
      else
        assert_eq /bin/bash "$interp" "macos: /bin/bash"
        # plistlib parses it as launchd would read it.
        assert_eq "$(printf '%s\n' "/bin/bash|$SC_BIN|tick" "{}" True)" \
          "$("$SC_PY" -c 'import plistlib,sys; d=plistlib.load(open(sys.argv[1],"rb")); print("|".join(d["ProgramArguments"])); print(d["StartCalendarInterval"]); print(d["RunAtLoad"])' "$SC_UNIT")" \
          "macos: tick through the installed entrypoint, an all-wildcard calendar interval (every minute, run on wake), RunAtLoad"
        assert_not_match '<key>StartInterval</key>' "$(cat "$SC_UNIT")" "macos: no StartInterval, which misses intervals asleep"
        assert_match "^launchctl load -w $SC_UNIT\$" "$(cat "$FAKE_LOG")" "macos: the agent is loaded"
      fi
    ) || exit 1
  done
}

t_shadow_install_observes_only_and_activation_switches_in_place() {
  # Task 2.3 (ARCH-09): a deployment starts in observation mode. The shadow
  # schedule runs `tick --shadow` every minute and nothing else: no bridge
  # refresh, which writes bridges.env. A plain install activates the same
  # unit in place; a later shadow install retires the refresh again.
  local plat br
  for plat in $(sc_platforms); do
    (
      sc_env "$plat"
      if [ "$plat" = linux ]; then br="$XDG_CONFIG_HOME/systemd/user/nice-dns-health-bridges.timer"
      else br="$HOME/Library/LaunchAgents/org.nice-dns.health-bridges.plist"; fi
      sc_cli "$SC_TREE/health/nice-dns-health" install --bogus
      assert_rc 2 "$SC_RC" "$plat: an unknown install option is refused"
      assert_no_path "$SC_UNIT" "$plat: and nothing is written"
      sc_cli "$SC_TREE/health/nice-dns-health" install --shadow
      assert_rc 0 "$SC_RC" "$plat: install --shadow: $SC_OUT"
      assert_eq shadow "$(sc_receipt mode)" "$plat: the receipt records the shadow mode"
      if [ "$plat" = linux ]; then
        assert_match "^ExecStart=$(sc_receipt interpreter) $SC_BIN tick --shadow\$" "$(cat "$SC_UNIT")" "linux: the minutely pass only records"
      else
        assert_eq "/bin/bash|$SC_BIN|tick|--shadow" \
          "$("$SC_PY" -c 'import plistlib,sys; print("|".join(plistlib.load(open(sys.argv[1],"rb"))["ProgramArguments"]))' "$SC_UNIT")" \
          "macos: the minutely pass only records"
      fi
      assert_no_path "$br" "$plat: no bridge refresh schedule in shadow"
      assert_not_match 'health-bridges' "$(cat "$FAKE_LOG")" "$plat: no bridge refresh was enabled"
      assert_not_match 'health-bridges' "$(awk -F '\t' '$1 == "schedule"' "$SC_ROOT/install.tsv")" "$plat: the receipt owns no bridge schedule"
      sc_cli "$SC_BIN" status
      assert_match '^Mode: shadow' "$SC_OUT" "$plat: status names the mode"
      sc_cli "$SC_TREE/health/nice-dns-health" install
      assert_rc 0 "$SC_RC" "$plat: activation: $SC_OUT"
      assert_eq active "$(sc_receipt mode)" "$plat: the receipt records the active mode"
      assert_not_match 'tick --shadow|<string>--shadow</string>' "$(cat "$SC_UNIT")" "$plat: the same unit now acts"
      assert_file "$br" "$plat: the bridge refresh is scheduled once active"
      : >"$FAKE_LOG"
      sc_cli "$SC_TREE/health/nice-dns-health" install --shadow
      assert_rc 0 "$SC_RC" "$plat: back to shadow: $SC_OUT"
      assert_no_path "$br" "$plat: returning to shadow removes the bridge refresh"
      if [ "$plat" = linux ]; then
        assert_match '^systemctl --user disable --now nice-dns-health-bridges.timer$' "$(cat "$FAKE_LOG")" "linux: and stops its timer"
      else
        assert_match "^launchctl unload $br\$" "$(cat "$FAKE_LOG")" "macos: and unloads its agent"
      fi
    ) || exit 1
  done
}

t_installed_controller_runs_without_the_checkout() {
  local plat
  for plat in $(sc_platforms); do
    (
      sc_env "$plat"
      sc_cli "$SC_TREE/health/nice-dns-health" install
      assert_rc 0 "$SC_RC" "$plat: install: $SC_OUT"
      mv "$SC_TREE" "$SC_TREE.moved"
      sc_cli "$SC_BIN" self-check
      assert_rc 0 "$SC_RC" "$plat: the installed copy loads its bundle after the checkout moved: $SC_OUT"
      assert_match "^ok $SC_ROOT/bundles/[0-9a-f]{16}\$" "$SC_OUT" "$plat: from its own bundle"
      sc_cli "$SC_BIN" observe
      assert_rc 0 "$SC_RC" "$plat: observe works from the bundle: $SC_OUT"
      assert_match '^obs	route:cloudflare-exit	' "$SC_OUT" "$plat: with the bundled route table"
      assert_eq "" "$(grep -rl "$SC_TREE" "$SC_BIN" "$SC_UNIT" 2>/dev/null)" "$plat: nothing installed names the checkout"
    ) || exit 1
  done
}

t_reinstall_keeps_previous_bundle_and_prunes_older() {
  local plat b1 b2 b3
  for plat in $(sc_platforms); do
    (
      sc_env "$plat"
      sc_cli "$SC_TREE/health/nice-dns-health" install; b1="$(sc_receipt bundle)"
      chmod u+w "$SC_TREE/lib/policy.sh"; printf '\n# v2\n' >>"$SC_TREE/lib/policy.sh"
      sc_cli "$SC_TREE/health/nice-dns-health" install; b2="$(sc_receipt bundle)"
      printf '\n# v3\n' >>"$SC_TREE/lib/policy.sh"
      sc_cli "$SC_TREE/health/nice-dns-health" install; b3="$(sc_receipt bundle)"
      assert_rc 0 "$SC_RC" "$plat: third install: $SC_OUT"
      assert_ne "$b1" "$b2" "$plat: a changed library is a new bundle"
      assert_eq "$b2" "$(sc_receipt previous)" "$plat: the previous bundle is recorded for rollback"
      assert_eq "$(printf '%s\n' "$b2" "$b3" | LC_ALL=C sort | tr '\n' ' ')" "$(sc_bundles)" "$plat: current and previous are kept, older ones pruned"
      sc_cli "$SC_TREE/health/nice-dns-health" install
      assert_eq "$b3" "$(sc_receipt bundle)" "$plat: an unchanged reinstall keeps the bundle"
      assert_eq "$b2" "$(sc_receipt previous)" "$plat: and its previous"
    ) || exit 1
  done
}

t_broken_bundle_never_replaces_a_working_install() {
  local plat unit bin good
  for plat in $(sc_platforms); do
    (
      sc_env "$plat"
      sc_cli "$SC_TREE/health/nice-dns-health" install
      good="$(sc_receipt bundle)"; unit="$(cat "$SC_UNIT")"; bin="$(cat "$SC_BIN")"
      : >"$FAKE_LOG"
      chmod u+w "$SC_TREE/lib/state.sh"; printf 'if then\n' >>"$SC_TREE/lib/state.sh"
      sc_cli "$SC_TREE/health/nice-dns-health" install
      assert_rc 1 "$SC_RC" "$plat: a bundle that does not load fails the install"
      assert_match 'unchanged' "$SC_OUT" "$plat: and says the working install is unchanged"
      assert_eq "$good" "$(sc_receipt bundle)" "$plat: the receipt still names the working bundle"
      assert_eq "$unit" "$(cat "$SC_UNIT")" "$plat: the schedule is unchanged"
      assert_eq "$bin" "$(cat "$SC_BIN")" "$plat: the entrypoint is unchanged"
      assert_eq "$good " "$(sc_bundles)" "$plat: the broken bundle was removed"
      assert_eq "" "$(cat "$FAKE_LOG")" "$plat: no scheduler command ran"
      sc_cli "$SC_BIN" self-check
      assert_rc 0 "$SC_RC" "$plat: the working controller still loads"
    ) || exit 1
  done
}

t_missing_interpreter_or_library_is_refused() {
  local plat
  for plat in $(sc_platforms); do
    (
      sc_env "$plat"
      ND_HEALTH_INTERPRETER=/nonexistent/bash sc_cli "$SC_TREE/health/nice-dns-health" install
      assert_rc 1 "$SC_RC" "$plat: a missing interpreter is refused"
      assert_match 'interpreter /nonexistent/bash is missing' "$SC_OUT" "$plat: and named"
      assert_no_path "$SC_BIN" "$plat: nothing was installed"
      assert_no_path "$SC_UNIT" "$plat: no schedule was written"
      chmod u+w "$SC_TREE/lib"; mv "$SC_TREE/lib/policy.sh" "$SC_TREE/lib/policy.sh.gone"
      sc_cli "$SC_TREE/health/nice-dns-health" install
      assert_rc 1 "$SC_RC" "$plat: a missing library is refused"
      assert_match 'lib/policy.sh is missing' "$SC_OUT" "$plat: and named"
      assert_no_path "$SC_UNIT" "$plat: still no schedule"
      mv "$SC_TREE/lib/policy.sh.gone" "$SC_TREE/lib/policy.sh"
      sc_cli "$SC_TREE/health/nice-dns-health" install
      assert_rc 0 "$SC_RC" "$plat: installs once complete"
      # A bundle that loses a library after install: the scheduled pass
      # refuses to run instead of running half a controller.
      chmod u+w "$SC_ROOT/bundles/$(sc_receipt bundle)/lib"; rm -f "$SC_ROOT/bundles/$(sc_receipt bundle)/lib/recovery.sh"
      sc_cli "$SC_BIN" tick
      assert_rc 2 "$SC_RC" "$plat: tick refuses a bundle missing a library"
      assert_match 'recovery.sh is missing' "$SC_OUT" "$plat: and names it"
    ) || exit 1
  done
}

t_uninstall_removes_only_what_install_owns() {
  local plat d
  for plat in $(sc_platforms); do
    (
      sc_env "$plat"
      d="$(dirname "$SC_UNIT")"; mkdir -p "$d" "$HOME/.local/bin"
      printf 'mine\n' >"$d/someone-else.unit"; printf 'mine\n' >"$HOME/.local/bin/other-tool"
      sc_cli "$SC_TREE/health/nice-dns-health" install
      assert_rc 0 "$SC_RC" "$plat: install: $SC_OUT"
      : >"$FAKE_LOG"
      sc_cli "$SC_BIN" uninstall
      assert_rc 0 "$SC_RC" "$plat: uninstall: $SC_OUT"
      assert_no_path "$SC_UNIT" "$plat: the schedule is removed"
      assert_no_path "$SC_BIN" "$plat: the entrypoint is removed"
      assert_no_path "$SC_ROOT" "$plat: the bundles and receipt are removed"
      assert_file "$d/someone-else.unit" "$plat: a neighbour's unit stays"
      assert_file "$HOME/.local/bin/other-tool" "$plat: a neighbour's tool stays"
      if [ "$plat" = linux ]; then
        assert_match '^systemctl --user disable --now nice-dns-health.timer nice-dns-health-bridges.timer$' "$(cat "$FAKE_LOG")" "linux: both timers are stopped first"
        assert_no_path "$XDG_CONFIG_HOME/systemd/user/nice-dns-health.timer" "linux: the timer unit is removed"
      else
        assert_match "^launchctl unload $SC_UNIT\$" "$(cat "$FAKE_LOG")" "macos: the agent is unloaded first"
      fi
    ) || exit 1
  done
}

# The patterns are literal installer text on purpose.
# shellcheck disable=SC2016
t_installers_install_the_controller() {
  # Both platform installers end by installing the controller from their own
  # checkout and fail loudly when it does not install.
  assert_match '"\$SCRIPT_DIR/\.\./health/nice-dns-health" install' "$(cat "$NICE_DNS_ROOT/deb/persistent-podman.sh")" "Linux: persistent-podman.sh installs the controller"
  assert_match '"\$HERE/\.\./health/nice-dns-health" install \|\| \{' "$(cat "$NICE_DNS_ROOT/mac/persist.sh")" "macOS: persist.sh installs the controller and fails when it does not"
  assert_eq "" "$(grep -rn 'StartInterval\|OnUnitActiveSec=30min\|nice-dns-health run' "$NICE_DNS_ROOT/deb" "$NICE_DNS_ROOT/mac" "$NICE_DNS_ROOT"/install-*.sh 2>/dev/null \
    | grep -v 'bridge-eval' | grep -v ':[0-9]*:[[:space:]]*#')" \
    "no installer keeps a second (legacy 30-minute run) controller schedule"
}

t_bash32_installs_and_uninstalls() {
  local w="$CASE_DIR/b32" img=docker.io/library/bash:3.2 out
  if ! podman image exists "$img" 2>/dev/null; then
    fail "image $img is not available locally; the Bash 3.2 proof cannot run (pull it: podman pull $img)"
  fi
  mkdir -p "$w"
  ob_write_stubs "$w/bin"
  ob_fake_data "$w/fake" macos
  cat >"$w/inner.sh" <<'INNER'
set -u
case "$BASH_VERSION" in 3.2.*) ;; *) echo "not bash 3.2: $BASH_VERSION"; exit 90 ;; esac
mkdir -p /tmp/tree /tmp/home && cp -R /src/health /src/lib /src/routes /tmp/tree/ && chmod -R go-w /tmp/tree
# The image has no /bin/bash; the macOS layout's interpreter is given.
PATH="/work/bin:$PATH" FAKE=/work/fake FAKE_LOG=/work/fake/calls.log FAKE_UNAME=Darwin HOME=/tmp/home
ND_HEALTH_INTERPRETER="$(command -v bash)"
export PATH FAKE FAKE_LOG FAKE_UNAME HOME ND_HEALTH_INTERPRETER
bash /tmp/tree/health/nice-dns-health install >/tmp/o 2>&1; echo "install=$?"
bash "$HOME/.local/bin/nice-dns-health" self-check >/tmp/o2 2>&1; echo "self-check=$?"
grep -c '<key>StartCalendarInterval</key>' "$HOME/Library/LaunchAgents/org.nice-dns.health.plist" | sed 's/^/calendar=/'
bash "$HOME/.local/bin/nice-dns-health" uninstall >/tmp/o3 2>&1; echo "uninstall=$?"
[ -e "$HOME/Library/LaunchAgents/org.nice-dns.health.plist" ] && echo agent-left || echo agent-gone
sed 's/^/out: /' /tmp/o /tmp/o2 /tmp/o3
INNER
  out="$(podman run --rm --network none --pull=never -v "$NICE_DNS_ROOT:/src:ro" -v "$w:/work" "$img" bash /work/inner.sh 2>&1)"
  assert_match '^install=0$' "$out" "bash 3.2: install: $out"
  assert_match '^self-check=0$' "$out" "bash 3.2: the installed copy loads"
  assert_match '^calendar=1$' "$out" "bash 3.2: the agent runs every minute"
  assert_match '^uninstall=0$' "$out" "bash 3.2: uninstall"
  assert_match '^agent-gone$' "$out" "bash 3.2: the agent is removed"
}

t_installed_controller_reads_its_timers_from_the_tunables_file() {
  # The scheduled pass has no environment of its own, so a test (or an
  # operator) sets the policy timers in <install root>/tunables.tsv: only
  # ND_POLICY_{STARTUP,GRACE,COOLDOWN}_S, 1..86400, in a private regular
  # file. The live gate uses 30 s in its extra configurations (user
  # decision, 2026-09-26) and the real timers in one per machine.
  local plat now st
  for plat in $(sc_platforms); do
    (
      sc_env "$plat"
      sc_cli "$SC_TREE/health/nice-dns-health" install --shadow
      assert_rc 0 "$SC_RC" "$plat: install: $SC_OUT"
      for p in 18531 18532 18533 853; do echo servfail >"$FAKE/probe/$p"; done
      now="$(date +%s)"
      if [ "$plat" = macos ]; then st="$HOME/Library/Application Support/nice-dns/controller/shadow"; else st="$XDG_STATE_HOME/nice-dns/controller/shadow"; fi
      mkdir -p "$st" && chmod 700 "$(dirname "$st")" "$st"
      printf 'schema\tnice-dns-controller-state/1\ngeneration\t1\nboot_id\tboot-a\nupdated\t%s\nstarted\t%s\nroute\tcloudflare-exit\noutage_since\t%s\noutage_restarts\t0\nlast_action\t-\nlast_action_at\t-\nrecovery_at\t-\n' \
        "$((now - 60))" "$((now - 7200))" "$((now - 60))" >"$st/state.tsv"; chmod 600 "$st/state.tsv"
      export ND_BOOT_ID=boot-a
      sc_cli "$SC_BIN" tick --shadow
      assert_match '^action	no-op$' "$SC_OUT" "$plat: a 60 s outage is inside the default 300 s grace: $SC_OUT"
      printf 'ND_POLICY_GRACE_S\t30\nND_POLICY_COOLDOWN_S\t30\nND_POLICY_STARTUP_S\t30\nND_POLICY_LADDER_S\t60\n' >"$SC_ROOT/tunables.tsv"; chmod 600 "$SC_ROOT/tunables.tsv"
      sc_cli "$SC_BIN" tick --shadow
      assert_match '^action	restart-component$' "$SC_OUT" "$plat: with a 30 s grace from the tunables file (the ladder hold is an allowed key too) the same outage restarts"
      printf 'ND_POLICY_GRACE_S\t30\nPATH\t/tmp\n' >"$SC_ROOT/tunables.tsv"
      sc_cli "$SC_BIN" tick --shadow
      assert_match 'tunables' "$SC_OUT" "$plat: an unknown key refuses the file, and says so"
      printf 'ND_POLICY_GRACE_S\t30\n' >"$SC_ROOT/tunables.tsv"; chmod 666 "$SC_ROOT/tunables.tsv"
      sc_cli "$SC_BIN" tick --shadow
      assert_match 'tunables' "$SC_OUT" "$plat: a group- or world-writable file is refused"
    ) || exit 1
  done
}

# Sub-plan 5 Task 1.4 (fix A): every launch path runs <controller root>/
# route-start before Unbound starts; it runs the installed controller's
# route-start, which demotes a persisted onion to the exit (lib/recovery.sh
# start_route). Only an active controller acts; shadow records, never acts.
t_route_start_launcher_demotes_an_onion_only_when_active() {
  local plat
  for plat in $(sc_platforms); do
    (
      local seed info
      sc_env "$plat"
      sc_launch() { SC_OUT="$(sh "$SC_ROOT/route-start" 2>&1)"; SC_RC=$?; }
      seed() { ND_PLATFORM="$plat" bash -c '. "$1/lib/recovery.sh" && seed_route cloudflare-onion 4' _ "$SC_TREE" >/dev/null; }
      info() { ND_PLATFORM="$plat" bash -c '. "$1/lib/recovery.sh" && _nd_route_file_info "$(nd_platform_route_dir)/forward-route.conf" | cut -f1,2' _ "$SC_TREE"; }
      sc_cli "$SC_TREE/health/nice-dns-health" install --shadow
      assert_rc 0 "$SC_RC" "$plat: install --shadow: $SC_OUT"
      assert_file "$SC_ROOT/route-start" "$plat: the launcher is written with the receipt"
      assert_eq 755 "$(stat -c %a "$SC_ROOT/route-start")" "$plat: executable, not group- or world-writable"
      seed
      assert_eq "cloudflare-onion	4" "$(info)" "$plat: an onion include, as the controller left it"
      sc_launch
      assert_rc 0 "$SC_RC" "$plat: the launcher never fails its caller: $SC_OUT"
      assert_eq "cloudflare-onion	4" "$(info)" "$plat: a shadow controller never acts"
      sc_cli "$SC_TREE/health/nice-dns-health" install
      assert_rc 0 "$SC_RC" "$plat: activation: $SC_OUT"
      sc_launch
      assert_rc 0 "$SC_RC" "$plat: active: $SC_OUT"
      assert_eq "cloudflare-exit	5" "$(info)" "$plat: an active controller demotes the onion to the exit at the next generation"
      assert_match 'ROUTE-START result=applied route=cloudflare-exit generation=5' "$(cat "$(dirname "$SC_ROOT")/../Logs/nice-dns-health/health.log" "$XDG_STATE_HOME/nice-dns-health/health.log" 2>/dev/null)" "$plat: the controller log records it"
      # A receipt the launcher must not trust, or cannot use: nothing runs,
      # and it still succeeds (Tier-1 review S6). The onion is back first.
      rm -f "$(ND_PLATFORM="$plat" bash -c '. "$1/lib/platform/'"$plat"'.sh" && nd_platform_route_dir' _ "$SC_TREE")"/forward-route.conf \
        "$(ND_PLATFORM="$plat" bash -c '. "$1/lib/platform/'"$plat"'.sh" && nd_platform_route_dir' _ "$SC_TREE")"/desired.tsv
      seed
      mv "$SC_ROOT/install.tsv" "$SC_ROOT/install.tsv.away"
      sc_launch
      assert_rc 0 "$SC_RC" "$plat: without a receipt the launcher does nothing and still succeeds: $SC_OUT"
      ln -s install.tsv.away "$SC_ROOT/install.tsv"
      sc_launch
      assert_rc 0 "$SC_RC" "$plat: a symlinked receipt: $SC_OUT"
      rm -f "$SC_ROOT/install.tsv"
      sed '1s/.*/schema\tsomething-else\/1/' "$SC_ROOT/install.tsv.away" >"$SC_ROOT/install.tsv"
      sc_launch
      assert_rc 0 "$SC_RC" "$plat: a receipt of another schema: $SC_OUT"
      awk -F '\t' -v OFS='\t' '$1 == "entrypoint" { $2 = "/nonexistent/nice-dns-health" } { print }' "$SC_ROOT/install.tsv.away" >"$SC_ROOT/install.tsv"
      sc_launch
      assert_rc 0 "$SC_RC" "$plat: a receipt whose entrypoint is gone: $SC_OUT"
      assert_eq "cloudflare-onion	4" "$(info)" "$plat: none of them ran the controller"
      mv -f "$SC_ROOT/install.tsv.away" "$SC_ROOT/install.tsv"
      sc_cli "$SC_BIN" uninstall
      assert_no_path "$SC_ROOT/route-start" "$plat: uninstall removes the launcher"
    ) || exit 1
  done
}

t_quadlets_leave_chain_restarts_to_the_controller() {
  # Close-out evaluator B1 and M2 (Sub-plan 3). The controller is the only
  # actor that restarts the Tor proxy or Unbound for a chain fault (ARCH-02,
  # Stage 1's single owner). Podman's HealthOnFailure=restart on a loopback
  # `nc -z` was a second restart owner that never saw the real fault: in
  # Sub-plan 1's live freeze it stayed green, then restarted Unbound and
  # Pi-hole while the frozen proxy was left alone. So:
  #  - the proxy and Unbound health checks verify the chain (the image's
  #    route probe; Unbound's own authenticated probe-route) and only report;
  #  - Unbound and Pi-hole do not Require= the unit before them, because an
  #    explicit restart of a required unit restarts its dependents
  #    (systemd.unit(5), Requires=): the controller's proxy restart would
  #    otherwise drop Unbound's cache and restart Pi-hole.
  # Checked on the units Podman's own generator writes, per variant, as
  # deb/persistent-podman.sh installs them. The generator escapes spaces in
  # --health-cmd as \x20, so each unit is unescaped before it is matched.
  local gen="${NICE_DNS_QUADLET:-/usr/libexec/podman/quadlet}" q v u out unit
  [ -x "$gen" ] || { echo "SKIP-REASON: no podman quadlet generator at $gen" >&2; return 1; }
  for v in haproxy socat; do
    q="$CASE_DIR/quadlet-$v"; mkdir -p "$q"
    cp "$NICE_DNS_ROOT"/deb/quadlet/{nice-dns.network,nice-dns.pod,unbound.container,pi-hole.container,tor-$v.container} "$q/"
    sed -i "s/__VARIANT__/$v/g" "$q/unbound.container"
    out="$(QUADLET_UNIT_DIRS="$q" "$gen" -dryrun -user 2>&1)" || { echo "$out" >&2; assert_eq 0 1 "$v: the quadlet generator accepts the units"; }
    for u in tor-$v unbound; do
      unit="$(printf '%s\n' "$out" | awk -v s="---$u.service---" '$0 == s { p = 1; next } /^---.*---$/ { p = 0 } p' | sed 's/\\x20/ /g')"
      assert_match 'ExecStart=.*--health-on-failure none' "$unit" "$v: $u's health check never restarts it (the controller owns that)"
      assert_not_match 'nc -z 127\.0\.0\.1' "$(printf '%s\n' "$unit" | grep '^ExecStart=')" "$v: $u's health check is not a loopback port check"
    done
    unit="$(printf '%s\n' "$out" | awk -v s="---tor-$v.service---" '$0 == s { p = 1; next } /^---.*---$/ { p = 0 } p' | sed 's/\\x20/ /g')"
    assert_match 'health-cmd .*nice-dns-route-probe 853 tor\.cloudflare-dns\.com' "$unit" "$v: the proxy health check is the image's verifying route probe"
    unit="$(printf '%s\n' "$out" | awk '$0 == "---unbound.service---" { p = 1; next } /^---.*---$/ { p = 0 } p' | sed 's/\\x20/ /g')"
    assert_match 'health-cmd .*unbound-control .*status.*nice-dns-unbound-start probe-route' "$unit" "$v: Unbound's health check needs Unbound answering control and its authenticated route resolving"
    assert_not_match '^Requires=tor-' "$unit" "$v: a proxy restart does not restart Unbound"
    assert_match "^Wants=tor-$v\\.service" "$unit" "$v: Unbound still pulls in its proxy"
    assert_match "^After=tor-$v\\.service" "$unit" "$v: and starts after it"
    unit="$(printf '%s\n' "$out" | awk '$0 == "---pi-hole.service---" { p = 1; next } /^---.*---$/ { p = 0 } p' | sed 's/\\x20/ /g')"
    assert_not_match '^Requires=unbound' "$unit" "$v: an Unbound restart does not restart Pi-hole"
    assert_match '^Wants=unbound\.service' "$unit" "$v: Pi-hole still pulls in Unbound"
    assert_match '^After=unbound\.service' "$unit" "$v: and starts after it"
  done
}
