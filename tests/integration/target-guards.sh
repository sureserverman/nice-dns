# shellcheck shell=bash
# Group integration/target-guards (sub-plan 01, Task 2.1; ARCH-03, ARCH-09).
#
# Every guard in tests/live/target.sh is exercised against fake ssh and
# ssh-keygen binaries placed first on PATH, so no real host is contacted.
# The fakes log their argv; the cases assert both the refusal and that no
# remote command was sent when a guard refused.

TG="$NICE_DNS_ROOT/tests/live/target.sh"

tg_setup() {
  # tg_setup: fake bin dir, a valid targets file and default fake behaviour.
  assert_file "$TG" "target.sh exists"
  mkdir -p "$CASE_DIR/bin"
  cat >"$CASE_DIR/bin/ssh" <<'FAKE'
#!/usr/bin/env bash
# Fake ssh: -G prints resolved config; otherwise logs argv and answers the
# remote script by keyword. Behaviour comes from FAKE_* variables.
if [ "$1" = -G ]; then
  printf 'hostname %s\nport %s\nuser tester\n' "${FAKE_HOSTNAME:-192.0.2.10}" "${FAKE_PORT:-22}"
  exit 0
fi
printf '%s\n' "$*" >>"$FAKE_LOG"
last="${!#}"
if [ -n "${FAKE_EXEC:-}" ]; then
  # Exec mode: run the real remote script locally against fake remote tools.
  PATH="$FAKE_RBIN:$PATH" eval "$last"
  exit $?
fi
case "$last" in
  *NICE_DNS_OP=probe*|*NICE_DNS_OP=snapshot*)
    printf 'machine_id\t%s\nhostname\t%s\nplatform\t%s\n' "${FAKE_MACHINE_ID:-remote-machine-0001}" "${FAKE_REMOTE_HOST:-disposable-1}" "${FAKE_PLATFORM:-linux}"
    printf 'section\tcontainers\n%s\n' "${FAKE_CONTAINERS:-tor-haproxy	running}" ;;
  *) printf 'ok\n' ;;
esac
exit "${FAKE_RC:-0}"
FAKE
  cat >"$CASE_DIR/bin/ssh-keygen" <<'FAKE'
#!/usr/bin/env bash
printf 'keygen %s\n' "$*" >>"$FAKE_LOG"
if [ -n "${FAKE_NO_KNOWN:-}" ]; then exit 1; fi
# Output shape of real `ssh-keygen -F NAME -l` (OpenSSH 9.6): one comment
# line and one "NAME TYPE FINGERPRINT" line per stored key.
printf '# Host %s found: line 1 \n' "$2"
printf '%s RSA %s\n' "$2" 'SHA256:RRRRotherkeytypeRRRRRRRRRRRRRRRRRRRRRRRRRRR'
printf '# Host %s found: line 2 \n' "$2"
printf '%s ED25519 %s\n' "$2" "${FAKE_FP:-SHA256:AAAAtestfingerprintAAAAAAAAAAAAAAAAAAAAAAAA}"
FAKE
  chmod 755 "$CASE_DIR/bin/ssh" "$CASE_DIR/bin/ssh-keygen"
  PATH="$CASE_DIR/bin:$PATH"
  FAKE_LOG="$CASE_DIR/ssh.log"
  : >"$FAKE_LOG"
  # Each case gets its own artifact dir: target state must not leak between cases.
  ARTIFACT_DIR="$CASE_DIR/art"
  mkdir -p "$ARTIFACT_DIR"
  export PATH FAKE_LOG ARTIFACT_DIR
  tg_targets 'lin1	linux	lin1-ssh	SHA256:AAAAtestfingerprintAAAAAAAAAAAAAAAAAAAAAAAA	disposable	2026-09-22'
}

tg_targets() {
  # tg_targets <row...>: write a targets file with the given rows.
  local r
  {
    printf '# alias\tplatform\tssh\thost_key\tdesignation\tdesignated_on\n'
    for r in "$@"; do printf '%s\n' "$r"; done
  } >"$CASE_DIR/targets.env"
  chmod 600 "$CASE_DIR/targets.env"
}

tg() {
  TG_OUT="$(bash "$TG" "$@" 2>&1)"
  TG_RC=$?
}

tg_sent() { grep -v '^keygen ' "$FAKE_LOG" | grep -c . | tr -d ' '; }

t_valid_targets_file_is_accepted() {
  tg_setup
  tg validate --targets "$CASE_DIR/targets.env"
  assert_rc 0 "$TG_RC" "valid file: $TG_OUT"
  assert_match '^lin1	linux	' "$TG_OUT" "validated alias listed"
}

t_example_file_is_valid_and_disposable_designated() {
  # A checkout gives the file mode 664, which the permission guard refuses;
  # validate the content from a private copy.
  cp "$NICE_DNS_ROOT/tests/live/targets.example" "$CASE_DIR/example.env"
  chmod 600 "$CASE_DIR/example.env"
  tg validate --targets "$CASE_DIR/example.env"
  assert_rc 0 "$TG_RC" "targets.example validates: $TG_OUT"
}

t_targets_env_is_git_ignored() {
  git -C "$NICE_DNS_ROOT" check-ignore -q tests/live/targets.env
  assert_rc 0 $? "tests/live/targets.env is ignored (local, never committed)"
}

t_malformed_rows_are_rejected() {
  local bad
  tg_setup
  tg validate --targets "$CASE_DIR/targets.env"
  assert_rc 0 "$TG_RC" "control: the valid row passes before each broken variant: $TG_OUT"
  for bad in \
    'lin1	linux	lin1-ssh	SHA256:AAAAtestfingerprintAAAAAAAAAAAAAAAAAAAAAAAA	disposable' \
    'lin1	windows	lin1-ssh	SHA256:AAAAtestfingerprintAAAAAAAAAAAAAAAAAAAAAAAA	disposable	2026-09-22' \
    'lin1	linux	lin1-ssh	SHA256:AAAAtestfingerprintAAAAAAAAAAAAAAAAAAAAAAAA	production	2026-09-22' \
    'lin1	linux	lin1-ssh	MD5:aa:bb	disposable	2026-09-22' \
    'lin1	linux	$(touch pwned)	SHA256:AAAAtestfingerprintAAAAAAAAAAAAAAAAAAAAAAAA	disposable	2026-09-22' \
    'lin1	linux	-oProxyCommand=x	SHA256:AAAAtestfingerprintAAAAAAAAAAAAAAAAAAAAAAAA	disposable	2026-09-22' \
    'l;in	linux	lin1-ssh	SHA256:AAAAtestfingerprintAAAAAAAAAAAAAAAAAAAAAAAA	disposable	2026-09-22' \
    'lin1	linux	lin1-ssh	SHA256:AAAAtestfingerprintAAAAAAAAAAAAAAAAAAAAAAAA	disposable	yesterday' \
    'lin1	linux	lin1-ssh	SHA256:AAAAtestfingerprintAAAAAAAAAAAAAAAAAAAAAAAA	disposable	2026-09-22	password=x'; do
    tg_targets "$bad"
    tg validate --targets "$CASE_DIR/targets.env"
    assert_nonzero "$TG_RC" "row accepted: $bad"
    assert_match 'targets' "$TG_OUT" "refusal points at the targets file"
  done
  assert_no_path "$CASE_DIR/pwned" "no shell evaluation of config data"
  assert_eq 0 "$(tg_sent)" "validation never contacts a host"
}

t_duplicate_alias_rejected() {
  tg_setup
  tg_targets 'lin1	linux	a	SHA256:AAAAtestfingerprintAAAAAAAAAAAAAAAAAAAAAAAA	disposable	2026-09-22' \
    'lin1	macos	b	SHA256:AAAAtestfingerprintAAAAAAAAAAAAAAAAAAAAAAAA	disposable	2026-09-22'
  tg validate --targets "$CASE_DIR/targets.env"
  assert_nonzero "$TG_RC" "duplicate alias"
  assert_match 'duplicate' "$TG_OUT" "names the duplicate"
}

t_unsafe_targets_file_rejected() {
  tg_setup
  ln -s "$CASE_DIR/targets.env" "$CASE_DIR/link.env"
  tg validate --targets "$CASE_DIR/link.env"
  assert_nonzero "$TG_RC" "symlinked targets file"
  chmod 666 "$CASE_DIR/targets.env"
  tg validate --targets "$CASE_DIR/targets.env"
  assert_nonzero "$TG_RC" "group/world-writable targets file"
  assert_match 'writable' "$TG_OUT" "names the permission problem"
}

t_unknown_alias_and_operation_rejected() {
  tg_setup
  tg probe nosuch --targets "$CASE_DIR/targets.env"
  assert_nonzero "$TG_RC" "unknown alias"
  assert_match 'unknown alias' "$TG_OUT" "names the alias problem"
  tg reboot lin1 --targets "$CASE_DIR/targets.env"
  assert_nonzero "$TG_RC" "operation outside the allow-list"
  assert_match 'unknown operation' "$TG_OUT" "names the operation problem"
  tg probe lin1 --targets "$CASE_DIR/targets.env" --command 'id'
  assert_nonzero "$TG_RC" "no free-form remote command option"
  assert_match 'unknown option' "$TG_OUT" "names the option problem"
  assert_eq 0 "$(tg_sent)" "nothing sent"
}

t_ssh_is_strict_and_non_interactive() {
  local line
  tg_setup
  tg probe lin1 --targets "$CASE_DIR/targets.env"
  assert_rc 0 "$TG_RC" "probe: $TG_OUT"
  line="$(grep -v '^keygen ' "$FAKE_LOG" | head -1)"
  assert_match '-o BatchMode=yes' "$line" "BatchMode"
  assert_match '-o StrictHostKeyChecking=yes' "$line" "strict host keys"
  assert_match '-o UpdateHostKeys=no' "$line" "no host key updates"
  assert_match '-o ForwardAgent=no' "$line" "no agent forwarding"
  assert_match '-o ClearAllForwardings=yes' "$line" "no port forwarding"
  assert_match '(^| )lin1-ssh( |$)' "$line" "connects to the configured ssh alias"
}

t_host_key_mismatch_refused_before_any_command() {
  tg_setup
  FAKE_FP='SHA256:BBBBdifferentkeyBBBBBBBBBBBBBBBBBBBBBBBBBBB' tg probe lin1 --targets "$CASE_DIR/targets.env"
  assert_nonzero "$TG_RC" "pinned host key mismatch"
  assert_match 'host key' "$TG_OUT" "names the host key"
  assert_eq 0 "$(tg_sent)" "no remote command sent"
  FAKE_NO_KNOWN=1 tg probe lin1 --targets "$CASE_DIR/targets.env"
  assert_nonzero "$TG_RC" "host not in known_hosts (no trust on first use)"
  assert_eq 0 "$(tg_sent)" "still nothing sent"
}

t_this_machine_is_refused() {
  local here
  tg_setup
  here="$(cat /etc/machine-id 2>/dev/null || hostname)"
  FAKE_MACHINE_ID="$here" tg probe lin1 --targets "$CASE_DIR/targets.env"
  assert_nonzero "$TG_RC" "remote machine identity equals this host"
  assert_match 'this machine' "$TG_OUT" "names the refusal"
  for h in 127.0.0.1 ::1 localhost "$(hostname)"; do
    : >"$FAKE_LOG"
    FAKE_HOSTNAME="$h" tg probe lin1 --targets "$CASE_DIR/targets.env"
    assert_nonzero "$TG_RC" "ssh hostname $h resolves to this machine"
    assert_eq 0 "$(tg_sent)" "nothing sent to $h"
  done
}

t_platform_mismatch_refused() {
  tg_setup
  tg probe lin1 --targets "$CASE_DIR/targets.env"
  assert_rc 0 "$TG_RC" "control: matching platform passes"
  FAKE_PLATFORM=macos tg probe lin1 --targets "$CASE_DIR/targets.env"
  assert_nonzero "$TG_RC" "configured linux, remote reports macos"
  assert_match 'platform' "$TG_OUT" "names the platform mismatch"
}

t_snapshot_is_run_scoped_with_identity() {
  local d
  tg_setup
  tg snapshot lin1 --targets "$CASE_DIR/targets.env"
  assert_rc 0 "$TG_RC" "snapshot: $TG_OUT"
  d="$ARTIFACT_DIR/targets/lin1"
  assert_file "$d/snapshot.tsv" "snapshot stored under the run's artifact dir"
  assert_match '^machine_id	remote-machine-0001$' "$(cat "$d/snapshot.tsv")" "snapshot carries the remote identity"
  assert_match '^tor-haproxy	running$' "$(cat "$d/snapshot.tsv")" "snapshot carries container state"
  assert_file "$d/receipt.tsv" "snapshot receipt"
}

t_mutation_without_snapshot_refused() {
  local op
  tg_setup
  for op in sever-upstream heal-upstream restore; do
    : >"$FAKE_LOG"
    if [ "$op" = restore ]; then tg restore lin1 --targets "$CASE_DIR/targets.env"
    else tg "$op" lin1 --targets "$CASE_DIR/targets.env" --component tor-haproxy; fi
    assert_nonzero "$TG_RC" "$op without a snapshot"
    assert_match 'snapshot' "$TG_OUT" "$op refusal names the snapshot"
    assert_eq 0 "$(tg_sent)" "$op without a snapshot never contacts the host"
  done
}

t_mutation_with_foreign_snapshot_refused() {
  tg_setup
  tg snapshot lin1 --targets "$CASE_DIR/targets.env"
  assert_rc 0 "$TG_RC" "snapshot"
  : >"$FAKE_LOG"
  FAKE_MACHINE_ID=another-machine-9999 tg sever-upstream lin1 --targets "$CASE_DIR/targets.env" --component tor-haproxy
  assert_nonzero "$TG_RC" "snapshot of a different machine"
  assert_eq 0 "$(grep -c 'NICE_DNS_OP=sever' "$FAKE_LOG")" "nothing mutating sent"
}

t_mutation_with_snapshot_runs_allow_listed_component_only() {
  local c
  tg_setup
  tg snapshot lin1 --targets "$CASE_DIR/targets.env"
  tg sever-upstream lin1 --targets "$CASE_DIR/targets.env" --component tor-haproxy
  assert_rc 0 "$TG_RC" "sever tor-haproxy after snapshot: $TG_OUT"
  assert_match 'NICE_DNS_OP=sever-upstream' "$(cat "$FAKE_LOG")" "sever sent"
  for c in unbound pi-hole 'tor-haproxy;id' '../x' ''; do
    : >"$FAKE_LOG"
    tg sever-upstream lin1 --targets "$CASE_DIR/targets.env" --component "$c"
    assert_nonzero "$TG_RC" "component '$c' refused"
    assert_eq 0 "$(tg_sent)" "nothing sent for '$c'"
  done
}

t_symlinked_state_dir_refused() {
  tg_setup
  mkdir -p "$ARTIFACT_DIR/targets" "$CASE_DIR/elsewhere"
  ln -s "$CASE_DIR/elsewhere" "$ARTIFACT_DIR/targets/lin1"
  tg snapshot lin1 --targets "$CASE_DIR/targets.env"
  assert_nonzero "$TG_RC" "state dir is a symlink"
  assert_match 'symlink' "$TG_OUT" "names the symlink"
  assert_eq "" "$(ls "$CASE_DIR/elsewhere")" "nothing written through the link"
}

tg_remote_tools() {
  # tg_remote_tools <uname>: fake remote tools that log their calls.
  local t
  mkdir -p "$CASE_DIR/rbin"
  for t in container podman sw_vers networksetup launchctl systemctl; do
    printf '#!/bin/sh\nprintf "%%s %%s\\n" "%s" "$*" >>"$FAKE_LOG"\n' "$t" >"$CASE_DIR/rbin/$t"
  done
  printf '#!/bin/sh\necho %s\n' "$1" >"$CASE_DIR/rbin/uname"
  printf '#!/bin/sh\necho %s\n' "'\"IOPlatformUUID\" = \"mac-machine-0001\"'" >"$CASE_DIR/rbin/ioreg"
  # The fake remote is this host, so its /etc/machine-id must read as another machine's.
  printf '#!/bin/sh\nif [ "$1" = /etc/machine-id ]; then echo linux-machine-0002; else exec /bin/cat "$@"; fi\n' >"$CASE_DIR/rbin/cat"
  chmod 755 "$CASE_DIR"/rbin/*
  FAKE_RBIN="$CASE_DIR/rbin" FAKE_EXEC=1
  export FAKE_RBIN FAKE_EXEC
}

t_macos_uses_container_cli_and_no_credentials() {
  tg_setup
  tg_remote_tools Darwin
  tg_targets 'mac1	macos	mac1-ssh	SHA256:AAAAtestfingerprintAAAAAAAAAAAAAAAAAAAAAAAA	disposable	2026-09-22'
  tg snapshot mac1 --targets "$CASE_DIR/targets.env"
  assert_rc 0 "$TG_RC" "mac snapshot: $TG_OUT"
  assert_match '^container list --all' "$(cat "$FAKE_LOG")" "macOS lists containers with the container CLI"
  assert_match '^networksetup -listallnetworkservices' "$(cat "$FAKE_LOG")" "macOS DNS ownership captured"
  assert_not_match '^podman ' "$(cat "$FAKE_LOG")" "podman is never called on macOS"
  assert_match '^machine_id	mac-machine-0001$' "$(cat "$ARTIFACT_DIR/targets/mac1/snapshot.tsv")" "IOPlatformUUID is the macOS identity"
  tg sever-upstream mac1 --targets "$CASE_DIR/targets.env" --component tor-socat
  assert_rc 0 "$TG_RC" "mac sever: $TG_OUT"
  assert_match '^container stop tor-socat$' "$(cat "$FAKE_LOG")" "sever stops only the named proxy container"
  assert_not_match '(password|passwd|sshpass|PRIVATE KEY)' "$(cat "$FAKE_LOG" "$NICE_DNS_ROOT/tests/live/target.sh")" "no embedded credentials"
}

t_linux_uses_rootless_podman() {
  tg_setup
  tg_remote_tools Linux
  tg snapshot lin1 --targets "$CASE_DIR/targets.env"
  assert_rc 0 "$TG_RC" "linux snapshot: $TG_OUT"
  assert_match '^podman ps -a' "$(cat "$FAKE_LOG")" "linux lists containers with podman"
  assert_not_match '^container ' "$(cat "$FAKE_LOG")" "container CLI never called on Linux"
  assert_not_match 'sudo' "$(cat "$FAKE_LOG")" "rootless: no sudo"
  tg heal-upstream lin1 --targets "$CASE_DIR/targets.env" --component tor-haproxy
  assert_rc 0 "$TG_RC" "linux heal: $TG_OUT"
  assert_match '^podman start tor-haproxy$' "$(cat "$FAKE_LOG")" "heal starts only the named proxy container"
}

t_remote_script_never_contains_config_text() {
  tg_setup
  tg_targets 'lin1	linux	lin1-ssh	SHA256:AAAAtestfingerprintAAAAAAAAAAAAAAAAAAAAAAAA	disposable	2026-09-22'
  tg probe lin1 --targets "$CASE_DIR/targets.env"
  assert_rc 0 "$TG_RC" "probe"
  assert_not_match 'lin1-ssh.*NICE_DNS_OP|2026-09-22' "$(grep -v '^keygen ' "$FAKE_LOG" | sed 's/^.* lin1-ssh //')" "remote script built from constants only"
}

t_symlinked_state_files_refused() {
  # Every file target.sh writes under its state dir must refuse a pre-planted
  # symlink (no overwrite or append through a link).
  local f
  for f in snapshot.tsv receipt.tsv ops.tsv; do
    tg_setup
    rm -rf "$ARTIFACT_DIR/targets"
    mkdir -p "$ARTIFACT_DIR/targets/lin1"
    : >"$CASE_DIR/victim-$f"
    ln -s "$CASE_DIR/victim-$f" "$ARTIFACT_DIR/targets/lin1/$f"
    tg snapshot lin1 --targets "$CASE_DIR/targets.env"
    assert_nonzero "$TG_RC" "snapshot with a symlinked $f"
    assert_match 'symlink' "$TG_OUT" "refusal names the symlink ($f)"
    assert_eq "" "$(cat "$CASE_DIR/victim-$f")" "nothing written through $f"
  done
}

# ─── Task 2.3 operations: config, health, collect, freeze/thaw ───────────────

tg_identity() {
  # tg_identity <images-value> [platform] [target]: a collect identity file.
  printf 'target_id\t%s\nplatform\t%s\nproxy\thaproxy\npihole\tstandard\nsource_rev\tabc123\nimages\t%s\n' \
    "${3:-lin1}" "${2:-linux}" "$1" >"$CASE_DIR/identity.tsv"
}

t_freeze_and_thaw_need_snapshot_and_upstream_component() {
  local c
  tg_setup
  tg freeze-upstream lin1 --targets "$CASE_DIR/targets.env" --component tor-haproxy
  assert_nonzero "$TG_RC" "freeze without a snapshot"
  assert_match 'no restore snapshot' "$TG_OUT" "refusal names the missing snapshot"
  assert_eq 0 "$(tg_sent)" "nothing sent without a snapshot"
  tg snapshot lin1 --targets "$CASE_DIR/targets.env"
  for c in unbound pi-hole 'tor-socat;id' ''; do
    : >"$FAKE_LOG"
    tg freeze-upstream lin1 --targets "$CASE_DIR/targets.env" --component "$c"
    assert_nonzero "$TG_RC" "freeze component '$c' refused"
    assert_eq 0 "$(tg_sent)" "nothing sent for '$c'"
  done
  for c in 5 59 1801 abc; do
    : >"$FAKE_LOG"
    TG_OUT="$(NICE_DNS_FREEZE_MAX_SECS="$c" bash "$TG" freeze-upstream lin1 --targets "$CASE_DIR/targets.env" --component tor-socat 2>&1)"; TG_RC=$?
    assert_rc 2 "$TG_RC" "freeze maximum '$c' refused"
    assert_eq 0 "$(tg_sent)" "nothing sent for maximum '$c'"
  done
  : >"$FAKE_LOG"
  tg freeze-upstream lin1 --targets "$CASE_DIR/targets.env" --component tor-socat
  assert_rc 0 "$TG_RC" "freeze after snapshot: $TG_OUT"
  assert_match 'NICE_DNS_OP=freeze-upstream NICE_DNS_COMPONENT=tor-socat NICE_DNS_FREEZE_MAX=900 ' "$(cat "$FAKE_LOG")" "freeze sent with the default dead-man maximum"
  tg thaw-upstream lin1 --targets "$CASE_DIR/targets.env" --component tor-socat
  assert_rc 0 "$TG_RC" "thaw after snapshot: $TG_OUT"
}

t_collect_refuses_unsafe_parameters() {
  local v
  tg_setup
  RUN_ID=run-1; export RUN_ID
  # Identity values travel as words of the ssh command: no shell syntax.
  for v in 'a;id' 'a$(id)' 'a b' 'a|id' 'a`id`' 'a&id' "a'b" 'a"b' 'a>b' ''; do
    tg_identity "$v"
    : >"$FAKE_LOG"
    tg collect lin1 --targets "$CASE_DIR/targets.env" --workload cold --count 1 --identity "$CASE_DIR/identity.tsv"
    assert_rc 2 "$TG_RC" "identity images value [$v] refused"
    assert_eq 0 "$(tg_sent)" "nothing sent for identity value [$v]"
  done
  tg_identity 'pi-hole=sha256:ab,unbound=sha256:cd'
  for v in 'Cold' 'cold;id' '' '-x'; do
    : >"$FAKE_LOG"
    tg collect lin1 --targets "$CASE_DIR/targets.env" --workload "$v" --count 1 --identity "$CASE_DIR/identity.tsv"
    assert_nonzero "$TG_RC" "workload [$v] refused"
    assert_eq 0 "$(tg_sent)" "nothing sent for workload [$v]"
  done
  for v in 0 abc 100000 '1;id'; do
    tg collect lin1 --targets "$CASE_DIR/targets.env" --workload cold --count "$v" --identity "$CASE_DIR/identity.tsv"
    assert_rc 2 "$TG_RC" "count [$v] refused"
  done
  tg_identity 'pi-hole=sha256:ab' macos
  tg collect lin1 --targets "$CASE_DIR/targets.env" --workload cold --count 1 --identity "$CASE_DIR/identity.tsv"
  assert_rc 2 "$TG_RC" "identity platform that is not the target's refused"
  tg_identity 'pi-hole=sha256:ab' linux other
  tg collect lin1 --targets "$CASE_DIR/targets.env" --workload cold --count 1 --identity "$CASE_DIR/identity.tsv"
  assert_rc 2 "$TG_RC" "identity for another alias refused"
  tg_identity 'pi-hole=sha256:ab'
  TG_OUT="$(RUN_ID='r;id' bash "$TG" collect lin1 --targets "$CASE_DIR/targets.env" --workload cold --count 1 --identity "$CASE_DIR/identity.tsv" 2>&1)"; TG_RC=$?
  assert_rc 2 "$TG_RC" "unsafe RUN_ID refused"
  tg probe lin1 --targets "$CASE_DIR/targets.env" --workload cold
  assert_rc 2 "$TG_RC" "collect options on another operation refused"
}

t_collect_runs_collector_on_target_and_maps_failures() {
  local out
  tg_setup
  tg_remote_tools Linux
  printf '#!/bin/sh\nprintf ";; ->>HEADER<<- opcode: QUERY, status: %%s, id: 1\\n" "${FAKE_DIG_STATUS:-NOERROR}"\n' >"$CASE_DIR/rbin/dig"
  chmod 755 "$CASE_DIR/rbin/dig"
  tg_identity 'pi-hole=sha256:ab,unbound=sha256:cd,tor-haproxy=sha256:ef'
  RUN_ID=run-collect-1; export RUN_ID
  tg collect lin1 --targets "$CASE_DIR/targets.env" --workload cold --count 3 --identity "$CASE_DIR/identity.tsv"
  assert_rc 0 "$TG_RC" "all attempts answered: $TG_OUT"
  out="$(printf '%s\n' "$TG_OUT" | grep -v '^collect.sh:')"
  assert_match '^# schema	nice-dns-sample/1$' "$out" "samples on stdout"
  assert_eq 3 "$(printf '%s\n' "$out" | grep -c '^run-collect-1	')" "one row per attempt"
  assert_match '	127\.0\.0\.1#53	udp	[0-9a-f]{16}\.example\.com	A	ok	NOERROR	' "$out" "linux resolves through the Pi-hole listener"
  assert_match 'NICE_DNS_ID_IMAGES=pi-hole=sha256:ab,unbound=sha256:cd,tor-haproxy=sha256:ef' "$(cat "$FAKE_LOG")" "identity sent as data words"
  FAKE_DIG_STATUS=SERVFAIL; export FAKE_DIG_STATUS
  tg collect lin1 --targets "$CASE_DIR/targets.env" --workload cold --count 2 --identity "$CASE_DIR/identity.tsv"
  assert_rc 3 "$TG_RC" "failed attempts are data (exit 3), not an error"
  assert_eq 2 "$(printf '%s\n' "$TG_OUT" | grep -c '	servfail	SERVFAIL	')" "failures kept as rows"
  assert_eq "" "$(find "$TMPDIR" -maxdepth 1 -name 'nice-dns-collect.*')" "remote bundle dir removed"
}

t_remote_script_never_reads_secret_sources() {
  local script
  script="$(sed -n "/^remote_script() {/,/^SH\$/p" "$TG" | grep -v "^[[:space:]]*#")"
  assert_match 'NICE_DNS_OP' "$script" "extracted the remote script"
  assert_not_match 'torrc|\.Env|printenv|environ|Bridge|pwhash|webpassword|ps -o[^|]*args' "$script" \
    "no tor arguments, container env, torrc or Pi-hole credentials are read"
}

t_linux_health_observes_healthchecks_without_running_them() {
  tg_setup
  tg_remote_tools Linux
  tg health lin1 --targets "$CASE_DIR/targets.env"
  assert_rc 0 "$TG_RC" "health: $TG_OUT"
  assert_match '^health	nice-dns-health	(absent|pass|fail)	' "$TG_OUT" "health tool verdict recorded"
  assert_not_match 'healthcheck run|(^| )(stop|start|restart|kill|rm) ' "$(cat "$FAKE_LOG")" "health never invokes or changes a container"
  assert_match '^podman inspect [a-z-]+ --format \{\{range \.State\.Health\.Log\}\}' "$(cat "$FAKE_LOG")" "check history read from inspect"
}


t_install_cell_needs_snapshot_valid_cell_and_pinned_commit() {
  local v sha=0123456789abcdef0123456789abcdef01234567
  tg_setup
  tg install-cell lin1 --targets "$CASE_DIR/targets.env" --cell socat/standard --source-sha "$sha"
  assert_nonzero "$TG_RC" "install without a snapshot"
  assert_eq 0 "$(tg_sent)" "nothing sent without a snapshot"
  tg snapshot lin1 --targets "$CASE_DIR/targets.env"
  for v in socat haproxy/x 'socat/standard;id' ''; do
    : >"$FAKE_LOG"
    tg install-cell lin1 --targets "$CASE_DIR/targets.env" --cell "$v" --source-sha "$sha"
    assert_rc 2 "$TG_RC" "cell [$v] refused"
    assert_eq 0 "$(tg_sent)" "nothing sent for cell [$v]"
  done
  for v in main 0123abc "$sha;id" ''; do
    : >"$FAKE_LOG"
    tg install-cell lin1 --targets "$CASE_DIR/targets.env" --cell socat/standard --source-sha "$v"
    assert_rc 2 "$TG_RC" "source [$v] refused"
    assert_eq 0 "$(tg_sent)" "nothing sent for source [$v]"
  done
  tg probe lin1 --targets "$CASE_DIR/targets.env" --cell socat/standard
  assert_rc 2 "$TG_RC" "--cell on another operation refused"
  : >"$FAKE_LOG"
  tg install-cell lin1 --targets "$CASE_DIR/targets.env" --cell haproxy/standard --source-sha "$sha"
  assert_rc 0 "$TG_RC" "install after snapshot: $TG_OUT"
  assert_match "NICE_DNS_OP=install-cell NICE_DNS_PROXY=haproxy NICE_DNS_PIHOLE=standard NICE_DNS_SOURCE_SHA=$sha " "$(cat "$FAKE_LOG")" "install sent as data words"
}

t_install_cell_maps_each_cell_to_its_installer() {
  local script
  script="$(sed -n "/^remote_script() {/,/^SH\$/p" "$TG")"
  assert_match 'linux/standard\) inst=install-deb\.sh' "$script" "linux standard"
  assert_match 'linux/hardened\) inst=install-deb-hardened\.sh' "$script" "linux hardened"
  assert_match 'macos/standard\) inst=install-mac\.sh' "$script" "macos standard"
  assert_match 'macos/hardened\) inst=install-mac-hardened\.sh' "$script" "macos hardened"
  assert_match 'git -C "\$w/nice-dns" checkout -q "\$NICE_DNS_SOURCE_SHA"' "$script" "installs the pinned commit"
  assert_match 'install-mac\.sh installs origin/main, which is not' "$script" "install-mac.sh (clones main itself) is refused unless main is the pinned commit"
  assert_match 'if \[ "\$plat" = macos \]; then PATH="/opt/homebrew/bin:' "$script" "macOS installers get Homebrew on PATH (ssh shells are not login shells)"
}

t_hardened_install_needs_the_pinned_local_sibling() {
  local sha=0123456789abcdef0123456789abcdef01234567 hsha
  hsha="$(git -C "$NICE_DNS_ROOT/../pi-hole-hardened" rev-parse HEAD)"
  tg_setup
  tg snapshot lin1 --targets "$CASE_DIR/targets.env"
  : >"$FAKE_LOG"
  tg install-cell lin1 --targets "$CASE_DIR/targets.env" --cell socat/hardened --source-sha "$sha"
  assert_rc 2 "$TG_RC" "hardened cell without --hardened-sha refused"
  tg install-cell lin1 --targets "$CASE_DIR/targets.env" --cell socat/hardened --source-sha "$sha" --hardened-sha "$sha"
  assert_rc 2 "$TG_RC" "a hardened sha that is not the sibling's HEAD refused"
  assert_match 'is not the HEAD of' "$TG_OUT" "refusal names the sibling"
  tg install-cell lin1 --targets "$CASE_DIR/targets.env" --cell socat/standard --source-sha "$sha" --hardened-sha "$hsha"
  assert_rc 2 "$TG_RC" "--hardened-sha on a standard cell refused"
  assert_eq 0 "$(tg_sent)" "nothing sent for any refused install"
  tg install-cell lin1 --targets "$CASE_DIR/targets.env" --cell socat/hardened --source-sha "$sha" --hardened-sha "$hsha"
  assert_rc 0 "$TG_RC" "hardened install with the sibling HEAD: $TG_OUT"
  assert_match "NICE_DNS_PIHOLE=hardened NICE_DNS_SOURCE_SHA=$sha NICE_DNS_HARDENED_SHA=$hsha" "$(cat "$FAKE_LOG")" "pinned sibling sent as a data word"
}

t_hardened_bundle_decodes_to_the_sibling_tree() {
  # The inline archive, decoded exactly as the remote script does, is the
  # sibling's tree at the pinned commit.
  local hsha d="$CASE_DIR/unpack"
  hsha="$(git -C "$NICE_DNS_ROOT/../pi-hole-hardened" rev-parse HEAD)"
  sed -n '/^BUNDLE_EOF=/p; /^hardened_bundle() {/,/^}/p' "$TG" >"$CASE_DIR/fn.sh"
  HSIB="$(cd "$NICE_DNS_ROOT/.." && pwd -P)/pi-hole-hardened" i_hsha="$hsha" \
    bash -c '. "$1"; hardened_bundle' _ "$CASE_DIR/fn.sh" >"$CASE_DIR/bundle.sh"
  assert_rc 0 $? "bundle generated"
  TMPDIR="$CASE_DIR" sh -c '. "$1"; mkdir "$2" && tar -xzf "$ND_HARDENED_TGZ" -C "$2"' _ "$CASE_DIR/bundle.sh" "$d"
  assert_rc 0 $? "bundle decodes and unpacks"
  assert_file "$d/Dockerfile" "Dockerfile unpacked"
  assert_file "$d/post-install.sh" "post-install.sh unpacked (the installer's sibling test)"
  assert_eq "$(git -C "$NICE_DNS_ROOT/../pi-hole-hardened" show "$hsha:Dockerfile" | cksum)" "$(cksum <"$d/Dockerfile")" "content is the pinned commit's"
}
