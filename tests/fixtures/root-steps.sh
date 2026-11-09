# shellcheck shell=bash
# The root steps of an install lifecycle in the installer world
# (tests/fixtures/install-fakes.sh), normalised for an exact comparison with
# the recorded sequence (tests/fixtures/root-steps-<platform>.txt), which is
# what the installers ran before root-ops (Sub-plan 5, Tasks 1.1 and 1.2):
# moving a step into root-ops changes none of it. A root-ops line itself is
# not a step; the sudo lines root-ops takes in its test mode are.
# Sourced after install-fakes.sh; needs its dt_* and ip_* helpers.

# rs_lifecycle <linux|macos>: a first install, a flavour and proxy switch, a
# failed reinstall (its rollback) and an uninstall, each step's exit status
# and root steps on stdout.
rs_lifecycle() {
  local os
  if [ "$1" = linux ]; then os=deb; else os=mac; fi
  dt_world "install-$os-hardened" "$(dt_fresh_state "install-$os")"
  echo "## first install"; rs_step "install-$os" haproxy
  printf 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\n' >"$FAKE/git_head"
  echo "## flavour and proxy switch"; rs_step "install-$os-hardened" socat
  printf 'cccccccccccccccccccccccccccccccccccccccc\n' >"$FAKE/git_head"
  : >"$FAKE/never_ready"
  echo "## failed reinstall"; rs_step "install-$os" haproxy
  rm -f "$FAKE/never_ready"
  echo "## uninstall"; rs_step "install-$os-hardened" uninstall
}

rs_step() {
  : >"$FAKE_LOG"
  ip_install "$@"
  printf 'rc %s\n' "$IP_RC"
  rs_root_lines "$FAKE_LOG"
  cat "$FAKE_LOG" >>"$FAKE/all-calls.log"
}

# rs_root_lines <log>: its sudo lines but root-ops', the world's paths as <W>,
# a rollback's saved copy (or root-ops' temporary one) as <SAVED>, and the
# generation ids as <G>.
rs_root_lines() {
  grep -E '^sudo ' "$1" | grep -Ev '^sudo bash [^ ]*/(deb|mac)/root-ops( |$)' |
    awk -v w="$IP_W" '{ while ((i = index($0, w)) > 0) $0 = substr($0, 1, i - 1) "<W>" substr($0, i + length(w)); print }' |
    sed -e 's#<W>/tmp/tmp\.[A-Za-z0-9]*#<SAVED>#g' \
        -e 's#<W>/home/[^<]*/rollback/s[0-9]*#<SAVED>#g' \
        -e 's#\.nice-dns-install\.[A-Za-z0-9]*#.nice-dns-install.<X>#g' \
        -e 's#generations/[^/ ]*#generations/<G>#g'
}
