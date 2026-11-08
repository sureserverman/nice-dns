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

# ─────────── the helper path (Sub-plan 5 Task 2.2: Linux, pkexec) ───────────

# ii_helper_world: a Linux world whose tree is under HOME (the helper refuses
# any other) and a staged helper asset. Sets II_ASSET, II_HELPER (the installed
# helper's path), II_OUTSIDE (the world's first tree, outside HOME).
ii_helper_world() {
  dt_world install-deb "$(dt_fresh_state install-deb)"
  II_OUTSIDE="$IP_TREE"
  ip_tree "$IP_HOME/src/nice-dns"
  IP_TREE="$IP_HOME/src/nice-dns"
  II_ASSET="$IP_HOME/staged/nice-dns-helper"
  ip_fake_helper "$II_ASSET"
  # The helper takes no tree its group or others can write (the runner's
  # umask may be 002).
  chmod -R go-w "$IP_HOME"
  II_HELPER="$FAKE_ROOT/usr/libexec/nice-dns-helper"
}

# ii_manifest_helper: the current generation's `helper` row value.
ii_manifest_helper() {
  awk -F '\t' '$1 == "helper" { print $2; exit }' "$IP_STATE/generations/$(cat "$IP_STATE/current")/prepare.tsv"
}

# ii_next_head: a new source commit, so each install is its own generation.
ii_next_head() { printf '%040d\n' "$1" >"$FAKE/git_head"; }

t_helper_linux_root_steps_go_through_pkexec() {
  local n
  ii_helper_world
  # No helper anywhere: every root step is a sudo line, none a pkexec one.
  ip_install install-deb haproxy
  assert_rc 0 "$IP_RC" "no helper: the install: $IP_OUT"
  assert_eq "" "$(grep -E '^pkexec ' "$FAKE_LOG")" "no helper: nothing goes through pkexec"
  assert_match "^sudo bash $IP_TREE/deb/root-ops pin$" "$(cat "$FAKE_LOG")" "no helper: the pin is a sudo line"
  assert_eq absent "$(ii_manifest_helper)" "no helper: the generation records it absent"
  # A staged helper: installed through sudo (there is none yet), then every
  # later root step goes through pkexec and the helper.
  : >"$FAKE_LOG"; ii_next_head 1
  ND_INST_HELPER_STAGED="$II_ASSET" ip_install install-deb haproxy
  assert_rc 0 "$IP_RC" "staged: the install: $IP_OUT"
  n="$(grep -nE "^sudo bash $IP_TREE/deb/root-ops install-helper $II_ASSET $IP_TREE/deb/org.nice-dns.policy$" "$FAKE_LOG" | cut -d: -f1)"
  assert_ne "" "$n" "staged: install-helper ran through sudo"
  assert_eq "" "$(tail -n +"$((n + 1))" "$FAKE_LOG" | grep -E '^sudo bash [^ ]*/root-ops ')" "staged: no root-ops sudo line after the helper is in"
  assert_eq "pkexec $II_HELPER --tree $IP_TREE version" "$(tail -n +"$((n + 1))" "$FAKE_LOG" | grep -E '^pkexec ' | head -n 1)" "staged: the new helper is asked its root-ops version first"
  assert_match "^pkexec $II_HELPER --tree $IP_TREE pin$" "$(cat "$FAKE_LOG")" "staged: the pin goes through pkexec"
  cmp -s "$II_ASSET" "$II_HELPER" || fail "staged: the helper installed is the staged asset"
  cmp -s "$IP_TREE/deb/root-ops" "$FAKE_ROOT/usr/libexec/nice-dns/root-ops" || fail "staged: the root-held root-ops is this tree's"
  cmp -s "$IP_TREE/deb/org.nice-dns.policy" "$FAKE_ROOT/usr/share/polkit-1/actions/org.nice-dns.policy" || fail "staged: the polkit action is installed"
  assert_eq "$(sed -n 's/^ND_HELPER_VERSION=//p' "$IP_TREE/deb/root-ops")" "$(ii_manifest_helper)" "staged: the generation records the helper's version"
  # A reinstall with nothing staged: no root-ops sudo line at all.
  : >"$FAKE_LOG"; : >"$FAKE/pkexec-ppids"; ii_next_head 2
  ip_install install-deb socat
  assert_rc 0 "$IP_RC" "reinstall: $IP_OUT"
  assert_eq "" "$(grep -E '^sudo bash [^ ]*/root-ops ' "$FAKE_LOG")" "reinstall: every root step goes through the helper"
  assert_ne "" "$(grep -E "^pkexec $II_HELPER --tree $IP_TREE " "$FAKE_LOG")" "reinstall: through pkexec"
  assert_match "^pkexec $II_HELPER --tree $IP_TREE dns check$" "$(cat "$FAKE_LOG")" "reinstall: the DNS helper's verbs too"
  # One process ran every pkexec of the install, so polkit asks once (OD-11),
  # though the calls come from subshells and deb/persistent-podman.sh.
  assert_eq 1 "$(sort -u "$FAKE/pkexec-ppids" | wc -l | tr -d ' ')" "reinstall: every pkexec has one parent, the runner"
  assert_eq "" "$(find "$IP_W/tmp" -maxdepth 1 -name 'nice-dns-root.*')" "reinstall: the runner and its directory are gone"
  # A tree its group can write (a checkout under umask 002) is refused by the
  # helper, so it keeps to sudo.
  : >"$FAKE_LOG"; ii_next_head 4; chmod g+w "$IP_TREE"
  ip_install install-deb socat
  assert_rc 0 "$IP_RC" "group-writable tree: $IP_OUT"
  assert_eq "" "$(grep -E '^pkexec ' "$FAKE_LOG")" "group-writable tree: nothing goes through pkexec"
  chmod g-w "$IP_TREE"
  # And a directory between it and HOME that its group can write.
  : >"$FAKE_LOG"; ii_next_head 5; chmod g+w "$IP_HOME/src"
  ip_install install-deb socat
  assert_rc 0 "$IP_RC" "group-writable parent: $IP_OUT"
  assert_eq "" "$(grep -E '^pkexec ' "$FAKE_LOG")" "group-writable parent: nothing goes through pkexec"
  chmod g-w "$IP_HOME/src"
  # A tree outside HOME, which the helper would refuse: sudo, as from a terminal.
  : >"$FAKE_LOG"; ii_next_head 3; IP_TREE="$II_OUTSIDE"
  ip_install install-deb socat
  assert_rc 0 "$IP_RC" "outside HOME: $IP_OUT"
  assert_eq "" "$(grep -E '^pkexec ' "$FAKE_LOG")" "outside HOME: nothing goes through pkexec"
  assert_match "^sudo bash $IP_TREE/deb/root-ops pin$" "$(cat "$FAKE_LOG")" "outside HOME: sudo"
}

t_helper_linux_refused_authorisation_aborts_or_rolls_back() {
  local rc msg dns0 dep0
  for rc in 126 127; do
    if [ "$rc" = 126 ]; then msg='authorisation cancelled'; else msg='not authorised'; fi
    ii_helper_world
    ND_INST_HELPER_STAGED="$II_ASSET" dt_installed install-deb
    # Refused at the first root step (the ownership check): nothing changes.
    dns0="$(dt_dns_state)"; dep0="$(dt_deploy_state)"
    echo "$rc" >"$FAKE/pkexec_rc"
    ip_install install-deb socat
    assert_nonzero "$IP_RC" "$rc first step: the install fails"
    assert_match "nice-dns: $msg" "$IP_OUT" "$rc first step: says so"
    assert_eq 1 "$(grep -cE '^pkexec ' "$FAKE_LOG")" "$rc first step: nothing after the refused call"
    assert_eq "" "$(grep -E '^sudo bash [^ ]*/root-ops ' "$FAKE_LOG")" "$rc first step: no sudo either"
    assert_eq "$dns0" "$(dt_dns_state)" "$rc first step: host DNS is untouched"
    assert_eq "$dep0" "$(dt_deploy_state)" "$rc first step: the deployment is untouched"
    # Refused at the pin, inside the interruption: the install rolls back.
    : >"$FAKE_LOG"; ii_next_head 5
    printf '^pkexec [^ ]* --tree [^ ]* pin$\n' >"$FAKE/pkexec_on"
    ip_install install-deb socat
    assert_nonzero "$IP_RC" "$rc pin: the install fails"
    assert_match "nice-dns: $msg" "$IP_OUT" "$rc pin: says so"
    assert_match 'Rolled back to the previous deployment' "$IP_OUT" "$rc pin: and rolls back"
    assert_eq "$dep0" "$(dt_deploy_state)" "$rc pin: the deployment it replaced is back"
    assert_eq "$dns0" "$(dt_dns_state)" "$rc pin: host DNS is as it was"
    # Refused at the pin and at every root step after it: the rollback cannot
    # give everything back, and says so.
    : >"$FAKE_LOG"; ii_next_head 6; : >"$FAKE/pkexec_after"
    ip_install install-deb socat
    assert_nonzero "$IP_RC" "$rc rollback refused: the install fails"
    assert_match "nice-dns: $msg" "$IP_OUT" "$rc rollback refused: says why"
    assert_match "was not restored \\(root-ops exit $rc\\)" "$IP_OUT" "$rc rollback refused: each refused restore says so"
    rm -f "$FAKE/pkexec_rc" "$FAKE/pkexec_on" "$FAKE/pkexec_after" "$FAKE/pkexec_refusing"
  done
}

t_helper_linux_wrong_version_or_owner_is_not_trusted() {
  local other
  ii_helper_world
  ND_INST_HELPER_STAGED="$II_ASSET" dt_installed install-deb
  # An older helper runs only the dns verbs (which every version allows, the
  # ownership check among them); sudo runs every other root step, and the generation records the
  # version found.
  ip_fake_helper "$II_HELPER" 0.0.9
  ip_install install-deb socat
  assert_rc 0 "$IP_RC" "old helper: $IP_OUT"
  assert_match "^pkexec $II_HELPER --tree $IP_TREE dns check$" "$(cat "$FAKE_LOG")" "old helper: the ownership check goes through it"
  assert_eq "" "$(grep -E '^pkexec ' "$FAKE_LOG" | grep -vE "^pkexec $II_HELPER --tree $IP_TREE dns [a-z]+$")" "old helper: only dns verbs go through it"
  assert_match "^sudo bash $IP_TREE/deb/root-ops pin$" "$(cat "$FAKE_LOG")" "old helper: the pin is a sudo line"
  assert_eq 0.0.9 "$(ii_manifest_helper)" "old helper: its version is recorded"
  # With a staged one, install-helper goes through the old helper (any
  # version may replace itself), and the rest through the new one.
  : >"$FAKE_LOG"; ii_next_head 6
  ND_INST_HELPER_STAGED="$II_ASSET" ip_install install-deb socat
  assert_rc 0 "$IP_RC" "old helper, staged: $IP_OUT"
  assert_match "^pkexec $II_HELPER --tree $IP_TREE install-helper $II_ASSET " "$(cat "$FAKE_LOG")" "old helper, staged: replaced through itself"
  assert_eq "" "$(grep -E '^sudo bash [^ ]*/root-ops ' "$FAKE_LOG")" "old helper, staged: no sudo"
  cmp -s "$II_ASSET" "$II_HELPER" || fail "old helper, staged: the staged asset is installed"
  # A held root-ops that is not the tree's, at the right version (an older
  # install's, or a rollback's): only the dns verbs go through the helper.
  : >"$FAKE_LOG"; ii_next_head 10
  printf '# older copy\n' >>"$FAKE_ROOT/usr/libexec/nice-dns/root-ops"
  ip_install install-deb socat
  assert_rc 0 "$IP_RC" "stale copy: $IP_OUT"
  assert_eq "" "$(grep -E '^pkexec ' "$FAKE_LOG" | grep -vE "^pkexec $II_HELPER --tree $IP_TREE dns [a-z]+$")" "stale copy: only dns verbs go through the helper"
  assert_match "^sudo bash $IP_TREE/deb/root-ops pin$" "$(cat "$FAKE_LOG")" "stale copy: sudo for the rest"
  cp "$IP_TREE/deb/root-ops" "$FAKE_ROOT/usr/libexec/nice-dns/root-ops"
  # A helper that is not root-owned (here: owned by another uid), a symlink or
  # not executable is never run.
  : >"$FAKE_LOG"; ii_next_head 7
  other=$(($(id -u) + 1))
  ND_INST_ROOT_OWNER="$other" ip_install install-deb socat
  assert_rc 0 "$IP_RC" "foreign owner: $IP_OUT"
  assert_eq "" "$(grep -E '^pkexec ' "$FAKE_LOG")" "foreign owner: the helper is not trusted"
  : >"$FAKE_LOG"; ii_next_head 8
  mv "$II_HELPER" "$II_HELPER.real"; ln -s "$II_HELPER.real" "$II_HELPER"
  ip_install install-deb socat
  assert_rc 0 "$IP_RC" "symlink: $IP_OUT"
  assert_eq "" "$(grep -E '^pkexec ' "$FAKE_LOG")" "symlink: the helper is not trusted"
  rm -f "$II_HELPER"; mv "$II_HELPER.real" "$II_HELPER"; chmod 644 "$II_HELPER"
  : >"$FAKE_LOG"; ii_next_head 9
  ip_install install-deb socat
  assert_rc 0 "$IP_RC" "not executable: $IP_OUT"
  assert_eq "" "$(grep -E '^pkexec ' "$FAKE_LOG")" "not executable: the helper is not run"
}

t_helper_linux_uninstall_removes_it() {
  ii_helper_world
  ND_INST_HELPER_STAGED="$II_ASSET" dt_installed install-deb
  assert_file "$II_HELPER" "installed: the helper"
  ip_install install-deb uninstall
  assert_rc 0 "$IP_RC" "uninstall: $IP_OUT"
  assert_match "^pkexec $II_HELPER --tree $IP_TREE uninstall$" "$(cat "$FAKE_LOG")" "uninstall: through the helper"
  assert_no_path "$II_HELPER" "uninstall: the helper is gone"
  assert_no_path "$FAKE_ROOT/usr/libexec/nice-dns" "uninstall: its root-ops copy and directory are gone"
  assert_no_path "$FAKE_ROOT/usr/share/polkit-1/actions/org.nice-dns.policy" "uninstall: the polkit action is gone"
}

t_root_ops_maps_a_steps_126_and_127_to_125() {
  local s rc
  s="$CASE_DIR/step"
  # A step root-ops runs that exits 126 or 127 (a command missing on the
  # host) must not read as pkexec's dismissed or refused authorisation.
  for rc in 126 127 9; do
    printf '#!/bin/sh\nexit %s\n' "$rc" >"$s"; chmod 755 "$s"
    ND_ROOT_TEST_SUDO="$s" bash "$NICE_DNS_ROOT/deb/root-ops" dns check >/dev/null 2>&1
    case "$rc" in 9) assert_rc 9 "$?" "a step's 9 passes through" ;; *) assert_rc 125 "$?" "a step's $rc becomes 125" ;; esac
  done
}

t_root_ops_install_helper_refuses_before_running_anything() {
  local s ro="$NICE_DNS_ROOT/deb/root-ops" pol="$NICE_DNS_ROOT/deb/org.nice-dns.policy" f out
  s="$CASE_DIR/sudo"; printf '#!/bin/sh\necho "$*" >>"%s/ran"\n' "$CASE_DIR" >"$s"; chmod 755 "$s"
  f="$CASE_DIR/asset"; : >"$f"; ln -s "$f" "$CASE_DIR/link"
  for args in "rel/asset $pol" "$CASE_DIR/link $pol" "$CASE_DIR/./asset $pol" "$CASE_DIR/missing $pol" "$f" "$f $pol extra" "$f $CASE_DIR"; do
    # shellcheck disable=SC2086  # each case is a word list
    out="$(ND_ROOT_TEST_SUDO="$s" bash "$ro" install-helper $args 2>&1)"
    assert_rc 2 "$?" "install-helper $args: refused"
    assert_match "verb 'install-helper'" "$out" "install-helper $args: names the verb"
  done
  # A policy file that is not the tree's own: refused before anything is installed.
  printf '<policyconfig/>\n' >"$CASE_DIR/other.policy"
  out="$(ND_ROOT_TEST_SUDO="$s" bash "$ro" install-helper "$f" "$CASE_DIR/other.policy" 2>&1)"
  assert_rc 1 "$?" "another policy: refused"
  assert_match "is not this tree's deb/org.nice-dns.policy" "$out" "another policy: says why"
  assert_no_path "$CASE_DIR/ran" "no root step ran for any refused call"
  out="$(ND_ROOT_TEST_SUDO="$s" bash "$ro" version 2>&1)"
  assert_eq "$(sed -n 's/^ND_HELPER_VERSION=//p' "$ro")" "$out" "version prints the helper version root-ops expects"
}

t_root_ops_expects_the_crates_helper_version() {
  local want crate
  want="$(sed -n 's/^ND_HELPER_VERSION=//p' "$NICE_DNS_ROOT/deb/root-ops")"
  crate="$(sed -n 's/^version = "\(.*\)"$/\1/p' "$NICE_DNS_ROOT/gui/helper/Cargo.toml" | head -n 1)"
  assert_ne "" "$want" "deb/root-ops names the helper version it expects"
  assert_eq "$crate" "$want" "deb/root-ops expects gui/helper's crate version"
  # The policy binds pkexec to the path the installer runs and asks for an
  # administrator, kept a few minutes.
  assert_match '<annotate key="org.freedesktop.policykit.exec.path">/usr/libexec/nice-dns-helper</annotate>' "$(cat "$NICE_DNS_ROOT/deb/org.nice-dns.policy")" "the policy names the helper's path"
  assert_eq 3 "$(grep -c '>auth_admin_keep<' "$NICE_DNS_ROOT/deb/org.nice-dns.policy")" "any, inactive and active ask for an administrator"
  if command -v xmllint >/dev/null 2>&1 && [ -f /usr/share/polkit-1/policyconfig-1.dtd ]; then
    xmllint --noout --dtdvalid /usr/share/polkit-1/policyconfig-1.dtd "$NICE_DNS_ROOT/deb/org.nice-dns.policy"
    assert_rc 0 "$?" "the policy is valid against polkit's DTD"
  else
    echo "note: no xmllint or polkit DTD here; the DTD check is skipped"
  fi
}

# ─────────── the helper path (Sub-plan 5 Task 2.3: macOS, setuid) ───────────

# ii_mac_helper_world: ii_helper_world on macOS; the helper is the setuid
# binary under /usr/local/libexec.
ii_mac_helper_world() {
  dt_world install-mac "$(dt_fresh_state install-mac)"
  ip_tree "$IP_HOME/src/nice-dns"
  IP_TREE="$IP_HOME/src/nice-dns"
  II_ASSET="$IP_HOME/staged/nice-dns-helper"
  ip_fake_helper "$II_ASSET" "" mac
  chmod -R go-w "$IP_HOME"
  II_HELPER="$FAKE_ROOT/usr/local/libexec/nice-dns-helper"
}

t_helper_macos_root_steps_go_through_the_setuid_helper() {
  local n
  ii_mac_helper_world
  # A staged helper: installed through sudo, root:wheel 4755 (here: the test
  # user), with the owner file and the root-held root-ops; then every later
  # root step goes through it, the new helper first asked its version.
  ND_INST_HELPER_STAGED="$II_ASSET" ip_install install-mac haproxy
  assert_rc 0 "$IP_RC" "staged: the install: $IP_OUT"
  n="$(grep -nE "^sudo bash $IP_TREE/mac/root-ops install-helper $II_ASSET$" "$FAKE_LOG" | cut -d: -f1)"
  assert_ne "" "$n" "staged: install-helper ran through sudo"
  assert_eq 4755 "$(stat -c %a "$II_HELPER")" "staged: the helper is setuid, 4755"
  assert_eq "$(id -u)" "$(cat "$FAKE_ROOT/usr/local/libexec/nice-dns/owner")" "staged: the owner file names the installing user"
  cmp -s "$IP_TREE/mac/root-ops" "$FAKE_ROOT/usr/local/libexec/nice-dns/root-ops" || fail "staged: the root-held root-ops is this tree's"
  assert_eq "" "$(tail -n +"$((n + 1))" "$FAKE_LOG" | grep -E '^sudo bash [^ ]*/root-ops ')" "staged: no root-ops sudo line after the helper is in"
  assert_eq "nice-dns-helper --tree $IP_TREE version" "$(tail -n +"$((n + 1))" "$FAKE_LOG" | grep -E '^nice-dns-helper ' | head -n 1)" "staged: the new helper is asked its root-ops version first"
  assert_eq "$(sed -n 's/^ND_HELPER_VERSION=//p' "$IP_TREE/mac/root-ops")" "$(ii_manifest_helper)" "staged: the generation records the helper's version"
  # A reinstall: no root-ops sudo line at all; the helper stays.
  : >"$FAKE_LOG"; ii_next_head 2
  ip_install install-mac socat
  assert_rc 0 "$IP_RC" "reinstall: $IP_OUT"
  assert_eq "" "$(grep -E '^sudo bash [^ ]*/root-ops ' "$FAKE_LOG")" "reinstall: every root step goes through the helper"
  assert_match "^nice-dns-helper --tree $IP_TREE agent check$" "$(cat "$FAKE_LOG")" "reinstall: the ownership check"
  # The teardown runs from the private build copy under HOME
  # (nd_install_macos_stage_tree), which the helper takes too.
  assert_match "^nice-dns-helper --tree $IP_HOME/\\.nice-dns-install\\.[A-Za-z0-9]+/nice-dns teardown reinstall$" "$(cat "$FAKE_LOG")" "reinstall: the teardown, from the build copy"
  assert_file "$II_HELPER" "reinstall: the helper stays"
}

t_helper_macos_wrong_mode_owner_or_version_is_not_trusted() {
  ii_mac_helper_world
  ND_INST_HELPER_STAGED="$II_ASSET" dt_installed install-mac
  # Not setuid: never run; sudo, as from a terminal.
  chmod 755 "$II_HELPER"
  ip_install install-mac socat
  assert_rc 0 "$IP_RC" "not setuid: $IP_OUT"
  assert_eq "" "$(grep -E '^nice-dns-helper ' "$FAKE_LOG")" "not setuid: the helper is not run"
  assert_match "^sudo bash [^ ]*/mac/root-ops teardown reinstall$" "$(cat "$FAKE_LOG")" "not setuid: sudo"
  chmod 4755 "$II_HELPER"
  # Owned by another uid: never run.
  : >"$FAKE_LOG"; ii_next_head 3
  ND_INST_ROOT_OWNER=$(($(id -u) + 1)) ip_install install-mac socat
  assert_rc 0 "$IP_RC" "foreign owner: $IP_OUT"
  assert_eq "" "$(grep -E '^nice-dns-helper ' "$FAKE_LOG")" "foreign owner: the helper is not run"
  # An older helper runs only the agent verbs (the ownership check among them).
  : >"$FAKE_LOG"; ii_next_head 4
  ip_fake_helper "$II_HELPER" 0.0.9; chmod 4755 "$II_HELPER"
  ip_install install-mac socat
  assert_rc 0 "$IP_RC" "old helper: $IP_OUT"
  assert_match "^nice-dns-helper --tree $IP_TREE agent check$" "$(cat "$FAKE_LOG")" "old helper: the ownership check goes through it"
  assert_eq "" "$(grep -E '^nice-dns-helper ' "$FAKE_LOG" | grep -vE "^nice-dns-helper --tree [^ ]+ agent [a-z-]+$")" "old helper: only agent verbs go through it"
  assert_eq 0.0.9 "$(ii_manifest_helper)" "old helper: its version is recorded"
  # A held root-ops that is not the tree's, at the right version: only the
  # agent verbs go through the helper.
  : >"$FAKE_LOG"; ii_next_head 5
  ip_fake_helper "$II_HELPER" "" mac; chmod 4755 "$II_HELPER"
  printf '# older copy\n' >>"$FAKE_ROOT/usr/local/libexec/nice-dns/root-ops"
  ip_install install-mac socat
  assert_rc 0 "$IP_RC" "stale copy: $IP_OUT"
  assert_eq "" "$(grep -E '^nice-dns-helper ' "$FAKE_LOG" | grep -vE "^nice-dns-helper --tree [^ ]+ agent [a-z-]+$")" "stale copy: only agent verbs go through the helper"
  assert_match "^sudo bash [^ ]*/mac/root-ops teardown reinstall$" "$(cat "$FAKE_LOG")" "stale copy: sudo for the rest"
  # An owner file naming another user: the helper is not used at all, and a
  # staged helper is installed for this user, through sudo.
  : >"$FAKE_LOG"; ii_next_head 6
  cp "$IP_TREE/mac/root-ops" "$FAKE_ROOT/usr/local/libexec/nice-dns/root-ops"
  echo $(($(id -u) + 1)) >"$FAKE_ROOT/usr/local/libexec/nice-dns/owner"
  ip_install install-mac socat
  assert_rc 0 "$IP_RC" "another owner: $IP_OUT"
  assert_eq "" "$(grep -E '^nice-dns-helper ' "$FAKE_LOG")" "another owner: the helper is not run"
  : >"$FAKE_LOG"; ii_next_head 7
  ND_INST_HELPER_STAGED="$II_ASSET" ip_install install-mac socat
  assert_rc 0 "$IP_RC" "another owner, staged: $IP_OUT"
  assert_match "^sudo bash $IP_TREE/mac/root-ops install-helper $II_ASSET$" "$(cat "$FAKE_LOG")" "another owner, staged: installed through sudo"
  assert_eq "$(id -u)" "$(cat "$FAKE_ROOT/usr/local/libexec/nice-dns/owner")" "another owner, staged: the helper is now this user's"
}

t_helper_macos_uninstall_removes_it() {
  ii_mac_helper_world
  ND_INST_HELPER_STAGED="$II_ASSET" dt_installed install-mac
  ip_install install-mac uninstall
  assert_rc 0 "$IP_RC" "uninstall: $IP_OUT"
  assert_match "^nice-dns-helper --tree [^ ]* teardown uninstall$" "$(cat "$FAKE_LOG")" "uninstall: through the helper"
  # Every root step of the uninstall, the DNS restore after the teardown
  # among them, went through the helper; removing it is the last.
  assert_eq "" "$(grep -E '^sudo bash [^ ]*/root-ops ' "$FAKE_LOG")" "uninstall: no root step needed sudo"
  assert_match "^nice-dns-helper --tree [^ ]* agent restore$" "$(cat "$FAKE_LOG")" "uninstall: the DNS restore goes through the helper"
  assert_eq "nice-dns-helper --tree $IP_TREE remove-helper" "$(grep -E '^(nice-dns-helper|sudo bash [^ ]*/root-ops) ' "$FAKE_LOG" | tail -n 1)" "uninstall: removing the helper is the last root step"
  assert_no_path "$II_HELPER" "uninstall: the helper is gone"
  assert_no_path "$FAKE_ROOT/usr/local/libexec/nice-dns" "uninstall: its owner file, root-ops copy and directory are gone"
  # A helper that cannot be removed is passwordless root left behind: the
  # uninstall fails and says how to remove it.
  ii_mac_helper_world
  ND_INST_HELPER_STAGED="$II_ASSET" dt_installed install-mac
  printf '^sudo rm -f [^ ]*/usr/local/libexec/nice-dns-helper \n' >"$FAKE/fail"
  ip_install install-mac uninstall
  assert_nonzero "$IP_RC" "helper not removed: the uninstall fails"
  assert_match "nice-dns-helper, a setuid root program, was NOT removed" "$IP_OUT" "helper not removed: says so"
  rm -f "$FAKE/fail"
}
