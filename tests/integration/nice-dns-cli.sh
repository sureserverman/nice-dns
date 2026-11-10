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
      *ls-remote*)
        [ -f "\$FAKE/ls_remote_fails" ] && { echo "fatal: unable to access the remote" >&2; exit 128; }
        [ -f "\$FAKE/ls_remote" ] && cat "\$FAKE/ls_remote" ;;
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
# An install from a clone records that clone's commit (\$FAKE/new_commit).
if [ -f "$CL_FAKE/new_commit" ] && [ "\${CL_INSTALLER_RC:-0}" = 0 ]; then
  for f in "\$HOME/.local/state/nice-dns-install/generations/"*/prepare.tsv "\$HOME/Library/Application Support/nice-dns-install/generations/"*/prepare.tsv; do
    [ -f "\$f" ] || continue
    awk -F '\t' -v c="\$(cat "$CL_FAKE/new_commit")" 'BEGIN { OFS = "\t" } \$1 == "source_commit" { \$2 = c } { print }' "\$f" >"\$f.new" && mv "\$f.new" "\$f"
  done
fi
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
  HOME="$CL_HOME" PATH="$CL_FAKE:$PATH" TMPDIR="$CASE_DIR" XDG_STATE_HOME="" XDG_CONFIG_HOME="" XDG_DATA_HOME="" XDG_CACHE_HOME="" bash "$cmd" "$@" >"$CL_W/out" 2>"$CL_W/err"
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
  assert_eq "" "$(find "$CL_HOME/.cache/nice-dns" -mindepth 1 -maxdepth 1 2>/dev/null)" "the clone is removed afterwards"
  assert_match "clone .* $CL_HOME/\\.cache/nice-dns/fetch\\.[A-Za-z0-9]+/nice-dns" "$(cl_calls '^git ')" "the clone sits under HOME, where nice-dns-helper takes a tree"
}

t_failed_clone_names_local_and_changes_nothing() {
  cl_world Darwin; cl_installed; cl_record haproxy standard main
  : >"$CL_FAKE/clone_fails"
  cl_run "$CL_CMD" reinstall
  assert_rc 1 "$CL_RC" "a failed clone fails"
  assert_match 'nice-dns reinstall --local' "$CL_ERR" "it names --local"
  assert_match 'running stack is untouched' "$CL_ERR" "it says the stack is untouched"
  assert_eq "" "$(cl_calls '^installer')" "no installer ran"
  assert_eq "" "$(find "$CL_HOME/.cache/nice-dns" -mindepth 1 -maxdepth 1 2>/dev/null)" "no clone is left"
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

# The hardened base is built from the source tree's own pihole-hardened/base
# (OD-6): no run names a checkout beside it, whether from the kept source, a
# clone or a checkout, and the library has no lookup left to honour one.
t_hardened_runs_name_no_sibling_checkout() {
  cl_world Linux; cl_installed; cl_record haproxy standard main
  cl_run "$CL_CMD" reinstall --hardened --local
  assert_rc 0 "$CL_RC" "a hardened reinstall from the kept source runs: $CL_OUT"
  assert_eq "installer[snapshot] install-deb-hardened.sh haproxy main" "$(cl_calls '^installer')" "from the kept source, with the hardened entrypoint"
  assert_eq "" "$(cl_calls '^sibling')" "the kept source: no checkout is named"
  : >"$CL_LOG"
  cl_run "$CL_CMD" reinstall --hardened
  assert_eq "" "$(cl_calls '^sibling')" "a clone: no checkout is named"
  cl_world Linux; cl_record haproxy standard main
  cl_run "$CL_TREE/nice-dns" install --hardened --branch dev
  assert_eq "" "$(cl_calls '^sibling')" "a checkout's clone: no checkout is named"
  : >"$CL_LOG"
  cl_run "$CL_TREE/nice-dns" install --hardened
  assert_eq "" "$(cl_calls '^sibling')" "a checkout: no checkout is named"
  assert_eq "" "$(grep -nE 'hardened_sibling|HARDENED_SIBLING' "$CL_TREE/nice-dns" "$CL_TREE/lib/install.sh")" "neither the command nor the library looks for one"
}

# ─────────────── switch: one choice changed, from the kept source ───────────────

# `nice-dns switch proxy|pihole <choice>` is `reinstall --local` with that one
# choice changed (DEC-018): the kept source, the recorded branch and the other
# recorded choice; never a clone, from anywhere it is run.
t_switch_changes_one_choice_from_the_kept_source() {
  local u os
  for u in $(cl_platforms); do
    os="$(cl_os "$u")"
    cl_world "$u"; cl_installed; cl_record haproxy standard dev
    cl_run "$CL_CMD" switch proxy socat
    assert_rc 0 "$CL_RC" "$u: switch proxy socat: $CL_ERR"
    assert_eq "installer[snapshot] install-$os.sh socat dev" "$(cl_calls '^installer')" "$u: the kept source's installer, the proxy changed, the branch recorded"
    assert_eq "" "$(cl_calls '^git ')" "$u: nothing is cloned"
    assert_match 'tor-socat' "$(printf '%s\n' "$CL_OUT" | tail -n 1)" "$u: the last line says what now runs"
    assert_match 'DNS is answering' "$(printf '%s\n' "$CL_OUT" | tail -n 1)" "$u: and that DNS answers"
    cl_world "$u"; cl_installed; cl_record socat standard dev
    cl_run "$CL_CMD" switch proxy haproxy
    assert_eq "installer[snapshot] install-$os.sh haproxy dev" "$(cl_calls '^installer')" "$u: switch proxy haproxy"
    cl_world "$u"; cl_installed; cl_record socat standard main
    cl_run "$CL_CMD" switch pihole hardened
    assert_rc 0 "$CL_RC" "$u: switch pihole hardened: $CL_ERR"
    assert_eq "installer[snapshot] install-$os-hardened.sh socat main" "$(cl_calls '^installer')" "$u: the hardened entrypoint, the proxy kept"
    assert_match 'hardened' "$(printf '%s\n' "$CL_OUT" | tail -n 1)" "$u: the last line names the flavour"
    cl_world "$u"; cl_installed; cl_record haproxy hardened main
    cl_run "$CL_CMD" switch pihole standard
    assert_eq "installer[snapshot] install-$os.sh haproxy main" "$(cl_calls '^installer')" "$u: switch pihole standard"
    assert_eq "" "$(cl_calls '^git ')" "$u: nothing is cloned"
  done
  # Run from a checkout too, the kept source is what it reinstalls.
  cl_world Linux; cl_installed; cl_record haproxy standard main
  cl_run "$CL_TREE/nice-dns" switch proxy socat
  assert_eq "installer[snapshot] install-deb.sh socat main" "$(cl_calls '^installer')" "from a checkout, the kept source still"
}

t_switch_to_the_installed_choice_changes_nothing() {
  local w
  for w in "proxy haproxy" "pihole standard"; do
    cl_world Linux; cl_installed; cl_record haproxy standard main
    # shellcheck disable=SC2086  # two words
    cl_run "$CL_CMD" switch $w
    assert_rc 0 "$CL_RC" "switch $w: $CL_ERR"
    assert_eq "Already ${w#* }; nothing changed." "$CL_OUT" "switch $w: says so"
    assert_eq "" "$(cl_calls '^installer')" "switch $w: no installer runs"
  done
}

t_switch_with_nothing_installed_or_no_kept_source() {
  cl_world Darwin
  cl_run "$CL_TREE/nice-dns" switch proxy socat
  assert_rc 1 "$CL_RC" "nothing installed: exit 1"
  assert_match 'nice-dns is not installed; run `nice-dns install`' "$CL_ERR" "the message"
  assert_eq "" "$(cl_calls .)" "nothing ran"
  cl_world Linux; cl_installed; cl_record haproxy standard main
  rm -rf "$CL_HOME/.local/share/nice-dns/source"
  cl_run "$CL_CMD" switch pihole hardened
  assert_rc 1 "$CL_RC" "no kept source: exit 1"
  assert_match "$CL_HOME/\\.local/share/nice-dns/source" "$CL_ERR" "it names the missing directory"
  assert_match 'nice-dns reinstall' "$CL_ERR" "and nice-dns reinstall"
  assert_eq "" "$(cl_calls .)" "nothing ran"
}

t_switch_whose_install_fails_says_the_old_choice_runs() {
  cl_world Linux; cl_installed; cl_record haproxy standard main
  CL_INSTALLER_RC=7 cl_run "$CL_CMD" switch proxy socat
  assert_rc 3 "$CL_RC" "a failed install: exit 3"
  assert_match 'did not happen' "$CL_ERR" "the switch did not happen"
  assert_match 'haproxy' "$CL_ERR" "the old choice still runs"
  assert_eq "installer[snapshot] install-deb.sh socat main" "$(cl_calls '^installer')" "the install was tried once"
}

t_switch_usage_errors_run_nothing() {
  local a
  for a in "switch" "switch proxy" "switch pihole" "switch proxy nginx" "switch pihole fancy" "switch dns socat" "switch proxy socat extra"; do
    cl_world Linux; cl_installed; cl_record haproxy standard main
    # shellcheck disable=SC2086  # the words
    cl_run "$CL_CMD" $a
    assert_rc 2 "$CL_RC" "$a: exit 2"
    assert_eq "" "$CL_OUT" "$a: nothing on stdout"
    assert_match 'switch' "$CL_ERR" "$a: a usage line"
    assert_eq "" "$(cl_calls .)" "$a: nothing ran"
  done
  cl_run "$CL_CMD" --help
  assert_match 'switch proxy haproxy\|socat' "$CL_OUT" "--help lists switch proxy"
  assert_match 'switch pihole standard\|hardened' "$CL_OUT" "and switch pihole"
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

# cl_restart_world <uname>: an installed stack with the controller's three
# schedules (the minute pass, the bridge refresh, the update check).
cl_restart_world() {
  cl_world "$1"; cl_record haproxy standard main
  CL_RESTART_PLAT=linux
  if [ "$1" = Darwin ]; then
    CL_RESTART_PLAT=macos
    mkdir -p "$CL_HOME/Library/LaunchAgents"
    : >"$CL_HOME/Library/LaunchAgents/org.nice-dns.health.plist"
    : >"$CL_HOME/Library/LaunchAgents/org.nice-dns.health-bridges.plist"
    : >"$CL_HOME/Library/LaunchAgents/org.nice-dns.health-update.plist"
  fi
}

# Lines of the log: hold, the one restart, release.
cl_hold_pat() { if [ "$CL_RESTART_PLAT" = linux ]; then echo '^systemctl --user stop nice-dns-health'; else echo '^launchctl unload .*org\.nice-dns\.health'; fi; }
cl_restart_pat() { if [ "$CL_RESTART_PLAT" = linux ]; then echo '^systemctl --user restart nice-dns-pod\.service'; else echo '^launchctl kickstart -k gui/'; fi; }
cl_release_pat() { if [ "$CL_RESTART_PLAT" = linux ]; then echo '^systemctl --user start nice-dns-health'; else echo '^launchctl load .*org\.nice-dns\.health'; fi; }
cl_line() { grep -nE "$1" "$CL_LOG" | "$2" -n 1 | cut -d: -f1; }

cl_assert_released() {
  assert_eq 3 "$(grep -cE "$(cl_release_pat)" "$CL_LOG")" "$1: all three schedules are released"
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

# Close-out M1: a schedule the owner stopped stays stopped. On macOS its plist
# is kept, so the hold must not read the plist as a loaded agent and the
# release must not load it.
t_restart_leaves_a_stopped_macos_schedule_stopped() {
  cl_restart_world Darwin
  mkdir -p "$CL_HOME/Library/Application Support/nice-dns-health"
  : >"$CL_HOME/Library/Application Support/nice-dns-health/schedule-stopped"
  cl_run "$CL_TREE/nice-dns" restart
  assert_rc 0 "$CL_RC" "macos: restart: $CL_ERR"
  assert_eq "" "$(cl_calls '^launchctl load .*org\.nice-dns\.health(-bridges|-update)?\.plist')" "macos: no stopped schedule is loaded again (stop stops them all)"
  # A stop from before the update check left the bridge refresh loaded: it
  # is quiet during the restart all the same.
  assert_match '^launchctl unload .*org\.nice-dns\.health-bridges\.plist' "$(cat "$CL_LOG")" "macos: the bridge refresh is unloaded for the restart"
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
  # ST_CUT: another cut (the BSD case below).
  [ -z "${ST_CUT:-}" ] || ln -sf "$ST_CUT" "$b/cut"
  for t in podman container dig curl git systemctl launchctl uname nc; do
    printf '#!/bin/sh\necho "%s $*" >>"%s/st-calls.log"\nexit 0\n' "$t" "$CL_W" >"$b/$t"
    chmod +x "$b/$t"
  done
  : >"$CL_W/st-calls.log"
  ST_OUT="$(HOME="$CL_HOME" PATH="$b" XDG_STATE_HOME="" XDG_CONFIG_HOME="" XDG_DATA_HOME="" ND_STATUS_NOW="$ST_NOW" ND_INST_ROOT="${ST_ROOT:-}" \
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
    for g in install controller obs route bridges update helper admin recent; do
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

t_status_helper_rows_read_the_file_and_the_generation() {
  local u h
  for u in $(cl_platforms); do
    st_world "$u"
    if [ "$u" = Linux ]; then h=/usr/libexec/nice-dns-helper; else h=/usr/local/libexec/nice-dns-helper; fi
    # ST_ROOT is st_rows' ND_INST_ROOT, which prefixes the root paths as in
    # the installer fixtures.
    ST_ROOT="$CL_W/root"
    st_rows
    assert_rc 0 "$ST_RC" "$u: rows: $(cat "$CL_W/st-err")"
    assert_eq "$h" "$(st_val helper path)" "$u: the helper's path"
    assert_eq no "$(st_val helper installed)" "$u: no helper file"
    assert_eq unknown "$(st_val helper version)" "$u: no helper row in the generation"
    mkdir -p "$ST_ROOT${h%/*}"
    printf '#!/bin/sh\necho RAN >>"%s/helper-ran"\n' "$CL_W" >"$ST_ROOT$h"
    chmod 755 "$ST_ROOT$h"
    printf 'helper\t0.1.0\n' >>"$ST_INST/generations/g1/prepare.tsv"
    st_rows
    assert_eq yes "$(st_val helper installed)" "$u: the helper is installed"
    assert_eq 0.1.0 "$(st_val helper version)" "$u: the version the generation recorded"
    assert_no_path "$CL_W/helper-ran" "$u: status never runs the helper"
    assert_eq "" "$ST_CALLS" "$u: nor any probe"
    ST_ROOT=""
  done
}

t_status_obs_rows_end_their_lines_with_a_bsd_cut() {
  local u n real
  real="$(command -v cut)"
  # macOS's cut prints no newline its input lacks (GNU cut adds one): with it,
  # every observation must still be a row of its own (the Stage 2 gate demo
  # found them joined on the mac).
  cat >"$CASE_DIR/bsd-cut" <<STUB
#!/bin/sh
f="\$($(command -v mktemp))"; $(command -v cat) >"\$f"
if [ -s "\$f" ] && [ "\$($(command -v tail) -c 1 "\$f" | $(command -v od) -An -c | $(command -v tr) -d ' ')" != '\\n' ]; then "$real" "\$@" <"\$f" | $(command -v head) -c -1; else "$real" "\$@" <"\$f"; fi
$(command -v rm) -f "\$f"
STUB
  chmod 755 "$CASE_DIR/bsd-cut"
  for u in $(cl_platforms); do
    st_world "$u"
    ST_CUT="$CASE_DIR/bsd-cut" st_rows
    assert_rc 0 "$ST_RC" "$u: rows: $(cat "$CL_W/st-err")"
    n="$(printf '%s\n' "$ST_OUT" | awk -F '\t' '$1 == "obs"' | wc -l | tr -d ' ')"
    assert_eq 3 "$n" "$u: three observations, three rows"
    assert_match "^route	selected	" "$ST_OUT" "$u: the route row starts its own line"
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

# Close-out M1: `nice-dns-health stop` on macOS unloads the agent but keeps
# its plist, so the plist alone is no evidence the schedule runs; the stop
# leaves schedule-stopped beside the controller's receipt.
t_status_a_stopped_macos_schedule_reads_stopped() {
  st_world Darwin
  st_pass $((ST_NOW - 30)) OK
  st_rows
  assert_eq loaded "$(st_val controller schedule)" "macos: the agent's plist, no stop mark"
  : >"$CL_HOME/Library/Application Support/nice-dns-health/schedule-stopped"
  st_rows
  assert_rc 0 "$ST_RC" "macos: rows: $(cat "$CL_W/st-err")"
  assert_eq stopped "$(st_val controller schedule)" "macos: the plist is kept, but nice-dns-health stop marked it stopped"
}

t_status_not_installed_names_the_curl_line_and_exits_1() {
  local u
  for u in $(cl_platforms); do
    st_world "$u"; rm -rf "$ST_INST"; st_rows
    assert_rc 1 "$ST_RC" "$u: nothing installed"
    assert_eq no "$(st_val install installed)" "$u: installed no"
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
    bad="$(printf '%s\n' "$CL_OUT" | awk -F '\t' 'NR > 1 && ($1 !~ /^(install|controller|obs|route|bridges|update|helper|admin|recent)$/ || NF < 3)')"
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
    cl_run "$CL_TREE/nice-dns" status --tsv
    assert_rc 1 "$CL_RC" "$u: nothing installed exits 1"
    assert_eq "install	hint	$(grep -F "install-$(cl_os "$u").sh -o" "$NICE_DNS_ROOT/README.md" | head -n 1)" "$(printf '%s\n' "$CL_OUT" | awk -F '\t' '$1 == "install" && $2 == "hint"')" "$u: the hint is the README's install line"
    assert_eq "installed	no" "$(printf '%s\n' "$CL_OUT" | awk -F '\t' 'NR == 2 { print $2 "\t" $3 }')" "$u: right after the installed row"
    cl_run "$CL_TREE/nice-dns" status
    assert_rc 1 "$CL_RC" "$u: the sections too"
    assert_match "hint +curl -fsSL" "$CL_OUT" "$u: and name the install line"
  done
}

t_status_is_in_the_help() {
  cl_world Linux
  cl_run "$CL_TREE/nice-dns" --help
  assert_match "^  status \[--tsv\]" "$CL_OUT" "--help lists status"
}

# ─────── Status and update plan, Stage 1 gate round 1: what status trusts ───

# A file that is there but cannot be read is never read as absent.
t_status_never_reads_an_unreadable_file_as_absent() {
  local u p
  for u in $(cl_platforms); do
    st_world "$u"
    p="${ST_SD%/*}"
    chmod 000 "$p"; st_rows; chmod 700 "$p"
    assert_rc 2 "$ST_RC" "$u: an unreachable state directory"
    assert_match "^controller	unreadable	cannot read " "$ST_OUT" "$u: says so rather than 'never ran'"
    chmod 000 "$ST_SD/state.tsv"; st_rows; chmod 600 "$ST_SD/state.tsv"
    assert_rc 2 "$ST_RC" "$u: an unreadable state.tsv"
    assert_match "^route	unreadable	cannot read ~/" "$ST_OUT" "$u: the route row says so, under ~/"
    chmod 000 "$ST_SD/recovery.tsv"; st_rows; chmod 600 "$ST_SD/recovery.tsv"
    assert_rc 2 "$ST_RC" "$u: an unreadable journal"
    assert_match "^recent	unreadable	" "$ST_OUT" "$u: the recent row says so"
    chmod 000 "$CL_HOME/.config/nice-dns/bridges.env"; st_rows; chmod 600 "$CL_HOME/.config/nice-dns/bridges.env"
    assert_rc 2 "$ST_RC" "$u: an unreadable bridges.env"
    assert_match "^bridges	unreadable	" "$ST_OUT" "$u: the bridges row says so"
    chmod 000 "$ST_INST/generations/g1/prepare.tsv"; st_rows; chmod 600 "$ST_INST/generations/g1/prepare.tsv"
    assert_rc 2 "$ST_RC" "$u: an unreadable install record is not 'not installed'"
    assert_match "^install	unreadable	" "$ST_OUT" "$u: the install row says so"
    printf '../../x\n' >"$ST_INST/current"; st_rows; printf 'g1\n' >"$ST_INST/current"
    assert_rc 2 "$ST_RC" "$u: a current file naming no generation"
    rm -f "$ST_SD/observations.tsv"; mkfifo "$ST_SD/observations.tsv"; st_rows; rm -f "$ST_SD/observations.tsv"
    assert_rc 2 "$ST_RC" "$u: a FIFO is never opened"
    printf 'garbage\n' >"$ST_SD/observations.tsv"; st_rows
    assert_rc 2 "$ST_RC" "$u: a garbled observations file"
    assert_match "^controller	unreadable	.*is not a pass the controller wrote" "$ST_OUT" "$u: says so"
    assert_eq never "$(st_val controller last_pass)" "$u: and reports no pass"
  done
}

t_status_epochs_are_plain_numbers_and_a_future_pass_is_stale() {
  local e
  st_world Linux
  st_pass $((ST_NOW + 600)) OK; st_rows
  assert_rc 0 "$ST_RC" "a pass dated in the future"
  assert_eq future "$(st_val controller stale)" "is stale, never 'no'"
  for e in 0800000000 1234567890123456789012 12a; do
    st_pass "$e" OK; st_rows
    assert_rc 2 "$ST_RC" "epoch $e: rejected"
    assert_eq never "$(st_val controller last_pass)" "epoch $e: no pass"
    assert_eq "" "$(cat "$CL_W/st-err")" "epoch $e: no shell arithmetic error"
  done
  st_pass $((ST_NOW - 30)) OK
  ST_NOW=garbage st_rows
  assert_rc 0 "$ST_RC" "a garbage ND_STATUS_NOW is ignored"
  assert_eq "" "$(cat "$CL_W/st-err")" "without an arithmetic error"
}

t_status_route_absent_until_chosen_and_journal_fields_stay_aligned() {
  st_world Linux
  printf 'schema\tnice-dns-controller-state/1\ngeneration\t1\nroute\t-\n' >"$ST_SD/state.tsv"
  printf '%s\tnd-x\t\tresultX\tdetail\n' $((ST_NOW - 1)) >>"$ST_SD/recovery.tsv"
  st_rows
  assert_eq "" "$(printf '%s\n' "$ST_OUT" | awk -F '\t' '$1 == "route"')" "no route row before a route is chosen"
  assert_eq "$((ST_NOW - 1))	-	resultX" "$(printf '%s\n' "$ST_OUT" | awk -F '\t' '$1 == "recent" { l = $2 "\t" $3 "\t" $4 } END { print l }')" "an empty journal field is printed as -"
}

t_status_hint_survives_an_unreadable_state() {
  st_world Linux; rm -rf "$ST_INST"; chmod 000 "$ST_SD"
  cl_run "$CL_TREE/nice-dns" status --tsv
  chmod 700 "$ST_SD"
  assert_rc 2 "$CL_RC" "unreadable wins"
  assert_match "^install	hint	curl -fsSL" "$CL_OUT" "and the install hint is still there"
}

# ─────────────── Status and update plan, Task 2.1: update --check ───────────

UP_LOCAL=0123456789abcdef0123456789abcdef01234567
UP_REMOTE=fedcba9876543210fedcba9876543210fedcba98

# up_world <uname> [source_commit] [source_dirty]: an installed host whose
# record names branch main and that commit.
up_world() {
  st_world "$1"
  sed -i.bak '/^source_commit\t/d' "$ST_INST/generations/g1/prepare.tsv" && rm -f "$ST_INST/generations/g1/prepare.tsv.bak"
  printf 'source_commit\t%s\nsource_dirty\t%s\n' "${2:-$UP_LOCAL}" "${3:-0}" >>"$ST_INST/generations/g1/prepare.tsv"
}
up_remote() { printf '%s\trefs/heads/main\n' "$1" >"$CL_FAKE/ls_remote"; }

t_update_check_compares_the_recorded_commit_with_the_branch() {
  local u c
  for u in $(cl_platforms); do
    up_world "$u"; up_remote "$UP_LOCAL"
    cl_run "$CL_TREE/nice-dns" update --check
    assert_rc 0 "$CL_RC" "$u: same commit: $CL_ERR"
    assert_eq current "$CL_OUT" "$u: says current"
    assert_match "^git .*ls-remote --heads https://github.com/sureserverman/nice-dns.git refs/heads/main$" "$(cl_calls '^git ')" "$u: asks for the recorded branch only"
    assert_eq "" "$(cl_calls '^git .*clone')" "$u: and clones nothing"
    c="$ST_SD/update-check.tsv"
    assert_eq "schema	nice-dns-update-check/1" "$(head -n 1 "$c")" "$u: the cache has its schema"
    assert_eq "$c" "$(find "$c" -maxdepth 0 -type f -perm 0600)" "$u: mode 0600"
    assert_eq "current" "$(awk -F '\t' '$1 == "result" { print $2 }' "$c")" "$u: and the result"
    up_remote "$UP_REMOTE"
    cl_run "$CL_TREE/nice-dns" update --check
    assert_rc 10 "$CL_RC" "$u: a newer commit: $CL_ERR"
    assert_eq "available fedcba987654" "$CL_OUT" "$u: names its short commit"
    assert_eq "$UP_REMOTE" "$(awk -F '\t' '$1 == "remote_commit" { print $2 }' "$c")" "$u: the cache keeps the remote commit"
    assert_eq "$UP_LOCAL" "$(awk -F '\t' '$1 == "local_commit" { print $2 }' "$c")" "$u: and the local one"
    assert_eq main "$(awk -F '\t' '$1 == "branch" { print $2 }' "$c")" "$u: and the branch"
    : >"$CL_LOG"
    ND_STATUS_NOW="$ST_NOW" cl_run "$CL_TREE/nice-dns" status --tsv
    assert_match "^update	result	available$" "$CL_OUT" "$u: status shows the cached result"
    assert_match "^update	remote_commit	$UP_REMOTE$" "$CL_OUT" "$u: and the remote commit"
    assert_eq "" "$(cl_calls '^git ')" "$u: without asking the remote again"
  done
}

t_update_check_unknown_changes_nothing_but_the_cache() {
  local u c
  for u in $(cl_platforms); do
    up_world "$u"; c="$ST_SD/update-check.tsv"
    : >"$CL_FAKE/ls_remote_fails"
    cl_run "$CL_TREE/nice-dns" update --check
    assert_rc 1 "$CL_RC" "$u: an unreachable remote"
    assert_match "^unknown: " "$CL_OUT" "$u: says unknown with a reason"
    assert_eq unknown "$(awk -F '\t' '$1 == "result" { print $2 }' "$c")" "$u: the cache says unknown"
    assert_eq "" "$(cl_calls '^installer')" "$u: nothing is installed"
    rm -f "$CL_FAKE/ls_remote_fails"; : >"$CL_FAKE/ls_remote"
    cl_run "$CL_TREE/nice-dns" update --check
    assert_rc 1 "$CL_RC" "$u: a branch the remote does not have"
    assert_match "^unknown: .*main" "$CL_OUT" "$u: names it"
    up_world "$u" unknown 0; up_remote "$UP_REMOTE"
    cl_run "$CL_TREE/nice-dns" update --check
    assert_rc 1 "$CL_RC" "$u: an unknown source commit"
    assert_eq "unknown: the installed source was not a clean commit" "$CL_OUT" "$u: says so"
    up_world "$u" "$UP_LOCAL" 1
    cl_run "$CL_TREE/nice-dns" update --check
    assert_rc 1 "$CL_RC" "$u: a dirty source"
    assert_eq "unknown: the installed source was not a clean commit" "$CL_OUT" "$u: says so"
    assert_eq unknown "$(awk -F '\t' '$1 == "result" { print $2 }' "$c")" "$u: the cache says unknown"
  done
}

t_update_check_with_nothing_installed() {
  cl_world Linux; up_remote "$UP_REMOTE"
  cl_run "$CL_TREE/nice-dns" update --check
  assert_rc 1 "$CL_RC" "nothing installed"
  assert_eq "unknown: nothing is installed" "$CL_OUT" "an unknown line on stdout, as for every exit 1"
  assert_match 'not installed' "$CL_ERR" "says so"
  assert_eq "" "$(cl_calls '^git ')" "and asks no remote"
}

# ─────────────── Status and update plan, Task 2.2: update applies ──────────

t_update_installs_the_recorded_choices_when_available() {
  local u os
  for u in $(cl_platforms); do
    up_world "$u"; os="$(cl_os "$u")"; cl_installed; up_remote "$UP_REMOTE"
    printf '%s\n' "$UP_REMOTE" >"$CL_FAKE/new_commit"
    sed -i.bak 's/^variant\t.*/variant\tsocat/; s/^pihole\t.*/pihole\thardened/' "$ST_INST/generations/g1/prepare.tsv"; rm -f "$ST_INST/generations/g1/prepare.tsv.bak"
    cl_run "$CL_CMD" update
    assert_rc 0 "$CL_RC" "$u: update: $CL_ERR"
    assert_eq "installer[clone] install-$os-hardened.sh socat main" "$(cl_calls '^installer')" "$u: the recorded variant, flavour and branch, from a clone of the branch"
    assert_eq "updated to fedcba987654" "$(printf '%s\n' "$CL_OUT" | tail -n 1)" "$u: the last line names the new commit"
    assert_not_match "^available" "$CL_OUT" "$u: and the check's own line is not printed"
    assert_eq current "$(awk -F '\t' '$1 == "result" { print $2 }' "$ST_SD/update-check.tsv")" "$u: and re-checks"
  done
}

t_update_from_a_checkout_still_installs_the_branch() {
  up_world Linux; up_remote "$UP_REMOTE"
  cl_run "$CL_TREE/nice-dns" update
  assert_eq "installer[clone] install-deb.sh haproxy main" "$(cl_calls '^installer')" "a checkout's update installs the branch, not itself"
}

t_update_current_installs_nothing_unless_forced() {
  local u os
  for u in $(cl_platforms); do
    up_world "$u"; os="$(cl_os "$u")"; cl_installed; up_remote "$UP_LOCAL"
    cl_run "$CL_CMD" update
    assert_rc 0 "$CL_RC" "$u: current: $CL_ERR"
    assert_eq "already current" "$CL_OUT" "$u: says exactly that"
    assert_eq "" "$(cl_calls '^installer')" "$u: and installs nothing"
    assert_eq "" "$(cl_calls '^git .*clone')" "$u: nor clones"
    cl_run "$CL_CMD" update --force
    assert_rc 0 "$CL_RC" "$u: --force: $CL_ERR"
    assert_eq "installer[clone] install-$os.sh haproxy main" "$(cl_calls '^installer')" "$u: --force reinstalls anyway"
  done
}

t_update_unknown_installs_nothing() {
  local u
  for u in $(cl_platforms); do
    up_world "$u"; cl_installed
    : >"$CL_FAKE/ls_remote_fails"
    cl_run "$CL_CMD" update --force
    assert_rc 1 "$CL_RC" "$u: unknown"
    assert_match "^unknown: could not reach" "$CL_OUT" "$u: with the reason"
    assert_eq "" "$(cl_calls '^installer')" "$u: installs nothing, even with --force"
    assert_eq "" "$(cl_calls '^git .*clone')" "$u: clones nothing"
    up_world "$u" unknown 0; cl_installed; up_remote "$UP_REMOTE"
    cl_run "$CL_CMD" update
    assert_rc 1 "$CL_RC" "$u: a source that was not a clean commit"
    assert_match "nice-dns reinstall" "$CL_ERR" "$u: names reinstall as the way forward"
    assert_eq "" "$(cl_calls '^installer')" "$u: installs nothing"
  done
}

t_update_a_failed_install_names_reinstall_local() {
  up_world Linux; cl_installed; up_remote "$UP_REMOTE"
  CL_INSTALLER_RC=10 cl_run "$CL_CMD" update
  assert_rc 3 "$CL_RC" "a failed install is exit 3, whatever the installer's code (10 would read as available)"
  assert_match "installer exit 10" "$CL_ERR" "the installer's code is named"
  assert_match "nice-dns reinstall --local" "$CL_ERR" "names --local"
  assert_eq available "$(awk -F '\t' '$1 == "result" { print $2 }' "$ST_SD/update-check.tsv")" "the cache still says available"
}

t_update_refuses_local_and_widens_nothing() {
  up_world Linux; cl_installed; up_remote "$UP_REMOTE"
  cl_run "$CL_CMD" update --local
  assert_rc 2 "$CL_RC" "--local has no meaning for update"
  assert_eq "" "$(cl_calls '^installer')" "and installs nothing"
  cl_run "$CL_CMD" update --branch dev
  assert_match "ls-remote --heads https://github.com/sureserverman/nice-dns.git refs/heads/dev$" "$(cl_calls '^git ')" "--branch asks that branch"
}

# ─────── Status and update plan, Stage 2 gate round 1: the update contract ──

t_update_installed_but_not_current_is_exit_11() {
  up_world Linux; cl_installed; up_remote "$UP_REMOTE"
  rm -f "$CL_FAKE/new_commit"
  cl_run "$CL_CMD" update
  assert_rc 11 "$CL_RC" "the install ran, but the record still names the old commit"
  assert_eq "installed; the check now says available" "$(printf '%s\n' "$CL_OUT" | tail -n 1)" "the last line says so"
  assert_match "installer\[clone\]" "$(cl_calls '^installer')" "and the install did run"
}

t_update_check_takes_only_branch() {
  up_world Linux; up_remote "$UP_REMOTE"
  cl_run "$CL_TREE/nice-dns" update --check --force
  assert_rc 2 "$CL_RC" "--check with --force is a usage error"
  cl_run "$CL_TREE/nice-dns" update --check socat
  assert_rc 2 "$CL_RC" "--check with a choice is a usage error"
  assert_eq "" "$(cl_calls '^git ')" "and nothing is asked"
}

t_update_check_of_another_branch_keeps_no_cache() {
  up_world Linux; up_remote "$UP_REMOTE"
  printf '%s\trefs/heads/dev\n' "$UP_REMOTE" >"$CL_FAKE/ls_remote"
  cl_run "$CL_TREE/nice-dns" update --check --branch dev
  assert_rc 10 "$CL_RC" "dev differs: $CL_ERR"
  assert_eq "" "$(find "$ST_SD" -name update-check.tsv)" "status compares the installed commit with its own branch only"
}

t_update_check_without_a_controller_keeps_no_cache_and_creates_nothing() {
  up_world Linux; up_remote "$UP_LOCAL"
  rm -rf "${ST_SD:?}"
  cl_run "$CL_TREE/nice-dns" update --check
  assert_rc 0 "$CL_RC" "the answer stands"
  assert_eq current "$CL_OUT" "and is printed"
  assert_match "not kept" "$CL_ERR" "the missing cache is named"
  [ ! -e "$ST_SD" ] || fail "update created the controller's state directory"
}

t_update_check_reads_only_its_own_branch_line() {
  up_world Linux
  printf '%s\trefs/heads/mainline\n%s\trefs/heads/main\n' "$UP_REMOTE" "$UP_LOCAL" >"$CL_FAKE/ls_remote"
  cl_run "$CL_TREE/nice-dns" update --check
  assert_eq current "$CL_OUT" "refs/heads/mainline is not main"
  printf '%s\trefs/heads/main\n' "${UP_REMOTE%?}" >"$CL_FAKE/ls_remote"
  cl_run "$CL_TREE/nice-dns" update --check
  assert_rc 1 "$CL_RC" "a 39-character commit is no commit"
  assert_match "^unknown: the remote has no branch 'main'" "$CL_OUT" "says so"
  printf 'garbage\n' >"$CL_FAKE/ls_remote"
  cl_run "$CL_TREE/nice-dns" update --check
  assert_rc 1 "$CL_RC" "garbage is no commit"
  up_remote "$UP_LOCAL"; cl_run "$CL_TREE/nice-dns" update --check
  assert_match "^git -c http.lowSpeedLimit=1 -c http.lowSpeedTime=60 ls-remote" "$(cl_calls '^git ')" "the transfer has its low-speed bound"
}

t_update_check_bounds_its_wait_under_a_minute() {
  local b
  up_world Linux; b="$CL_W/slow"; mkdir -p "$b"
  # A git that never answers, behind the real timeout(1).
  printf '#!/bin/sh\nexec sleep 300\n' >"$b/git"; chmod +x "$b/git"
  ln -s "$(command -v timeout)" "$b/timeout"
  SECONDS=0
  HOME="$CL_HOME" PATH="$b:$CL_FAKE:$PATH" TMPDIR="$CASE_DIR" XDG_STATE_HOME="" XDG_CONFIG_HOME="" XDG_DATA_HOME="" bash "$CL_TREE/nice-dns" update --check >"$CL_W/out" 2>"$CL_W/err"
  CL_RC=$?
  assert_rc 1 "$CL_RC" "a stalled remote is unknown"
  [ "$SECONDS" -lt 60 ] || fail "the answer took ${SECONDS}s, not under a minute"
  assert_eq unknown "$(awk -F '\t' '$1 == "result" { print $2 }' "$ST_SD/update-check.tsv")" "the cache says unknown"
}

t_update_cache_names_no_commit_for_an_unclean_record() {
  up_world Linux unknown 0; up_remote "$UP_REMOTE"
  cl_run "$CL_TREE/nice-dns" update --check
  assert_eq - "$(awk -F '\t' '$1 == "local_commit" { print $2 }' "$ST_SD/update-check.tsv")" "local_commit is - when the record names no commit"
}

# ─────────────── Bridges toggle plan, Task 1.1: nice-dns bridges ────────────

# bt_mode_file: the mode file the toggle writes (absent means on).
bt_mode_file() { printf '%s\n' "$CL_HOME/.config/nice-dns/bridges-mode.env"; }

t_bridges_off_and_on_write_the_mode_line() {
  local u f pool
  for u in $(cl_platforms); do
    st_world "$u"; bt_restart_fakes; f="$(bt_mode_file)"
    pool="$(cat "$CL_HOME/.config/nice-dns/bridges.env")"
    cl_run "$CL_TREE/nice-dns" bridges off
    assert_rc 0 "$CL_RC" "$u: bridges off: $CL_ERR"
    assert_file "$f" "$u: off writes the mode file"
    assert_eq "TOR_BRIDGES=off" "$(cat "$f")" "$u: off writes exactly one line"
    assert_eq 1 "$(wc -l <"$f" | tr -d ' ')" "$u: and only that line"
    assert_eq 644 "$(stat -c %a "$f")" "$u: the mode file is 0644"
    assert_match "ISP" "$CL_OUT" "$u: off says what the ISP sees"
    assert_match "Tor guard" "$CL_OUT" "$u: plain Tor guard connections"
    assert_match "obfs4" "$CL_OUT" "$u: instead of obfs4 traffic"
    assert_eq "Bridges are off; the proxy restarted and DNS is answering." "$(printf '%s\n' "$CL_OUT" | tail -n 1)" "$u: off: the last line"
    assert_eq "" "$(find "$CL_HOME/.config/nice-dns" -name '.bridges-mode*')" "$u: no temporary file is left"
    assert_eq "$pool" "$(cat "$CL_HOME/.config/nice-dns/bridges.env")" "$u: the bridge pool is untouched"
    cl_run "$CL_TREE/nice-dns" bridges on
    assert_rc 0 "$CL_RC" "$u: bridges on: $CL_ERR"
    assert_eq "TOR_BRIDGES=on" "$(cat "$f")" "$u: on writes on"
    assert_eq 644 "$(stat -c %a "$f")" "$u: still 0644"
    assert_not_match "Tor guard" "$CL_OUT" "$u: on carries no privacy note"
    assert_eq "Bridges are on; the proxy restarted and DNS is answering." "$(printf '%s\n' "$CL_OUT" | tail -n 1)" "$u: on: the last line"
    assert_eq "$pool" "$(cat "$CL_HOME/.config/nice-dns/bridges.env")" "$u: the bridge pool is still untouched"
  done
}

t_bridges_status_reads_the_mode_back() {
  local u
  for u in $(cl_platforms); do
    st_world "$u"; bt_restart_fakes
    cl_run "$CL_TREE/nice-dns" bridges status
    assert_rc 0 "$CL_RC" "$u: bridges status: $CL_ERR"
    assert_eq "mode	on
count	3
last_refresh	$((ST_NOW - 3600))" "$CL_OUT" "$u: absent means on, with the pool size and the last refresh"
    cl_run "$CL_TREE/nice-dns" bridges off
    cl_run "$CL_TREE/nice-dns" bridges status
    assert_rc 0 "$CL_RC" "$u: bridges status after off: $CL_ERR"
    assert_eq "mode	off
count	3
last_refresh	$((ST_NOW - 3600))" "$CL_OUT" "$u: status reads off back"
    ND_STATUS_NOW="$ST_NOW" cl_run "$CL_TREE/nice-dns" status --tsv
    assert_match "^bridges	mode	off$" "$CL_OUT" "$u: status --tsv shows the mode"
    cl_run "$CL_TREE/nice-dns" bridges on
    : >"$CL_LOG"
    ND_STATUS_NOW="$ST_NOW" cl_run "$CL_TREE/nice-dns" status --tsv
    assert_match "^bridges	mode	on$" "$CL_OUT" "$u: and on again"
    cl_run "$CL_TREE/nice-dns" bridges status
    assert_eq "" "$(cl_calls .)" "$u: bridges status runs nothing"
  done
}

t_bridges_bad_arguments_are_usage_errors() {
  local args
  st_world Linux
  for args in "bridges" "bridges frobnicate" "bridges On" "bridges off on" "bridges status --tsv" "bridges --help"; do
    # shellcheck disable=SC2086  # each row is a word list
    cl_run "$CL_TREE/nice-dns" $args
    assert_rc 2 "$CL_RC" "[$args] is a usage error"
    assert_match '^Usage: nice-dns' "$CL_ERR" "[$args]: usage on stderr"
    assert_eq "" "$CL_OUT" "[$args]: nothing on stdout"
    assert_no_path "$(bt_mode_file)" "[$args]: no mode file"
  done
}

t_bridges_not_installed_exits_1_and_writes_nothing() {
  local u sub
  for u in $(cl_platforms); do
    for sub in off on status; do
      cl_world "$u"; mkdir -p "$CL_HOME/.config/nice-dns"
      cl_run "$CL_TREE/nice-dns" bridges "$sub"
      assert_rc 1 "$CL_RC" "$u bridges $sub: exit 1"
      # shellcheck disable=SC2016  # the backticks are text for the reader
      assert_match 'nice-dns is not installed; run `nice-dns install`' "$CL_ERR" "$u bridges $sub: the message"
      assert_eq "" "$CL_OUT" "$u bridges $sub: nothing on stdout"
      assert_no_path "$(bt_mode_file)" "$u bridges $sub: the mode file is not written"
      assert_eq "" "$(cl_calls .)" "$u bridges $sub: nothing ran"
    done
  done
}

t_bridges_an_unwritable_mode_file_names_the_path() {
  local u d
  for u in $(cl_platforms); do
    st_world "$u"; bt_restart_fakes; d="$CL_HOME/.config/nice-dns"
    cl_run "$CL_TREE/nice-dns" bridges on
    chmod 500 "$d"
    cl_run "$CL_TREE/nice-dns" bridges off
    chmod 700 "$d"
    assert_nonzero "$CL_RC" "$u: an unwritable directory fails"
    assert_match "$d/bridges-mode.env" "$CL_ERR" "$u: the error names the path"
    assert_not_match "takes effect" "$CL_OUT" "$u: no success line"
    assert_eq "TOR_BRIDGES=on" "$(cat "$(bt_mode_file)")" "$u: the mode is unchanged"
    assert_eq "" "$(find "$d" -name '.bridges-mode*')" "$u: no temporary file is left"
    rm -rf "${d:?}"
    cl_run "$CL_TREE/nice-dns" bridges off
    assert_nonzero "$CL_RC" "$u: a missing config directory fails"
    assert_match "$d/bridges-mode.env" "$CL_ERR" "$u: and names the path"
    assert_no_path "$d" "$u: nothing is created"
  done
}

t_bridges_is_in_the_help() {
  cl_world Linux
  cl_run "$CL_TREE/nice-dns" --help
  assert_match "^  bridges on\|off\|status" "$CL_OUT" "--help lists bridges"
}

# ─────── Bridges toggle plan, Task 1.4: a mode change restarts the proxy ─────

# bt_restart_fakes: st_world plus a runtime that answers. A proxy restart
# (Linux: its unit; macOS: the agent's kickstart) starts a new container and
# records whether the controller's state lock was held at that moment.
bt_restart_fakes() {
  local f
  CL_RESTART_PLAT=linux
  if [ "$CL_UNAME" = Darwin ]; then
    CL_RESTART_PLAT=macos
    mkdir -p "$CL_HOME/Library/LaunchAgents"
    : >"$CL_HOME/Library/LaunchAgents/org.nice-dns.health.plist"
    : >"$CL_HOME/Library/LaunchAgents/org.nice-dns.health-bridges.plist"
    : >"$CL_HOME/Library/LaunchAgents/org.nice-dns.health-update.plist"
  fi
  echo 1 >"$CL_FAKE/gen"
  # The installed proxy launcher carries the mode, as an install of this
  # branch leaves it (Linux: the quadlet; macOS: the agent under ND_INST_ROOT).
  BT_ROOT="$CL_W/root"; export ND_INST_ROOT="$BT_ROOT"
  if [ "$CL_UNAME" = Darwin ]; then BT_LAUNCHER="$BT_ROOT/usr/local/sbin/start-container.sh"; else BT_LAUNCHER="$CL_HOME/.config/containers/systemd/tor-haproxy.container"; fi
  mkdir -p "${BT_LAUNCHER%/*}"
  printf 'PodmanArgs=--env TOR_BRIDGES\n' >"$BT_LAUNCHER"
  f="$CL_FAKE/proxy-restarted"
  cat >"$f" <<EOF2
#!/bin/bash
if [ -L "$ST_SD/lock" ]; then echo "proxy restart: lock held" >>"$CL_LOG"; else echo "proxy restart: lock free" >>"$CL_LOG"; fi
echo \$(( \$(cat "$CL_FAKE/gen") + 1 )) >"$CL_FAKE/gen"
EOF2
  chmod +x "$f"
  cat >"$CL_FAKE/podman" <<EOF2
#!/bin/bash
echo "podman \$*" >>"$CL_LOG"
case "\$1" in
  ps) printf 'pi-hole\nunbound\ntor-haproxy\n' ;;
  inspect) echo "id\$(cat "$CL_FAKE/gen") 2026-11-07T00:00:0\$(cat "$CL_FAKE/gen")Z running" ;;
esac
exit 0
EOF2
  cat >"$CL_FAKE/container" <<EOF2
#!/bin/bash
echo "container \$*" >>"$CL_LOG"
case "\$1" in
  ls) g="\$(cat "$CL_FAKE/gen")"
      printf 'ID IMAGE STATE STARTED\npi-hole p running t%s\nunbound u running t%s\ntor-haproxy t running t%s\n' "\$g" "\$g" "\$g" ;;
esac
exit 0
EOF2
  cat >"$CL_FAKE/systemctl" <<EOF2
#!/bin/bash
echo "systemctl \$*" >>"$CL_LOG"
case "\$*" in
  *is-active*) exit 0 ;;
  *"restart tor-"*)
    [ -f "$CL_FAKE/restart_rc" ] && { echo "the restart broke" >&2; exit "\$(cat "$CL_FAKE/restart_rc")"; }
    "$CL_FAKE/proxy-restarted" ;;
esac
exit 0
EOF2
  cat >"$CL_FAKE/launchctl" <<EOF2
#!/bin/bash
echo "launchctl \$*" >>"$CL_LOG"
case "\$*" in
  *kickstart*)
    [ -f "$CL_FAKE/restart_rc" ] && { echo "the restart broke" >&2; exit "\$(cat "$CL_FAKE/restart_rc")"; }
    rm -f "\$HOME/.local/state/nice-dns/restart-requested"
    "$CL_FAKE/proxy-restarted" ;;
  print*) printf '\tstate = not running\n' ;;
esac
exit 0
EOF2
  chmod +x "$CL_FAKE"/*
}
bt_proxy_restart_pat() { if [ "$CL_RESTART_PLAT" = linux ]; then echo '^systemctl --user restart tor-haproxy\.service$'; else echo '^launchctl kickstart -k gui/'; fi; }
bt_journal() { cat "$ST_SD/recovery.tsv" 2>/dev/null; }

t_bridges_a_mode_change_restarts_the_proxy_under_the_lock() {
  local u m id hold rs rel
  for u in $(cl_platforms); do
    st_world "$u"; bt_restart_fakes
    for m in off on; do
      : >"$CL_LOG"
      cl_run "$CL_TREE/nice-dns" bridges "$m"
      assert_rc 0 "$CL_RC" "$u bridges $m: $CL_ERR"
      assert_eq "TOR_BRIDGES=$m" "$(cat "$(bt_mode_file)")" "$u: $m is written"
      assert_eq 1 "$(grep -cE "$(bt_proxy_restart_pat)" "$CL_LOG")" "$u $m: one proxy restart"
      assert_eq "proxy restart: lock held" "$(grep '^proxy restart:' "$CL_LOG")" "$u $m: the state lock is held during the restart"
      hold="$(cl_line "$(cl_hold_pat)" tail)"; rs="$(cl_line "$(bt_proxy_restart_pat)" head)"; rel="$(cl_line "$(cl_release_pat)" head)"
      [ -n "$hold" ] && [ "$hold" -lt "$rs" ] && [ "$rs" -lt "$rel" ] || fail "$u $m: hold, restart, release in that order:
$(cat "$CL_LOG")"
      cl_assert_released "$u $m"
      id="$(awk -F '\t' -v m="$m" '$3 == "bridges" && $4 == "mode-change" && $5 == m { print $2 }' "$ST_SD/recovery.tsv" | tail -n 1)"
      assert_match "^bridges-$m-[0-9]+\$" "$id" "$u $m: the change is journalled under its own request"
      assert_match "$id	service	requested	" "$(bt_journal)" "$u $m: requested"
      assert_match "$id	service	acknowledged	" "$(bt_journal)" "$u $m: acknowledged"
      assert_match '^dig ' "$(cat "$CL_LOG")" "$u $m: DNS is checked after the restart"
      assert_eq "Bridges are $m; the proxy restarted and DNS is answering." "$(printf '%s\n' "$CL_OUT" | tail -n 1)" "$u $m: the last line"
    done
  done
}

t_bridges_an_unchanged_mode_restarts_nothing() {
  local u
  for u in $(cl_platforms); do
    st_world "$u"; bt_restart_fakes
    : >"$CL_LOG"
    cl_run "$CL_TREE/nice-dns" bridges on
    assert_rc 0 "$CL_RC" "$u: on over no mode file (on): $CL_ERR"
    assert_eq "TOR_BRIDGES=on" "$(cat "$(bt_mode_file)")" "$u: the mode is written"
    assert_eq "Bridges are already on; nothing restarted." "$(printf '%s\n' "$CL_OUT" | tail -n 1)" "$u: the last line"
    assert_eq "" "$(cl_calls .)" "$u: nothing held, restarted or checked"
    assert_not_match 'mode-change' "$(bt_journal)" "$u: nothing journalled"
    cl_run "$CL_TREE/nice-dns" bridges off
    : >"$CL_LOG"
    cl_run "$CL_TREE/nice-dns" bridges off
    assert_rc 0 "$CL_RC" "$u: off again: $CL_ERR"
    assert_eq "" "$(cl_calls .)" "$u: off over off runs nothing"
    assert_eq 1 "$(grep -c 'mode-change' "$ST_SD/recovery.tsv")" "$u: one change, one journal row"
  done
}

t_bridges_a_failed_restart_names_the_written_mode() {
  st_world Linux; bt_restart_fakes
  echo 5 >"$CL_FAKE/restart_rc"
  cl_run "$CL_TREE/nice-dns" bridges off
  assert_rc 1 "$CL_RC" "a failed restart fails"
  assert_match 'next proxy start' "$CL_ERR" "the error says when the mode applies"
  assert_match 'Run `nice-dns restart` to apply it now' "$CL_ERR" "and how to apply it now (asking for off again restarts nothing)"
  assert_eq "TOR_BRIDGES=off" "$(cat "$(bt_mode_file)")" "the mode stays written"
  assert_eq "" "$(cl_calls '^dig ')" "no DNS wait after a failed restart"
  cl_assert_released Linux
}

t_bridges_a_busy_controller_changes_nothing() {
  local d="$CASE_DIR/state-busy-br"
  st_world Linux; bt_restart_fakes
  mkdir -p "$d"; chmod 700 "$d"
  ln -s "nd-lock:$$:$(cat /proc/sys/kernel/random/boot_id):$(date +%s):tok" "$d/lock"
  ND_STATE_DIR="$d" ND_CLI_LOCK_TRIES=1 cl_run "$CL_TREE/nice-dns" bridges off
  assert_rc 1 "$CL_RC" "a busy controller refuses: $CL_ERR"
  assert_match 'still busy' "$CL_ERR" "the message"
  assert_no_path "$(bt_mode_file)" "the mode is not written"
  assert_eq 0 "$(grep -cE "$(bt_proxy_restart_pat)" "$CL_LOG")" "no restart while a pass runs"
  cl_assert_released Linux
}

t_bridges_releases_on_a_signal() {
  local u pid i
  for u in $(cl_platforms); do
    st_world "$u"; bt_restart_fakes
    : >"$CL_FAKE/no_dns"
    HOME="$CL_HOME" PATH="$CL_FAKE:$PATH" TMPDIR="$CASE_DIR" XDG_STATE_HOME="" XDG_CONFIG_HOME="" ND_INST_READY_TRIES=50 \
      bash "$CL_TREE/nice-dns" bridges off >"$CL_W/out" 2>"$CL_W/err" &
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
    assert_no_path "$ST_SD/lock" "$u: the lock is given back"
    assert_eq "" "$(find "$CASE_DIR" -maxdepth 1 -name 'nice-dns-restart.*')" "$u: its temporary directory is gone"
  done
}

# Stage 1 gate (demo B1): a mode path that is a directory is not written into.
# `mv` would move the temporary file inside it and the restart would run with
# the mode unchanged.
t_bridges_a_mode_path_that_is_a_directory_is_refused() {
  local u d
  for u in $(cl_platforms); do
    st_world "$u"; bt_restart_fakes; d="$CL_HOME/.config/nice-dns"
    mkdir -p "$d/bridges-mode.env"
    : >"$CL_LOG"
    cl_run "$CL_TREE/nice-dns" bridges off
    assert_rc 1 "$CL_RC" "$u: a directory in place of the mode file fails"
    assert_match "$d/bridges-mode.env" "$CL_ERR" "$u: the error names the path"
    assert_eq "" "$(find "$d/bridges-mode.env" -mindepth 1)" "$u: nothing is written inside it"
    assert_eq 0 "$(grep -cE "$(bt_proxy_restart_pat)" "$CL_LOG")" "$u: nothing restarted"
    assert_not_match 'mode-change' "$(bt_journal)" "$u: nothing journalled"
    cl_assert_released "$u"
  done
}

# Stage 1 gate (demo Material 1): a launcher from before the switch would start
# the proxy without the mode, so the switch would report a change Tor never
# sees. It is refused before anything is held.
t_bridges_an_install_older_than_the_switch_is_refused() {
  local u
  for u in $(cl_platforms); do
    st_world "$u"; bt_restart_fakes
    printf 'EnvironmentFile=%%h/.config/nice-dns/bridges.env\n' >"$BT_LAUNCHER"
    : >"$CL_LOG"
    cl_run "$CL_TREE/nice-dns" bridges off
    assert_rc 1 "$CL_RC" "$u: an older install refuses the switch"
    assert_match 'nice-dns update' "$CL_ERR" "$u: and says how to get the switch"
    assert_match "$BT_LAUNCHER" "$CL_ERR" "$u: naming the launcher it read"
    assert_no_path "$(bt_mode_file)" "$u: the mode is not written"
    assert_eq "" "$(cl_calls .)" "$u: nothing held or restarted"
    rm -f "$BT_LAUNCHER"
    cl_run "$CL_TREE/nice-dns" bridges off
    assert_rc 1 "$CL_RC" "$u: no launcher at all refuses too"
    unset ND_INST_ROOT
  done
}
