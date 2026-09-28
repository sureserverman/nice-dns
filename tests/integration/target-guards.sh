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
    assert_match 'no restore snapshot' "$TG_OUT" "$op refusal names the snapshot"
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
  # The word is allowed only in comments, the admin password file's path and
  # the Pi-hole API's JSON key (Sub-plan 4 Task 2.3); no value is embedded.
  assert_not_match '(password|passwd|sshpass|PRIVATE KEY)' "$(cat "$FAKE_LOG" "$NICE_DNS_ROOT/tests/live/target.sh" \
    | grep -v -e '^[[:space:]]*#' -e 'secrets/pihole/pihole_webpassword"$' -e "printf '{\"password\":\"'" -e "'{\"password\":\"nd-live-wrong\"}'")" "no embedded credentials"
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
  # Sub-plan 4 Task 2.3: the one sanctioned credential read. lifecycle-report
  # and mark-state read the Pi-hole admin password file on the target and feed
  # it to curl on stdin, to prove the real admin API (SEC-ADMIN-AUTH); how is
  # checked in t_lifecycle_ops_are_guarded. Exactly those two path lines may
  # name it; every other read stays forbidden.
  assert_eq 2 "$(printf '%s\n' "$script" | grep -c 'webpassword')" "only the two sanctioned lines name the admin password file"
  assert_eq 2 "$(printf '%s\n' "$script" | grep -c '^    pwf="\${XDG_STATE_HOME:-\$HOME/\.local/state}/nice-dns/secrets/pihole/pihole_webpassword"$')" "and they are the path assignments"
  assert_not_match 'torrc|\.Env|printenv|environ|Bridge|pwhash|webpassword|ps -o[^|]*args' \
    "$(printf '%s\n' "$script" | grep -v '^    pwf="\${XDG_STATE_HOME:-\$HOME/\.local/state}/nice-dns/secrets/pihole/pihole_webpassword"$')" \
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
  local v sha
  sha="$(git -C "$NICE_DNS_ROOT" rev-parse HEAD)"
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
  for v in main 0123abc "$sha;id" 0123456789abcdef0123456789abcdef01234567 ''; do
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
  assert_match "NICE_DNS_OP=install-cell NICE_DNS_ACTION=install NICE_DNS_PROXY=haproxy NICE_DNS_PIHOLE=standard NICE_DNS_SOURCE_SHA=$sha " "$(cat "$FAKE_LOG")" "install sent as data words"
}

t_install_cell_maps_each_cell_to_its_installer() {
  local script
  script="$(sed -n "/^remote_script() {/,/^SH\$/p" "$TG")"
  assert_match 'linux/standard\) inst=install-deb\.sh' "$script" "linux standard"
  assert_match 'linux/hardened\) inst=install-deb-hardened\.sh' "$script" "linux hardened"
  assert_match 'macos/standard\) inst=install-mac\.sh' "$script" "macos standard"
  assert_match 'macos/hardened\) inst=install-mac-hardened\.sh' "$script" "macos hardened"
  assert_match 'tar -xzf "\$ND_SOURCE_TGZ" -C "\$w/nice-dns"' "$script" "installs the pinned commit's archive"
  assert_not_match 'git clone' "$script" "nothing is fetched on the target (its DNS may be the broken stack)"
  # Sub-plan 4 Task 1.1: every entrypoint installs the tree it sits in, so
  # the macOS installer runs from the inline archive like the others.
  assert_not_match 'origin/main' "$(grep -v '^[[:space:]]*#' "$TG")" "no cell depends on this checkout's origin/main"
  assert_not_match 'ls-remote' "$script" "nothing reads GitHub main on the target"
  assert_match 'bash "\./\$inst" "\$NICE_DNS_PROXY" main\)' "$script" "install runs the archived entrypoint"
  assert_match 'bash "\./\$inst" uninstall\)' "$script" "uninstall-cell runs the archived entrypoint's uninstall"
  assert_match "test -d /pihole && echo hardened" "$script" "hardened marker survives the image's own lockdown (post-install.sh deletes itself)"
  assert_match 'if \[ "\$plat" = macos \]; then PATH="/opt/homebrew/bin:' "$script" "macOS installers get Homebrew on PATH (ssh shells are not login shells)"
}

t_hardened_install_needs_the_pinned_local_sibling() {
  local sha hsha
  sha="$(git -C "$NICE_DNS_ROOT" rev-parse HEAD)"
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

t_source_bundle_decodes_to_the_pinned_tree() {
  local sha d="$CASE_DIR/src"
  sha="$(git -C "$NICE_DNS_ROOT" rev-parse HEAD)"
  sed -n '/^BUNDLE_EOF=/p; /^source_bundle() {/,/^}/p' "$TG" >"$CASE_DIR/fn.sh"
  ND_CHECKOUT="$NICE_DNS_ROOT" i_sha="$sha" bash -c '. "$1"; source_bundle' _ "$CASE_DIR/fn.sh" >"$CASE_DIR/bundle.sh"
  assert_rc 0 $? "bundle generated"
  TMPDIR="$CASE_DIR" sh -c '. "$1"; mkdir "$2" && tar -xzf "$ND_SOURCE_TGZ" -C "$2"' _ "$CASE_DIR/bundle.sh" "$d"
  assert_rc 0 $? "bundle decodes and unpacks"
  assert_file "$d/install-deb.sh" "installer unpacked"
  assert_file "$d/deb/quadlet/nice-dns.pod" "in-tree marker the Linux installers look for"
  assert_eq "$(git -C "$NICE_DNS_ROOT" show "$sha:install-deb.sh" | cksum)" "$(cksum <"$d/install-deb.sh")" "content is the pinned commit's"
}

t_state_files_are_owner_only_even_standalone() {
  tg_setup
  TG_OUT="$(umask 022; bash "$TG" snapshot lin1 --targets "$CASE_DIR/targets.env" 2>&1)"; TG_RC=$?
  assert_rc 0 "$TG_RC" "snapshot under umask 022: $TG_OUT"
  local f m
  for f in "$ARTIFACT_DIR/targets/lin1" "$ARTIFACT_DIR/targets/lin1/receipt.tsv" "$ARTIFACT_DIR/targets/lin1/ops.tsv" "$ARTIFACT_DIR/targets/lin1/snapshot.tsv"; do
    m="$(stat -c %a "$f" 2>/dev/null || stat -f %Lp "$f")"
    case "$m" in 600|700) ;; *) fail "$f has mode $m, expected owner-only" ;; esac
  done
  assert_eq 1 1 "all state paths owner-only"
}

t_failed_bundle_is_never_sent() {
  # A bundle that cannot be built must stop remote_run before ssh starts.
  sed -n '/^BUNDLE_EOF=/p; /^remote_run() {/,/^}/p; /^build_payload() {/,/^}/p; /^hardened_bundle() {/,/^}/p' "$TG" >"$CASE_DIR/fn.sh"
  cat >>"$CASE_DIR/fn.sh" <<'FN'
ssh() { printf 'SENT\n' >>"$SSH_MARK"; cat >/dev/null; }
remote_script() { printf 'echo remote\n'; }
source_bundle() { return 0; }
FN
  : >"$CASE_DIR/sent"
  HSIB="$(cd "$NICE_DNS_ROOT/.." && pwd -P)/pi-hole-hardened" SSH_MARK="$CASE_DIR/sent" \
    bash -c '. "$1"; op=install-cell i_hsha=0000000000000000000000000000000000000000 SSH_OPTS=(); T_SSH=x; remote_run "NICE_DNS_OP=install-cell"' _ "$CASE_DIR/fn.sh" >"$CASE_DIR/out" 2>&1
  assert_rc 2 $? "a failed archive (unknown object) is a refusal: $(cat "$CASE_DIR/out")"
  assert_eq "" "$(cat "$CASE_DIR/sent")" "ssh never started"
  assert_match 'nothing was sent' "$(cat "$CASE_DIR/out")" "says nothing was sent"
}

t_collect_refused_by_the_collector_is_exit_2() {
  tg_setup
  tg_remote_tools Linux
  printf '#!/bin/sh\nprintf ";; ->>HEADER<<- opcode: QUERY, status: NOERROR, id: 1\\n"\n' >"$CASE_DIR/rbin/dig"
  chmod 755 "$CASE_DIR/rbin/dig"
  # A proxy value that is valid data but no matrix cell: collect.sh refuses.
  printf 'target_id\tlin1\nplatform\tlinux\nproxy\tnginx\npihole\tstandard\nsource_rev\tabc\nimages\tx=y\n' >"$CASE_DIR/identity.tsv"
  RUN_ID=run-refused-1; export RUN_ID
  tg collect lin1 --targets "$CASE_DIR/targets.env" --workload cold --count 1 --identity "$CASE_DIR/identity.tsv"
  assert_rc 2 "$TG_RC" "collector refusal surfaces as refused (2), not failed (1): $TG_OUT"
}

# ─── controller operations (Sub-plan 3, Task 2.3) ────────────────────────────

t_controller_ops_need_snapshot_and_allow_listed_values() {
  local sha psha v w
  sha="$(git -C "$NICE_DNS_ROOT" rev-parse HEAD)"
  psha="$(git -C "$NICE_DNS_ROOT/../tor-haproxy" rev-parse HEAD)"
  tg_setup
  for v in "quiesce-agents" "build-proxy --component tor-haproxy --source-sha $psha" "recreate-proxy --component tor-haproxy" \
           "install-controller --source-sha $sha --mode shadow" "fault-route --component tor-haproxy --route cloudflare-onion" \
           "heal-route --component tor-haproxy --route cloudflare-onion"; do
    : >"$FAKE_LOG"
    read -r -a w <<<"$v"
    tg "${w[0]}" lin1 --targets "$CASE_DIR/targets.env" "${w[@]:1}"
    assert_nonzero "$TG_RC" "${v%% *} without a snapshot"
    assert_match 'no restore snapshot' "$TG_OUT" "${v%% *}: the refusal names the snapshot"
    assert_eq 0 "$(tg_sent)" "${v%% *}: nothing sent without a snapshot"
  done
  tg snapshot lin1 --targets "$CASE_DIR/targets.env"
  for v in "build-proxy --component unbound --source-sha $psha" "build-proxy --component tor-haproxy --source-sha $sha" \
           "build-proxy --component tor-haproxy --source-sha main" "build-proxy --component tor-haproxy" \
           "recreate-proxy --component pi-hole" "recreate-proxy --component tor-socat;id" \
           "install-controller --source-sha $sha" "install-controller --source-sha $sha --mode bogus" \
           "install-controller --source-sha $psha --mode active" "install-controller --mode shadow" \
           "fault-route --component tor-haproxy --route cloudflare-legacy" "fault-route --component tor-haproxy --route x;id" \
           "fault-route --component unbound --route quad9-exit" "fault-route --component tor-haproxy" \
           "quiesce-agents --component tor-haproxy" "probe --mode shadow" "probe --route quad9-exit"; do
    : >"$FAKE_LOG"
    read -r -a w <<<"$v"
    tg "${w[0]}" lin1 --targets "$CASE_DIR/targets.env" "${w[@]:1}"
    assert_rc 2 "$TG_RC" "[$v] refused: $TG_OUT"
    assert_eq 0 "$(tg_sent)" "nothing sent for [$v]"
  done
  : >"$FAKE_LOG"
  tg install-controller lin1 --targets "$CASE_DIR/targets.env" --source-sha "$sha" --mode shadow
  assert_rc 0 "$TG_RC" "install-controller after snapshot: $TG_OUT"
  assert_match "NICE_DNS_OP=install-controller NICE_DNS_COMPONENT= NICE_DNS_FREEZE_MAX=900 NICE_DNS_ROUTE= NICE_DNS_MODE=shadow NICE_DNS_SOURCE_SHA=$sha " "$(cat "$FAKE_LOG")" "sent as data words"
  : >"$FAKE_LOG"
  tg fault-route lin1 --targets "$CASE_DIR/targets.env" --component tor-socat --route cloudflare-onion
  assert_rc 0 "$TG_RC" "fault-route after snapshot: $TG_OUT"
  assert_match "NICE_DNS_OP=fault-route NICE_DNS_COMPONENT=tor-socat NICE_DNS_FREEZE_MAX=900 NICE_DNS_ROUTE=cloudflare-onion " "$(cat "$FAKE_LOG")" "fault sent with the dead-man maximum"
}

t_proxy_bundle_decodes_to_the_pinned_sibling_tree() {
  local psha d="$CASE_DIR/src"
  psha="$(git -C "$NICE_DNS_ROOT/../tor-haproxy" rev-parse HEAD)"
  sed -n '/^BUNDLE_EOF=/p; /^proxy_bundle() {/,/^}/p' "$TG" >"$CASE_DIR/fn.sh"
  PSIB="$NICE_DNS_ROOT/../tor-haproxy" i_sha="$psha" bash -c '. "$1"; proxy_bundle' _ "$CASE_DIR/fn.sh" >"$CASE_DIR/bundle.sh"
  assert_rc 0 $? "bundle generated"
  TMPDIR="$CASE_DIR" sh -c '. "$1"; mkdir "$2" && tar -xzf "$ND_PROXY_TGZ" -C "$2"' _ "$CASE_DIR/bundle.sh" "$d"
  assert_rc 0 $? "bundle decodes and unpacks"
  assert_eq "$(git -C "$NICE_DNS_ROOT/../tor-haproxy" show "$psha:Dockerfile" | cksum)" "$(cksum <"$d/Dockerfile")" "content is the pinned commit's"
  assert_no_path "$d/bridge-eval/bridge-eval" "the untracked local binary is not sent (the image builds bridge-eval from source)"
}

t_controller_report_is_read_only_and_holds_no_secrets() {
  local plat
  for plat in Linux Darwin; do
    tg_setup
    tg_remote_tools "$plat"
    if [ "$plat" = Darwin ]; then
      tg_targets 'mac1	macos	mac1-ssh	SHA256:AAAAtestfingerprintAAAAAAAAAAAAAAAAAAAAAAAA	disposable	2026-09-22'
      tg controller-report mac1 --targets "$CASE_DIR/targets.env"
    else
      tg controller-report lin1 --targets "$CASE_DIR/targets.env"
    fi
    assert_rc 0 "$TG_RC" "$plat: controller-report: $TG_OUT"
    assert_match '^section	install$' "$TG_OUT" "$plat: install section"
    assert_match '^section	ticks$' "$TG_OUT" "$plat: tick lines section"
    assert_match '^section	journal-shadow$' "$TG_OUT" "$plat: shadow journal section"
    assert_match '^section	bridges$' "$TG_OUT" "$plat: bridge set section (a hash, never the lines)"
    assert_match '^section	power$' "$TG_OUT" "$plat: power section (the sleep count, for the wake scenario)"
    assert_not_match '(^| )(stop|start|restart|kill|rm|delete|kickstart|bootout|load|unload|enable|disable|build|tag|tick|run|install) ' "$(grep -v '^keygen ' "$FAKE_LOG" | grep -v 'NICE_DNS_OP=')" \
      "$plat: controller-report never changes anything"
  done
  assert_match 'nd_br_redact|redact' "$(sed -n "/^remote_script() {/,/^SH\$/p" "$TG")" "the report output is redacted at the source"
}

t_quiesce_stops_only_the_legacy_mutating_agents() {
  local script
  script="$(sed -n "/^remote_script() {/,/^SH\$/p" "$TG")"
  assert_match 'org\.nice-dns\.health org\.nice-dns\.bridge-eval org\.nice-dns\.health-bridges' "$script" "macOS: the old controller and both bridge agents"
  assert_match 'nice-dns-health\.timer nice-dns-health-bridges\.timer' "$script" "Linux: the controller and bridge timers"
  assert_not_match 'bootout[^;]*start-container|bootout[^;]*debug-monitor' "$script" "the stack's own starter and the read-only debug monitor keep running"
}

t_macos_build_uses_its_own_resolver_and_stops_the_builder() {
  # Starting Apple's builder (default network) wedges dnsnet, and with it the
  # Mac's DNS (debug-monitor: 2026-09-24 20:54 and 2026-09-25 16:30 UTC, each
  # ~15 s after buildkit started). The build therefore brings its own
  # resolver (a declared bootstrap exception: image pulls, never client
  # queries) and stops the builder whatever the result; recreate-proxy's
  # start-container run then repairs the datapath.
  local script
  script="$(sed -n "/^remote_script() {/,/^SH\$/p" "$TG" | sed -n '/^  build-proxy)/,/;;$/p')"
  assert_match 'ctl builder start --dns 1\.1\.1\.1' "$script" "macOS: the builder gets its own resolver"
  assert_match 'ctl builder stop' "$script" "macOS: the builder is stopped after the build"
  assert_match 'ctl image pull' "$script" "macOS: the base images are pulled before the builder starts (the host fetches them, and the wedge takes the host's DNS)"
  [ "$(printf '%s\n' "$script" | grep -n 'ctl image pull' | head -1 | cut -d: -f1)" -lt "$(printf '%s\n' "$script" | grep -n 'ctl builder start' | head -1 | cut -d: -f1)" ] \
    || fail "the pull comes before the builder starts"
  assert_match 'PRIV-BOOTSTRAP-DECLARED' "$(sed -n "/^remote_script() {/,/^SH\$/p" "$TG")" "the exception is declared where it is made"
}

t_dead_man_timers_never_hold_the_ssh_session() {
  # `cond && nohup ... >/dev/null 2>&1 &` backgrounds the whole list in a
  # subshell that keeps ssh's stdout open, so the operation returns only when
  # the timer ends (live run 3: fault-route on tor-haproxy took the full
  # 900 s and healed itself). Every nohup starts its own command.
  local script
  script="$(sed -n "/^remote_script() {/,/^SH\$/p" "$TG")"
  assert_match 'nohup' "$script" "the remote script has dead-man timers"
  assert_eq "" "$(printf '%s\n' "$script" | grep -nE '(&&|\|\|)[[:space:]]*nohup')" "no nohup after && or ||"
  assert_eq "" "$(printf '%s\n' "$script" | grep -n 'nohup' | grep -vE '^[0-9]+:[[:space:]]*nohup ')" "every nohup is the first word of its line"
}

t_activation_ops_need_snapshot_and_allow_listed_values() {
  # Sub-plan 3 Task 2.3, the test-only activation faults: thaw Tor when the
  # controller's restart request lands (the in-image acknowledged path),
  # wedge and heal the runtime, and run the daily bridge refresh now.
  local v w
  tg_setup
  for v in "thaw-on-request --component tor-haproxy" "wedge-runtime" "heal-runtime" "bridges-refresh" "hold-bridge-refresh"; do
    : >"$FAKE_LOG"
    read -r -a w <<<"$v"
    tg "${w[0]}" lin1 --targets "$CASE_DIR/targets.env" "${w[@]:1}"
    assert_nonzero "$TG_RC" "${w[0]} without a snapshot"
    assert_match 'no restore snapshot' "$TG_OUT" "${w[0]}: the refusal names the snapshot"
    assert_eq 0 "$(tg_sent)" "${w[0]}: nothing sent without a snapshot"
  done
  tg snapshot lin1 --targets "$CASE_DIR/targets.env"
  for v in "thaw-on-request" "thaw-on-request --component unbound" "wedge-runtime --component tor-haproxy" "bridges-refresh --route quad9-exit"; do
    : >"$FAKE_LOG"
    read -r -a w <<<"$v"
    tg "${w[0]}" lin1 --targets "$CASE_DIR/targets.env" "${w[@]:1}"
    assert_rc 2 "$TG_RC" "[$v] refused: $TG_OUT"
    assert_eq 0 "$(tg_sent)" "nothing sent for [$v]"
  done
  : >"$FAKE_LOG"
  tg thaw-on-request lin1 --targets "$CASE_DIR/targets.env" --component tor-socat
  assert_rc 0 "$TG_RC" "thaw-on-request after snapshot: $TG_OUT"
  assert_match 'NICE_DNS_OP=thaw-on-request NICE_DNS_COMPONENT=tor-socat NICE_DNS_FREEZE_MAX=900 ' "$(cat "$FAKE_LOG")" "sent with its maximum wait"
}

t_activation_ops_do_what_they_say() {
  local script op
  script="$(sed -n "/^remote_script() {/,/^SH\$/p" "$TG")"
  op="$(printf '%s\n' "$script" | sed -n '/^  thaw-on-request)/,/;;$/p')"
  assert_match 'tor-restart-pending' "$op" "thaw-on-request waits for the image to claim the controller's request"
  assert_match 'pkill -CONT -x tor' "$op" "and then thaws Tor, whose pending TERM ends it"
  op="$(printf '%s\n' "$script" | sed -n '/^  wedge-runtime)/,/;;$/p')"
  assert_match 'run -d --name nice-dns-wedge' "$op" "macOS: a container on the default network (the observed wedge trigger)"
  assert_match 'systemctl --user stop pi-hole\.service' "$op" "Linux: the stack's containers go missing"
  op="$(printf '%s\n' "$script" | sed -n '/^  heal-runtime)/,/;;$/p')"
  assert_match 'delete --force nice-dns-wedge' "$op" "macOS: the wedge container is removed"
  op="$(printf '%s\n' "$script" | sed -n '/^  bridges-refresh)/,/;;$/p')"
  assert_match '"\$t" bridges-refresh' "$op" "bridges-refresh runs the installed controller's refresh"
  assert_match 'redact <' "$op" "and its output is redacted"
  assert_not_match 'PIPESTATUS' "$script" "the remote script is /bin/sh (dash on Linux): no PIPESTATUS"
  op="$(printf '%s\n' "$script" | sed -n '/^  hold-bridge-refresh)/,/;;$/p')"
  assert_match 'nice-dns/controller' "$op" "hold-bridge-refresh writes only the controller's own rate-limit stamp"
  assert_match 'bridges\.last' "$op" "(bridges.last, read by refresh_bridges_on_outage)"
}

t_remote_script_is_posix_sh() {
  # The remote script runs as `/bin/sh -s`: dash on Linux, bash-as-sh on
  # macOS. Bash-only syntax (PIPESTATUS, [[ ]], arrays) silently misbehaves
  # under dash.
  sed -n "/^remote_script() {/,/^SH\$/p" "$TG" | sed '1,2d;$d' >"$CASE_DIR/remote.sh"
  assert_match 'NICE_DNS_OP' "$(cat "$CASE_DIR/remote.sh")" "extracted the remote script"
  if command -v dash >/dev/null 2>&1; then
    dash -n "$CASE_DIR/remote.sh"; assert_rc 0 $? "dash parses the remote script"
  fi
  shellcheck -s sh -S warning "$CASE_DIR/remote.sh" >"$CASE_DIR/sc.txt" 2>&1
  assert_rc 0 $? "shellcheck as POSIX sh: $(head -n 5 "$CASE_DIR/sc.txt")"
}

t_install_agent_is_macos_only_and_pinned() {
  # Sub-plan 3 Task 2.3: a cell installed from origin/main carries its
  # old mac/start-container.sh; install-agent replaces the LaunchAgent's
  # root-owned copy with this checkout's at --source-sha (the target has
  # sudo that asks for no credential; sudo -n never prompts).
  local sha script op
  sha="$(git -C "$NICE_DNS_ROOT" rev-parse HEAD)"
  tg_setup
  tg install-agent lin1 --targets "$CASE_DIR/targets.env" --source-sha "$sha"
  assert_nonzero "$TG_RC" "install-agent without a snapshot"
  assert_match 'no restore snapshot' "$TG_OUT" "names the snapshot"
  tg snapshot lin1 --targets "$CASE_DIR/targets.env"
  : >"$FAKE_LOG"
  tg install-agent lin1 --targets "$CASE_DIR/targets.env"
  assert_rc 2 "$TG_RC" "install-agent needs --source-sha"
  assert_eq 0 "$(tg_sent)" "nothing sent"
  script="$(sed -n "/^remote_script() {/,/^SH\$/p" "$TG")"
  op="$(printf '%s\n' "$script" | sed -n '/^  install-agent)/,/;;$/p')"
  assert_match 'sudo -n install -m 755 "\$w/mac/start-container\.sh" /usr/local/sbin/start-container\.sh' "$op" "installs exactly the agent script, never prompting"
  assert_match 'plat" != macos' "$op" "refused off macOS"
}

t_set_tunables_writes_only_the_controller_timers() {
  # Live gate, user decision 2026-09-26: extra configurations run with 30 s
  # policy timers; one per machine keeps the real ones. The operation writes
  # (fast) or removes (default) exactly the controller's tunables file.
  local script op v w
  tg_setup
  tg set-tunables lin1 --targets "$CASE_DIR/targets.env" --mode fast
  assert_match 'no restore snapshot' "$TG_OUT" "set-tunables needs a snapshot"
  tg snapshot lin1 --targets "$CASE_DIR/targets.env"
  for v in "set-tunables" "set-tunables --mode shadow" "set-tunables --mode fast;id"; do
    : >"$FAKE_LOG"
    read -r -a w <<<"$v"
    tg "${w[0]}" lin1 --targets "$CASE_DIR/targets.env" "${w[@]:1}"
    assert_rc 2 "$TG_RC" "[$v] refused"
    assert_eq 0 "$(tg_sent)" "nothing sent for [$v]"
  done
  : >"$FAKE_LOG"
  tg set-tunables lin1 --targets "$CASE_DIR/targets.env" --mode fast
  assert_rc 0 "$TG_RC" "fast after snapshot: $TG_OUT"
  assert_match 'NICE_DNS_OP=set-tunables .*NICE_DNS_MODE=fast ' "$(cat "$FAKE_LOG")" "sent as data words"
  script="$(sed -n "/^remote_script() {/,/^SH\$/p" "$TG")"
  op="$(printf '%s\n' "$script" | sed -n '/^  set-tunables)/,/;;$/p')"
  assert_match 'nice-dns-health/tunables\.tsv' "$op" "only the controller's tunables file"
  assert_match 'ND_POLICY_GRACE_S' "$op" "the policy timers"
}

# Sub-plan 4 Task 2.3: the lifecycle operations.
t_lifecycle_ops_are_guarded() {
  local sha script op
  sha="$(git -C "$NICE_DNS_ROOT" rev-parse HEAD)"
  tg_setup
  tg uninstall-cell lin1 --targets "$CASE_DIR/targets.env" --cell haproxy/standard --source-sha "$sha"
  assert_nonzero "$TG_RC" "uninstall-cell without a snapshot"
  assert_match 'no restore snapshot' "$TG_OUT" "names the snapshot"
  tg mark-state lin1 --targets "$CASE_DIR/targets.env"
  assert_nonzero "$TG_RC" "mark-state without a snapshot"
  tg snapshot lin1 --targets "$CASE_DIR/targets.env"
  : >"$FAKE_LOG"
  tg uninstall-cell lin1 --targets "$CASE_DIR/targets.env" --source-sha "$sha"
  assert_rc 2 "$TG_RC" "uninstall-cell needs --cell"
  tg uninstall-cell lin1 --targets "$CASE_DIR/targets.env" --cell haproxy/standard
  assert_rc 2 "$TG_RC" "uninstall-cell needs --source-sha"
  tg lifecycle-report lin1 --targets "$CASE_DIR/targets.env" --cell haproxy/standard
  assert_rc 2 "$TG_RC" "--cell is refused on other operations"
  NICE_DNS_WATCH_SECS=5 tg watch-dns lin1 --targets "$CASE_DIR/targets.env"
  assert_rc 2 "$TG_RC" "watch-dns is bounded (10..3600 s)"
  assert_eq 0 "$(tg_sent)" "nothing sent for a refused operation"
  tg uninstall-cell lin1 --targets "$CASE_DIR/targets.env" --cell haproxy/standard --source-sha "$sha"
  assert_rc 0 "$TG_RC" "uninstall-cell after snapshot: $TG_OUT"
  assert_match "NICE_DNS_OP=uninstall-cell NICE_DNS_ACTION=uninstall NICE_DNS_PROXY=haproxy NICE_DNS_PIHOLE=standard NICE_DNS_SOURCE_SHA=$sha " "$(cat "$FAKE_LOG")" "uninstall sent as data words"
  script="$(sed -n "/^remote_script() {/,/^SH\$/p" "$TG")"
  op="$(printf '%s\n' "$script" | sed -n '/^  lifecycle-report)/,/;;$/p')"
  assert_match "tr -d '.n' <\"\\\$pwf\"; printf '\"}'; } \\| curl -s -m 10 --data @-" "$op" "the admin password goes to curl on stdin, never as an argument"
  assert_match 'X-FTL-SID: \$sid" "\$base/api/auth"' "$op" "and the session is closed again"
  assert_match '\| redact ;;' "$op" "the report is redacted"
  op="$(printf '%s\n' "$script" | sed -n '/^  mark-state)/,/;;$/p')"
  assert_match '\| curl -s -m 10 --data @-' "$op" "mark-state logs in the same way"
  assert_not_match 'echo .*pwf|cat "\$pwf"' "$op" "and never prints the password"
}
