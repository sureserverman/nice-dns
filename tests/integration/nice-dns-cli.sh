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
  systemctl)
    case "\$*" in
      *is-active*) exit 0 ;;
      *restart*) [ -f "\$FAKE/restart_rc" ] && { echo "the restart broke" >&2; exit "\$(cat "\$FAKE/restart_rc")"; } ;;
    esac ;;
  git)
    [ -f "\$FAKE/clone_fails" ] && exit 128
    case "\$*" in
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
  HOME="$CL_HOME" PATH="$CL_FAKE:$PATH" TMPDIR="$CASE_DIR" XDG_STATE_HOME="" bash "$cmd" "$@" >"$CL_W/out" 2>"$CL_W/err"
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
    assert_eq "installer[checkout] install-$os-hardened.sh socat dev" "$(cl_calls '^installer')" "$u: install with every choice"
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
  assert_eq "installer[checkout] install-deb.sh haproxy main" "$(cl_calls '^installer')" "every flag overrides"
  : >"$CL_LOG"
  cl_run "$CL_TREE/nice-dns" reinstall --branch next
  assert_eq "installer[checkout] install-deb-hardened.sh socat next" "$(cl_calls '^installer')" "one flag leaves the rest recorded"
}

t_installed_reinstall_clones_the_recorded_branch() {
  cl_world Linux; cl_installed; cl_record socat standard dev
  cl_run "$CL_CMD" reinstall
  assert_rc 0 "$CL_RC" "reinstall: $CL_ERR"
  assert_match '^git .*clone .*-b dev ' "$(cl_calls '^git ')" "the recorded branch is cloned"
  assert_eq "installer[clone] install-deb.sh socat dev" "$(cl_calls '^installer')" "the clone's installer runs"
  assert_eq "" "$(find "$CASE_DIR" -maxdepth 1 -name 'nice-dns-reinstall.*')" "the clone is removed afterwards"
}

t_failed_clone_names_local_and_changes_nothing() {
  cl_world Darwin; cl_installed; cl_record haproxy standard main
  : >"$CL_FAKE/clone_fails"
  cl_run "$CL_CMD" reinstall
  assert_rc 1 "$CL_RC" "a failed clone fails"
  assert_match 'nice-dns reinstall --local' "$CL_ERR" "it names --local"
  assert_match 'running stack is untouched' "$CL_ERR" "it says the stack is untouched"
  assert_eq "" "$(cl_calls '^installer')" "no installer ran"
  assert_eq "" "$(find "$CASE_DIR" -maxdepth 1 -name 'nice-dns-reinstall.*')" "no clone is left"
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
