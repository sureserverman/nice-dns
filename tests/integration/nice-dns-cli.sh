# shellcheck shell=bash
# Group integration/nice-dns-cli (command-and-unbound-recovery plan, Stage 2).
# The `nice-dns` command against stub install scripts and fake platform tools,
# on both faked `uname` values. Nothing here touches the host: HOME is the
# case's directory, and every tool the command calls is a logging stub.
#
# Sourced by tests/run.sh (assert_* helpers; NICE_DNS_ROOT, CASE_DIR).

cl_platforms() { printf 'Linux Darwin\n'; }
cl_os() { if [ "$1" = Linux ]; then echo deb; else echo mac; fi; }

# cl_world <uname>: HOME, the fake tools and a checkout whose install scripts
# only log. CL_LOG holds every call in order.
cl_world() {
  local real_uname s
  CL_UNAME="$1"
  CL_W="$CASE_DIR/w-$1"
  CL_HOME="$CL_W/home" CL_FAKE="$CL_W/fake" CL_TREE="$CL_W/tree" CL_LOG="$CL_W/calls.log"
  rm -rf "$CL_W"
  mkdir -p "$CL_HOME/.local/bin" "$CL_FAKE" "$CL_TREE"
  : >"$CL_LOG"
  real_uname="$(command -v uname)"
  cat >"$CL_FAKE/uname" <<EOF
#!/bin/bash
if [ "\${1:-}" = -s ]; then echo "$1"; else exec "$real_uname" "\$@"; fi
EOF
  for s in git systemctl launchctl dig podman container sudo networksetup mullvad; do
    cat >"$CL_FAKE/$s" <<EOF
#!/bin/bash
echo "$s \$*" >>"$CL_LOG"
FAKE="$CL_FAKE"
case "$s" in
  dig) [ -f "\$FAKE/no_dns" ] && exit 9; echo 1.2.3.4 ;;
  launchctl)
    case "\$*" in
      *kickstart*)
        [ -f "\$FAKE/agent_stuck" ] || rm -f "\$HOME/.local/state/nice-dns/restart-requested"
        [ -f "\$FAKE/restart_rc" ] && { echo "the restart broke" >&2; exit "\$(cat "\$FAKE/restart_rc")"; } ;;
      print*) [ -f "\$FAKE/agent_stuck" ] && printf '\tstate = running\n'; [ -f "\$FAKE/agent_stuck" ] || printf '\tstate = not running\n' ;;
    esac ;;
  systemctl)
    case "\$*" in
      *is-active*) exit 0 ;;
      *restart*) [ -f "\$FAKE/restart_rc" ] && { echo "the restart broke" >&2; exit "\$(cat "\$FAKE/restart_rc")"; } ;;
    esac ;;
  git)
    [ -f "\$FAKE/clone_fails" ] && exit 128
    case "\$*" in
      *rev-parse*) [ -f "\$FAKE/git_branch" ] && cat "\$FAKE/git_branch" ;;
      *clone*)
        for last; do :; done
        mkdir -p "\$last"
        cp "\$FAKE"/../tree/install-*.sh "\$last/"
        mkdir -p "\$last/lib"; : >"\$last/lib/install.sh"
        echo cloned >"\$last/from-clone" ;;
    esac ;;
esac
exit 0
EOF
  done
  chmod +x "$CL_FAKE"/*
  cp "$NICE_DNS_ROOT/nice-dns" "$CL_TREE/nice-dns"
  mkdir -p "$CL_TREE/lib"
  cp -R "$NICE_DNS_ROOT/lib/." "$CL_TREE/lib/"
  for s in install-deb install-deb-hardened install-mac install-mac-hardened; do
    cat >"$CL_TREE/$s.sh" <<EOF
#!/bin/bash
where=checkout
[ -f "\$(dirname "\$0")/from-clone" ] && where=clone
case "\$0" in *"/.local/share/nice-dns/source/"*) where=snapshot ;; esac
echo "installer[\$where] $s.sh \$*" >>"$CL_LOG"
[ -z "\${ND_INST_HARDENED_SIBLING:-}" ] || echo "sibling \$ND_INST_HARDENED_SIBLING" >>"$CL_LOG"
exit "\${CL_INSTALLER_RC:-0}"
EOF
  done
}

# cl_installed: the world as an install leaves it: the command alone on PATH,
# the source kept beside it.
cl_installed() {
  mkdir -p "$CL_HOME/.local/share/nice-dns"
  cp -R "$CL_TREE" "$CL_HOME/.local/share/nice-dns/source"
  cp "$CL_TREE/nice-dns" "$CL_HOME/.local/bin/nice-dns"
  CL_CMD="$CL_HOME/.local/bin/nice-dns"
}

# cl_record <variant> <pihole> <branch>: a current generation.
cl_record() {
  local sd
  if [ "$CL_UNAME" = Linux ]; then sd="$CL_HOME/.local/state/nice-dns-install"; else sd="$CL_HOME/Library/Application Support/nice-dns-install"; fi
  mkdir -p "$sd/generations/g1"
  printf 'g1\n' >"$sd/current"
  printf 'schema\tnice-dns-install-prepare/1\nvariant\t%s\npihole\t%s\nbranch\t%s\n' "$1" "$2" "$3" >"$sd/generations/g1/prepare.tsv"
}

# cl_run <command path> <args...>: CL_OUT, CL_ERR, CL_RC.
cl_run() {
  local cmd="$1"
  shift
  HOME="$CL_HOME" PATH="$CL_FAKE:$PATH" TMPDIR="$CASE_DIR" XDG_STATE_HOME="" XDG_CONFIG_HOME="" XDG_DATA_HOME="" bash "$cmd" "$@" >"$CL_W/out" 2>"$CL_W/err"
  CL_RC=$?
  CL_OUT="$(cat "$CL_W/out")" CL_ERR="$(cat "$CL_W/err")"
}

cl_calls() { grep -E "$1" "$CL_LOG" || true; }

# ─────────────────────────── Task 2.1: the dispatcher ───────────────────────

t_each_command_reaches_the_right_script() {
  local u os
  for u in $(cl_platforms); do
    cl_world "$u"; os="$(cl_os "$u")"
    cl_run "$CL_TREE/nice-dns" install
    assert_rc 0 "$CL_RC" "$u: install: $CL_ERR"
    assert_eq "installer[checkout] install-$os.sh haproxy main" "$(cl_calls '^installer')" "$u: install defaults"
    : >"$CL_LOG"
    cl_run "$CL_TREE/nice-dns" install socat --hardened --branch dev
    assert_eq "installer[clone] install-$os-hardened.sh socat dev" "$(cl_calls '^installer')" "$u: --branch installs that branch, from a clone"
    : >"$CL_LOG"
    cl_run "$CL_TREE/nice-dns" uninstall
    assert_rc 0 "$CL_RC" "$u: uninstall: $CL_ERR"
    assert_eq "installer[checkout] install-$os.sh uninstall" "$(cl_calls '^installer')" "$u: uninstall delegates"
  done
}

t_an_installer_failure_is_the_commands_failure() {
  cl_world Linux
  CL_INSTALLER_RC=7 cl_run "$CL_TREE/nice-dns" install
  assert_rc 7 "$CL_RC" "the installer's exit comes through"
}

t_installed_command_uses_the_kept_source() {
  local u os
  for u in $(cl_platforms); do
    cl_world "$u"; os="$(cl_os "$u")"; cl_installed
    cl_run "$CL_CMD" uninstall
    assert_eq "installer[snapshot] install-$os.sh uninstall" "$(cl_calls '^installer')" "$u: the snapshot uninstalls"
  done
}

t_root_is_refused_with_the_installers_message() {
  local msg
  cl_world Linux
  printf '#!/bin/bash\necho 0\n' >"$CL_FAKE/id"; chmod +x "$CL_FAKE/id"
  cl_run "$CL_TREE/nice-dns" install
  assert_rc 1 "$CL_RC" "root is refused"
  assert_eq "Please run nice-dns as a regular user, not with sudo." "$CL_ERR" "the message"
  assert_eq "" "$(cl_calls .)" "nothing ran"
  msg="$(grep -F 'as a regular user, not with sudo.' "$NICE_DNS_ROOT/install-deb.sh" | head -n 1)"
  assert_match 'as a regular user, not with sudo\.' "$msg" "the installers word it the same"
}

t_unknown_commands_and_options_are_usage_errors() {
  local args
  cl_world Linux
  for args in "" "frobnicate" "install --nope" "install --local" "install --standard" "install haproxy socat" \
              "install --branch" "install --branch --hardened" "uninstall --hardened" "restart --hardened" "reinstall --nope"; do
    # shellcheck disable=SC2086  # each row is a word list
    cl_run "$CL_TREE/nice-dns" $args
    assert_rc 2 "$CL_RC" "[$args] is a usage error"
    assert_match '^Usage: nice-dns' "$CL_ERR" "[$args]: usage on stderr"
    assert_eq "" "$CL_OUT" "[$args]: nothing on stdout"
    assert_eq "" "$(cl_calls .)" "[$args]: nothing ran"
  done
}

t_unsupported_platform_is_refused() {
  cl_world FreeBSD
  cl_run "$CL_TREE/nice-dns" install
  assert_rc 1 "$CL_RC" "refused"
  assert_match "unsupported platform 'FreeBSD'" "$CL_ERR" "the message"
}

# The sweep the Stage 2 gate names: macOS runs this under Bash 3.2.
t_command_keeps_to_bash_32_syntax() {
  local hits
  hits="$(grep -nE 'declare -A|mapfile|readarray|\$\{[A-Za-z_][A-Za-z_0-9]*(,,|\^\^)' "$NICE_DNS_ROOT/nice-dns" || true)"
  assert_eq "" "$hits" "no Bash 4 syntax in nice-dns"
  bash -n "$NICE_DNS_ROOT/nice-dns" || fail "nice-dns does not parse"
}

# ─────────────────────────── Task 2.3: reinstall ────────────────────────────

t_reinstall_uses_the_recorded_choices() {
  local u os
  for u in $(cl_platforms); do
    cl_world "$u"; os="$(cl_os "$u")"; cl_record socat hardened dev
    cl_run "$CL_TREE/nice-dns" reinstall
    assert_rc 0 "$CL_RC" "$u: reinstall: $CL_ERR"
    assert_eq "installer[checkout] install-$os-hardened.sh socat dev" "$(cl_calls '^installer')" "$u: the record reaches the hardened script"
    assert_eq "" "$(cl_calls '^git ')" "$u: a checkout does not clone"
  done
}

t_reinstall_flags_override_the_record() {
  cl_world Linux; cl_record socat hardened dev
  cl_run "$CL_TREE/nice-dns" reinstall haproxy --standard --branch main
  assert_eq "installer[clone] install-deb.sh haproxy main" "$(cl_calls '^installer')" "every flag overrides; a named branch comes from a clone"
  : >"$CL_LOG"
  cl_run "$CL_TREE/nice-dns" reinstall --branch next
  assert_eq "installer[clone] install-deb-hardened.sh socat next" "$(cl_calls '^installer')" "one flag leaves the rest recorded"
  : >"$CL_LOG"
  cl_run "$CL_TREE/nice-dns" reinstall haproxy --standard
  assert_eq "installer[checkout] install-deb.sh haproxy dev" "$(cl_calls '^installer')" "with no branch named, the checkout installs itself"
  cl_run "$CL_TREE/nice-dns" reinstall --local --branch next
  assert_rc 2 "$CL_RC" "--local with --branch is a usage error"
}

t_installed_reinstall_clones_the_recorded_branch() {
  cl_world Linux; cl_installed; cl_record socat standard dev
  cl_run "$CL_CMD" reinstall
  assert_rc 0 "$CL_RC" "reinstall: $CL_ERR"
  assert_match '^git .*clone .*-b dev ' "$(cl_calls '^git ')" "the recorded branch is cloned"
  assert_eq "installer[clone] install-deb.sh socat dev" "$(cl_calls '^installer')" "the clone's installer runs"
  assert_eq "" "$(find "$CASE_DIR" -maxdepth 1 -name 'nice-dns-fetch.*')" "the clone is removed afterwards"
}

t_failed_clone_names_local_and_changes_nothing() {
  cl_world Darwin; cl_installed; cl_record haproxy standard main
  : >"$CL_FAKE/clone_fails"
  cl_run "$CL_CMD" reinstall
  assert_rc 1 "$CL_RC" "a failed clone fails"
  assert_match 'nice-dns reinstall --local' "$CL_ERR" "it names --local"
  assert_match 'running stack is untouched' "$CL_ERR" "it says the stack is untouched"
  assert_eq "" "$(cl_calls '^installer')" "no installer ran"
  assert_eq "" "$(find "$CASE_DIR" -maxdepth 1 -name 'nice-dns-fetch.*')" "no clone is left"
}

t_reinstall_local_uses_the_snapshot_with_no_clone() {
  cl_world Linux; cl_installed; cl_record haproxy standard main
  : >"$CL_FAKE/clone_fails"
  cl_run "$CL_CMD" reinstall --local
  assert_rc 0 "$CL_RC" "--local: $CL_ERR"
  assert_eq "installer[snapshot] install-deb.sh haproxy main" "$(cl_calls '^installer')" "the snapshot's installer runs"
  assert_eq "" "$(cl_calls '^git ')" "nothing is cloned"
  rm -rf "$CL_HOME/.local/share/nice-dns/source"
  : >"$CL_LOG"
  cl_run "$CL_CMD" reinstall --local
  assert_rc 1 "$CL_RC" "--local with no snapshot fails"
  assert_match 'no kept source' "$CL_ERR" "and says so"
}

t_reinstall_and_restart_with_nothing_installed() {
  local u cmd
  for u in $(cl_platforms); do
    for cmd in reinstall restart; do
      cl_world "$u"
      cl_run "$CL_TREE/nice-dns" "$cmd"
      assert_rc 1 "$CL_RC" "$u $cmd: exit 1"
      assert_match 'nice-dns is not installed; run `nice-dns install`' "$CL_ERR" "$u $cmd: the message"
      assert_eq "" "$(cl_calls .)" "$u $cmd: nothing ran"
    done
  done
}

# The installers ignore their branch argument in a checkout, so what is recorded
# must be what was installed (review, 2026-10-31).
t_a_named_branch_is_what_gets_installed_and_recorded() {
  cl_world Linux
  printf 'feature\n' >"$CL_FAKE/git_branch"
  cl_run "$CL_TREE/nice-dns" install
  assert_eq "installer[checkout] install-deb.sh haproxy feature" "$(cl_calls '^installer')" "a checkout records its own branch"
  rm -f "$CL_FAKE/git_branch"
  : >"$CL_LOG"
  : >"$CL_FAKE/clone_fails"
  cl_run "$CL_TREE/nice-dns" install --branch dev
  assert_rc 1 "$CL_RC" "a branch that cannot be fetched fails"
  assert_eq "" "$(cl_calls '^installer')" "and installs nothing"
}

t_hardened_off_a_clone_or_the_kept_source_finds_its_sibling() {
  local sd
  cl_world Linux; cl_installed; cl_record haproxy standard main
  cl_run "$CL_CMD" reinstall --hardened --local
  assert_eq "sibling $CL_HOME/.local/share/nice-dns/pi-hole-hardened" "$(cl_calls '^sibling')" "nothing recorded: a stable place the refusal can name"
  sd="$CL_HOME/.local/state/nice-dns-install"
  mkdir -p "$CL_W/mine/pi-hole-hardened"; : >"$CL_W/mine/pi-hole-hardened/Dockerfile"
  printf 'source\thardened-base\t%s@abc\n' "$CL_W/mine/pi-hole-hardened" >>"$sd/generations/g1/prepare.tsv"
  : >"$CL_LOG"
  cl_run "$CL_CMD" reinstall --hardened
  assert_eq "sibling $CL_W/mine/pi-hole-hardened" "$(cl_calls '^sibling')" "the recorded one"
  cl_world Linux; cl_record haproxy standard main
  cl_run "$CL_TREE/nice-dns" install --hardened --branch dev
  assert_eq "sibling $CL_W/pi-hole-hardened" "$(cl_calls '^sibling')" "a checkout's neighbour, for its clone"
  : >"$CL_LOG"
  cl_run "$CL_TREE/nice-dns" install --hardened
  assert_eq "" "$(cl_calls '^sibling')" "a checkout's own run is the installer's business"
  (
    # shellcheck disable=SC2034  # read by the sourced lib/install.sh
    ND_INST_SRC="$CL_TREE" ND_INST_HARDENED_SIBLING="$CL_W/mine/pi-hole-hardened" ND_INST_PLATFORM=linux
    # shellcheck source=lib/install.sh
    . "$CL_TREE/lib/install.sh"
    mkdir -p "$CL_W/mine/pi-hole-hardened"
    : >"$CL_W/mine/pi-hole-hardened/Dockerfile"; : >"$CL_W/mine/pi-hole-hardened/post-install.sh"
    # shellcheck disable=SC2034
    ND_INST_MANIFEST=/dev/null
    _nd_inst_manifest_row() { return 0; }
    assert_eq "$CL_W/mine/pi-hole-hardened" "$(_nd_inst_hardened_sibling 2>/dev/null)" "the library honours the name it is given"
  ) || exit 1
}

t_reinstall_refuses_an_unreadable_record() {
  cl_world Linux; cl_record "" standard main
  cl_run "$CL_TREE/nice-dns" reinstall
  assert_rc 1 "$CL_RC" "no variant in the record"
  assert_eq "" "$(cl_calls '^installer')" "no installer ran"
  : >"$CL_LOG"
  cl_run "$CL_TREE/nice-dns" reinstall socat
  assert_rc 0 "$CL_RC" "a flag supplies it: $CL_ERR"
}

# ─────────────────────────── Task 2.4: restart ──────────────────────────────

# cl_restart_world <uname>: an installed stack with the controller's schedules.
cl_restart_world() {
  cl_world "$1"; cl_record haproxy standard main
  CL_RESTART_PLAT=linux
  if [ "$1" = Darwin ]; then
    CL_RESTART_PLAT=macos
    mkdir -p "$CL_HOME/Library/LaunchAgents"
    : >"$CL_HOME/Library/LaunchAgents/org.nice-dns.health.plist"
    : >"$CL_HOME/Library/LaunchAgents/org.nice-dns.health-bridges.plist"
  fi
}

# Lines of the log: hold, the one restart, release.
cl_hold_pat() { if [ "$CL_RESTART_PLAT" = linux ]; then echo '^systemctl --user stop nice-dns-health'; else echo '^launchctl unload .*org\.nice-dns\.health'; fi; }
cl_restart_pat() { if [ "$CL_RESTART_PLAT" = linux ]; then echo '^systemctl --user restart nice-dns-pod\.service'; else echo '^launchctl kickstart -k gui/'; fi; }
cl_release_pat() { if [ "$CL_RESTART_PLAT" = linux ]; then echo '^systemctl --user start nice-dns-health'; else echo '^launchctl load .*org\.nice-dns\.health'; fi; }
cl_line() { grep -nE "$1" "$CL_LOG" | "$2" -n 1 | cut -d: -f1; }

cl_assert_released() {
  assert_eq 2 "$(grep -cE "$(cl_release_pat)" "$CL_LOG")" "$1: both schedules are released"
}

t_restart_runs_once_between_hold_and_release() {
  local u last_hold rs first_rel
  for u in $(cl_platforms); do
    cl_restart_world "$u"
    cl_run "$CL_TREE/nice-dns" restart
    assert_rc 0 "$CL_RC" "$u: restart: $CL_ERR"
    assert_match 'DNS is answering' "$CL_OUT" "$u: it reports the result"
    assert_eq 1 "$(grep -cE "$(cl_restart_pat)" "$CL_LOG")" "$u: one restart"
    last_hold="$(cl_line "$(cl_hold_pat)" tail)"; rs="$(cl_line "$(cl_restart_pat)" head)"; first_rel="$(cl_line "$(cl_release_pat)" head)"
    [ -n "$last_hold" ] && [ "$last_hold" -lt "$rs" ] || fail "$u: the hold comes first:
$(cat "$CL_LOG")"
    [ "$rs" -lt "$first_rel" ] || fail "$u: the release comes after the wait:
$(cat "$CL_LOG")"
    cl_assert_released "$u"
    assert_eq "" "$(cl_calls '^(sudo|networksetup|mullvad) ')" "$u: no resolver command ran"
  done
}

t_restart_without_an_answer_says_so_and_releases() {
  local u
  for u in $(cl_platforms); do
    cl_restart_world "$u"
    : >"$CL_FAKE/no_dns"
    ND_INST_READY_TRIES=1 cl_run "$CL_TREE/nice-dns" restart
    assert_rc 1 "$CL_RC" "$u: no answer is a failure"
    assert_match 'DNS is not answering yet' "$CL_ERR" "$u: the message"
    assert_match 'nice-dns-health status' "$CL_ERR" "$u: it names the status command"
    assert_not_match 'not pinning' "$CL_ERR" "$u: not the installer's wording"
    cl_assert_released "$u"
  done
}

# kickstart returns at once and the old stack can still answer (review, 2026-10-31).
t_macos_restart_waits_for_the_rebuild_before_checking_dns() {
  cl_restart_world Darwin
  : >"$CL_FAKE/agent_stuck"
  ND_CLI_REBUILD_S=1 ND_INST_READY_TRIES=1 cl_run "$CL_TREE/nice-dns" restart
  assert_rc 1 "$CL_RC" "a rebuild still running is not a success: $CL_OUT"
  assert_eq "" "$(cl_calls '^dig ')" "DNS is not checked against the old stack"
  assert_match 'not answering yet' "$CL_ERR" "the message"
  cl_assert_released Darwin
}

t_restart_failure_is_reported_and_releases() {
  cl_restart_world Linux
  echo 5 >"$CL_FAKE/restart_rc"
  cl_run "$CL_TREE/nice-dns" restart
  assert_rc 1 "$CL_RC" "a failed restart fails"
  assert_match 'exit 5.*the restart broke' "$CL_ERR" "with the reason"
  assert_eq "" "$(cl_calls '^dig ')" "no wait after a failed restart"
  cl_assert_released Linux
}

t_restart_releases_on_a_signal() {
  local u pid i
  for u in $(cl_platforms); do
    cl_restart_world "$u"
    : >"$CL_FAKE/no_dns"
    HOME="$CL_HOME" PATH="$CL_FAKE:$PATH" TMPDIR="$CASE_DIR" XDG_STATE_HOME="" ND_INST_READY_TRIES=50 \
      bash "$CL_TREE/nice-dns" restart >"$CL_W/out" 2>"$CL_W/err" &
    pid=$!
    i=0
    until grep -q '^dig ' "$CL_LOG"; do
      i=$((i + 1)); [ "$i" -lt 100 ] || { kill "$pid" 2>/dev/null; fail "$u: the wait never began"; }
      sleep 0.1
    done
    kill -TERM "$pid"
    wait "$pid"
    assert_rc 143 "$?" "$u: the signal ends it"
    cl_assert_released "$u"
    assert_eq "" "$(find "$CASE_DIR" -maxdepth 1 -name 'nice-dns-restart.*')" "$u: its temporary directory is gone"
  done
}

# Stopping a timer does not end a pass already running: the state lock is what
# keeps a restart and a controller action apart.
t_restart_waits_for_a_running_pass_and_gives_up_cleanly() {
  local d="$CASE_DIR/state-busy"
  cl_restart_world Linux
  mkdir -p "$d"; chmod 700 "$d"
  ln -s "nd-lock:$$:$(cat /proc/sys/kernel/random/boot_id):$(date +%s):tok" "$d/lock"
  ND_STATE_DIR="$d" ND_CLI_LOCK_TRIES=1 cl_run "$CL_TREE/nice-dns" restart
  assert_rc 1 "$CL_RC" "a busy controller refuses: $CL_ERR"
  assert_match 'still busy; nothing was restarted' "$CL_ERR" "the message"
  assert_eq 0 "$(grep -cE "$(cl_restart_pat)" "$CL_LOG")" "no restart while a pass runs"
  cl_assert_released Linux
  rm -f "$d/lock"
  : >"$CL_LOG"
  ND_STATE_DIR="$d" ND_CLI_LOCK_TRIES=1 cl_run "$CL_TREE/nice-dns" restart
  assert_rc 0 "$CL_RC" "a free lock restarts: $CL_ERR"
  assert_eq "" "$(readlink "$d/lock" 2>/dev/null)" "the lock is given back"
}

# Live 2026-10-31: 120 tries of 5 s took 935 s, each with its dig on top, while
# the error said 600 s and `restart` held the controller throughout.
t_the_readiness_wait_keeps_to_its_stated_limit() {
  local t0 out rc took
  t0="$(date +%s)"
  out="$(
    sed -n '/^nd_install_wait_ready() {/,/^}/p' "$NICE_DNS_ROOT/lib/install.sh" >"$CASE_DIR/wait.sh"
    # shellcheck disable=SC1091
    . "$CASE_DIR/wait.sh"
    _nd_inst_dns_addr() { echo 127.0.0.1; }
    _nd_inst_route_probe() { return 0; }
    _nd_inst_err() { printf '%s\n' "$1"; }
    dig() { command sleep 8; }
    sleep() { :; }
    ND_INST_PROBE_NAME=example.com ND_INST_READY_TRIES=4
    nd_install_wait_ready
  )"; rc=$?
  took=$(( $(date +%s) - t0 ))
  assert_rc 1 "$rc" "no answer fails: $out"
  assert_match "within 20 s" "$out" "the message states the limit"
  # Four 8 s attempts by count alone take 32 s; the limit stops it at the third.
  [ "$took" -le 26 ] || fail "the wait took ${took}s against a 20 s limit"
  out="$(
    # shellcheck disable=SC1091
    . "$CASE_DIR/wait.sh"
    _nd_inst_dns_addr() { echo 127.0.0.1; }
    _nd_inst_route_probe() { return 0; }
    _nd_inst_err() { printf '%s\n' "$1"; }
    dig() { echo 1.2.3.4; }
    sleep() { :; }
    ND_INST_PROBE_NAME=example.com ND_INST_READY_TRIES=1
    nd_install_wait_ready
  )"
  assert_rc 0 "$?" "an answer passes: $out"
  # A count of tries still ends the wait where sleep is faked.
  t0="$(date +%s)"
  (
    # shellcheck disable=SC1091
    . "$CASE_DIR/wait.sh"
    _nd_inst_dns_addr() { echo 127.0.0.1; }
    _nd_inst_err() { :; }
    dig() { :; }
    sleep() { :; }
    ND_INST_PROBE_NAME=example.com ND_INST_READY_TRIES=120
    nd_install_wait_ready
  ) >/dev/null
  assert_rc 1 "$?" "a wait that never answers ends"
  [ $(( $(date +%s) - t0 )) -lt 5 ] || fail "with sleep faked the tries end it at once"
}

# ─────────────── Status and update plan, Task 1.2: the status rows ──────────

# st_world <uname>: the files a host with a working stack holds, under the
# case's HOME: the install's generation, the controller's receipt, state,
# journal and last observations, the bridge files and the schedule. Sets
# ST_PLAT, ST_SD (the controller's state directory), ST_NOW.
st_world() {
  local rd i
  cl_world "$1"; cl_record haproxy standard main
  ST_NOW=1800000000
  if [ "$1" = Linux ]; then
    ST_PLAT=linux ST_INST="$CL_HOME/.local/state/nice-dns-install" ST_SD="$CL_HOME/.local/state/nice-dns/controller"
    rd="$CL_HOME/.local/share/nice-dns-health" ST_SCHED="$CL_HOME/.config/systemd/user/default.target.wants/nice-dns-health.timer"
  else
    ST_PLAT=macos ST_INST="$CL_HOME/Library/Application Support/nice-dns-install" ST_SD="$CL_HOME/Library/Application Support/nice-dns/controller"
    rd="$CL_HOME/Library/Application Support/nice-dns-health" ST_SCHED="$CL_HOME/Library/LaunchAgents/org.nice-dns.health.plist"
  fi
  mkdir -p "$ST_SD" "$rd" "${ST_SCHED%/*}" "$CL_HOME/.config/nice-dns"
  chmod 700 "$ST_SD"
  : >"$ST_SCHED"
  printf 'source_commit\t%s\nplatform\t%s\nlock\tsha256:%s\ncredential\tpihole-admin\t%s\tkept\n' \
    0123456789abcdef0123456789abcdef01234567 \
    "$ST_PLAT" lockdigest "$CL_HOME/secret/pihole_webpassword" >>"$ST_INST/generations/g1/prepare.tsv"
  printf 'schema\tnice-dns-health-install/1\nmode\tactive\n' >"$rd/install.tsv"
  st_pass $((ST_NOW - 30)) OK
  printf 'schema\tnice-dns-controller-state/1\ngeneration\t42\nroute\tcloudflare-onion\n' >"$ST_SD/state.tsv"
  : >"$ST_SD/recovery.tsv"
  for i in 1 2 3 4 5 6 7; do
    printf '%s\tnd-%s\troute:r%s\tresult%s\tdetail %s\n' $((ST_NOW - 100 + i)) "$i" "$i" "$i" "$i" >>"$ST_SD/recovery.tsv"
  done
  printf 'BRIDGE1=obfs4 a\nBRIDGE2=obfs4 b\nBRIDGE3=obfs4 c\n' >"$CL_HOME/.config/nice-dns/bridges.env"
  printf '%s\n' $((ST_NOW - 3600)) >"$ST_SD/bridges.last"
}

# st_pass <epoch> <verdict>: the controller's last observations.
st_pass() {
  printf 'schema\tnice-dns-observations/1\nobs\tcontainer:unbound\thealthy\t3\trunning\nobs\tcontainer:pi-hole\tunhealthy\t5\tpaused\nobs\troute:cloudflare-onion\thealthy\t120\tanswered\npass\t%s\t%s\n' "$1" "$2" >"$ST_SD/observations.tsv"
}

# st_rows: nd_status_rows under a PATH of awk, sed, cat, date, tr and cut,
# plus logging stubs for every tool that would probe or reach the network.
# ST_OUT, ST_RC; ST_CALLS lists the stub calls.
st_rows() {
  local b="$CL_W/st-bin" t p
  rm -rf "$b"; mkdir -p "$b"
  for t in awk sed cat date tr cut; do p="$(command -v "$t")" && ln -s "$p" "$b/$t"; done
  for t in podman container dig curl git systemctl launchctl uname nc; do
    printf '#!/bin/sh\necho "%s $*" >>"%s/st-calls.log"\nexit 0\n' "$t" "$CL_W" >"$b/$t"
    chmod +x "$b/$t"
  done
  : >"$CL_W/st-calls.log"
  ST_OUT="$(HOME="$CL_HOME" PATH="$b" XDG_STATE_HOME="" XDG_CONFIG_HOME="" XDG_DATA_HOME="" ND_STATUS_NOW="$ST_NOW" \
    /bin/bash -c '. "$1" && nd_status_rows "$2"' st "$NICE_DNS_ROOT/lib/status.sh" "$ST_PLAT" 2>"$CL_W/st-err")"
  ST_RC=$?
  ST_CALLS="$(cat "$CL_W/st-calls.log")"
}

# st_val <group> <key>: the rest of that row (tabs kept).
st_val() { printf '%s\n' "$ST_OUT" | awk -F '\t' -v g="$1" -v k="$2" '$1 == g && $2 == k { sub(/^[^\t]*\t[^\t]*\t/, ""); print; exit }'; }

t_status_rows_cover_every_group_without_running_anything() {
  local u g n
  for u in $(cl_platforms); do
    st_world "$u"; st_rows
    assert_rc 0 "$ST_RC" "$u: rows: $(cat "$CL_W/st-err")"
    assert_eq "" "$ST_CALLS" "$u: status runs no probe, runtime, scheduler or network tool"
    assert_eq "schema	nice-dns-status/1" "$(printf '%s\n' "$ST_OUT" | head -n 1)" "$u: the schema line comes first"
    for g in install controller obs route bridges update admin recent; do
      assert_match "^$g	" "$ST_OUT" "$u: the $g group is there"
    done
    assert_eq yes "$(st_val install installed)" "$u: installed"
    assert_eq main "$(st_val install branch)" "$u: branch"
    assert_eq "$ST_PLAT" "$(st_val install platform)" "$u: platform"
    assert_eq active "$(st_val controller mode)" "$u: controller mode"
    assert_eq $((ST_NOW - 30)) "$(st_val controller last_pass)" "$u: last pass"
    assert_eq OK "$(st_val controller verdict)" "$u: verdict"
    assert_eq no "$(st_val controller stale)" "$u: a 30 s old pass is not stale"
    assert_eq loaded "$(st_val controller schedule)" "$u: schedule"
    n="$(printf '%s\n' "$ST_OUT" | awk -F '\t' '$1 == "obs"' | wc -l | tr -d ' ')"
    assert_eq 3 "$n" "$u: every observation of the pass is copied"
    assert_match "^obs	container:pi-hole	unhealthy	5	paused$" "$ST_OUT" "$u: as the controller wrote it"
    assert_eq "cloudflare-onion	42" "$(st_val route selected)" "$u: the selected route"
    assert_eq on "$(st_val bridges mode)" "$u: bridges on without a mode file"
    assert_eq 3 "$(st_val bridges count)" "$u: bridge count"
    assert_eq $((ST_NOW - 3600)) "$(st_val bridges last_refresh)" "$u: last refresh"
    assert_eq "unknown	never-checked" "$(st_val update result)" "$u: no update check yet"
    assert_eq "$CL_HOME/secret/pihole_webpassword" "$(st_val admin password_path)" "$u: the admin password's path, never the password"
    n="$(printf '%s\n' "$ST_OUT" | awk -F '\t' '$1 == "recent" { print $2 "\t" $3 "\t" $4 }' | tr '\n' '|')"
    assert_eq "$((ST_NOW - 97))	route:r3	result3|$((ST_NOW - 96))	route:r4	result4|$((ST_NOW - 95))	route:r5	result5|$((ST_NOW - 94))	route:r6	result6|$((ST_NOW - 93))	route:r7	result7|" "$n" "$u: the last five journal rows, oldest first"
  done
}

t_status_flags_a_stale_or_missing_pass_and_still_prints_it() {
  local u
  for u in $(cl_platforms); do
    st_world "$u"
    st_pass $((ST_NOW - 400)) "FAIL [container:pi-hole]"
    st_rows
    assert_rc 0 "$ST_RC" "$u: a stale pass is not an error"
    assert_eq 400 "$(st_val controller stale)" "$u: stale for 400 s"
    assert_eq "FAIL [container:pi-hole]" "$(st_val controller verdict)" "$u: its verdict"
    assert_match "^obs	container:unbound	" "$ST_OUT" "$u: its observations are still printed"
    rm -f "$ST_SD/observations.tsv"; st_rows
    assert_eq never "$(st_val controller stale)" "$u: no pass yet"
    assert_eq never "$(st_val controller last_pass)" "$u: no last pass"
    rm -f "$ST_SCHED"; st_rows
    assert_eq stopped "$(st_val controller schedule)" "$u: no schedule"
  done
}

t_status_not_installed_names_the_curl_line_and_exits_1() {
  local u
  for u in $(cl_platforms); do
    st_world "$u"; rm -rf "$ST_INST"; st_rows
    assert_rc 1 "$ST_RC" "$u: nothing installed"
    assert_eq no "$(st_val install installed)" "$u: installed no"
    assert_match "^install	hint	curl -fsSL https://raw.githubusercontent.com/sureserverman/nice-dns/main/install-$(cl_os "$u").sh" "$ST_OUT" "$u: the README's curl line"
  done
}

t_status_unreadable_state_exits_2() {
  local u
  for u in $(cl_platforms); do
    st_world "$u"; chmod 000 "$ST_SD"; st_rows; chmod 700 "$ST_SD"
    assert_rc 2 "$ST_RC" "$u: unreadable state"
    assert_match "^controller	unreadable	" "$ST_OUT" "$u: says so"
  done
}

t_status_values_carry_no_control_characters() {
  st_world Linux
  printf 'schema\tnice-dns-install-prepare/1\nvariant\thaproxy\npihole\tstandard\nbranch\tma\033[31min\n' >"$ST_INST/generations/g1/prepare.tsv"
  st_rows
  assert_eq "ma[31min" "$(st_val install branch)" "an escape in a file value is removed"
}

# ─────────────── Status and update plan, Task 1.3: the status command ───────

t_status_command_prints_rows_and_sections_with_its_exit_codes() {
  local u bad s
  for u in $(cl_platforms); do
    st_world "$u"
    ND_STATUS_NOW="$ST_NOW" cl_run "$CL_TREE/nice-dns" status --tsv
    assert_rc 0 "$CL_RC" "$u: status --tsv: $CL_ERR"
    assert_eq "schema	nice-dns-status/1" "$(printf '%s\n' "$CL_OUT" | head -n 1)" "$u: --tsv starts with the schema line"
    bad="$(printf '%s\n' "$CL_OUT" | awk -F '\t' 'NR > 1 && ($1 !~ /^(install|controller|obs|route|bridges|update|admin|recent)$/ || NF < 3)')"
    assert_eq "" "$bad" "$u: every other row is a known group with a key and a value"
    assert_eq "" "$(cl_calls '^(podman|container|dig|systemctl|launchctl|git) ')" "$u: status runs no runtime, scheduler, resolver or git"
    ND_STATUS_NOW="$ST_NOW" cl_run "$CL_TREE/nice-dns" status
    assert_rc 0 "$CL_RC" "$u: status: $CL_ERR"
    for s in Install Controller Containers Routes Bridges Update Admin "Recent actions"; do
      assert_match "^$s" "$CL_OUT" "$u: the $s section"
    done
    assert_match "pi-hole +unhealthy +paused" "$CL_OUT" "$u: a container line"
    assert_match "cloudflare-onion +healthy +answered" "$CL_OUT" "$u: a route line"
    assert_not_match "\\(stale" "$CL_OUT" "$u: a fresh pass's observations carry no stale marker"
    assert_match "^  stale +no$" "$CL_OUT" "$u: and the controller says so"
    st_pass $((ST_NOW - 400)) OK
    ND_STATUS_NOW="$ST_NOW" cl_run "$CL_TREE/nice-dns" status
    assert_match "^Containers \(stale: last pass 400 s ago\)" "$CL_OUT" "$u: stale observations are marked and still printed"
    assert_match "pi-hole +unhealthy +paused" "$CL_OUT" "$u: still printed"
    chmod 000 "$ST_SD"
    cl_run "$CL_TREE/nice-dns" status --tsv
    chmod 700 "$ST_SD"
    assert_rc 2 "$CL_RC" "$u: an unreadable state directory exits 2"
    rm -rf "$ST_INST"
    cl_run "$CL_TREE/nice-dns" status
    assert_rc 1 "$CL_RC" "$u: nothing installed exits 1"
    assert_match "curl -fsSL" "$CL_OUT" "$u: and names the curl line"
  done
}

t_status_is_in_the_help() {
  cl_world Linux
  cl_run "$CL_TREE/nice-dns" --help
  assert_match "^  status \[--tsv\]" "$CL_OUT" "--help lists status"
}
