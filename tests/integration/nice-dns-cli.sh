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
