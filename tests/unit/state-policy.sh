# shellcheck shell=bash
# Group unit/state-policy (Sub-plan 3, Task 1.2; ARCH-02, ARCH-03, ARCH-07).
#
# Sourced by tests/run.sh (assert_* helpers; NICE_DNS_ROOT, CASE_DIR). Drives
# lib/state.sh (schema-versioned state, one mutation lock, generation-checked
# commits, staged output) and lib/policy.sh (the pure decision function) with
# files under the case directory only. The boot identity and the clock are
# inputs (ND_BOOT_ID, explicit epochs), so reboots and wall-clock rollback are
# simulated, never caused. t_bash32_runs_state_and_policy starts a throwaway
# docker.io/library/bash:3.2 container (--rm, no name, no network) to run the
# libraries under macOS's Bash version.

SP_STATE="$NICE_DNS_ROOT/lib/state.sh"
SP_POLICY="$NICE_DNS_ROOT/lib/policy.sh"
SP_T0=1760000000

sp_env() {
  export ND_STATE_DIR="$CASE_DIR/state" ND_BOOT_ID="boot-a" ND_PLATFORM=linux
  export ND_ROUTES_FILE="$NICE_DNS_ROOT/routes/providers.tsv"
  unset ND_STATE_LEASE_S ND_POLICY_STARTUP_S ND_POLICY_GRACE_S ND_POLICY_COOLDOWN_S ND_POLICY_LADDER_S ND_POLICY_RUNTIME_REPAIRS \
    ND_POLICY_PROMOTE ND_POLICY_DEMOTE ND_POLICY_MAX_RESTARTS ND_POLICY_UNBOUND_FAILS ND_POLICY_UNBOUND_MAX_RESTARTS ND_POLICY_RETRY_S ND_POLICY_RUNTIME_REPAIR_MAX \
    ND_POLICY_PIHOLE_FAILS ND_POLICY_PIHOLE_MAX_RESTARTS ND_POLICY_PAUSED_PASSES \
    ND_POLICY_CRASH_WINDOW_S ND_POLICY_CRASH_BURST ND_POLICY_PAUSED_MAX_REPAIRS
}

sp_libs() {
  sp_env
  # The controller's shell options (health/nice-dns-health:27).
  set -uo pipefail
  # shellcheck source=lib/state.sh
  . "$SP_STATE" || fail "cannot source lib/state.sh"
  # shellcheck source=lib/policy.sh
  . "$SP_POLICY" || fail "cannot source lib/policy.sh"
}

# sp_obs <file> <runtime> <onion> <exit> <quad9> <legacy>: an observation
# file; "-" leaves that record out. Runtime values: healthy, down, missing,
# cli, indeterminate.
sp_obs() {
  local f="$1" rt="$2"
  {
    printf 'schema\tnice-dns-observations/1\n'
    case "$rt" in
      healthy) printf 'obs\truntime\thealthy\t5\trunning: pi-hole unbound tor-haproxy\n' ;;
      down) printf 'obs\truntime\tunhealthy\t5\truntime-down: podman ps exited 125\n' ;;
      missing) printf 'obs\truntime\tunhealthy\t5\tcontainers-missing: unbound\n' ;;
      cli) printf 'obs\truntime\tunhealthy\t5\tcli-missing: podman not found\n' ;;
      indeterminate) printf 'obs\truntime\tindeterminate\t10000\tdeadline: podman ps\n' ;;
      -) ;;
    esac
    printf 'obs\tdns-owner\thealthy\t3\tresolv.conf names 127.0.0.1\n'
    printf 'obs\tlocal-cache\thealthy\t4\tNOERROR (may be cached; not upstream health)\n'
    [ "$3" = - ] || printf 'obs\troute:cloudflare-onion\t%s\t900\tprobe\n' "$3"
    [ "$4" = - ] || printf 'obs\troute:cloudflare-exit\t%s\t900\tprobe\n' "$4"
    [ "$5" = - ] || printf 'obs\troute:quad9-exit\t%s\t900\tprobe\n' "$5"
    [ "$6" = - ] || printf 'obs\troute:cloudflare-legacy\t%s\t900\tprobe\n' "$6"
  } >"$f"
}

# sp_decide <obs> <state|-> <now> [boot]: runs nd_policy_decide; sets SP_OUT,
# SP_ACTION, SP_TARGET, SP_REASON and writes the next state to $CASE_DIR/next.
sp_decide() {
  local st="$2"
  if [ "$st" = - ]; then st="$CASE_DIR/empty-state"; : >"$st"; fi
  SP_OUT="$(nd_policy_decide "$1" "$st" "$3" "${4:-boot-a}")"; SP_RC=$?
  assert_rc 0 "$SP_RC" "nd_policy_decide exit status"
  SP_ACTION="$(printf '%s\n' "$SP_OUT" | awk -F '\t' '$1 == "action" { print $2; exit }')"
  SP_TARGET="$(printf '%s\n' "$SP_OUT" | awk -F '\t' '$1 == "target" { print $2; exit }')"
  SP_REASON="$(printf '%s\n' "$SP_OUT" | awk -F '\t' '$1 == "reason" { print $2; exit }')"
  printf '%s\n' "$SP_OUT" | awk '$0 == "schema\tnice-dns-controller-state/1" { s = 1 } s' >"$CASE_DIR/next"
}

# sp_key <file> <key>: the value of a state key.
sp_key() { awk -F '\t' -v k="$2" '$1 == k { print $2; exit }' "$1"; }
sp_streak() { awk -F '\t' -v r="$2" '$1 == "streak" && $2 == r { print $3 "/" $4; exit }' "$1"; }

# sp_run <obs> <now>...: feed the next state back in, one observation per
# call, every call at the given epoch.
sp_steps() {
  local obs="$1" t
  shift
  for t in "$@"; do
    sp_decide "$obs" "$CASE_DIR/cur" "$t"
    cp "$CASE_DIR/next" "$CASE_DIR/cur"
  done
}

# ───────────────────────────── state ─────────────────────────────────────────

t_state_commit_bumps_generation_and_loads_back() {
  local tok gen out
  sp_libs
  nd_state_init || fail "init"
  out="$(nd_state_load)"; assert_rc 0 $? "load of a missing state"
  assert_eq 0 "$(printf '%s\n' "$out" | awk -F '\t' '$1 == "generation" { print $2 }')" "a new state is generation 0"
  tok="$(nd_state_lock)"; assert_rc 0 $? "lock"
  printf 'schema\tnice-dns-controller-state/1\nboot_id\tboot-a\nupdated\t%s\nstarted\t%s\nroute\tcloudflare-exit\noutage_since\t-\noutage_restarts\t0\nlast_action\tswitch-route\nlast_action_at\t%s\nrecovery_at\t-\nstreak\tcloudflare-onion\t0\t3\t0\n' \
    "$SP_T0" "$SP_T0" "$SP_T0" >"$CASE_DIR/n1"
  gen="$(nd_state_commit "$tok" 0 "$CASE_DIR/n1")"; assert_rc 0 $? "commit at generation 0"
  assert_eq 1 "$gen" "first commit is generation 1"
  out="$(nd_state_load)"
  assert_match '^route	cloudflare-exit$' "$out" "route loads back"
  assert_match '^streak	cloudflare-onion	0	3	0$' "$out" "streak loads back"
  assert_match '^generation	1$' "$out" "generation loads back"
  gen="$(nd_state_commit "$tok" 1 "$CASE_DIR/n1")"; assert_rc 0 $? "second commit"
  assert_eq 2 "$gen" "generation increments"
  nd_state_unlock "$tok"; assert_rc 0 $? "unlock"
  [ -z "$(find "$ND_STATE_DIR" -maxdepth 0 \( -perm -0040 -o -perm -0004 -o -perm -0020 -o -perm -0002 \))" ] \
    || fail "state directory is readable or writable by group/others"
  [ -z "$(find "$ND_STATE_DIR/state.tsv" \( -perm -0040 -o -perm -0004 \))" ] || fail "state.tsv is group/other readable"
}

t_state_commit_refuses_stale_generation() {
  local tok
  sp_libs
  nd_state_init
  tok="$(nd_state_lock)"
  printf 'schema\tnice-dns-controller-state/1\nboot_id\tboot-a\nupdated\t1\nstarted\t1\nroute\t-\noutage_since\t-\noutage_restarts\t0\nlast_action\t-\nlast_action_at\t-\nrecovery_at\t-\n' >"$CASE_DIR/n"
  nd_state_commit "$tok" 0 "$CASE_DIR/n" >/dev/null || fail "first commit"
  nd_state_commit "$tok" 0 "$CASE_DIR/n" >/dev/null 2>"$CASE_DIR/err"
  assert_rc 4 $? "a commit expecting an old generation is a conflict"
  assert_match 'generation' "$(cat "$CASE_DIR/err")" "the conflict names the generation"
  assert_match '^generation	1$' "$(nd_state_load)" "the conflicting commit changed nothing"
}

t_state_rejects_malformed_and_never_executes_it() {
  local base bad rc
  sp_libs
  nd_state_init
  base='schema\tnice-dns-controller-state/1\ngeneration\t3\nboot_id\tboot-a\nupdated\t1\nstarted\t1\nroute\t-\noutage_since\t-\noutage_restarts\t0\nlast_action\t-\nlast_action_at\t-\nrecovery_at\t-\n'
  # shellcheck disable=SC2059
  printf "$base" >"$ND_STATE_DIR/state.tsv"; chmod 600 "$ND_STATE_DIR/state.tsv"
  nd_state_load >/dev/null; assert_rc 0 $? "the well-formed base loads"
  # The $(touch PWNED) row is literal on purpose: it must never run.
  # shellcheck disable=SC2016
  for bad in \
    's/^schema.*/schema\tnice-dns-controller-state\/2/' \
    '/^route/d' \
    's/^route\t-/route\t-\nroute\tcloudflare-exit/' \
    's/^updated\t1/updated\t1x/' \
    's/^route\t-/route\t$(touch PWNED)/' \
    's/^last_action\t-/last_action\treboot-the-host/' \
    's/^boot_id\tboot-a/boot_id\tboot a/' \
    's/^started\t1/started\t1\r/' \
    's/^recovery_at\t-/recovery_at\t-\nbonus\tx/' \
    's/^recovery_at\t-/recovery_at\t-\nstreak\tcloudflare-onion\t1\t0/' \
    's/^recovery_at\t-/recovery_at\t-\nstreak\tcloudflare-onion\t1\t0\t0\nstreak\tcloudflare-onion\t2\t0\t0/'; do
    # shellcheck disable=SC2059
    printf "$base" | sed "$bad" >"$ND_STATE_DIR/state.tsv"
    (cd "$CASE_DIR" && nd_state_load >/dev/null 2>"$CASE_DIR/err"); rc=$?
    assert_rc 2 "$rc" "malformed state refused: $bad"
    assert_no_path "$CASE_DIR/PWNED" "state content was executed"
  done
}

t_state_dir_must_be_private_and_real() {
  local rc
  sp_libs
  mkdir -p "$CASE_DIR/elsewhere"; chmod 700 "$CASE_DIR/elsewhere"
  ln -s "$CASE_DIR/elsewhere" "$ND_STATE_DIR"
  nd_state_init 2>/dev/null; rc=$?
  assert_nonzero "$rc" "a symlinked state directory is refused"
  nd_state_lock >/dev/null 2>&1; assert_rc 2 $? "lock refuses a symlinked state directory"
  rm -f "$ND_STATE_DIR"; mkdir "$ND_STATE_DIR"; chmod 750 "$ND_STATE_DIR"
  nd_state_lock >/dev/null 2>"$CASE_DIR/err"; assert_rc 2 $? "a group-accessible state directory is refused"
  assert_match 'group|other' "$(cat "$CASE_DIR/err")" "says why"
  chmod 700 "$ND_STATE_DIR"
  ln -s /etc/passwd "$ND_STATE_DIR/state.tsv"
  nd_state_load >/dev/null 2>&1; assert_rc 2 $? "a symlinked state file is refused"
}

t_state_overlapping_actors_one_lock_winner() {
  local i n
  sp_libs
  nd_state_init
  for i in 1 2 3 4 5 6 7 8; do
    ( if tok="$(nd_state_lock)"; then printf '%s\n' "$tok" >"$CASE_DIR/won.$i"; sleep 2; nd_state_unlock "$tok"; fi ) &
  done
  wait
  n="$(find "$CASE_DIR" -maxdepth 1 -name 'won.*' | wc -l | tr -d ' ')"
  assert_eq 1 "$n" "exactly one of eight concurrent actors holds the lock"
  tok="$(nd_state_lock)"; assert_rc 0 $? "the lock is free after release"
  nd_state_unlock "$tok"
}

t_state_orphan_lock_of_dead_process_is_reclaimed() {
  local dead tok
  sp_libs
  nd_state_init
  sh -c 'exit 0' & dead=$!; wait "$dead"
  ln -s "nd-lock:$dead:boot-a:$(date +%s):orphan" "$ND_STATE_DIR/lock"
  tok="$(nd_state_lock 2>"$CASE_DIR/err")"; assert_rc 0 $? "a dead holder's lock is reclaimed"
  assert_ne orphan "$tok" "a fresh token"
  nd_state_lock_held "$tok"; assert_rc 0 $? "the new holder holds it"
}

t_state_lock_from_previous_boot_is_reclaimed() {
  local tok
  sp_libs
  nd_state_init
  # Our own live pid, but recorded under another boot: a pid is only
  # meaningful within the boot that issued it.
  ln -s "nd-lock:$$:boot-old:$(date +%s):old" "$ND_STATE_DIR/lock"
  tok="$(nd_state_lock)"; assert_rc 0 $? "a lock from before the reboot is reclaimed"
  nd_state_unlock "$tok"
}

t_state_live_lock_is_respected_until_lease_expiry() {
  local now tok sleeper
  sp_libs
  nd_state_init
  sleep 30 & sleeper=$!
  now="$(date +%s)"
  ln -s "nd-lock:$sleeper:boot-a:$now:live" "$ND_STATE_DIR/lock"
  nd_state_lock >/dev/null 2>"$CASE_DIR/err"; assert_rc 3 $? "a live holder within its lease keeps the lock"
  assert_match "$sleeper" "$(cat "$CASE_DIR/err")" "busy names the holder"
  # Clock rolled back: the holder's acquisition time is in the future. Age
  # cannot be judged, so the lease is not treated as expired.
  rm -f "$ND_STATE_DIR/lock"
  ln -s "nd-lock:$sleeper:boot-a:$((now + 7200)):future" "$ND_STATE_DIR/lock"
  nd_state_lock >/dev/null 2>&1; assert_rc 3 $? "a future acquisition time does not expire the lease"
  rm -f "$ND_STATE_DIR/lock"
  ln -s "nd-lock:$sleeper:boot-a:$((now - 601)):expired" "$ND_STATE_DIR/lock"
  tok="$(nd_state_lock 2>/dev/null)"; assert_rc 0 $? "a lease older than 600 s is reclaimed from a live holder"
  kill "$sleeper" 2>/dev/null; wait "$sleeper" 2>/dev/null
  # The old holder's token no longer holds the lock: it cannot commit.
  printf 'schema\tnice-dns-controller-state/1\nboot_id\tboot-a\nupdated\t1\nstarted\t1\nroute\t-\noutage_since\t-\noutage_restarts\t0\nlast_action\t-\nlast_action_at\t-\nrecovery_at\t-\n' >"$CASE_DIR/n"
  nd_state_commit expired 0 "$CASE_DIR/n" >/dev/null 2>&1; assert_rc 5 $? "a reclaimed holder cannot commit"
  nd_state_unlock expired 2>/dev/null; assert_nonzero $? "a reclaimed holder cannot release the new lock"
  nd_state_lock_held "$tok"; assert_rc 0 $? "the new holder still holds it"
}

t_state_release_only_removes_its_own_lock() {
  local tok
  sp_libs
  nd_state_init
  _ND_LK_NOW="$(date +%s)" _ND_LK_BOOT=boot-a
  ln -s "nd-lock:$$:boot-a:$_ND_LK_NOW:newholder" "$ND_STATE_DIR/lock"
  # A releaser or reaper that read an older value arrives after the lock
  # changed hands: the compare-and-delete must leave the new lock in place.
  _nd_lock_cad "$ND_STATE_DIR" "nd-lock:$$:boot-a:1:oldholder"
  assert_nonzero $? "compare-and-delete of a changed lock fails"
  assert_eq "nd-lock:$$:boot-a:$_ND_LK_NOW:newholder" "$(readlink "$ND_STATE_DIR/lock")" "the new holder's lock is intact"
  _nd_lock_cad "$ND_STATE_DIR" "nd-lock:$$:boot-a:$_ND_LK_NOW:newholder"
  assert_rc 0 $? "compare-and-delete of the observed value succeeds"
  assert_no_path "$ND_STATE_DIR/lock" "and removes it"
  assert_eq "" "$(find "$ND_STATE_DIR" -maxdepth 1 -name 'lock.*')" "no temporary lock names are left behind"
  tok="$(nd_state_lock)"; nd_state_unlock "$tok"; assert_rc 0 $? "unlock through compare-and-delete"
  assert_no_path "$ND_STATE_DIR/lock" "unlock removed it"
}

t_state_crash_mid_commit_keeps_last_generation() {
  local tok gen
  sp_libs
  nd_state_init
  tok="$(nd_state_lock)"
  printf 'schema\tnice-dns-controller-state/1\nboot_id\tboot-a\nupdated\t1\nstarted\t1\nroute\tcloudflare-exit\noutage_since\t-\noutage_restarts\t0\nlast_action\t-\nlast_action_at\t-\nrecovery_at\t-\n' >"$CASE_DIR/n"
  nd_state_commit "$tok" 0 "$CASE_DIR/n" >/dev/null || fail "commit"
  # A writer killed before its rename leaves a partial temporary file.
  printf 'schema\tnice-dns-controller-state/1\ngeneration\t2\nroute\tquad9' >"$ND_STATE_DIR/.state.tsv.tmp.4242"
  assert_match '^generation	1$' "$(nd_state_load)" "the partial write is invisible"
  assert_match '^route	cloudflare-exit$' "$(nd_state_load)" "the last committed route stands"
  gen="$(nd_state_commit "$tok" 1 "$CASE_DIR/n")"; assert_rc 0 $? "the next commit succeeds"
  assert_eq 2 "$gen" "and continues from the committed generation"
  assert_no_path "$ND_STATE_DIR/.state.tsv.tmp.4242" "the lock holder clears abandoned temporary files"
  nd_state_unlock "$tok"
}

t_state_bridge_staging_does_not_hold_the_lock() {
  local tok rc
  sp_libs
  nd_state_init
  ( nd_state_stage bridges sh -c 'sleep 3; printf "bridge obfs4 a\n"' ) >"$CASE_DIR/stage.out" 2>&1 &
  sleep 1
  tok="$(nd_state_lock)"; rc=$?
  assert_rc 0 "$rc" "the lock is free while a slow staging command runs"
  nd_state_unlock "$tok"
  wait $!; assert_rc 0 $? "staging completes"
  assert_file "$ND_STATE_DIR/staged/bridges" "staged output is published"
  assert_eq 'bridge obfs4 a' "$(cat "$ND_STATE_DIR/staged/bridges")" "staged content"
  ( nd_state_stage bridges sh -c 'printf partial; exit 7' ) >/dev/null 2>&1; assert_rc 7 $? "a failed staging command returns its status"
  assert_eq 'bridge obfs4 a' "$(cat "$ND_STATE_DIR/staged/bridges")" "a failed staging keeps the last good output"
}

# ───────────────────────────── policy ────────────────────────────────────────

t_policy_is_pure() {
  local out
  sp_libs
  sp_obs "$CASE_DIR/o" healthy healthy healthy healthy healthy
  mkdir -p "$CASE_DIR/cwd"
  out="$(cd "$CASE_DIR/cwd" && PATH=/nonexistent nd_policy_decide "$CASE_DIR/o" /dev/null "$SP_T0" boot-a 2>&1)"
  assert_rc 0 $? "decides with no external command available"
  assert_match '^action	' "$out" "and prints a decision"
  assert_eq "" "$(ls -A "$CASE_DIR/cwd")" "no file was written"
  assert_no_path "$ND_STATE_DIR" "no state directory was created"
}

t_policy_startup_picks_a_healthy_exit_while_onion_is_cold() {
  sp_libs
  sp_obs "$CASE_DIR/o" healthy unhealthy healthy healthy healthy
  sp_decide "$CASE_DIR/o" - "$SP_T0"
  assert_eq switch-route "$SP_ACTION" "a first healthy observation selects a route"
  assert_eq cloudflare-exit "$SP_TARGET" "the most preferred healthy exit"
  assert_eq cloudflare-exit "$(sp_key "$CASE_DIR/next" route)" "the next state records it"
  # The onion answers at once, but it is not promoted on one observation.
  sp_obs "$CASE_DIR/o" healthy healthy healthy healthy healthy
  : >"$CASE_DIR/cur"
  sp_decide "$CASE_DIR/o" "$CASE_DIR/cur" "$SP_T0"
  assert_eq cloudflare-exit "$SP_TARGET" "a single healthy onion observation is not sustained"
}

t_policy_promotes_onion_only_after_sustained_streak() {
  local t
  sp_libs
  sp_obs "$CASE_DIR/o" healthy healthy healthy healthy healthy
  : >"$CASE_DIR/cur"
  sp_steps "$CASE_DIR/o" "$SP_T0"
  assert_eq cloudflare-exit "$(sp_key "$CASE_DIR/cur" route)" "starts on the exit"
  for t in 1 2 3; do
    sp_steps "$CASE_DIR/o" $((SP_T0 + 60 * t))
    assert_eq no-op "$SP_ACTION" "observation $((t + 1)) of 5 does not promote"
  done
  sp_steps "$CASE_DIR/o" $((SP_T0 + 240))
  assert_eq switch-route "$SP_ACTION" "the fifth consecutive healthy observation promotes"
  assert_eq cloudflare-onion "$SP_TARGET" "to the onion"
  sp_steps "$CASE_DIR/o" $((SP_T0 + 300))
  assert_eq no-op "$SP_ACTION" "a selected route stays selected"
}

t_policy_demotes_after_failure_streak_without_restart() {
  local t
  sp_libs
  printf 'schema\tnice-dns-controller-state/1\nboot_id\tboot-a\nupdated\t%s\nstarted\t%s\nroute\tcloudflare-onion\noutage_since\t-\noutage_restarts\t0\nlast_action\t-\nlast_action_at\t-\nrecovery_at\t-\nstreak\tcloudflare-onion\t9\t0\t0\n' \
    "$SP_T0" $((SP_T0 - 3600)) >"$CASE_DIR/cur"
  sp_obs "$CASE_DIR/o" healthy unhealthy healthy unhealthy healthy
  sp_steps "$CASE_DIR/o" $((SP_T0 + 60))
  assert_eq no-op "$SP_ACTION" "one failed onion observation does not demote"
  sp_steps "$CASE_DIR/o" $((SP_T0 + 120))
  assert_eq switch-route "$SP_ACTION" "the second consecutive failure demotes"
  assert_eq cloudflare-exit "$SP_TARGET" "to the best healthy identity route"
  # The onion stays down for far longer than the outage grace: a working
  # exit route means Tor works, so it is never restarted.
  for t in 3 5 10 20 40; do
    sp_steps "$CASE_DIR/o" $((SP_T0 + 60 * t))
    assert_ne restart-component "$SP_ACTION" "no Tor restart while an exit works (minute $t)"
  done
}

t_policy_unobserved_current_route_is_left_for_a_healthy_one() {
  local t
  sp_libs
  # The onion is selected and sustained, then its probe only times out
  # (indeterminate) while the exit answers every time.
  printf 'schema\tnice-dns-controller-state/1\nboot_id\tboot-a\nupdated\t%s\nstarted\t%s\nroute\tcloudflare-onion\noutage_since\t-\noutage_restarts\t0\nlast_action\t-\nlast_action_at\t-\nrecovery_at\t-\nstreak\tcloudflare-onion\t9\t0\t0\n' \
    "$SP_T0" $((SP_T0 - 3600)) >"$CASE_DIR/cur"
  sp_obs "$CASE_DIR/o" healthy indeterminate healthy healthy healthy
  for t in 1 2 3 4; do
    sp_steps "$CASE_DIR/o" $((SP_T0 + 60 * t))
    assert_eq no-op "$SP_ACTION" "unknown for $t observations: the selection holds"
  done
  sp_steps "$CASE_DIR/o" $((SP_T0 + 300))
  assert_eq switch-route "$SP_ACTION" "five observations without evidence give the route up"
  assert_eq cloudflare-exit "$SP_TARGET" "for the route that answers"
  sp_steps "$CASE_DIR/o" $((SP_T0 + 360))
  assert_eq no-op "$SP_ACTION" "the old healthy streak does not promote an unobserved onion back"
  assert_eq cloudflare-exit "$(sp_key "$CASE_DIR/cur" route)" "the exit stays"
}

t_policy_old_streak_is_not_current_evidence() {
  sp_libs
  # quad9 was healthy long ago (ok 9) and is unknown now; the exit is current.
  printf 'schema\tnice-dns-controller-state/1\nboot_id\tboot-a\nupdated\t%s\nstarted\t1\nroute\tquad9-exit\noutage_since\t-\noutage_restarts\t0\nlast_action\t-\nlast_action_at\t-\nrecovery_at\t-\nstreak\tcloudflare-onion\t0\t0\t9\nstreak\tcloudflare-exit\t0\t0\t0\nstreak\tquad9-exit\t9\t0\t9\n' "$SP_T0" >"$CASE_DIR/cur"
  sp_obs "$CASE_DIR/o" healthy indeterminate healthy indeterminate healthy
  sp_decide "$CASE_DIR/o" "$CASE_DIR/cur" $((SP_T0 + 60))
  assert_eq switch-route "$SP_ACTION" "an unobserved current route with an old streak is left"
  assert_ne quad9-exit "$SP_TARGET" "and is not chosen again"
  printf 'schema\tsomething-else/9\nroute\tquad9-exit\n' >"$CASE_DIR/bad-state"
  nd_policy_decide "$CASE_DIR/o" "$CASE_DIR/bad-state" "$SP_T0" boot-a >/dev/null 2>&1
  assert_rc 2 $? "a state file without the state schema is refused"
}

t_policy_never_selects_the_compat_route() {
  local t
  sp_libs
  sp_obs "$CASE_DIR/o" healthy unhealthy unhealthy unhealthy healthy
  : >"$CASE_DIR/cur"
  for t in 0 1 2 5 10 20; do
    sp_steps "$CASE_DIR/o" $((SP_T0 + 600 + 60 * t))
    assert_ne cloudflare-legacy "$SP_TARGET" "compat is never a target (DEC-005)"
    assert_ne switch-route "$SP_ACTION" "nothing to switch to"
    assert_ne restart-component "$SP_ACTION" "an answering compat route shows Tor works"
  done
  printf 'schema\tnice-dns-controller-state/1\nboot_id\tboot-a\nupdated\t%s\nstarted\t1\nroute\tcloudflare-legacy\noutage_since\t-\noutage_restarts\t0\nlast_action\t-\nlast_action_at\t-\nrecovery_at\t-\n' "$SP_T0" >"$CASE_DIR/cur"
  sp_obs "$CASE_DIR/o" healthy unhealthy healthy unhealthy healthy
  sp_decide "$CASE_DIR/o" "$CASE_DIR/cur" $((SP_T0 + 60))
  assert_eq switch-route "$SP_ACTION" "a stack left on compat moves to an identity route"
  assert_eq cloudflare-exit "$SP_TARGET" "the healthy identity route"
}

t_policy_unknown_observations_are_never_health() {
  local t
  sp_libs
  sp_obs "$CASE_DIR/o" healthy indeterminate indeterminate indeterminate indeterminate
  : >"$CASE_DIR/cur"
  for t in 0 5 10 20; do
    sp_steps "$CASE_DIR/o" $((SP_T0 + 600 + 60 * t))
    assert_eq no-op "$SP_ACTION" "indeterminate routes: nothing selected, nothing restarted (minute $t)"
  done
  assert_eq - "$(sp_key "$CASE_DIR/cur" route)" "no route was selected from unknowns"
  assert_eq - "$(sp_key "$CASE_DIR/cur" outage_since)" "unknown is not an outage either"
  sp_obs "$CASE_DIR/o" healthy - - - -
  sp_steps "$CASE_DIR/o" $((SP_T0 + 3000))
  assert_eq no-op "$SP_ACTION" "missing route records select nothing"
  assert_eq - "$(sp_key "$CASE_DIR/cur" route)" "missing records are not health"
  # An outage clock from earlier passes plus a pass that observed nothing:
  # the clock is held, and nothing acts on it.
  printf 'schema\tnice-dns-controller-state/1\nboot_id\tboot-a\nupdated\t%s\nstarted\t%s\nroute\tcloudflare-exit\noutage_since\t%s\noutage_restarts\t0\nlast_action\t-\nlast_action_at\t-\nrecovery_at\t-\n' \
    $((SP_T0 + 3000)) $((SP_T0 - 7200)) $((SP_T0 + 2000)) >"$CASE_DIR/held"
  sp_obs "$CASE_DIR/o" healthy indeterminate indeterminate indeterminate indeterminate
  sp_decide "$CASE_DIR/o" "$CASE_DIR/held" $((SP_T0 + 3060))
  assert_eq no-op "$SP_ACTION" "an old outage clock and an all-unknown pass restart nothing"
  assert_eq $((SP_T0 + 2000)) "$(sp_key "$CASE_DIR/next" outage_since)" "the clock is held"
  printf 'garbage\n' >"$CASE_DIR/bad"
  sp_decide "$CASE_DIR/bad" "$CASE_DIR/cur" $((SP_T0 + 3060))
  assert_eq escalate "$SP_ACTION" "unreadable observations escalate"
  printf 'schema\tnice-dns-observations/1\nobs\troute:cloudflare-exit\tgreat\t1\tx\n' >"$CASE_DIR/bad"
  sp_decide "$CASE_DIR/bad" "$CASE_DIR/cur" $((SP_T0 + 3060))
  assert_eq escalate "$SP_ACTION" "an unknown observation state escalates"
}

t_policy_full_outage_waits_grace_then_restarts_tor_once_per_cooldown() {
  local t
  sp_libs
  printf 'schema\tnice-dns-controller-state/1\nboot_id\tboot-a\nupdated\t%s\nstarted\t%s\nroute\tcloudflare-onion\noutage_since\t-\noutage_restarts\t0\nlast_action\t-\nlast_action_at\t-\nrecovery_at\t-\n' \
    "$SP_T0" $((SP_T0 - 3600)) >"$CASE_DIR/cur"
  sp_obs "$CASE_DIR/o" healthy unhealthy unhealthy unhealthy unhealthy
  for t in 1 2 3 4 5; do
    sp_steps "$CASE_DIR/o" $((SP_T0 + 60 * t))
    assert_eq no-op "$SP_ACTION" "minute $t of the outage is inside the 5-minute grace"
  done
  assert_eq $((SP_T0 + 60)) "$(sp_key "$CASE_DIR/cur" outage_since)" "the outage clock starts at the first failed observation"
  sp_steps "$CASE_DIR/o" $((SP_T0 + 360))
  assert_eq restart-component "$SP_ACTION" "sustained 5-minute full outage restarts"
  assert_eq tor "$SP_TARGET" "the Tor component"
  for t in 7 8 9 10; do
    sp_steps "$CASE_DIR/o" $((SP_T0 + 60 * t))
    assert_eq no-op "$SP_ACTION" "minute $t is inside the 5-minute cooldown"
  done
  # The ladder's next step waits out the first restart's readiness window
  # (ND_POLICY_LADDER_S, 660: 600 s from the acknowledgement plus a minute
  # for it), not only the cooldown: a proxy restart 300 s in would land on a
  # Tor still bootstrapping (close-out evaluator M1; the receipt's service
  # fallback became ready 433 s after its acknowledgement).
  for t in 11 12 13 14 15 16; do
    sp_steps "$CASE_DIR/o" $((SP_T0 + 60 * t))
    assert_eq no-op "$SP_ACTION" "minute $t is inside the first restart's readiness window"
  done
  assert_match 'readiness window' "$SP_REASON" "the hold says it waits for the first restart's readiness"
  sp_steps "$CASE_DIR/o" $((SP_T0 + 1020))
  assert_eq restart-component "$SP_ACTION" "after the readiness window a second restart is allowed"
  # Live (Sub-plan 3 Task 2.3, mac runtime wedge): two acknowledged in-image
  # restarts never helped a fault outside Tor. The second restart of one
  # outage is the service restart, which recreates the proxy (macOS: the
  # whole stack, which also repairs a wedged datapath).
  assert_eq proxy "$SP_TARGET" "the second restart of one outage restarts the proxy service"
  sp_steps "$CASE_DIR/o" $((SP_T0 + 1320))
  assert_eq escalate "$SP_ACTION" "restarts that do not recover escalate instead of looping"
  assert_match 'after 2 restarts \(tor, then proxy\)' "$SP_REASON" "the reason names the ladder's restarts, not two Tor restarts"
  # Recovery clears the outage and its restart count.
  sp_obs "$CASE_DIR/o" healthy unhealthy healthy unhealthy unhealthy
  sp_steps "$CASE_DIR/o" $((SP_T0 + 1380))
  assert_eq - "$(sp_key "$CASE_DIR/cur" outage_since)" "a healthy route clears the outage"
  assert_eq 0 "$(sp_key "$CASE_DIR/cur" outage_restarts)" "and its restart count"
}

t_policy_startup_allowance_blocks_restart() {
  local t
  sp_libs
  sp_obs "$CASE_DIR/o" healthy unhealthy unhealthy unhealthy unhealthy
  : >"$CASE_DIR/cur"
  # Boot at SP_T0; the outage is visible from the first check.
  for t in 0 1 2 3 4 5 6; do
    sp_steps "$CASE_DIR/o" $((SP_T0 + 60 * t))
    assert_eq no-op "$SP_ACTION" "minute $t after start: allowance and grace hold"
  done
  sp_steps "$CASE_DIR/o" $((SP_T0 + 60 * 7))
  assert_eq restart-component "$SP_ACTION" "the outage outlasts the allowance plus the grace"
}

t_policy_reboot_resets_timers_and_cooldown() {
  sp_libs
  printf 'schema\tnice-dns-controller-state/1\nboot_id\tboot-a\nupdated\t%s\nstarted\t1\nroute\tcloudflare-onion\noutage_since\t%s\noutage_restarts\t1\nlast_action\trestart-component\nlast_action_at\t%s\nrecovery_at\t%s\nstreak\tcloudflare-onion\t0\t8\t0\n' \
    "$SP_T0" $((SP_T0 - 3600)) "$SP_T0" "$SP_T0" >"$CASE_DIR/cur"
  sp_obs "$CASE_DIR/o" healthy unhealthy unhealthy unhealthy unhealthy
  sp_decide "$CASE_DIR/o" "$CASE_DIR/cur" $((SP_T0 + 60)) boot-b
  assert_eq no-op "$SP_ACTION" "an outage clock from the previous boot does not carry over"
  assert_eq boot-b "$(sp_key "$CASE_DIR/next" boot_id)" "the new boot is recorded"
  assert_eq $((SP_T0 + 60)) "$(sp_key "$CASE_DIR/next" started)" "startup allowance restarts"
  assert_eq $((SP_T0 + 60)) "$(sp_key "$CASE_DIR/next" outage_since)" "the outage clock restarts"
  assert_eq 0 "$(sp_key "$CASE_DIR/next" outage_restarts)" "restart count is per boot"
  assert_eq 0/1 "$(sp_streak "$CASE_DIR/next" cloudflare-onion)" "streaks restart"
  # Sub-plan 5 Task 1.3 (ARCH-04): a boot means cold circuits, so a selected
  # onion is dropped (was: "the last route stays in place"); with no route
  # healthy nothing is selected yet.
  assert_eq - "$(sp_key "$CASE_DIR/next" route)" "a boot drops the onion"
}

t_policy_clock_rollback_restarts_timers() {
  sp_libs
  printf 'schema\tnice-dns-controller-state/1\nboot_id\tboot-a\nupdated\t%s\nstarted\t1\nroute\tcloudflare-onion\noutage_since\t%s\noutage_restarts\t0\nlast_action\t-\nlast_action_at\t-\nrecovery_at\t%s\n' \
    $((SP_T0 + 86400)) $((SP_T0 + 80000)) $((SP_T0 + 86000)) >"$CASE_DIR/cur"
  sp_obs "$CASE_DIR/o" healthy unhealthy unhealthy unhealthy unhealthy
  # The wall clock moved back a day: every stored duration is meaningless.
  sp_decide "$CASE_DIR/o" "$CASE_DIR/cur" "$SP_T0"
  assert_eq no-op "$SP_ACTION" "no restart on a negative or huge elapsed time"
  assert_eq "$SP_T0" "$(sp_key "$CASE_DIR/next" outage_since)" "the outage clock restarts now"
  assert_eq "$SP_T0" "$(sp_key "$CASE_DIR/next" started)" "the allowance restarts now"
  assert_eq "$SP_T0" "$(sp_key "$CASE_DIR/next" recovery_at)" "the cooldown restarts now, never shortens"
  assert_match 'clock' "$SP_REASON" "the reason says why"
}

t_policy_runtime_faults_are_repaired_only_on_evidence() {
  sp_libs
  printf 'schema\tnice-dns-controller-state/1\nboot_id\tboot-a\nupdated\t%s\nstarted\t%s\nroute\tcloudflare-exit\noutage_since\t-\noutage_restarts\t0\nlast_action\t-\nlast_action_at\t-\nrecovery_at\t-\n' \
    "$SP_T0" $((SP_T0 - 3600)) >"$CASE_DIR/cur"
  sp_obs "$CASE_DIR/o" down indeterminate indeterminate indeterminate indeterminate
  sp_decide "$CASE_DIR/o" "$CASE_DIR/cur" $((SP_T0 + 60))
  assert_eq repair-runtime "$SP_ACTION" "a runtime that does not answer is repaired"
  assert_eq runtime-down "$SP_TARGET" "names the fault"
  sp_obs "$CASE_DIR/o" missing indeterminate indeterminate indeterminate indeterminate
  sp_decide "$CASE_DIR/o" "$CASE_DIR/cur" $((SP_T0 + 60))
  assert_eq repair-runtime "$SP_ACTION" "missing containers are repaired"
  assert_eq containers-missing "$SP_TARGET" "names the fault"
  sp_obs "$CASE_DIR/o" cli indeterminate indeterminate indeterminate indeterminate
  sp_decide "$CASE_DIR/o" "$CASE_DIR/cur" $((SP_T0 + 60))
  assert_eq escalate "$SP_ACTION" "a missing runtime CLI cannot be repaired from here"
  sp_obs "$CASE_DIR/o" indeterminate unhealthy unhealthy unhealthy unhealthy
  sp_decide "$CASE_DIR/o" "$CASE_DIR/cur" $((SP_T0 + 60))
  assert_ne repair-runtime "$SP_ACTION" "an unknown runtime state is no evidence of a runtime fault"
  sp_obs "$CASE_DIR/o" down indeterminate indeterminate indeterminate indeterminate
  sp_decide "$CASE_DIR/o" "$CASE_DIR/cur" $((SP_T0 + 60)) boot-b
  assert_eq no-op "$SP_ACTION" "no runtime repair inside the startup allowance"
  printf 'schema\tnice-dns-controller-state/1\nboot_id\tboot-a\nupdated\t%s\nstarted\t%s\nroute\tcloudflare-exit\noutage_since\t-\noutage_restarts\t0\nlast_action\trepair-runtime\nlast_action_at\t%s\nrecovery_at\t%s\n' \
    "$SP_T0" $((SP_T0 - 3600)) "$SP_T0" "$SP_T0" >"$CASE_DIR/cur"
  sp_decide "$CASE_DIR/o" "$CASE_DIR/cur" $((SP_T0 + 120))
  assert_eq no-op "$SP_ACTION" "runtime repair respects the recovery cooldown"
}

t_policy_decision_and_next_state_are_valid_data() {
  local rc
  sp_libs
  nd_state_init
  sp_obs "$CASE_DIR/o" healthy healthy healthy unhealthy healthy
  sp_decide "$CASE_DIR/o" - "$SP_T0"
  assert_match '^schema	nice-dns-decision/1$' "$SP_OUT" "decision schema"
  assert_match '^action	(no-op|switch-route|refresh-bridges|restart-component|repair-runtime|escalate)$' "$SP_OUT" "action enum"
  assert_eq 1 "$(printf '%s\n' "$SP_OUT" | grep -c '^action	')" "exactly one action"
  assert_not_match "$(printf '\r')" "$SP_OUT" "no carriage returns"
  tok="$(nd_state_lock)"
  nd_state_commit "$tok" 0 "$CASE_DIR/next" >/dev/null 2>"$CASE_DIR/err"; rc=$?
  assert_rc 0 "$rc" "the policy's next state is accepted by commit: $(cat "$CASE_DIR/err")"
  nd_state_unlock "$tok"
  assert_eq 1/0 "$(nd_state_load | awk -F '\t' '$1 == "streak" && $2 == "cloudflare-exit" { print $3 "/" $4 }')" "streaks survive the round trip"
}

t_bash32_runs_state_and_policy() {
  local w="$CASE_DIR/b32" img=docker.io/library/bash:3.2 out
  if ! podman image exists "$img" 2>/dev/null; then
    fail "image $img is not available locally; the Bash 3.2 proof cannot run (pull it: podman pull $img)"
  fi
  mkdir -p "$w"
  sp_obs "$w/o" healthy unhealthy unhealthy unhealthy unhealthy
  cat >"$w/inner.sh" <<'INNER'
set -uo pipefail
case "$BASH_VERSION" in 3.2.*) ;; *) echo "not bash 3.2: $BASH_VERSION"; exit 90 ;; esac
ND_STATE_DIR=/tmp/st ND_BOOT_ID=b32 ND_PLATFORM=linux ND_ROUTES_FILE=/src/routes/providers.tsv
export ND_STATE_DIR ND_BOOT_ID ND_PLATFORM ND_ROUTES_FILE
. /src/lib/state.sh && . /src/lib/policy.sh || { echo source-failed; exit 91; }
nd_state_init; echo "init=$?"
: >/tmp/empty
t=1760000000 i=0
cp /tmp/empty /tmp/cur
while [ $i -le 7 ]; do
  nd_policy_decide /work/o /tmp/cur $((t + 60 * i)) b32 >/tmp/out || { echo "decide-rc=$?"; exit 92; }
  awk '$0 == "schema\tnice-dns-controller-state/1" { s = 1 } s' /tmp/out >/tmp/cur
  i=$((i + 1))
done
awk -F '\t' '$1 == "action" { print "last-action=" $2 }' /tmp/out
tok="$(nd_state_lock)"; echo "lock=$?"
( nd_state_lock >/dev/null 2>&1; echo "second-lock=$?" )
nd_state_commit "$tok" 0 /tmp/cur; echo "commit=$?"
nd_state_unlock "$tok"; echo "unlock=$?"
nd_state_load | awk -F '\t' '$1 == "generation" || $1 == "last_action" { print $1 "=" $2 }'
INNER
  out="$(podman run --rm --network none --pull=never -v "$NICE_DNS_ROOT:/src:ro" -v "$w:/work" "$img" bash /work/inner.sh 2>&1)"
  assert_rc 0 $? "bash 3.2 run: $out"
  assert_match '^init=0$' "$out" "init under bash 3.2"
  assert_match '^last-action=restart-component$' "$out" "the outage sequence under bash 3.2"
  assert_match '^lock=0$' "$out" "lock under bash 3.2"
  assert_match '^second-lock=3$' "$out" "a second actor is refused under bash 3.2"
  assert_match '^commit=0$' "$out" "commit under bash 3.2"
  assert_match '^generation=1$' "$out" "generation under bash 3.2"
  assert_match '^last_action=restart-component$' "$out" "state round trip under bash 3.2"
}

t_policy_escalates_a_runtime_fault_the_platform_cannot_repair() {
  # Pre-merge review, Important: rootless Podman has no runtime-down repair
  # (lib/platform/linux.sh), so on Linux the controller re-issued an
  # "unsupported" repair every cooldown for ever and never escalated.
  # ND_POLICY_RUNTIME_REPAIRS (set by the tick from the platform adapter)
  # names the faults this platform can repair; any other escalates at once.
  sp_libs
  printf 'schema\tnice-dns-controller-state/1\nboot_id\tboot-a\nupdated\t%s\nstarted\t%s\nroute\tcloudflare-exit\noutage_since\t-\noutage_restarts\t0\nlast_action\t-\nlast_action_at\t-\nrecovery_at\t-\n' \
    "$SP_T0" $((SP_T0 - 3600)) >"$CASE_DIR/cur"
  sp_obs "$CASE_DIR/o" down indeterminate indeterminate indeterminate indeterminate
  ND_POLICY_RUNTIME_REPAIRS=containers-missing sp_decide "$CASE_DIR/o" "$CASE_DIR/cur" $((SP_T0 + 60))
  assert_eq escalate "$SP_ACTION" "runtime-down with no repair on this platform escalates"
  assert_match 'no repair' "$SP_REASON" "and says there is no repair here"
  sp_obs "$CASE_DIR/o" missing indeterminate indeterminate indeterminate indeterminate
  ND_POLICY_RUNTIME_REPAIRS=containers-missing sp_decide "$CASE_DIR/o" "$CASE_DIR/cur" $((SP_T0 + 60))
  assert_eq repair-runtime "$SP_ACTION" "a fault the platform can repair is still repaired"
  ( . "$NICE_DNS_ROOT/lib/platform/linux.sh"
    assert_eq "containers-missing containers-paused" "$(nd_platform_runtime_repairs)" "linux: missing and paused containers are repairable, the runtime is not" ) || exit 1
  ( . "$NICE_DNS_ROOT/lib/platform/macos.sh"
    assert_eq "runtime-down containers-missing" "$(nd_platform_runtime_repairs)" "macos: both faults are repairable" ) || exit 1
}

# ───────── a fresh proxy (Sub-plan 5 Task 1.3; ARCH-04 startup rule) ─────────
# After the proxy restarts (its generation changes) or the host boots, Tor's
# circuits are cold: a selected onion gives way to the preferred healthy
# exit, and the onion is promoted again only once sustained.

# sp_proxy <obs file> <generation>: adds the proxy observation.
sp_proxy() { printf 'obs\tproxy\thealthy\t4\tgeneration:%s\n' "$2" >>"$1"; }

sp_onion_state() {
  # sp_onion_state <file> <proxy_gen or ->: onion selected and long sustained.
  printf 'schema\tnice-dns-controller-state/1\nboot_id\tboot-a\nupdated\t%s\nstarted\t1\nroute\tcloudflare-onion\noutage_since\t-\noutage_restarts\t0\nlast_action\tswitch-route\nlast_action_at\t%s\nrecovery_at\t-\nstreak\tcloudflare-onion\t40\t0\t0\nstreak\tcloudflare-exit\t40\t0\t0\nstreak\tquad9-exit\t40\t0\t0\n' \
    "$SP_T0" "$SP_T0" >"$1"
  [ "$2" = - ] || printf 'proxy_gen\t%s\n' "$2" >>"$1"
}

t_policy_fresh_proxy_falls_back_to_an_exit() {
  local t
  sp_libs
  sp_onion_state "$CASE_DIR/cur" 0123456789abcdef
  sp_obs "$CASE_DIR/o" healthy healthy healthy healthy healthy
  sp_proxy "$CASE_DIR/o" fedcba9876543210
  sp_decide "$CASE_DIR/o" "$CASE_DIR/cur" $((SP_T0 + 60))
  assert_eq switch-route "$SP_ACTION" "a restarted proxy moves off the onion: $SP_OUT"
  assert_eq cloudflare-exit "$SP_TARGET" "to the preferred healthy exit"
  assert_match 'fresh proxy' "$SP_REASON" "and says why"
  assert_eq fedcba9876543210 "$(sp_key "$CASE_DIR/next" proxy_gen)" "the new generation is recorded"
  assert_eq 1/0 "$(sp_streak "$CASE_DIR/next" cloudflare-onion)" "the onion's streak restarts"
  cp "$CASE_DIR/next" "$CASE_DIR/cur"
  for t in 2 3 4 5; do
    sp_steps "$CASE_DIR/o" $((SP_T0 + 60 * t))
    [ "$t" = 5 ] || assert_eq no-op "$SP_ACTION" "observation $t of 5 does not promote the onion"
  done
  assert_eq switch-route "$SP_ACTION" "the fifth sustained observation promotes it again"
  assert_eq cloudflare-onion "$SP_TARGET" "to the onion"
}

t_policy_same_proxy_keeps_the_onion() {
  sp_libs
  sp_onion_state "$CASE_DIR/cur" 0123456789abcdef
  sp_obs "$CASE_DIR/o" healthy healthy healthy healthy healthy
  sp_proxy "$CASE_DIR/o" 0123456789abcdef
  sp_decide "$CASE_DIR/o" "$CASE_DIR/cur" $((SP_T0 + 60))
  assert_eq no-op "$SP_ACTION" "an unchanged proxy keeps the sustained onion: $SP_OUT"
  assert_eq cloudflare-onion "$(sp_key "$CASE_DIR/next" route)" "route"
  assert_eq 41/0 "$(sp_streak "$CASE_DIR/next" cloudflare-onion)" "streaks continue"
}

t_policy_first_proxy_generation_counts_as_fresh() {
  # A state from before this rule has no proxy_gen: the first one seen is a
  # fresh proxy (installs recreate the proxy), which costs one promotion wait.
  sp_libs
  sp_onion_state "$CASE_DIR/cur" -
  sp_obs "$CASE_DIR/o" healthy healthy healthy healthy healthy
  sp_proxy "$CASE_DIR/o" 0123456789abcdef
  sp_decide "$CASE_DIR/o" "$CASE_DIR/cur" $((SP_T0 + 60))
  assert_eq cloudflare-exit "$SP_TARGET" "first generation seen: back to the exit: $SP_OUT"
}

t_policy_without_a_proxy_observation_nothing_is_fresh() {
  sp_libs
  sp_onion_state "$CASE_DIR/cur" 0123456789abcdef
  sp_obs "$CASE_DIR/o" healthy healthy healthy healthy healthy
  sp_decide "$CASE_DIR/o" "$CASE_DIR/cur" $((SP_T0 + 60))
  assert_eq no-op "$SP_ACTION" "no proxy record is no evidence of a restart: $SP_OUT"
  assert_eq 0123456789abcdef "$(sp_key "$CASE_DIR/next" proxy_gen)" "the known generation is kept"
  printf 'obs\tproxy\tindeterminate\t10000\tdeadline: inspect\n' >>"$CASE_DIR/o"
  sp_decide "$CASE_DIR/o" "$CASE_DIR/cur" $((SP_T0 + 60))
  assert_eq no-op "$SP_ACTION" "an indeterminate proxy record is no evidence either"
}

t_policy_fresh_proxy_keeps_an_exit_route() {
  sp_libs
  sp_onion_state "$CASE_DIR/cur" 0123456789abcdef
  sed -i 's/^route\tcloudflare-onion$/route\tquad9-exit/' "$CASE_DIR/cur"
  sp_obs "$CASE_DIR/o" healthy healthy healthy healthy healthy
  sp_proxy "$CASE_DIR/o" fedcba9876543210
  sp_decide "$CASE_DIR/o" "$CASE_DIR/cur" $((SP_T0 + 60))
  assert_eq no-op "$SP_ACTION" "an exit route stays through a restart: $SP_OUT"
  assert_eq quad9-exit "$(sp_key "$CASE_DIR/next" route)" "route"
}

t_state_accepts_and_checks_proxy_gen() {
  local d
  sp_libs
  d="$CASE_DIR/state"; nd_state_init || fail "init"
  sp_onion_state "$CASE_DIR/s" 0123456789abcdef
  _nd_state_check "$CASE_DIR/s" 0 2>"$CASE_DIR/err"
  assert_rc 0 "$?" "a 16-hex proxy_gen is valid: $(cat "$CASE_DIR/err")"
  sp_onion_state "$CASE_DIR/s" 'not-hex!'
  _nd_state_check "$CASE_DIR/s" 0 2>"$CASE_DIR/err"
  assert_nonzero "$?" "a malformed proxy_gen is refused"
  assert_match 'proxy_gen' "$(cat "$CASE_DIR/err")" "and named"
  sp_onion_state "$CASE_DIR/s" -
  _nd_state_check "$CASE_DIR/s" 0 2>"$CASE_DIR/err"
  assert_rc 0 "$?" "a state without proxy_gen (older bundles) stays valid"
}

# Tier-1 review (Important): the policy never writes a value into the next
# state that lib/state.sh would refuse, because the tick acts before it
# commits. A malformed generation is no evidence; an overlong boot id or a
# malformed route id refuses the whole decision (exit 2) before any action.
t_policy_never_emits_state_the_validator_refuses() {
  sp_libs
  sp_onion_state "$CASE_DIR/cur" 0123456789abcdef
  sp_obs "$CASE_DIR/o" healthy healthy healthy healthy healthy
  printf 'obs\tproxy\thealthy\t4\tgeneration:a\n' >>"$CASE_DIR/o"
  sp_decide "$CASE_DIR/o" "$CASE_DIR/cur" $((SP_T0 + 60))
  assert_eq no-op "$SP_ACTION" "a malformed generation is no evidence of a restart: $SP_OUT"
  assert_eq 0123456789abcdef "$(sp_key "$CASE_DIR/next" proxy_gen)" "the recorded generation is kept"
  _nd_state_check "$CASE_DIR/next" 0 2>"$CASE_DIR/err"
  assert_rc 0 "$?" "the next state validates: $(cat "$CASE_DIR/err")"
  nd_policy_decide "$CASE_DIR/o" "$CASE_DIR/cur" $((SP_T0 + 60)) "$(printf 'b%.0s' $(seq 1 65))" >/dev/null 2>"$CASE_DIR/err"
  assert_eq 2 "$?" "a boot id longer than state allows is refused: $(cat "$CASE_DIR/err")"
  { cat "$ND_ROUTES_FILE"; printf 'Bad_Route\t18534\tx.example\tx\tidentity\n'; } >"$CASE_DIR/routes.tsv"
  ND_ROUTES_FILE="$CASE_DIR/routes.tsv" nd_policy_decide "$CASE_DIR/o" "$CASE_DIR/cur" $((SP_T0 + 60)) boot-a >/dev/null 2>"$CASE_DIR/err"
  assert_eq 2 "$?" "a route id state would refuse is refused: $(cat "$CASE_DIR/err")"
}

# ─────────────────────────── Unbound's own health ────────────────────────────

# sp_ub <file> <verdict> <reason>: add an unbound record to an observation file.
sp_ub() { printf 'obs\tunbound\t%s\t40\t%s\n' "$2" "$3" >>"$1"; }

# sp_ub_start: routes healthy, a route selected, the startup allowance over;
# $CASE_DIR/cur is the state and SP_NOW the next time. $CASE_DIR/ok holds healthy
# routes with no unbound record.
sp_ub_start() {
  sp_libs
  sp_obs "$CASE_DIR/ok" healthy healthy healthy healthy healthy
  sp_decide "$CASE_DIR/ok" - "$SP_T0"
  cp "$CASE_DIR/next" "$CASE_DIR/cur"
  SP_NOW=$((SP_T0 + 600))
}

# sp_ub_pass <obs>: one pass a minute after the last; SP_ACTION and SP_TARGET.
sp_ub_pass() {
  SP_NOW=$((SP_NOW + 60))
  sp_decide "$1" "$CASE_DIR/cur" "$SP_NOW"
  cp "$CASE_DIR/next" "$CASE_DIR/cur"
}

# sp_missing_run <route verdict> <first> <last> <step>: passes with a container
# missing; one "seconds action target" row per action, in SP_ACTIONS.
sp_missing_run() {
  local v="$1" t="$2" last="$3" step="$4"
  sp_obs "$CASE_DIR/o" "${SP_RT:-missing}" "$v" "$v" "$v" "$v"
  while [ "$t" -le "$last" ]; do
    sp_steps "$CASE_DIR/o" "$t"
    [ "$SP_ACTION" = no-op ] || SP_ACTIONS="$SP_ACTIONS$((t - SP_T0)) $SP_ACTION $SP_TARGET
"
    t=$((t + step))
  done
}

# Live 2026-10-31 (decisions evaluator): the repair reset recovery_at every 300 s,
# so a container that stayed missing never reached the stack restart.
t_a_container_that_stays_missing_reaches_the_stack_restart() {
  local v rows first_stack second_stack n
  sp_libs
  for v in unhealthy healthy; do
    : >"$CASE_DIR/cur"; SP_ACTIONS=""
    sp_missing_run "$v" "$SP_T0" $((SP_T0 + 4200)) 60
    rows="$SP_ACTIONS"
    assert_eq 3 "$(printf '%s' "$rows" | grep -c ' repair-runtime containers-missing$')" "routes $v: three repairs, then no more ($rows)"
    first_stack="$(printf '%s' "$rows" | awk '$2 == "restart-component" && $3 == "stack" { print $1; exit }')"
    second_stack="$(printf '%s' "$rows" | awk '$2 == "restart-component" && $3 == "stack" { n++; if (n == 2) { print $1; exit } }')"
    assert_ne "" "$first_stack" "routes $v: the stack restarts ($rows)"
    assert_eq "$(printf '%s' "$rows" | awk '$2 == "repair-runtime" { l = $1 } END { print l + 300 }')" "$first_stack" "routes $v: one cooldown after the last repair"
    assert_eq 1800 "$((second_stack - first_stack))" "routes $v: then every ND_POLICY_RETRY_S"
    n="$(printf '%s' "$rows" | awk -v a="$first_stack" -v b="$second_stack" '$2 == "escalate" && $1 > a && $1 < b { n++ } END { print n + 0 }')"
    assert_match '^[1-9]' "$n" "routes $v: the passes between escalate"
  done
}

t_a_healthy_runtime_reading_clears_the_repair_count() {
  sp_libs
  : >"$CASE_DIR/cur"; SP_ACTIONS=""
  sp_missing_run unhealthy "$SP_T0" $((SP_T0 + 480)) 60
  assert_eq 2 "$(sp_key "$CASE_DIR/cur" runtime_repairs)" "two repairs counted"
  sp_obs "$CASE_DIR/o" healthy healthy healthy healthy healthy
  sp_steps "$CASE_DIR/o" $((SP_T0 + 540))
  assert_eq "" "$(sp_key "$CASE_DIR/cur" runtime_repairs)" "a healthy reading clears it, and the row goes"
  SP_ACTIONS=""
  sp_missing_run unhealthy $((SP_T0 + 600)) $((SP_T0 + 2400)) 60
  assert_eq 3 "$(printf '%s' "$SP_ACTIONS" | grep -c ' repair-runtime containers-missing$')" "a new fault gets three repairs again ($SP_ACTIONS)"
  sp_obs "$CASE_DIR/o" indeterminate unhealthy unhealthy unhealthy unhealthy
  sp_steps "$CASE_DIR/o" $((SP_T0 + 2460))
  assert_eq 4 "$(sp_key "$CASE_DIR/cur" runtime_repairs)" "an indeterminate reading holds the count"
}

# A stack restart needs the runtime that is reported down: it keeps its repair.
t_runtime_down_keeps_its_repair_past_the_limit() {
  sp_libs
  : >"$CASE_DIR/cur"; SP_ACTIONS=""
  SP_RT=down sp_missing_run unhealthy "$SP_T0" $((SP_T0 + 2400)) 60
  assert_eq "" "$(printf '%s' "$SP_ACTIONS" | grep ' stack$' || true)" "no stack restart ($SP_ACTIONS)"
  assert_match '^[1-9]' "$(printf '%s' "$SP_ACTIONS" | grep -c ' repair-runtime runtime-down$' | awk '$1 >= 5 { print $1 }')" "the repair goes on"
}

t_the_repair_count_passes_the_state_validator() {
  sp_libs
  : >"$CASE_DIR/cur"; SP_ACTIONS=""
  sp_missing_run unhealthy "$SP_T0" $((SP_T0 + 180)) 60
  assert_eq 1 "$(sp_key "$CASE_DIR/cur" runtime_repairs)" "one repair counted"
  nd_state_init || fail "state init"
  { cat "$CASE_DIR/cur"; printf 'generation\t1\n'; } >"$ND_STATE_DIR/state.tsv"
  assert_match '^runtime_repairs	1$' "$(nd_state_load | grep '^runtime_repairs')" "lib/state.sh loads the row"
  printf 'runtime_repairs\tx\n' >>"$ND_STATE_DIR/state.tsv"
  nd_state_load >/dev/null 2>&1
  assert_nonzero "$?" "and refuses one that is not a number"
}

t_unbound_failing_with_routes_healthy_restarts_it_on_the_third_pass() {
  local r i
  for r in 'control: exit 1: connection refused' 'route: probe-route exit 1'; do
    sp_ub_start
    cp "$CASE_DIR/ok" "$CASE_DIR/bad"; sp_ub "$CASE_DIR/bad" unhealthy "$r"
    sp_ub_pass "$CASE_DIR/bad"; assert_eq no-op "$SP_ACTION" "$r: first failure"
    sp_ub_pass "$CASE_DIR/bad"; assert_eq no-op "$SP_ACTION" "$r: second failure"
    sp_ub_pass "$CASE_DIR/bad"
    assert_eq restart-component "$SP_ACTION" "$r: third failure in a row"
    assert_eq unbound "$SP_TARGET" "$r: the target is Unbound"
    assert_match 'nbound' "$SP_REASON" "$r: the reason names Unbound"
    assert_eq 1 "$(sp_key "$CASE_DIR/cur" unbound_restarts)" "$r: the restart is counted"
    assert_eq "$SP_NOW" "$(sp_key "$CASE_DIR/cur" recovery_at)" "$r: it starts the cooldown"
    assert_eq 0 "$(sp_key "$CASE_DIR/cur" outage_restarts)" "$r: the Tor ladder is not charged"
  done
}

t_unbound_route_failure_in_a_full_outage_never_restarts_it() {
  local i seen=0
  sp_ub_start
  sp_obs "$CASE_DIR/out" healthy unhealthy unhealthy unhealthy unhealthy
  sp_ub "$CASE_DIR/out" unhealthy 'route: probe-route exit 1'
  for i in 1 2 3 4 5 6 7 8 9 10 11 12; do
    sp_ub_pass "$CASE_DIR/out"
    [ "$SP_TARGET" = unbound ] && seen=1
  done
  assert_eq 0 "$seen" "the probe is telling the truth about the outage: Unbound is left alone"
  assert_eq "" "$(sp_key "$CASE_DIR/cur" unbound_fail)" "and it is not counted against Unbound"
  assert_ne 0 "$(sp_key "$CASE_DIR/cur" outage_restarts)" "the Tor ladder ran"
}

t_unbound_control_failure_in_a_full_outage_restarts_it() {
  sp_ub_start
  sp_obs "$CASE_DIR/out" healthy unhealthy unhealthy unhealthy unhealthy
  sp_ub "$CASE_DIR/out" unhealthy 'control: no answer'
  sp_ub_pass "$CASE_DIR/out"; sp_ub_pass "$CASE_DIR/out"; sp_ub_pass "$CASE_DIR/out"
  assert_eq restart-component "$SP_ACTION" "a dead control socket is Unbound's own fault"
  assert_eq unbound "$SP_TARGET" "even during a Tor outage"
}

t_unbound_startup_and_cooldown_hold_the_restart() {
  sp_libs
  sp_obs "$CASE_DIR/ok" healthy healthy healthy healthy healthy
  cp "$CASE_DIR/ok" "$CASE_DIR/bad"; sp_ub "$CASE_DIR/bad" unhealthy 'control: exit 1'
  sp_decide "$CASE_DIR/ok" - "$SP_T0"; cp "$CASE_DIR/next" "$CASE_DIR/cur"
  sp_steps "$CASE_DIR/bad" $((SP_T0 + 10)) $((SP_T0 + 20)) $((SP_T0 + 30)) $((SP_T0 + 40))
  assert_ne unbound "$SP_TARGET" "inside the startup allowance"
  sp_steps "$CASE_DIR/bad" $((SP_T0 + 130))
  assert_eq unbound "$SP_TARGET" "the allowance over, the streak acts"
  sp_steps "$CASE_DIR/bad" $((SP_T0 + 190)) $((SP_T0 + 250)) $((SP_T0 + 310)) $((SP_T0 + 370))
  assert_ne unbound "$SP_TARGET" "inside the cooldown (300 s from the restart)"
  sp_steps "$CASE_DIR/bad" $((SP_T0 + 430))
  assert_eq unbound "$SP_TARGET" "the cooldown over, a second restart"
  assert_eq 2 "$(sp_key "$CASE_DIR/cur" unbound_restarts)" "two restarts"
}

t_unbound_retries_every_half_hour_after_two_restarts() {
  local i last
  sp_ub_start
  cp "$CASE_DIR/ok" "$CASE_DIR/bad"; sp_ub "$CASE_DIR/bad" unhealthy 'control: exit 1'
  # Two restarts, each after three failures and the cooldown.
  for i in 1 2 3 4 5 6 7 8; do sp_ub_pass "$CASE_DIR/bad"; done
  assert_eq 2 "$(sp_key "$CASE_DIR/cur" unbound_restarts)" "two restarts first"
  last="$(sp_key "$CASE_DIR/cur" recovery_at)"
  i=0
  while [ "$(sp_key "$CASE_DIR/cur" unbound_restarts)" = 2 ] && [ "$i" -lt 60 ]; do
    sp_ub_pass "$CASE_DIR/bad"; i=$((i + 1))
    if [ "$SP_NOW" -lt $((last + 1800)) ]; then
      assert_ne unbound "$SP_TARGET" "no restart before the retry interval ($((SP_NOW - last)) s)"
      # Once the streak is met again, a pass held back by the interval says so.
      if [ "$(sp_key "$CASE_DIR/cur" unbound_fail)" -ge 3 ]; then
        assert_match 'Unbound failed' "$SP_REASON" "a waiting pass says so: it never stops silently"
      fi
    fi
  done
  assert_eq 3 "$(sp_key "$CASE_DIR/cur" unbound_restarts)" "a third restart at the retry interval"
  assert_eq 1 "$(( $(sp_key "$CASE_DIR/cur" recovery_at) - last >= 1800 ))" "no sooner than 1800 s after the second"
  last="$(sp_key "$CASE_DIR/cur" recovery_at)"
  i=0
  while [ "$(sp_key "$CASE_DIR/cur" unbound_restarts)" = 3 ] && [ "$i" -lt 60 ]; do sp_ub_pass "$CASE_DIR/bad"; i=$((i + 1)); done
  assert_eq 4 "$(sp_key "$CASE_DIR/cur" unbound_restarts)" "and again"
  assert_eq 1 "$(( $(sp_key "$CASE_DIR/cur" recovery_at) - last >= 1800 ))" "at the same interval"
}

t_unbound_healthy_reading_clears_both_counters_and_indeterminate_holds() {
  sp_ub_start
  cp "$CASE_DIR/ok" "$CASE_DIR/bad"; sp_ub "$CASE_DIR/bad" unhealthy 'control: exit 1'
  cp "$CASE_DIR/ok" "$CASE_DIR/good"; sp_ub "$CASE_DIR/good" healthy 'control and route answer'
  cp "$CASE_DIR/ok" "$CASE_DIR/idk"; sp_ub "$CASE_DIR/idk" indeterminate 'deadline: nothing answered'
  sp_ub_pass "$CASE_DIR/bad"; sp_ub_pass "$CASE_DIR/bad"
  assert_eq 2 "$(sp_key "$CASE_DIR/cur" unbound_fail)" "two failures counted"
  sp_ub_pass "$CASE_DIR/idk"
  assert_eq 2 "$(sp_key "$CASE_DIR/cur" unbound_fail)" "indeterminate changes nothing"
  assert_eq no-op "$SP_ACTION" "and acts on nothing"
  sp_ub_pass "$CASE_DIR/ok"
  assert_eq 2 "$(sp_key "$CASE_DIR/cur" unbound_fail)" "an older image with no record changes nothing"
  sp_ub_pass "$CASE_DIR/good"
  assert_eq "" "$(sp_key "$CASE_DIR/cur" unbound_fail)" "a healthy reading clears the streak"
  sp_ub_pass "$CASE_DIR/bad"; sp_ub_pass "$CASE_DIR/bad"; sp_ub_pass "$CASE_DIR/bad"
  assert_eq 1 "$(sp_key "$CASE_DIR/cur" unbound_restarts)" "a restart"
  sp_ub_pass "$CASE_DIR/good"
  assert_eq 1 "$(sp_key "$CASE_DIR/cur" unbound_restarts)" "a healthy reading right after a restart keeps the count: a flap is not a cure"
  SP_NOW=$((SP_NOW + 1800))
  sp_ub_pass "$CASE_DIR/good"
  assert_eq "" "$(sp_key "$CASE_DIR/cur" unbound_restarts)" "healthy a retry interval after the last restart clears it"
}

t_unbound_new_boot_clears_the_counters() {
  sp_ub_start
  cp "$CASE_DIR/ok" "$CASE_DIR/bad"; sp_ub "$CASE_DIR/bad" unhealthy 'control: exit 1'
  sp_ub_pass "$CASE_DIR/bad"; sp_ub_pass "$CASE_DIR/bad"
  sp_decide "$CASE_DIR/ok" "$CASE_DIR/cur" $((SP_NOW + 60)) boot-b
  assert_eq "" "$(sp_key "$CASE_DIR/next" unbound_fail)" "a new boot restarts the streak"
}

t_unbound_state_rows_exist_only_when_non_zero() {
  local tok
  sp_ub_start
  sp_ub_pass "$CASE_DIR/ok"
  assert_eq 0 "$(grep -c '^runtime_repairs' "$CASE_DIR/cur")" "nor a zero repair count"
  assert_eq 0 "$(grep -c '^unbound_' "$CASE_DIR/cur")" "a zero-counter state has no new rows (BL-036: a rollback refuses rows it does not know)"
  cp "$CASE_DIR/ok" "$CASE_DIR/bad"; sp_ub "$CASE_DIR/bad" unhealthy 'control: exit 1'
  sp_ub_pass "$CASE_DIR/bad"
  assert_eq 1 "$(sp_key "$CASE_DIR/cur" unbound_fail)" "a non-zero counter is written"
  nd_state_init || fail "init"
  tok="$(nd_state_lock)" || fail "lock"
  nd_state_commit "$tok" 0 "$CASE_DIR/cur" >/dev/null; assert_rc 0 $? "lib/state.sh accepts the new rows"
  assert_eq 1 "$(nd_state_load | awk -F '\t' '$1 == "unbound_fail" { print $2 }')" "and loads them back"
  printf 'unbound_fail\tnope\n' >>"$CASE_DIR/cur"
  nd_state_commit "$tok" 1 "$CASE_DIR/cur" >/dev/null 2>&1; assert_rc 2 $? "a bad value is refused"
  nd_state_unlock "$tok"
}

# ─────────────────────────── past the restart cap ────────────────────────────

t_full_outage_past_the_cap_restarts_the_stack_every_half_hour() {
  local i last n=0 esc=0
  sp_ub_start
  sp_obs "$CASE_DIR/out" healthy unhealthy unhealthy unhealthy unhealthy
  i=0
  while [ "$(sp_key "$CASE_DIR/cur" outage_restarts)" != 2 ] && [ "$i" -lt 60 ]; do sp_ub_pass "$CASE_DIR/out"; i=$((i + 1)); done
  assert_eq proxy "$SP_TARGET" "the ladder before the cap is unchanged: Tor, then the proxy"
  last="$(sp_key "$CASE_DIR/cur" recovery_at)"
  i=0
  while [ "$SP_TARGET" != stack ] && [ "$i" -lt 60 ]; do
    sp_ub_pass "$CASE_DIR/out"; i=$((i + 1))
    [ "$SP_ACTION" = escalate ] && esc=$((esc + 1))
  done
  assert_eq stack "$SP_TARGET" "past the cap, the stack restarts"
  assert_eq restart-component "$SP_ACTION" "as a restart"
  assert_eq 1 "$(( SP_NOW - last >= 1800 ))" "restart 3 lands no sooner than 1800 s after restart 2 ($((SP_NOW - last)) s)"
  assert_eq 1 "$(( esc > 0 ))" "other passes still journal the escalation"
  last="$SP_NOW"
  i=0
  sp_ub_pass "$CASE_DIR/out"
  while [ "$SP_TARGET" != stack ] && [ "$i" -lt 60 ]; do sp_ub_pass "$CASE_DIR/out"; i=$((i + 1)); done
  assert_eq stack "$SP_TARGET" "and again"
  assert_eq 1 "$(( SP_NOW - last >= 1800 && SP_NOW - last <= 1860 ))" "at that interval ($((SP_NOW - last)) s)"
  sp_ub_pass "$CASE_DIR/ok"
  assert_eq 0 "$(sp_key "$CASE_DIR/cur" outage_restarts)" "a healthy route clears the count"
  assert_eq - "$(sp_key "$CASE_DIR/cur" outage_since)" "and the outage"
}

t_unbound_flapping_probe_cannot_defeat_the_restart_cap() {
  local i n=0
  sp_ub_start
  cp "$CASE_DIR/ok" "$CASE_DIR/bad"; sp_ub "$CASE_DIR/bad" unhealthy 'route: probe-route exit 1'
  cp "$CASE_DIR/ok" "$CASE_DIR/good"; sp_ub "$CASE_DIR/good" healthy 'control and route answer'
  # F F F H, for 60 passes (an hour): at most 2 restarts plus one per retry interval.
  for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do
    sp_ub_pass "$CASE_DIR/bad"; [ "$SP_TARGET" = unbound ] && n=$((n + 1))
    sp_ub_pass "$CASE_DIR/bad"; [ "$SP_TARGET" = unbound ] && n=$((n + 1))
    sp_ub_pass "$CASE_DIR/bad"; [ "$SP_TARGET" = unbound ] && n=$((n + 1))
    sp_ub_pass "$CASE_DIR/good"
  done
  assert_eq 1 "$(( n <= 4 ))" "an hour of flapping restarted Unbound $n times"
}

t_unbound_retry_does_not_starve_the_stack_restart() {
  local i stack=0
  sp_ub_start
  sp_obs "$CASE_DIR/out" healthy unhealthy unhealthy unhealthy unhealthy
  sp_ub "$CASE_DIR/out" unhealthy 'control: no answer'
  for i in $(seq 1 150); do
    sp_ub_pass "$CASE_DIR/out"
    if [ "$SP_TARGET" = stack ]; then stack=$((stack + 1)); fi
    # Past the ladder's cap a stack restart covers Unbound as well.
    if [ "$SP_TARGET" = unbound ] && [ "$(sp_key "$CASE_DIR/cur" outage_restarts)" -ge 2 ]; then
      fail "past the cap the stack is what restarts, not Unbound (pass $i)"
    fi
  done
  assert_eq 1 "$(( stack >= 2 ))" "the stack restarts during a long outage with a dead control socket: $stack"
}

t_unbound_acts_only_on_a_failure_seen_in_this_pass() {
  sp_ub_start
  cp "$CASE_DIR/ok" "$CASE_DIR/bad"; sp_ub "$CASE_DIR/bad" unhealthy 'control: exit 1'
  cp "$CASE_DIR/ok" "$CASE_DIR/idk"; sp_ub "$CASE_DIR/idk" indeterminate 'deadline: nothing answered'
  sp_ub_pass "$CASE_DIR/bad"; sp_ub_pass "$CASE_DIR/bad"; sp_ub_pass "$CASE_DIR/bad"
  assert_eq unbound "$SP_TARGET" "the first restart"
  sp_ub_pass "$CASE_DIR/bad"; sp_ub_pass "$CASE_DIR/bad"; sp_ub_pass "$CASE_DIR/bad"
  assert_ne unbound "$SP_TARGET" "the streak is met again inside the cooldown"
  SP_NOW=$((SP_NOW + 300))
  sp_ub_pass "$CASE_DIR/idk"
  assert_ne unbound "$SP_TARGET" "an indeterminate pass acts on nothing, even with the streak met"
  sp_ub_pass "$CASE_DIR/ok"
  assert_ne unbound "$SP_TARGET" "nor does a pass with no reading"
  sp_ub_pass "$CASE_DIR/bad"
  assert_eq unbound "$SP_TARGET" "a failure seen in this pass does"
}

t_unbound_route_failure_with_only_compat_answering_is_not_counted() {
  sp_ub_start
  sp_obs "$CASE_DIR/cmp" healthy unhealthy unhealthy unhealthy healthy
  sp_ub "$CASE_DIR/cmp" unhealthy 'route: probe-route exit 1'
  sp_ub_pass "$CASE_DIR/cmp"; sp_ub_pass "$CASE_DIR/cmp"; sp_ub_pass "$CASE_DIR/cmp"; sp_ub_pass "$CASE_DIR/cmp"
  assert_eq "" "$(sp_key "$CASE_DIR/cur" unbound_fail)" "compat is never selected, so it says nothing about Unbound's route"
}

t_unbound_past_the_cap_with_routes_unknown_is_still_restarted() {
  local now
  sp_ub_start
  now=$((SP_NOW + 7200))
  # Past the cap, no route observed, control dead: the stack restart cannot act
  # on this pass, so Unbound's own rule must.
  sp_obs "$CASE_DIR/idk" healthy indeterminate indeterminate indeterminate indeterminate
  sp_ub "$CASE_DIR/idk" unhealthy 'control: exit 1'
  awk -F '\t' -v n="$now" 'BEGIN { OFS = "\t" } $1 == "outage_since" { $2 = n - 3600 } $1 == "outage_restarts" { $2 = 2 } { print }' "$CASE_DIR/cur" >"$CASE_DIR/cur.2" && mv "$CASE_DIR/cur.2" "$CASE_DIR/cur"
  SP_NOW="$now"
  sp_ub_pass "$CASE_DIR/idk"; sp_ub_pass "$CASE_DIR/idk"; sp_ub_pass "$CASE_DIR/idk"
  assert_eq unbound "$SP_TARGET" "a dead control socket is not left to a stack restart that cannot run"
}

# ─────────────────────────── Pi-hole's own health ────────────────────────────

# sp_ph <file> <container verdict|-> <local-service verdict|->: add Pi-hole's
# records (container:pi-hole, local-service) to an observation file.
sp_ph() {
  case "$2" in
    healthy) printf 'obs\tcontainer:pi-hole\thealthy\t30\trunning: health healthy restarts 0\n' >>"$1" ;;
    unhealthy) printf 'obs\tcontainer:pi-hole\tunhealthy\t30\tunhealthy: FTL is not answering restarts 0\n' >>"$1" ;;
    indeterminate) printf 'obs\tcontainer:pi-hole\tindeterminate\t30\tdeadline: the state of pi-hole gave no answer within 5s restarts ?\n' >>"$1" ;;
  esac
  case "$3" in
    healthy) printf 'obs\tlocal-service\thealthy\t4\tNOERROR pi.hole\n' >>"$1" ;;
    unhealthy) printf 'obs\tlocal-service\tunhealthy\t4\tdig exit 9: no servers could be reached\n' >>"$1" ;;
    indeterminate) printf 'obs\tlocal-service\tindeterminate\t10000\tdeadline: nothing answered\n' >>"$1" ;;
  esac
}

# sp_ph_files: $CASE_DIR/phbad (the container check fails), phls (only
# local-service fails), phgood (both healthy), phidk (both indeterminate), on
# top of healthy routes.
sp_ph_files() {
  cp "$CASE_DIR/ok" "$CASE_DIR/phbad"; sp_ph "$CASE_DIR/phbad" unhealthy healthy
  cp "$CASE_DIR/ok" "$CASE_DIR/phls"; sp_ph "$CASE_DIR/phls" healthy unhealthy
  cp "$CASE_DIR/ok" "$CASE_DIR/phgood"; sp_ph "$CASE_DIR/phgood" healthy healthy
  cp "$CASE_DIR/ok" "$CASE_DIR/phidk"; sp_ph "$CASE_DIR/phidk" indeterminate indeterminate
}

t_pihole_failing_restarts_it_on_the_third_pass() {
  local f
  for f in phbad phls; do
    sp_ub_start; sp_ph_files
    sp_ub_pass "$CASE_DIR/$f"; assert_eq no-op "$SP_ACTION" "$f: first failure"
    sp_ub_pass "$CASE_DIR/$f"; assert_eq no-op "$SP_ACTION" "$f: second failure"
    sp_ub_pass "$CASE_DIR/$f"
    assert_eq restart-component "$SP_ACTION" "$f: third failure in a row"
    assert_eq pi-hole "$SP_TARGET" "$f: the target is Pi-hole"
    assert_match 'Pi-hole failed 3 checks' "$SP_REASON" "$f: the reason names Pi-hole"
    assert_eq 1 "$(sp_key "$CASE_DIR/cur" pihole_restarts)" "$f: the restart is counted"
    assert_eq "" "$(sp_key "$CASE_DIR/cur" pihole_fail)" "$f: the streak starts over"
    assert_eq "$SP_NOW" "$(sp_key "$CASE_DIR/cur" recovery_at)" "$f: it starts the cooldown"
    assert_eq 0 "$(sp_key "$CASE_DIR/cur" outage_restarts)" "$f: the Tor ladder is not charged"
  done
}

t_pihole_startup_and_cooldown_hold_the_restart() {
  sp_libs
  sp_obs "$CASE_DIR/ok" healthy healthy healthy healthy healthy
  sp_ph_files
  sp_decide "$CASE_DIR/ok" - "$SP_T0"; cp "$CASE_DIR/next" "$CASE_DIR/cur"
  sp_steps "$CASE_DIR/phbad" $((SP_T0 + 10)) $((SP_T0 + 20)) $((SP_T0 + 30)) $((SP_T0 + 40))
  assert_ne pi-hole "$SP_TARGET" "inside the startup allowance"
  assert_match 'Pi-hole failed 4 checks in a row, inside the startup allowance or cooldown' "$SP_REASON" "the journal says why it waits"
  sp_steps "$CASE_DIR/phbad" $((SP_T0 + 130))
  assert_eq pi-hole "$SP_TARGET" "the allowance over, the streak acts"
  sp_steps "$CASE_DIR/phbad" $((SP_T0 + 190)) $((SP_T0 + 250)) $((SP_T0 + 310)) $((SP_T0 + 370))
  assert_ne pi-hole "$SP_TARGET" "inside the cooldown (300 s from the restart)"
  assert_match 'inside the startup allowance or cooldown' "$SP_REASON" "the journal says why it waits"
  sp_steps "$CASE_DIR/phbad" $((SP_T0 + 430))
  assert_eq pi-hole "$SP_TARGET" "the cooldown over, a second restart"
  assert_eq 2 "$(sp_key "$CASE_DIR/cur" pihole_restarts)" "two restarts"
}

t_pihole_retries_every_half_hour_after_two_restarts() {
  local i last
  sp_ub_start; sp_ph_files
  for i in 1 2 3 4 5 6 7 8; do sp_ub_pass "$CASE_DIR/phbad"; done
  assert_eq 2 "$(sp_key "$CASE_DIR/cur" pihole_restarts)" "two restarts first"
  last="$(sp_key "$CASE_DIR/cur" recovery_at)"
  i=0
  while [ "$(sp_key "$CASE_DIR/cur" pihole_restarts)" = 2 ] && [ "$i" -lt 60 ]; do
    sp_ub_pass "$CASE_DIR/phbad"; i=$((i + 1))
    if [ "$SP_NOW" -lt $((last + 1800)) ]; then
      assert_ne pi-hole "$SP_TARGET" "no restart before the retry interval ($((SP_NOW - last)) s)"
      if [ "$(sp_key "$CASE_DIR/cur" pihole_fail)" -ge 3 ]; then
        if [ "$SP_NOW" -lt $((last + 300)) ]; then
          assert_match 'Pi-hole failed .* inside the startup allowance or cooldown' "$SP_REASON" "a pass in the cooldown says so"
        else
          assert_match 'Pi-hole failed .* after 2 restarts; next restart 1800 s after the last' "$SP_REASON" "a pass held by the retry interval says so"
        fi
      fi
    fi
  done
  assert_eq 3 "$(sp_key "$CASE_DIR/cur" pihole_restarts)" "a third restart at the retry interval"
  assert_eq 1 "$(( $(sp_key "$CASE_DIR/cur" recovery_at) - last >= 1800 ))" "no sooner than 1800 s after the second"
  last="$(sp_key "$CASE_DIR/cur" recovery_at)"
  i=0
  while [ "$(sp_key "$CASE_DIR/cur" pihole_restarts)" = 3 ] && [ "$i" -lt 60 ]; do sp_ub_pass "$CASE_DIR/phbad"; i=$((i + 1)); done
  assert_eq 4 "$(sp_key "$CASE_DIR/cur" pihole_restarts)" "and again"
  assert_eq 1 "$(( $(sp_key "$CASE_DIR/cur" recovery_at) - last >= 1800 ))" "at the same interval"
}

t_pihole_healthy_reading_clears_and_indeterminate_holds() {
  sp_ub_start; sp_ph_files
  sp_ub_pass "$CASE_DIR/phbad"; sp_ub_pass "$CASE_DIR/phls"
  assert_eq 2 "$(sp_key "$CASE_DIR/cur" pihole_fail)" "either record counts toward one streak"
  sp_ub_pass "$CASE_DIR/phidk"
  assert_eq 2 "$(sp_key "$CASE_DIR/cur" pihole_fail)" "indeterminate changes nothing"
  assert_eq no-op "$SP_ACTION" "and acts on nothing"
  sp_ub_pass "$CASE_DIR/ok"
  assert_eq 2 "$(sp_key "$CASE_DIR/cur" pihole_fail)" "no record changes nothing"
  sp_ub_pass "$CASE_DIR/phgood"
  assert_eq "" "$(sp_key "$CASE_DIR/cur" pihole_fail)" "a healthy reading clears the streak"
  sp_ub_pass "$CASE_DIR/phbad"; sp_ub_pass "$CASE_DIR/phbad"; sp_ub_pass "$CASE_DIR/phbad"
  assert_eq 1 "$(sp_key "$CASE_DIR/cur" pihole_restarts)" "a restart"
  sp_ub_pass "$CASE_DIR/phgood"
  assert_eq 1 "$(sp_key "$CASE_DIR/cur" pihole_restarts)" "healthy right after a restart keeps the count: a flap is not a cure"
  SP_NOW=$((SP_NOW + 1800))
  sp_ub_pass "$CASE_DIR/phgood"
  assert_eq "" "$(sp_key "$CASE_DIR/cur" pihole_restarts)" "healthy a retry interval after the last restart clears it"
}

# Live 2026-11-05 (restart-policy Task 3.3): a SIGSTOPped pihole-FTL reads as
# these records, copied from mint and the mac. local-service is a dig timeout,
# indeterminate, and the macOS container record stays healthy (no health
# check). Before the fix neither counted, and the healthy container record
# cleared the streak each pass, so a hung Pi-hole was never restarted.
sp_ph_frozen() {
  case "$2" in
    macos) printf 'obs\tcontainer:pi-hole\thealthy\t0\trunning: health none restarts 0\n' >>"$1" ;;
    linux) printf 'obs\tcontainer:pi-hole\tunhealthy\t148\tunhealthy: the health check fails restarts 0\n' >>"$1" ;;
  esac
  printf 'obs\tlocal-service\tindeterminate\t6046\tdig timed out at 127.0.0.1#53 (pi.hole)\n' >>"$1"
}

t_a_frozen_pihole_is_restarted_on_both_platforms() {
  local plat
  for plat in macos linux; do
    sp_ub_start
    cp "$CASE_DIR/ok" "$CASE_DIR/frozen"; sp_ph_frozen "$CASE_DIR/frozen" "$plat"
    sp_ub_pass "$CASE_DIR/frozen"; assert_eq no-op "$SP_ACTION" "$plat: first pass"
    assert_eq 1 "$(sp_key "$CASE_DIR/cur" pihole_fail)" "$plat: a timed-out pi.hole with a route answering counts"
    sp_ub_pass "$CASE_DIR/frozen"; assert_eq no-op "$SP_ACTION" "$plat: second pass"
    sp_ub_pass "$CASE_DIR/frozen"
    assert_eq restart-component "$SP_ACTION" "$plat: the third pass restarts"
    assert_eq pi-hole "$SP_TARGET" "$plat: Pi-hole"
    if [ "$plat" = macos ]; then
      assert_match 'Pi-hole failed 3 checks in a row: local-service: dig timed out' "$SP_REASON" "macos: the reason says pi.hole timed out"
    else
      assert_match 'Pi-hole failed 3 checks in a row: container: unhealthy: the health check fails' "$SP_REASON" "linux: the reason names podman's failing check"
    fi
  done
}

# Without a route answering, a timeout says nothing about Pi-hole: the host or
# the network may be what is slow. It neither counts nor clears.
t_a_pihole_timeout_without_a_route_holds_the_streak() {
  sp_ub_start; sp_ph_files
  sp_ub_pass "$CASE_DIR/phls"; sp_ub_pass "$CASE_DIR/phls"
  assert_eq 2 "$(sp_key "$CASE_DIR/cur" pihole_fail)" "two failures"
  sp_obs "$CASE_DIR/down" healthy unhealthy unhealthy unhealthy unhealthy
  sp_ph_frozen "$CASE_DIR/down" macos
  sp_ub_pass "$CASE_DIR/down"
  assert_eq 2 "$(sp_key "$CASE_DIR/cur" pihole_fail)" "no route answering: the timeout neither counts nor lets the container record clear"
  assert_ne pi-hole "$SP_TARGET" "and restarts nothing"
}

t_pihole_new_boot_clears_the_counters() {
  sp_ub_start; sp_ph_files
  sp_ub_pass "$CASE_DIR/phbad"; sp_ub_pass "$CASE_DIR/phbad"
  assert_eq 2 "$(sp_key "$CASE_DIR/cur" pihole_fail)" "two failures"
  sp_decide "$CASE_DIR/ok" "$CASE_DIR/cur" $((SP_NOW + 60)) boot-b
  assert_eq "" "$(sp_key "$CASE_DIR/next" pihole_fail)" "a new boot restarts the streak"
}

t_pihole_in_a_full_outage_past_the_cap_is_left_to_the_stack_restart() {
  local i
  sp_ub_start
  sp_obs "$CASE_DIR/out" healthy unhealthy unhealthy unhealthy unhealthy
  sp_ph "$CASE_DIR/out" unhealthy unhealthy
  for i in $(seq 1 150); do
    sp_ub_pass "$CASE_DIR/out"
    if [ "$SP_TARGET" = pi-hole ] && [ "$(sp_key "$CASE_DIR/cur" outage_restarts)" -ge 2 ]; then
      fail "past the cap the stack is what restarts, not Pi-hole (pass $i)"
    fi
  done
  assert_match '^[2-9]' "$(sp_key "$CASE_DIR/cur" outage_restarts)" "the stack restarts ran"
}

t_pihole_state_rows_exist_only_when_non_zero() {
  local tok
  sp_ub_start; sp_ph_files
  sp_ub_pass "$CASE_DIR/phgood"
  assert_eq 0 "$(grep -c '^pihole_' "$CASE_DIR/cur")" "a zero-counter state has no new rows (BL-036)"
  sp_ub_pass "$CASE_DIR/phbad"
  assert_eq 1 "$(sp_key "$CASE_DIR/cur" pihole_fail)" "a non-zero counter is written"
  nd_state_init || fail "init"
  tok="$(nd_state_lock)" || fail "lock"
  nd_state_commit "$tok" 0 "$CASE_DIR/cur" >/dev/null; assert_rc 0 $? "lib/state.sh accepts the new rows"
  assert_eq 1 "$(nd_state_load | awk -F '\t' '$1 == "pihole_fail" { print $2 }')" "and loads them back"
  printf 'pihole_restarts\tnope\n' >>"$CASE_DIR/cur"
  nd_state_commit "$tok" 1 "$CASE_DIR/cur" >/dev/null 2>&1; assert_rc 2 $? "a bad value is refused"
  nd_state_unlock "$tok"
}

# ─────────────────────────── paused containers ───────────────────────────────

# sp_paused <file> <name>: add a paused container record.
sp_paused() { printf 'obs\tcontainer:%s\tunhealthy\t20\tpaused restarts 0\n' "$2" >>"$1"; }

t_a_paused_container_is_unpaused_after_two_passes() {
  sp_ub_start
  cp "$CASE_DIR/ok" "$CASE_DIR/pz"; sp_paused "$CASE_DIR/pz" unbound
  # A paused Unbound's control socket fails too: the unpause comes first.
  sp_ub "$CASE_DIR/pz" unhealthy 'control: no answer'
  cp "$CASE_DIR/ok" "$CASE_DIR/run"; printf 'obs\tcontainer:unbound\thealthy\t20\trunning: health healthy restarts 0\n' >>"$CASE_DIR/run"
  sp_ub_pass "$CASE_DIR/pz"
  assert_eq no-op "$SP_ACTION" "one paused pass is left alone: an operator may pause on purpose"
  assert_eq 1 "$(sp_key "$CASE_DIR/cur" paused_unbound)" "the pass is counted"
  sp_ub_pass "$CASE_DIR/pz"
  assert_eq repair-runtime "$SP_ACTION" "two paused passes decide the repair"
  assert_eq containers-paused "$SP_TARGET" "the fault is containers-paused"
  assert_match '^containers-paused: unbound ' "$SP_REASON" "the reason names the container"
  assert_eq "$SP_NOW" "$(sp_key "$CASE_DIR/cur" recovery_at)" "the repair starts the cooldown"
  sp_ub_pass "$CASE_DIR/run"
  assert_eq "" "$(sp_key "$CASE_DIR/cur" paused_unbound)" "a running reading clears the count, and the row goes"
}

t_a_paused_container_waits_out_the_cooldown() {
  sp_ub_start
  cp "$CASE_DIR/ok" "$CASE_DIR/pz"; sp_paused "$CASE_DIR/pz" pi-hole
  awk -F '\t' -v n="$SP_NOW" 'BEGIN { OFS = "\t" } $1 == "recovery_at" { $2 = n } { print }' "$CASE_DIR/cur" >"$CASE_DIR/cur.2" && mv "$CASE_DIR/cur.2" "$CASE_DIR/cur"
  sp_ub_pass "$CASE_DIR/pz"; sp_ub_pass "$CASE_DIR/pz"
  assert_ne repair-runtime "$SP_ACTION" "inside the cooldown"
  assert_match 'paused.*inside the recovery cooldown' "$SP_REASON" "the journal says why it waits"
  sp_ub_pass "$CASE_DIR/pz"; sp_ub_pass "$CASE_DIR/pz"; sp_ub_pass "$CASE_DIR/pz"
  assert_eq repair-runtime "$SP_ACTION" "the cooldown over, the repair"
  assert_eq containers-paused "$SP_TARGET" "of the paused container"
}

t_a_paused_container_escalates_where_no_unpause_exists() {
  sp_ub_start
  export ND_POLICY_RUNTIME_REPAIRS="runtime-down containers-missing"
  local before
  cp "$CASE_DIR/ok" "$CASE_DIR/pz"; sp_paused "$CASE_DIR/pz" tor-haproxy
  before="$(sp_key "$CASE_DIR/cur" recovery_at)"
  sp_ub_pass "$CASE_DIR/pz"; sp_ub_pass "$CASE_DIR/pz"
  assert_eq escalate "$SP_ACTION" "macOS lists no unpause: the policy escalates"
  assert_match 'paused: tor-haproxy' "$SP_REASON" "with the reason"
  assert_eq "$before" "$(sp_key "$CASE_DIR/cur" recovery_at)" "and nothing is restarted or repaired"
}

t_paused_rows_exist_only_when_non_zero() {
  local tok
  sp_ub_start
  sp_ub_pass "$CASE_DIR/ok"
  assert_eq 0 "$(grep -c '^paused_' "$CASE_DIR/cur")" "a zero-counter state has no new rows (BL-036)"
  cp "$CASE_DIR/ok" "$CASE_DIR/pz"; sp_paused "$CASE_DIR/pz" pi-hole
  sp_ub_pass "$CASE_DIR/pz"
  nd_state_init || fail "init"
  tok="$(nd_state_lock)" || fail "lock"
  nd_state_commit "$tok" 0 "$CASE_DIR/cur" >/dev/null; assert_rc 0 $? "lib/state.sh accepts paused_pi-hole"
  printf 'paused_nginx\t1\n' >>"$CASE_DIR/cur"
  nd_state_commit "$tok" 1 "$CASE_DIR/cur" >/dev/null 2>&1; assert_rc 2 $? "a row for a container outside the stack is refused"
  nd_state_unlock "$tok"
}

# ─────────────────────────── crash loops ─────────────────────────────────────

# sp_cnt <file> <container> <restarts> [verdict] [reason before "restarts"]:
# add a container record carrying the unit's restart count.
sp_cnt() { printf 'obs\tcontainer:%s\t%s\t20\t%s restarts %s\n' "$2" "${4:-healthy}" "${5:-running: health healthy}" "$3" >>"$1"; }

# sp_px_pass <restarts> [route verdict]: one pass a minute after the last with
# the proxy's count; routes healthy unless told.
sp_px_pass() {
  sp_obs "$CASE_DIR/px" healthy "${2:-healthy}" "${2:-healthy}" "${2:-healthy}" "${2:-healthy}"
  sp_cnt "$CASE_DIR/px" tor-haproxy "$1"
  sp_ub_pass "$CASE_DIR/px"
}

t_a_restart_count_rise_holds_a_due_pihole_restart() {
  sp_ub_start
  cp "$CASE_DIR/ok" "$CASE_DIR/f0"; sp_cnt "$CASE_DIR/f0" pi-hole 0 unhealthy 'unhealthy: FTL is not answering'
  cp "$CASE_DIR/ok" "$CASE_DIR/f1"; sp_cnt "$CASE_DIR/f1" pi-hole 1 unhealthy 'exited: rc 134'
  sp_ub_pass "$CASE_DIR/f0"; sp_ub_pass "$CASE_DIR/f0"
  assert_eq 2 "$(sp_key "$CASE_DIR/cur" pihole_fail)" "two failures"
  sp_ub_pass "$CASE_DIR/f1"
  assert_ne pi-hole "$SP_TARGET" "the unit restarted Pi-hole itself: the due restart is held"
  assert_match 'Pi-hole.*restarting on its own' "$SP_REASON" "the journal says why it waits"
  assert_eq "$SP_NOW" "$(sp_key "$CASE_DIR/cur" recovery_at)" "the rise starts the cooldown"
  assert_eq 1 "$(sp_key "$CASE_DIR/cur" restart_seen_pi-hole)" "the count is kept"
  local held_until=$((SP_NOW + 600)) seen=0
  while [ "$SP_NOW" -lt $((held_until + 120)) ]; do
    sp_ub_pass "$CASE_DIR/f1"
    if [ "$SP_TARGET" = pi-hole ]; then
      seen=1
      assert_eq 1 "$(( SP_NOW >= held_until ))" "no restart while the rise is under 600 s old ($((SP_NOW - held_until + 600)) s)"
      break
    fi
  done
  assert_eq 1 "$seen" "a stable count lets the held restart go"
}

t_three_rises_escalate_once_as_a_crash_loop() {
  local n esc=0
  sp_ub_start
  sp_px_pass 0
  assert_eq "" "$(sp_key "$CASE_DIR/cur" restart_seen_tor-haproxy)" "a zero count writes no row"
  sp_px_pass 1; assert_ne escalate "$SP_ACTION" "one rise"
  sp_px_pass 2; assert_ne escalate "$SP_ACTION" "two rises"
  sp_px_pass 3
  assert_eq escalate "$SP_ACTION" "three rises in 600 s"
  assert_match '^crash-loop: tor-haproxy ' "$SP_REASON" "named"
  assert_match 'first escalation of this loop' "$SP_REASON" "the first escalation of the loop says so: it writes the dump"
  for n in 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22 23 24 25 26 27; do
    sp_px_pass "$n"
    case "$SP_ACTION:$SP_REASON" in escalate:*crash-loop:*) esc=$((esc + 1)) ;; esac
    assert_not_match 'first escalation' "$SP_REASON" "only the first says so"
  done
  assert_eq 0 "$esc" "a rise every minute for 24 more minutes escalates nothing new"
  for n in 28 29 30 31 32 33 34 35; do
    sp_px_pass "$n"
    case "$SP_ACTION:$SP_REASON" in escalate:*crash-loop:*) esc=$((esc + 1)) ;; esac
  done
  assert_eq 1 "$esc" "once a retry interval later"
}

t_a_crash_loop_never_gets_a_controller_restart() {
  local n
  sp_ub_start
  # A full outage while the proxy crashes: the Tor ladder would act at once.
  sp_px_pass 0 unhealthy
  for n in 1 2 3 4 5 6 7 8 9 10 11 12; do
    sp_px_pass "$n" unhealthy
    case "$SP_TARGET" in tor|proxy|stack) fail "the proxy is restarting on its own; the controller restarted $SP_TARGET (pass $n)" ;; esac
  done
  assert_match 'restart count rose|restarting on its own' "$SP_REASON" "the journal says why"
  sp_obs "$CASE_DIR/mx" missing unhealthy unhealthy unhealthy unhealthy
  printf 'obs\truntime\tunhealthy\t5\tcontainers-missing: tor-haproxy (running: pi-hole unbound)\n' >"$CASE_DIR/mx.rt"
  awk -F '\t' 'NR == FNR { r = $0; next } $2 == "runtime" { print r; next } { print }' "$CASE_DIR/mx.rt" "$CASE_DIR/mx" >"$CASE_DIR/mx.2"
  sp_cnt "$CASE_DIR/mx.2" tor-haproxy 13 indeterminate 'transient: state stopping'
  SP_NOW=$((SP_NOW + 300)); sp_ub_pass "$CASE_DIR/mx.2"
  assert_ne repair-runtime "$SP_ACTION" "nor is a container restarting on its own started by name"
}

t_a_stable_count_clears_the_loop_and_a_fall_is_a_new_baseline() {
  local n
  sp_ub_start
  for n in 0 1 2 3; do sp_px_pass "$n"; done
  assert_eq escalate "$SP_ACTION" "a loop"
  assert_ne "" "$(sp_key "$CASE_DIR/cur" crash_tor-haproxy)" "its rises are kept"
  for n in 1 2 3 4 5 6 7 8 9 10; do sp_px_pass 3; done
  assert_eq "" "$(sp_key "$CASE_DIR/cur" crash_tor-haproxy)" "a count stable for 600 s clears it"
  assert_eq "" "$(sp_key "$CASE_DIR/cur" crash_esc_tor-haproxy)" "and its escalation"
  sp_px_pass 0
  assert_eq "" "$(sp_key "$CASE_DIR/cur" crash_tor-haproxy)" "a fall (a manual restart resets NRestarts) is no rise"
  assert_eq "" "$(sp_key "$CASE_DIR/cur" restart_seen_tor-haproxy)" "but a new baseline"
  sp_px_pass 1
  assert_ne "" "$(sp_key "$CASE_DIR/cur" crash_tor-haproxy)" "from which a rise counts"
}

t_a_new_boot_clears_the_crash_rows() {
  sp_ub_start
  sp_px_pass 0; sp_px_pass 5; sp_px_pass 6
  assert_ne "" "$(sp_key "$CASE_DIR/cur" crash_tor-haproxy)" "rises before the boot"
  sp_obs "$CASE_DIR/px" healthy healthy healthy healthy healthy; sp_cnt "$CASE_DIR/px" tor-haproxy 2
  sp_decide "$CASE_DIR/px" "$CASE_DIR/cur" $((SP_NOW + 60)) boot-b; cp "$CASE_DIR/next" "$CASE_DIR/cur"
  assert_eq "" "$(sp_key "$CASE_DIR/cur" crash_tor-haproxy)" "a new boot clears them"
  assert_eq 2 "$(sp_key "$CASE_DIR/cur" restart_seen_tor-haproxy)" "and the count it reads is a baseline"
  assert_eq "" "$(awk -F '\t' '$1 ~ /^crash/' "$CASE_DIR/cur")" "not a rise"
}

t_crash_rows_pass_the_state_validator() {
  local tok
  sp_ub_start
  sp_px_pass 0
  assert_eq 0 "$(grep -c -e '^crash' -e '^restart_seen' "$CASE_DIR/cur")" "a zero-counter state has no new rows (BL-036)"
  sp_px_pass 1; sp_px_pass 2; sp_px_pass 3
  nd_state_init || fail "init"
  tok="$(nd_state_lock)" || fail "lock"
  nd_state_commit "$tok" 0 "$CASE_DIR/cur" >/dev/null; assert_rc 0 $? "lib/state.sh accepts the crash rows: $(grep -e '^crash' -e '^restart_seen' "$CASE_DIR/cur" | tr '\n\t' '; ')"
  printf 'crash_tor-haproxy\t1,x\n' >"$CASE_DIR/bad.row"
  awk -F '\t' '$1 != "crash_tor-haproxy"' "$CASE_DIR/cur" >"$CASE_DIR/cur.bad"; cat "$CASE_DIR/bad.row" >>"$CASE_DIR/cur.bad"
  nd_state_commit "$tok" 1 "$CASE_DIR/cur.bad" >/dev/null 2>&1; assert_rc 2 $? "a bad rise list is refused"
  nd_state_unlock "$tok"
}

# Live 2026-11-05 (restart-policy Task 3.3): mint's awk is mawk 1.3.4, which
# panicked compiling the crash-row pattern, so every controller pass there
# exited 2 from install on. The suite ran under gawk and never saw it. The
# validator runs under each awk the Linux hosts ship (macOS's BSD awk ran it
# live): the crash rows are accepted, a bad one refused, under every one.
t_state_validator_runs_under_every_awk_the_hosts_ship() {
  local tok impl d n=0 out
  sp_ub_start
  sp_px_pass 0; sp_px_pass 1; sp_px_pass 2; sp_px_pass 3
  assert_match 'crash_tor-haproxy' "$(cat "$CASE_DIR/cur")" "the state holds a crash row"
  awk -F '\t' '$1 != "crash_tor-haproxy"' "$CASE_DIR/cur" >"$CASE_DIR/cur.bad"; printf 'crash_tor-haproxy\t1,,2\n' >>"$CASE_DIR/cur.bad"
  for impl in mawk gawk "busybox awk"; do
    command -v "${impl%% *}" >/dev/null 2>&1 || continue
    [ "$impl" != "busybox awk" ] || busybox awk 'BEGIN { exit 0 }' 2>/dev/null || continue
    n=$((n + 1)); d="$CASE_DIR/awk-$n"; mkdir -p "$d"
    printf '#!/bin/sh\nexec %s "$@"\n' "$impl" >"$d/awk"; chmod +x "$d/awk"
    (
      PATH="$d:$PATH"
      ND_STATE_DIR="$CASE_DIR/st-$n"; export ND_STATE_DIR
      nd_state_init || exit 9
      tok="$(nd_state_lock)" || exit 9
      out="$(nd_state_commit "$tok" 0 "$CASE_DIR/cur" 2>&1)"; rc=$?
      [ "$rc" = 0 ] || { echo "accept rc=$rc: $out"; exit 1; }
      out="$(nd_state_commit "$tok" 1 "$CASE_DIR/cur.bad" 2>&1)"; rc=$?
      [ "$rc" = 2 ] || { echo "refuse rc=$rc: $out"; exit 1; }
      nd_state_unlock "$tok"
    ) >"$CASE_DIR/awk-$n.log" 2>&1
    assert_rc 0 $? "$impl: the crash rows are accepted and a bad one refused: $(cat "$CASE_DIR/awk-$n.log")"
  done
  assert_ne 0 "$n" "at least one awk was tried"
  command -v mawk >/dev/null 2>&1 || echo "note: mawk is not installed here; the Linux hosts' default awk was not tried" >&2
}

# Tier-2 round 1: the crash-loop code ran tr, tail, sed and wc, so with no
# external command the window emptied and the hold never engaged.
t_policy_is_pure_through_a_crash_loop() {
  local n out
  sp_ub_start
  for n in 0 1 2 3 4 5 6 7 8 9 10; do
    sp_obs "$CASE_DIR/px" healthy healthy healthy healthy healthy
    sp_cnt "$CASE_DIR/px" tor-haproxy "$n"
    SP_NOW=$((SP_NOW + 30))
    out="$(PATH=/nonexistent nd_policy_decide "$CASE_DIR/px" "$CASE_DIR/cur" "$SP_NOW" boot-a 2>&1)"
    assert_rc 0 $? "pass $n decides with no external command: $out"
    printf '%s\n' "$out" | awk '$0 == "schema\tnice-dns-controller-state/1" { s = 1 } s' >"$CASE_DIR/cur"
    [ "$n" = 3 ] && assert_match 'reason	crash-loop: tor-haproxy restarted 3 times' "$out" "the third rise escalates without tr or wc"
  done
  assert_match '^([0-9]+,){7}[0-9]+$' "$(sp_key "$CASE_DIR/cur" crash_tor-haproxy)" "ten rises keep the newest eight, without tail or sed"
}

t_the_unpause_is_capped_and_never_starves_the_other_rules() {
  local i unp=0 ph=0 esc=0 last
  sp_ub_start
  # Pi-hole stays paused: its own check fails as well.
  cp "$CASE_DIR/ok" "$CASE_DIR/pz"; sp_paused "$CASE_DIR/pz" pi-hole
  printf 'obs\tlocal-service\tunhealthy\t4\tdig exit 9\n' >>"$CASE_DIR/pz"
  for i in $(seq 1 40); do
    sp_ub_pass "$CASE_DIR/pz"
    case "$SP_ACTION:$SP_TARGET" in
      repair-runtime:containers-paused) unp=$((unp + 1)); [ "$unp" -le 2 ] || [ $((SP_NOW - last)) -ge 1800 ] || fail "unpause $unp only $((SP_NOW - last)) s after the last"; last="$SP_NOW" ;;
      restart-component:pi-hole) ph=$((ph + 1)); last="$SP_NOW" ;;
      escalate:*) assert_match 'stays paused after 2 unpauses' "$SP_REASON" "a held pass escalates with the reason"; esc=$((esc + 1)) ;;
    esac
  done
  assert_eq 2 "$unp" "two unpauses in 40 minutes, then the retry interval"
  assert_eq 1 "$(( ph >= 1 ))" "past the cap Pi-hole's own rule acts ($ph restarts)"
  assert_eq 1 "$(( esc >= 1 ))" "and passes no rule acted on escalate"
  assert_eq 2 "$(sp_key "$CASE_DIR/cur" paused_repairs)" "the count is kept"
  cp "$CASE_DIR/ok" "$CASE_DIR/run"; printf 'obs\tcontainer:pi-hole\thealthy\t20\trunning: health healthy restarts 0\n' >>"$CASE_DIR/run"
  sp_ub_pass "$CASE_DIR/run"
  assert_eq "" "$(sp_key "$CASE_DIR/cur" paused_repairs)" "a running reading clears it, and the row goes"
}
