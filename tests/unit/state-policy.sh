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
    ND_POLICY_PROMOTE ND_POLICY_DEMOTE ND_POLICY_MAX_RESTARTS
}

sp_libs() {
  sp_env
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
set -u
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
    assert_eq containers-missing "$(nd_platform_runtime_repairs)" "linux: only missing containers are repairable" ) || exit 1
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
