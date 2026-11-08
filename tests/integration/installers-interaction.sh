# shellcheck shell=bash
# Group integration/installers-interaction (Sub-plan 4, Stage 1 gate;
# ARCH-03, ARCH-05, ARCH-06, ARCH-08; WF-DNS-003).
#
# Sourced by tests/run.sh (assert_* helpers; NICE_DNS_ROOT, CASE_DIR). The
# Stage 1 outputs together, in the installer world (tests/fixtures/
# install-fakes.sh): shared preparation (Task 1.1), the owned-DNS transaction
# (Task 1.2) and the locked inputs (Task 1.3), across a lifecycle that
# switches flavour and proxy, fails, is interrupted and ends in an uninstall.
# Every platform runs; the standard and hardened entrypoints share one state.
#
# Scenarios: OP-OWNED-RESTORE, OP-NO-HOST-PUBLIC, OP-BOOTSTRAP.

. "$NICE_DNS_ROOT/tests/fixtures/install-fakes.sh"

II_BOOT="$NICE_DNS_ROOT/release/bootstrap.tsv"
# Calls that use the network (or run a step that does), whatever the tool.
II_NET='^(sudo )?(apt-get (update|install)|add-apt-repository)|^git clone|^podman (pull|build)|^container (image pull|build |builder start|system start)|^curl |^(HOMEBREW_NO_AUTO_UPDATE=1 )?brew (update|install|upgrade|fetch)|^sudo softwareupdate|^cosign |^persistent-podman\.sh '

ii_platforms() { printf 'linux macos\n'; }
ii_ep() { if [ "$2" = hardened ]; then echo "install-$1-hardened"; else echo "install-$1"; fi; }   # <deb|mac> <flavor>
ii_os() { if [ "$1" = linux ]; then echo deb; else echo mac; fi; }

# ii_step <what> <entrypoint> [args...]: one lifecycle step in the current
# world; after it the owned DNS state is the original or the pin, nothing else.
ii_step() {
  local what="$1" ep="$2" st
  shift 2
  ip_install "$ep" "$@"
  II_RC="$IP_RC"
  st="$(dt_dns_state)"
  if [ "$st" != "$II_DNS0" ] && ! dt_pinned; then
    fail "$what: host DNS is neither the recorded original nor the pin:
$st"
  fi
  assert_eq "" "$(grep -E '^sudo tee [^ ]*resolv\.conf' "$FAKE_LOG")" "$what: no installer writes resolv.conf"
  if [ -f "$FAKE_ROOT/.netsvc/list" ]; then
    ii_mac_writes_are_pin_or_recorded "$what"
  fi
}

# ii_mac_writes_are_pin_or_recorded <what>: every network-service DNS write of
# the step (the helpers', through the fake networksetup) sets the pin or the
# servers recorded for that service before nice-dns.
ii_mac_writes_are_pin_or_recorded() {
  local rest svc rec ok
  while IFS= read -r rest; do
    [ -n "$rest" ] || continue
    ok=0
    while IFS= read -r svc; do
      rec="$(printf '%s\n' "$II_DNS0" | awk -v s="$svc" 'index($0, "service " s ": ") == 1 { print substr($0, length("service " s ": ") + 1); exit }')"
      [ -n "$rec" ] || rec=Empty
      case "$rest" in "$svc 172.31.240.250"|"$svc $rec") ok=1 ;; esac
    done <"$FAKE_ROOT/.netsvc/list"
    [ "$ok" = 1 ] || fail "$1: a DNS write that is neither the pin nor the recorded servers: networksetup -setdnsservers $rest"
  done <<EOF
$(sed -n 's/^\(sudo \)\{0,1\}networksetup -setdnsservers //p' "$FAKE_LOG")
EOF
}

# One world per platform: standard haproxy, then hardened socat, then a
# failed standard reinstall (and an interrupted one), then uninstall.
t_lifecycle_restores_exactly_what_it_owns() {
  local plat
  for plat in $(ii_platforms); do
    (
      local os dep_b cur_b
      os="$(ii_os "$plat")"
      dt_world "$(ii_ep "$os" hardened)" "$(dt_fresh_state "$(ii_ep "$os" standard)")"
      II_DNS0="$(dt_dns_state)"
      ii_step "$plat: standard haproxy" "$(ii_ep "$os" standard)" haproxy
      assert_rc 0 "$II_RC" "$plat: first install: $IP_OUT"
      dt_pinned || fail "$plat: pinned after the first install"
      printf 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\n' >"$FAKE/git_head"
      ii_step "$plat: hardened socat" "$(ii_ep "$os" hardened)" socat
      assert_rc 0 "$II_RC" "$plat: flavour and proxy switch: $IP_OUT"
      dep_b="$(dt_deploy_state)"; cur_b="$(cat "$IP_STATE/current")"
      assert_match 'tor-socat' "$dep_b" "$plat: the socat deployment runs"
      printf 'cccccccccccccccccccccccccccccccccccccccc\n' >"$FAKE/git_head"
      : >"$FAKE/never_ready"
      ii_step "$plat: failed standard reinstall" "$(ii_ep "$os" standard)" haproxy
      rm -f "$FAKE/never_ready"
      assert_nonzero "$II_RC" "$plat: the failed reinstall fails"
      assert_eq "$dep_b" "$(dt_deploy_state)" "$plat: the hardened socat deployment is back"
      assert_eq "$cur_b" "$(cat "$IP_STATE/current")" "$plat: and still current"
      if [ "$plat" = linux ]; then printf '^podman system migrate\n' >"$FAKE/sigint"; else printf '^container build \n' >"$FAKE/sigint"; fi
      ii_step "$plat: interrupted standard reinstall" "$(ii_ep "$os" standard)" haproxy
      rm -f "$FAKE/sigint"
      assert_nonzero "$II_RC" "$plat: the interrupted reinstall fails"
      assert_eq "$dep_b" "$(dt_deploy_state)" "$plat: the hardened socat deployment is back again"
      ii_step "$plat: uninstall" "$(ii_ep "$os" hardened)" uninstall
      assert_rc 0 "$II_RC" "$plat: uninstall: $IP_OUT"
      assert_eq "$II_DNS0" "$(dt_dns_state)" "$plat: exactly the DNS state recorded before nice-dns"
      assert_no_path "$(dt_receipt "$plat")" "$plat: no record is left"
      assert_no_path "$IP_STATE/current" "$plat: nothing is current"
      assert_eq "" "$(awk '$1 ~ /:latest$/ && $1 ~ /(unbound|pi-hole|tor-(haproxy|socat))/' "$FAKE/images")" "$plat: no deployment image is left"
    ) || exit 1
  done
}

# The same lifecycle, watched for public DNS: every step leaves the owned
# state at the original or the pin, and no installer writes host DNS itself
# (ii_step); the helpers write only those two values
# (dns-transaction t_no_installer_writes_the_resolver_directly).
t_no_step_points_the_host_at_public_dns() {
  local plat
  for plat in $(ii_platforms); do
    (
      local os inj
      os="$(ii_os "$plat")"
      dt_world "$(ii_ep "$os" standard)" "$(dt_fresh_state "$(ii_ep "$os" standard)")"
      II_DNS0="$(dt_dns_state)"
      # A failed first install, then the real one, then failures of every
      # kind on the reinstall, then uninstall.
      : >"$FAKE/persist_fail"; ii_step "$plat: failed first install" "$(ii_ep "$os" standard)"; rm -f "$FAKE/persist_fail"
      assert_eq "$II_DNS0" "$(dt_dns_state)" "$plat: a failed first install leaves the original"
      # A new source commit: two generations in one (fake) second must not collide.
      printf 'dddddddddddddddddddddddddddddddddddddddd\n' >"$FAKE/git_head"
      ii_step "$plat: install" "$(ii_ep "$os" standard)"
      assert_rc 0 "$II_RC" "$plat: $IP_OUT"
      for inj in persist_fail never_ready selfcheck_fail probe_fail; do
        printf '%s\n' "$(printf '%s' "$inj" | od -An -tx1 | tr -d ' \n' | cut -c1-12)aaaaaaaaaaaaaaaaaaaaaaaaaaaa" >"$FAKE/git_head"
        : >"$FAKE/$inj"; ii_step "$plat: reinstall with $inj" "$(ii_ep "$os" standard)" socat; rm -f "$FAKE/$inj"
        assert_nonzero "$II_RC" "$plat: $inj fails the reinstall"
        dt_pinned || fail "$plat: after $inj the host stays pinned (fails closed): $(dt_dns_state)"
      done
      ii_step "$plat: uninstall" "$(ii_ep "$os" standard)" uninstall
      assert_eq "$II_DNS0" "$(dt_dns_state)" "$plat: uninstall gives back the original"
    ) || exit 1
  done
}

# ii_declared <platform> <call> <phase>: the call matches a declared
# exception of this platform and phase.
ii_declared() {
  local plat="$1" call="$2" phase="$3" kind p ere ph
  while IFS="$(printf '\t')" read -r kind _ p ere ph _; do
    [ "$kind" = exception ] || continue
    [ "$p" = all ] || [ "$p" = "$plat" ] || continue
    [ "$ph" = "$phase" ] || continue
    if printf '%s\n' "$call" | grep -Eq -- "$ere"; then return 0; fi
  done <"$II_BOOT"
  return 1
}

# Every network use of an install is a declared exception in its phase; after
# the interruption only calls that need no host resolver run.
t_bootstrap_use_is_declared() {
  local ep hits f
  for f in lib/install.sh deb/persistent-podman.sh mac/persist.sh deb/root-ops mac/root-ops lib/root.sh; do
    assert_file "$NICE_DNS_ROOT/$f" "the network-tool scan reads $f"
  done
  hits="$(grep -nE '(^|[[:space:];|&(])(wget|ncat|nc|rsync|scp|ssh) ' "$NICE_DNS_ROOT"/lib/install.sh "$NICE_DNS_ROOT"/install-*.sh \
    "$NICE_DNS_ROOT"/deb/persistent-podman.sh "$NICE_DNS_ROOT"/mac/persist.sh "$NICE_DNS_ROOT"/deb/root-ops "$NICE_DNS_ROOT"/mac/root-ops \
    "$NICE_DNS_ROOT"/lib/root.sh | grep -vE ':[0-9]+:[[:space:]]*#' || true)"
  assert_eq "" "$hits" "the installers use no network tool the inventory does not classify"
  assert_eq "$(printf 'schema\tnice-dns-bootstrap/1')" "$(head -n 1 "$II_BOOT")" "the inventory's schema"
  for ep in install-deb install-deb-hardened install-mac install-mac-hardened; do
    (
      local plat first n=0 line call ph
      plat="$(ip_platform "$ep")"
      dt_world "$ep" "$(dt_fresh_state "$ep")"
      ln -s fakecmd "$IP_BIN/cosign"
      [ "$plat" = macos ] && printf 'container\n' >"$FAKE/brew_outdated"
      dt_installed "$ep"
      [ "$plat" = macos ] && printf 'container\n' >"$FAKE/brew_outdated"
      ip_install "$ep" socat
      assert_rc 0 "$IP_RC" "$ep reinstall: $IP_OUT"
      first="$(ip_first "$FAKE_LOG" "$IP_DISRUPTIVE")"
      assert_ne "" "$first" "$ep: the reinstall interrupts"
      while IFS= read -r line; do
        n=$((n + 1))
        call="${line#*:}"
        if [ "${line%%:*}" -lt "$first" ]; then ph=preparation; else ph=interruption; fi
        ii_declared "$plat" "$call" "$ph" || fail "$ep: undeclared network use in $ph: $call"
      done <<EOF
$(ip_lines "$FAKE_LOG" "$II_NET")
EOF
      assert_ne 0 "$n" "$ep: the network uses were classified"
      if [ "$plat" = macos ]; then
        assert_match '^brew fetch --formula container$' "$(sed -n "1,${first}p" "$FAKE_LOG")" "$ep: the runtime upgrade is fetched in preparation"
        assert_match '^HOMEBREW_NO_AUTO_UPDATE=1 brew upgrade --formula container$' "$(sed -n "${first},\$p" "$FAKE_LOG")" "$ep: and applied offline in the interruption"
      fi
    ) || exit 1
  done
}

# root-ops (Sub-plan 5 Task 1.1): run as a user it refuses (exit 1) before
# anything; an unknown verb or a malformed argument exits 2, naming it, with
# nothing run. A fake sudo that logs every call stands for its test mode; one
# that is setuid is not a test sudo, so the user is refused as well.
t_root_ops_refuses_before_running_anything() {
  local w="$CASE_DIR/ro" os out rc
  mkdir -p "$w/bin"
  printf '#!/bin/sh\nprintf "sudo %%s\\n" "$*" >>"%s/log"\n' "$w" >"$w/bin/sudo"; chmod 755 "$w/bin/sudo"
  for os in $(ro_oses); do
    : >"$w/log"
    rc=0; out="$(env -u ND_ROOT_TEST_SUDO bash "$NICE_DNS_ROOT/$os/root-ops" pin 2>&1)" || rc=$?
    assert_eq 1 "$rc" "$os: a user run exits 1"
    assert_match 'must run as root' "$out" "$os: and says why"
    # The host's setuid sudo; a malformed call, so that a wrongly accepted
    # test sudo exits 2 before anything runs instead of 1.
    if [ -u /usr/bin/sudo ]; then
      rc=0; out="$(ND_ROOT_TEST_SUDO=/usr/bin/sudo bash "$NICE_DNS_ROOT/$os/root-ops" pin extra 2>&1)" || rc=$?
      assert_eq 1 "$rc" "$os: a setuid program is no test sudo: $out"
    fi
    for bad in "frob" "pin extra" "dns frob" "dns" "save-previous /etc/shadow" "restore /etc/passwd -" \
               "restore $(ND_INST_ROOT='' ro_owned "$os") /etc/shadow" ""; do
      rc=0
      # shellcheck disable=SC2086  # the words are the call
      out="$(ND_ROOT_TEST_SUDO="$w/bin/sudo" ND_INST_ROOT='' bash "$NICE_DNS_ROOT/$os/root-ops" $bad 2>&1)" || rc=$?
      assert_eq 2 "$rc" "$os: '$bad' exits 2: $out"
      assert_match "root-ops: " "$out" "$os: '$bad' is named"
    done
    rc=0; out="$(ND_ROOT_TEST_SUDO="$w/bin/sudo" ND_INST_ROOT='' bash "$NICE_DNS_ROOT/$os/root-ops" "$(ro_helper_verb "$os")" "check status" 2>&1)" || rc=$?
    assert_eq 2 "$rc" "$os: a run of helper verbs in one argument exits 2: $out"
    assert_eq "" "$(cat "$w/log")" "$os: nothing ran"
  done
}

# ro_oses: the trees with a root-ops.
ro_oses() { echo deb mac; }

# ro_helper_verb <os>: the verb that runs the DNS helper.
ro_helper_verb() { if [ "$1" = deb ]; then echo dns; else echo agent; fi; }

# ro_owned <os>: one root file the installer keeps for a rollback.
ro_owned() { if [ "$1" = deb ]; then echo /usr/bin/custom-dns-deb; else echo /etc/sudoers.d/start-container; fi; }

# The root rows of the rollback list (lib/install.sh _nd_inst_owned_paths)
# are exactly what root-ops lets a rollback read and write back, each with
# the mode the list records.
t_root_ops_owns_the_rollback_list() {
  local w="$CASE_DIR/rl" os plat p mode who n=0
  mkdir -p "$w/bin" "$w/root/usr/local/sbin" "$w/root/etc/sudoers.d"
  chmod 755 "$w/root/usr/local" "$w/root/usr/local/sbin"
  printf '#!/bin/sh\nprintf "sudo %%s\\n" "$*" >>"%s/log"\n' "$w" >"$w/bin/sudo"; chmod 755 "$w/bin/sudo"
  for os in $(ro_oses); do
    if [ "$os" = deb ]; then plat=linux; else plat=macos; fi
    while IFS="$(printf '\t')" read -r _ p mode who; do
      [ "$who" = root ] || continue
      n=$((n + 1)); : >"$w/log"
      printf 'x\n' | ND_ROOT_TEST_SUDO="$w/bin/sudo" ND_INST_ROOT="$w/root" TMPDIR="$w" bash "$NICE_DNS_ROOT/$os/root-ops" restore "$p" - >/dev/null 2>&1
      assert_match "^sudo install -m $mode [^ ]* $p\$" "$(cat "$w/log")" "$os: root-ops restores $p with mode $mode"
    done <<ROWS
$(HOME=/nonexistent ND_INST_ROOT="$w/root" ND_INST_PLATFORM="$plat" ND_INST_SRC="$NICE_DNS_ROOT" bash -c '. "$1/lib/install.sh"; _nd_inst_owned_paths' _ "$NICE_DNS_ROOT")
ROWS
    assert_eq 1 "$(( n >= 5 ))" "$os: the list has its root rows ($n)"
  done
}

# Moving the root steps into root-ops changes none of them: an install
# lifecycle's root steps, normalised, are exactly the ones recorded from the
# installers before root-ops (tests/fixtures/root-steps.sh).
t_root_steps_are_the_recorded_ones() {
  . "$NICE_DNS_ROOT/tests/fixtures/root-steps.sh"
  local plat got
  for plat in $(ii_platforms); do
    rs_lifecycle "$plat" >"$CASE_DIR/root-steps-$plat" 2>&1
    got="$(cat "$CASE_DIR/root-steps-$plat")"
    assert_eq "$(cat "$NICE_DNS_ROOT/tests/fixtures/root-steps-$plat.txt")" "$got" "$plat: the root steps and their order"
    # Every root step ran inside root-ops: the sudo lines but root-ops' own
    # are, as a multiset, the ones root-ops took.
    assert_eq "$(sort "$FAKE/root-inner.log" 2>/dev/null)" \
      "$(grep -E '^sudo ' "$FAKE/all-calls.log" | grep -Ev '^sudo bash [^ ]*/(deb|mac)/root-ops( |$)' | sort)" \
      "$plat: no root step ran outside root-ops"
    if [ "$plat" = linux ]; then
      assert_ne "" "$(grep -E '^sudo bash [^ ]*/deb/root-ops pin$' "$FAKE/all-calls.log")" "$plat: the pin is a root-ops verb"
    else
      assert_ne "" "$(grep -E '^sudo bash [^ ]*/mac/root-ops teardown reinstall$' "$FAKE/all-calls.log")" "$plat: the teardown is a root-ops verb"
    fi
  done
}

# mac/root-ops runs on macOS's Bash 3.2: the docker.io/library/bash:3.2
# image (as tests/unit/state-policy.sh uses it; --rm, no network) parses it,
# and its refusals run there too, as root.
t_bash32_parses_mac_root_ops() {
  local img=docker.io/library/bash:3.2 out
  if ! podman image exists "$img" 2>/dev/null; then
    fail "image $img is not available locally; the Bash 3.2 proof cannot run (pull it: podman pull $img)"
  fi
  out="$(podman run --rm --network none --pull=never -v "$NICE_DNS_ROOT:/src:ro" "$img" bash -c '
    case "$BASH_VERSION" in 3.2.*) ;; *) echo "not bash 3.2: $BASH_VERSION"; exit 90 ;; esac
    bash -n /src/mac/root-ops || exit 91
    bash /src/mac/root-ops frob 2>&1; echo "unknown=$?"
    bash /src/mac/root-ops agent pre 2>&1; echo "agent-pre=$?"
    bash /src/deb/root-ops frob 2>&1; echo "deb-unknown=$?"' 2>&1)"
  assert_rc 0 $? "bash 3.2 run: $out"
  assert_match '^unknown=2$' "$out" "an unknown verb exits 2 under bash 3.2: $out"
  assert_match '^agent-pre=2$' "$out" "a helper verb the installer does not call exits 2: $out"
  # The container runs as root: the refusals hold after the environment scrub
  # (which once removed root-ops' own functions), for deb/root-ops too.
  assert_match '^deb-unknown=2$' "$out" "deb/root-ops as root: an unknown verb exits 2: $out"
  assert_not_match 'command not found' "$out" "no function of root-ops is lost as root: $out"
}

# The podman and crun versions are read as the installing user, with the
# user's PATH (a podman in /usr/local/bin or ~/.local/bin counts), never by
# root-ops with root's PATH (Stage 1 gate review, 2026-11-08).
t_versions_are_read_as_the_user() {
  assert_eq "" "$(grep -nE '(podman|crun) --version' "$NICE_DNS_ROOT/deb/root-ops" || true)" "root-ops reads no version"
  assert_match 'podman --version' "$(awk '/^nd_install_linux_host_prereqs\(\)/,/^}/' "$NICE_DNS_ROOT/lib/install.sh")" "the installer does"
}

# fix-bin-owner gives ~/.local/bin back to the user from the directory it
# entered and checked, and refuses a symlinked ~/.local or ~/.local/bin.
t_root_ops_fix_bin_owner() {
  local w="$CASE_DIR/fbo" rc out
  mkdir -p "$w/bin" "$w/h1/.local/bin" "$w/h2" "$w/h3/.local" "$w/elsewhere/bin"
  # shellcheck disable=SC2016  # expanded by the stub
  printf '#!/bin/sh\nprintf "sudo %%s|%%s\\n" "$*" "$(pwd -P)" >>"%s/log"\n' "$w" >"$w/bin/sudo"; chmod 755 "$w/bin/sudo"
  : >"$w/log"
  rc=0; out="$(cd / && ND_ROOT_TEST_SUDO="$w/bin/sudo" HOME="$w/h1" bash "$NICE_DNS_ROOT/deb/root-ops" fix-bin-owner 2>&1)" || rc=$?
  assert_eq 0 "$rc" "a real ~/.local/bin: $out"
  assert_eq "sudo chown -R -P --preserve-root $(id -u):$(id -g) .|$w/h1/.local/bin" "$(cat "$w/log")" "chown runs from the directory it checked"
  ln -s "$w/elsewhere" "$w/h2/.local"
  ln -s "$w/elsewhere/bin" "$w/h3/.local/bin"
  for h in h2 h3; do
    : >"$w/log"
    rc=0; out="$(ND_ROOT_TEST_SUDO="$w/bin/sudo" HOME="$w/$h" bash "$NICE_DNS_ROOT/deb/root-ops" fix-bin-owner 2>&1)" || rc=$?
    assert_eq 1 "$rc" "$h: a symlinked component is refused: $out"
    assert_eq "" "$(cat "$w/log")" "$h: nothing ran"
  done
}

# A root file root-ops reads or writes back is never a symlink, and the
# macOS helpers' directories must be root's (here the test user's) and
# writable by no one else, for every verb that touches them.
t_root_ops_refuses_symlinks_and_open_dirs() {
  local w="$CASE_DIR/sym" os p rc out
  mkdir -p "$w/bin" "$w/r/usr/bin" "$w/r/usr/local/sbin" "$w/r/etc/sudoers.d"
  chmod 755 "$w/r/usr/local" "$w/r/usr/local/sbin"
  printf '#!/bin/sh\nprintf "sudo %%s\\n" "$*" >>"%s/log"\n' "$w" >"$w/bin/sudo"; chmod 755 "$w/bin/sudo"
  ln -s /etc/hostname "$w/r/usr/bin/custom-dns-deb"
  ln -s /etc/hostname "$w/r/usr/local/sbin/start-container.sh"
  for os in deb mac; do
    if [ "$os" = deb ]; then p="$w/r/usr/bin/custom-dns-deb"; else p="$w/r/usr/local/sbin/start-container.sh"; fi
    : >"$w/log"
    rc=0; out="$(ND_ROOT_TEST_SUDO="$w/bin/sudo" ND_INST_ROOT="$w/r" bash "$NICE_DNS_ROOT/$os/root-ops" save-previous "$p" 2>&1)" || rc=$?
    assert_eq 1 "$rc" "$os: save-previous refuses a symlink: $out"
    rc=0; out="$(printf 'x\n' | ND_ROOT_TEST_SUDO="$w/bin/sudo" ND_INST_ROOT="$w/r" TMPDIR="$w" bash "$NICE_DNS_ROOT/$os/root-ops" restore "$p" - 2>&1)" || rc=$?
    assert_eq 1 "$rc" "$os: restore refuses a symlink: $out"
    assert_eq "" "$(cat "$w/log")" "$os: nothing ran"
  done
  rm -f "$w/r/usr/local/sbin/start-container.sh"
  chmod 775 "$w/r/usr/local/sbin"
  for v in "persist socat" "teardown reinstall" "save-previous $w/r/usr/local/sbin/start-container.sh"; do
    : >"$w/log"
    rc=0
    # shellcheck disable=SC2086  # the words are the call
    out="$(ND_ROOT_TEST_SUDO="$w/bin/sudo" ND_INST_ROOT="$w/r" bash "$NICE_DNS_ROOT/mac/root-ops" $v 2>&1)" || rc=$?
    assert_eq 1 "$rc" "mac $v: a group-writable /usr/local/sbin is refused: $out"
    assert_eq "" "$(cat "$w/log")" "mac $v: nothing ran"
  done
}

# A root-ops refusal (exit 2) stops the installer like any failed root step
# (Stage 1 Outcome 2; owner, 2026-11-08: shown by this case, since no user
# input reaches root-ops as an argument). The installer copy in the world is
# edited to hand root-ops a malformed call: at the first root step the
# install aborts with nothing changed; at a root step inside the interruption
# it rolls back to the deployment it replaced.
t_root_ops_refusal_aborts_or_rolls_back() {
  local plat
  for plat in $(ii_platforms); do
    (
      local os ep dns0 dep0 call
      os="$(ii_os "$plat")"; ep="install-$os"
      # The first root step: the ownership check.
      dt_world "$ep" "$(dt_fresh_state "$ep")"
      dns0="$(dt_dns_state)"
      # shellcheck disable=SC2016  # the literal call text
      if [ "$plat" = linux ]; then call='nd_root_deb dns "$1"'; else call='nd_root_mac agent "$1"'; fi
      grep -qF "$call" "$IP_TREE/lib/install.sh" || fail "$plat: the call to mangle is in lib/install.sh"
      sed -i "s|$(printf '%s' "$call" | sed 's/[$"]/\\&/g')|${call%\"}-bad\"|" "$IP_TREE/lib/install.sh"
      ip_install "$ep" socat
      assert_nonzero "$IP_RC" "$plat: the install fails at the refused first step: $IP_OUT"
      assert_match "root-ops: verb '(dns|agent)': unknown helper verb 'check-bad'" "$IP_OUT" "$plat: root-ops names the refused call"
      assert_eq "$dns0" "$(dt_dns_state)" "$plat: host DNS is untouched"
      assert_eq "" "$(grep -E '^sudo bash [^ ]*/root-ops ' "$FAKE_LOG" | grep -v ' check-bad$')" "$plat: no other root step ran"
      assert_no_path "$IP_STATE/current" "$plat: nothing is installed"
      # A root step inside the interruption: the pin (Linux), the teardown (macOS).
      dt_world "$ep" "$(dt_fresh_state "$ep")"
      dt_installed "$ep"
      dep0="$(dt_deploy_state)"; dns0="$(dt_dns_state)"
      if [ "$plat" = linux ]; then
        sed -i 's|^  nd_root_deb pin$|  nd_root_deb pin bad|' "$IP_TREE/lib/install.sh"
      else
        # shellcheck disable=SC2016  # the literal call text
        sed -i 's|^  nd_root_mac teardown "\$mode"$|  nd_root_mac teardown "$mode" bad|' "$IP_TREE/lib/install.sh"
      fi
      ip_install "$ep" socat
      assert_nonzero "$IP_RC" "$plat: the reinstall fails at the refused step: $IP_OUT"
      assert_match "root-ops: verb '(pin|teardown)' takes [0-9]+ argument\(s\), got [0-9]+" "$IP_OUT" "$plat: root-ops names the refused verb"
      assert_match 'Rolled back to the previous deployment' "$IP_OUT" "$plat: the installer rolls back"
      assert_eq "$dep0" "$(dt_deploy_state)" "$plat: the deployment it replaced is back"
      assert_eq "$dns0" "$(dt_dns_state)" "$plat: host DNS is as it was"
    ) || exit 1
  done
}
