# shellcheck shell=bash
# Shared helpers for the proxy-image transport groups (sub-plan 02, Tasks
# 1.2 and 1.3; ARCH-04, ARCH-08, ARCH-09). Sourced by group files; the runner
# provides assert_*, fail, RUN_ID and CASE_DIR. Bash 3.2 compatible.
#
#   tp_setup <repo>        build (or reuse) localhost/nd-test-<repo>:<hash>
#                          from the sibling checkout; set the cleanup trap
#   tp_holder              a --network none namespace other containers join
#   tp_ns <cmd...>         run a host command inside that namespace
#   tp_socks_start         tests/fixtures/socksfixture.py on 127.0.0.1:9050
#                          inside the namespace (stands in for Tor)
#   tp_socks_mode <words>  accept | reject [IP...] | relay PORT
#   tp_send <port> <marker>  one TCP stream to 127.0.0.1:<port> carrying marker
#   tp_dests <marker>      "ip:port" per SOCKS request whose payload is marker
#   tp_run <name> <args>   podman run -d, joining the namespace; tracked
#   tp_supervised [args]   the image's own start.sh with a stand-in tor and
#                          three syntactically valid test bridges
#   tp_wait_file / tp_field / tp_request / tp_pid_of   restart-contract probes
#
# Safety: containers are named nd-test-tp-<run id>-<case>-*, never publish a
# port, and join a --network none namespace, so nothing leaves the host
# loopback of that namespace. The production pod and its images are never
# touched. The SOCKS fixture has no route anywhere: "destinations" are only
# recorded, never contacted.

# TP_IMG, TP_SRC, TP_CTR, TP_SOCKS and TP_NSPID are read by the group files.
# shellcheck disable=SC2034
TP_SIBS="${NICE_DNS_SIBLINGS_DIR:-$(dirname "$NICE_DNS_ROOT")}"
TP_SOCKS_PY="$NICE_DNS_ROOT/tests/fixtures/socksfixture.py"
TP_WARN="level=warning msg=\"The storage 'driver' option"

# tp_pm <podman args...>: TP_OUT (stdout+stderr, storage warning removed), TP_RC.
tp_pm() {
  TP_OUT="$(podman "$@" 2>&1)"
  TP_RC=$?
  TP_OUT="$(printf '%s\n' "$TP_OUT" | grep -v -- "$TP_WARN")"
}

tp_ns() { tp_pm unshare nsenter -t "$TP_NSPID" -n "$@"; }

tp_sha() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum | cut -d' ' -f1; else shasum -a 256 | cut -d' ' -f1; fi
}

# tp_src_hash <dir>: content hash of the build inputs: tracked and untracked
# (not ignored) files, excluding tests/ and the untracked bridge-eval binary.
tp_src_hash() {
  local f
  (cd "$1" && git ls-files -co --exclude-standard) | grep -v -e '^tests/' -e '^bridge-eval/bridge-eval$' \
    | LC_ALL=C sort | while IFS= read -r f; do
      printf '%s\n' "$f"
      if [ -f "$1/$f" ]; then tp_sha <"$1/$f"; else printf 'absent\n'; fi
    done | tp_sha
}

tp_setup() {
  local repo="$1" src h
  src="$TP_SIBS/$repo"
  TP_PFX="nd-test-tp-$RUN_ID-$(basename "$CASE_DIR" | tr '_' '-')"
  TP_CTRS="" TP_SOCKS_WRAP="" TP_NSPID="" TP_SOCKS=""
  trap tp_cleanup EXIT
  [ -f "$src/Dockerfile" ] || fail "$repo sibling checkout not found at $src"
  # Docker image format, as published: the OCI format drops HEALTHCHECK.
  h="$( { tp_src_hash "$src"; printf 'format=docker\n'; } | tp_sha)"
  # shellcheck disable=SC2034
  TP_SRC="$src"
  TP_IMG="localhost/nd-test-$repo:$(printf '%s' "$h" | cut -c1-16)"
  if ! podman image exists "$TP_IMG" 2>/dev/null; then
    podman build --format docker -t "$TP_IMG" "$src" >"$CASE_DIR/build.log" 2>&1 \
      || fail "$repo image build failed: $(tail -n 15 "$CASE_DIR/build.log")"
  fi
  printf 'image\t%s\t%s\t%s\n' "$repo" "$TP_IMG" "$(git -C "$src" rev-parse HEAD 2>/dev/null)" >"$CASE_DIR/image.tsv"
}

tp_cleanup() {
  local c rev=""
  if [ -n "$TP_SOCKS_WRAP" ]; then
    [ -f "$CASE_DIR/socks/pypid" ] && kill "$(cat "$CASE_DIR/socks/pypid")" 2>/dev/null
    kill "$TP_SOCKS_WRAP" 2>/dev/null; wait "$TP_SOCKS_WRAP" 2>/dev/null
  fi
  for c in $TP_CTRS; do rev="$c $rev"; done
  for c in $rev; do podman rm -f -t 0 "$c" >/dev/null 2>&1; done
  return 0
}

tp_holder() {
  TP_HOLDER="$TP_PFX-ns"
  TP_CTRS="$TP_CTRS $TP_HOLDER"
  tp_pm run -d --health-interval=disable --name "$TP_HOLDER" --network none --entrypoint /bin/sleep "$TP_IMG" 900
  assert_rc 0 "$TP_RC" "network namespace holder starts: $TP_OUT"
  TP_NSPID="$(podman inspect -f '{{.State.Pid}}' "$TP_HOLDER" 2>/dev/null)"
  assert_match '^[1-9][0-9]*$' "$TP_NSPID" "holder has a pid"
}

# tp_run <name suffix> <podman run args...>: a tracked container in the namespace.
tp_run() {
  local n="$TP_PFX-$1"
  shift
  TP_CTRS="$TP_CTRS $n"
  # shellcheck disable=SC2034
  TP_CTR="$n"
  # --health-interval=disable: the image HEALTHCHECK stays defined (run on
  # demand by tp_healthcheck_rc) but podman schedules no systemd timer.
  tp_pm run -d --health-interval=disable --name "$n" --network "container:$TP_HOLDER" "$@"
  assert_rc 0 "$TP_RC" "container $n starts: $TP_OUT"
}

tp_socks_start() {
  local d="$CASE_DIR/socks" i=0
  mkdir -m 700 "$d" || fail "cannot create $d"
  podman unshare nsenter -t "$TP_NSPID" -n sh -c 'echo $$ >"$1/pypid"; exec python3 "$2" --state "$1" --max-seconds "$3"' \
    sh "$d" "$TP_SOCKS_PY" "${FX_MAX_SECONDS:-600}" >"$d/fixture.log" 2>&1 </dev/null &
  TP_SOCKS_WRAP=$!
  while [ ! -f "$d/ready" ]; do
    i=$((i + 1))
    [ "$i" -le 300 ] || fail "SOCKS fixture did not start: $(cat "$d/fixture.log")"
    sleep 0.05
  done
  TP_SOCKS="$d"
}

tp_socks_mode() { printf '%s\n' "$*" >"$TP_SOCKS/mode"; }

# tp_wait_listen <port> [seconds]: wait until something listens on the port.
tp_wait_listen() {
  local i=0 max=$(( ${2:-20} * 5 ))
  while [ "$i" -lt "$max" ]; do
    tp_ns ss -Hltn "sport = :$1"
    case "$TP_OUT" in *LISTEN*) return 0 ;; esac
    i=$((i + 1)); sleep 0.2
  done
  return 1
}

# tp_send <port> <marker>: connect, send the marker, wait briefly for close.
tp_send() {
  # shellcheck disable=SC2016
  tp_ns python3 -c '
import socket, sys
s = socket.create_connection(("127.0.0.1", int(sys.argv[1])), timeout=5)
s.sendall(sys.argv[2].encode())
s.settimeout(3)
try:
    s.recv(64)
except OSError:
    pass
s.close()' "$1" "$2"
}

tp_dests() {
  awk -F '\t' -v m="$1" '$5 == m { print $2 ":" $3 }' "$TP_SOCKS/connects.tsv" | LC_ALL=C sort -u
}

# ─────────────────────────── supervision (image start.sh) ───────────────────

# tp_supervised [podman run args]: the image's full start.sh with a stand-in
# tor (logs "Bootstrapped 100%" and waits; its process name is "tor").
tp_supervised() {
  local b
  # HUP makes the fake tor exit 0 (nothing in either image sends tor a HUP):
  # an unrequested clean exit must still fail the container.
  printf '#!/bin/sh\ntrap "exit 0" HUP\necho "Bootstrapped 100%% (done): Done"\nwhile :; do sleep 1; done\n' >"$CASE_DIR/faketor"
  chmod 755 "$CASE_DIR/faketor"
  [ -n "$TP_NSPID" ] || tp_holder
  [ -n "$TP_SOCKS" ] || tp_socks_start
  # Caller's extra podman run args stay in "$@"; the bridges are appended.
  for b in 1 2 3; do
    set -- "$@" -e "BRIDGE$b=obfs4 192.0.2.$b:443 0123456789ABCDEF0123456789ABCDEF0123456$b cert=AAAAtestonly$b iat-mode=0"
  done
  tp_run sup "$@" -v "$CASE_DIR/faketor:/usr/bin/tor:ro" "$TP_IMG"
  tp_wait_file /app/data/control/tor-generation 60 || fail "start.sh never wrote /app/data/control/tor-generation: $(podman logs "$TP_CTR" 2>&1 | tail -n 20)"
}

# tp_clean_exit_case <repo>: Sub-plan 5 Task 2.1 (FQ-PROXY-CHILD-DEATH): a
# child that exits 0 unrequested (here tor, on HUP) still ends the container
# with a failure status, or Restart=on-failure would leave the proxy down.
tp_clean_exit_case() {
  local rc
  tp_setup "$1"
  tp_holder
  tp_socks_start
  tp_socks_mode accept
  tp_supervised
  tp_ready_wait 40 || fail "never ready: $(printf '%s\n' "$TP_LOGS" | tail -n 10)"
  tp_pm exec "$TP_CTR" pkill -HUP -x tor
  rc="$(timeout 30 podman wait "$TP_CTR" 2>/dev/null | grep -E '^[0-9]+$' | tail -1)"
  assert_match '^[0-9]+$' "$rc" "the container exited after tor exited unrequested"
  assert_ne 0 "$rc" "an unrequested clean exit is still a failure exit"
}

# Sub-plan 5 Task 1.4 (fix B). Readiness is a working stream, not a cached
# "Bootstrapped 100%" (mac 2026-09-29: Tor reported it 2 s after start, then
# no circuit for 2 min). The fake tor bootstraps at once; the SOCKS fixture
# decides whether a stream works.

# tp_ready_wait <seconds>: the supervisor reported readiness; TP_LOGS holds
# the container's log.
tp_ready_wait() {
  local i=0 max=$(( $1 * 2 ))
  while [ "$i" -lt "$max" ]; do
    TP_LOGS="$(podman logs "$TP_CTR" 2>&1)"
    case "$TP_LOGS" in *'Tor bootstrapped successfully'*) return 0 ;; esac
    i=$((i + 1)); sleep 0.5
  done
  return 1
}

# tp_stalled_start <repo> <fixture mode...>: the supervisor started against a
# fixture in that mode, and the fake tor has logged its bootstrap.
tp_stalled_start() {
  local repo="$1"
  shift
  tp_setup "$repo"
  tp_holder
  tp_socks_start
  tp_socks_mode "$@"
  tp_supervised
  tp_wait_file /app/data/tor.log 20 'Bootstrapped 100%' || fail "the fake tor never bootstrapped: $(podman logs "$TP_CTR" 2>&1 | tail -n 10)"
}

# tp_readiness_case <repo>: no readiness while every stream is refused; ready
# once one works.
tp_readiness_case() {
  tp_stalled_start "$1" reject
  sleep 12
  assert_not_match 'Tor bootstrapped successfully' "$(podman logs "$TP_CTR" 2>&1)" "no readiness while every stream through Tor fails, although Tor has bootstrapped"
  assert_match '	853	reject' "$(cat "$TP_SOCKS/connects.tsv")" "the probes ran and were refused"
  tp_socks_mode accept
  tp_ready_wait 40 || fail "never ready: $(printf '%s\n' "$TP_LOGS" | tail -n 10)"
  assert_match 'tor-supervisor: bootstrapped after [0-9]+ s, a stream works after [0-9]+ s \((exit|onion)\)' "$TP_LOGS" "time to the first stream, and its route, are logged"
}

# tp_readiness_onion_case <repo>: the exit resolver refused, the onion not:
# ready through the onion (Tier-1 review: an exit-only probe would call a Tor
# whose onion route works unready for ever).
tp_readiness_onion_case() {
  tp_stalled_start "$1" reject 1.1.1.1
  tp_ready_wait 40 || fail "never ready on the onion alone: $(podman logs "$TP_CTR" 2>&1 | tail -n 10)"
  assert_match 'a stream works after [0-9]+ s \(onion\)' "$TP_LOGS" "ready through the onion"
  assert_match '1\.1\.1\.1	853	reject' "$(cat "$TP_SOCKS/connects.tsv")" "the exit probe was refused"
}

# tp_stop_during_stall_case <repo>: a stop while the probes hang (the fixture
# accepts and answers after 120 s, a stalled circuit) ends within seconds,
# without SIGKILL (Tier-1 review: a foreground 20 s probe held the trap).
tp_stop_during_stall_case() {
  local rc t0 t1
  tp_stalled_start "$1" delay 120
  sleep 4
  t0="$(date +%s)"
  podman stop -t 10 "$TP_CTR" >/dev/null 2>&1
  t1="$(date +%s)"
  rc="$(podman inspect -f '{{.State.ExitCode}}' "$TP_CTR" 2>/dev/null)"
  assert_eq 143 "$rc" "the supervisor's own exit after cleanup, not SIGKILL (137), and nothing started after the stop"
  [ $((t1 - t0)) -lt 8 ]
  assert_rc 0 "$?" "stop completed within seconds while the probes hung ($((t1 - t0)) s)"
  assert_not_match 'haproxy version|Loading success|Starting PRIMARY' "$(podman logs "$TP_CTR" 2>&1)" "no front was started after the stop"
}

# tp_restart_during_stall_case <repo>: the restart contract holds while the
# supervisor waits for a working stream (Stage 1 gate, second pass I1: the
# watcher started only after that wait, which can now last 5 minutes, so a
# controller's request went unanswered exactly when Tor was stalled).
tp_restart_during_stall_case() {
  local ack
  tp_stalled_start "$1" delay 120
  sleep 3
  tp_request req-stall-1
  tp_wait_file /app/data/control/tor-restart-ack 40 '^request_id	req-stall-1$' || fail "a restart requested during the stall was not acknowledged: $(podman logs "$TP_CTR" 2>&1 | tail -n 15)"
  ack="$TP_OUT"
  assert_eq respawned "$(tp_field status "$ack")" "acknowledged as a respawn"
  assert_eq 2 "$(tp_field generation "$ack")" "with the new generation"
  tp_pm exec "$TP_CTR" test -e /app/data/control/tor-restart-request
  assert_nonzero "$TP_RC" "the request was consumed once"
  sleep 8
  tp_wait_file /app/data/control/tor-generation 2 '^generation	2$'
  assert_rc 0 "$?" "and it caused exactly one respawn (no late second one)"
}

# Stage 1 gate round 2: after the host sleeps, Tor in the macOS container VM
# kept dead circuits and refused every stream for 10-20 s (mac 2026-10-01:
# socat "socks: connect request rejected or failed"; a respawned tor carried a
# stream about 1 s after it started). The supervisor sees the sleep as wall
# time that passed while the uptime did not (the VM was frozen); a native
# Linux suspend counts in /proc/uptime and is not seen (Tor recovered there).
# These cases fake it: TOR_SUSPEND_UPTIME_FILE stands in for /proc/uptime,
# advances 100 s (tor has run that long; wall time minus uptime shrinks, no
# sleep), then steps back 25 s once (wall time minus uptime then grows by
# about 30 s within one 5 s check; tor's age by uptime is 75 s).
# TOR_SUSPEND_MIN_AGE=0 lets a fresh tor be judged, and
# TOR_SUSPEND_NET_PROBE, where given, replaces tor's bridges as the addresses
# whose TCP connect says the network is back (the test bridges 192.0.2.x have
# no route in the namespace).

# tp_suspend_start <repo> [podman run args]: the supervisor ready with the fake
# uptime source; a steady uptime causes no respawn.
tp_suspend_start() {
  local repo="$1"
  shift
  tp_setup "$repo"
  tp_holder
  tp_socks_start
  tp_socks_mode accept
  printf '1000.00 0.00\n' >"$CASE_DIR/uptime"
  chmod 644 "$CASE_DIR/uptime"
  tp_supervised -e TOR_SUSPEND_UPTIME_FILE=/run/nd-uptime -v "$CASE_DIR/uptime:/run/nd-uptime:ro" "$@"
  tp_ready_wait 40 || fail "never ready: $(printf '%s\n' "$TP_LOGS" | tail -n 10)"
  sleep 11
  tp_wait_file /app/data/control/tor-generation 2 '^generation	1$' || fail "a steady uptime is no sleep, yet tor was respawned"
}

# tp_suspend: the fake uptime advances 100 s, then (after one check) steps
# back 25 s (seen within one check).
tp_suspend() {
  printf '1100.00 0.00\n' >"$CASE_DIR/uptime"
  sleep 6
  printf '1075.00 0.00\n' >"$CASE_DIR/uptime"
}

tp_logs() { podman logs "$TP_CTR" 2>&1; }

# tp_suspend_respawn_case <repo>: no stream within 6 s after the sleep -> one
# respawn, acknowledged as request "suspend"; "suspend" is reserved, so a
# controller request carrying it is rejected.
tp_suspend_respawn_case() {
  local ack
  tp_suspend_start "$1" -e TOR_SUSPEND_MIN_AGE=0 -e TOR_SUSPEND_NET_PROBE=127.0.0.1:9050
  tp_socks_mode delay 120
  tp_suspend
  tp_wait_file /app/data/control/tor-restart-ack 40 '^request_id	suspend$' || fail "no respawn after a sleep with dead streams: $(tp_logs | tail -n 15)"
  ack="$TP_OUT"
  assert_eq respawned "$(tp_field status "$ack")" "acknowledged as a respawn"
  assert_eq 2 "$(tp_field generation "$ack")" "with the new generation"
  assert_match 'tor-supervisor: the host slept about [0-9]+ s; waiting for one of 1 bridge address' "$(tp_logs)" "the sleep is logged"
  assert_match 'no stream within 6 s after the sleep; respawning tor' "$(tp_logs)" "and why tor was respawned"
  sleep 11
  tp_wait_file /app/data/control/tor-generation 2 '^generation	2$'
  assert_rc 0 "$?" "exactly one respawn"
  tp_request suspend
  tp_wait_file /app/data/control/tor-restart-rejected 15 '^request_id	invalid$' || fail "a request with the reserved id was not rejected: $(tp_logs | tail -n 5)"
}

# tp_suspend_kept_case <repo>: a stream works after the sleep -> tor is kept
# (its circuits are warm; a respawn would cost a bootstrap).
tp_suspend_kept_case() {
  tp_suspend_start "$1" -e TOR_SUSPEND_MIN_AGE=0 -e TOR_SUSPEND_NET_PROBE=127.0.0.1:9050
  tp_suspend
  sleep 12
  assert_match 'a stream works after the sleep; tor kept' "$(tp_logs)" "the sleep was seen and tor kept: $(tp_logs | tail -n 8)"
  tp_wait_file /app/data/control/tor-generation 2 '^generation	1$'
  assert_rc 0 "$?" "no respawn"
  tp_pm exec "$TP_CTR" test -e /app/data/control/tor-restart-ack
  assert_nonzero "$TP_RC" "and no acknowledgement written"
}

# tp_suspend_young_case <repo>: with the default minimum age (120 s), a step
# right after the start is no sleep: tor is kept unprobed (a clock step during
# the first bootstrap; a repeated step respawns at most once per 120 s).
tp_suspend_young_case() {
  tp_suspend_start "$1" -e TOR_SUSPEND_NET_PROBE=127.0.0.1:9050
  tp_socks_mode delay 120
  tp_suspend
  sleep 12
  assert_match 'tor is younger than 120 s, kept' "$(tp_logs)" "a young tor is left alone: $(tp_logs | tail -n 5)"
  tp_wait_file /app/data/control/tor-generation 2 '^generation	1$'
  assert_rc 0 "$?" "no respawn"
}

# tp_suspend_clock_step_case <repo>: Stage 1 gate round 2 (second pass): a
# wall clock step is no running time. The fake uptime stands still while the
# wall clock runs (at least 11 s since the start), then steps back 30 s: by
# uptime tor has run 0 s, by the wall clock more than TOR_SUSPEND_MIN_AGE=5.
# Tor's age is its running time, so it is left alone (a forward NTP step
# during the first bootstrap must not respawn it with dead probes).
tp_suspend_clock_step_case() {
  tp_suspend_start "$1" -e TOR_SUSPEND_MIN_AGE=5 -e TOR_SUSPEND_NET_PROBE=127.0.0.1:9050
  tp_socks_mode delay 120
  printf '970.00 0.00\n' >"$CASE_DIR/uptime"
  sleep 12
  assert_match 'tor is younger than 5 s, kept' "$(tp_logs)" "a step is judged by tor's running time: $(tp_logs | tail -n 6)"
  tp_wait_file /app/data/control/tor-generation 2 '^generation	1$'
  assert_rc 0 "$?" "no respawn"
}

# tp_suspend_no_generation_case <repo>: Stage 1 gate round 2 (second pass): the
# check reads tor's pid from the generation file; a missing file (before the
# first spawn writes it) must not end the watcher (set -e): it still checks,
# and a restart request is still served afterwards.
tp_suspend_no_generation_case() {
  tp_suspend_start "$1" -e TOR_SUSPEND_MIN_AGE=0
  tp_pm exec "$TP_CTR" rm -f /app/data/control/tor-generation
  assert_rc 0 "$TP_RC" "generation file removed: $TP_OUT"
  tp_suspend
  sleep 8
  assert_match 'waiting for one of 0 bridge address' "$(tp_logs)" "the check ran without the file: $(tp_logs | tail -n 6)"
  tp_request req-nogen-1
  tp_wait_file /app/data/control/tor-restart-ack 50 '^request_id	req-nogen-1$' || fail "the watcher is gone: no acknowledgement: $(tp_logs | tail -n 10)"
}

# tp_suspend_bridges_case <repo>: tor's own bridges are the network check
# (read from its command line): none answers (no route), so after 30 s the
# streams are probed anyway, and a working one keeps tor.
tp_suspend_bridges_case() {
  tp_suspend_start "$1" -e TOR_SUSPEND_MIN_AGE=0
  tp_suspend
  sleep 8
  assert_match 'waiting for one of 3 bridge address\(es\)' "$(tp_logs)" "the three bridges were read from tor's command line: $(tp_logs | tail -n 5)"
  tp_wait_file /app/data/control/tor-generation 1 '^generation	1$' || fail "respawned while waiting for the network"
  sleep 36
  assert_match 'no bridge answered within 30 s; probing streams anyway' "$(tp_logs)" "the wait is bounded: $(tp_logs | tail -n 5)"
  assert_match 'a stream works after the sleep; tor kept' "$(tp_logs)" "and the streams decide"
}

# tp_suspend_request_case <repo>: a controller request during the check (the
# network is not back) is served by its own respawn and acknowledgement, at
# once, and the check makes no second one.
tp_suspend_request_case() {
  local ack
  tp_suspend_start "$1" -e TOR_SUSPEND_MIN_AGE=0 -e TOR_SUSPEND_NET_PROBE=127.0.0.1:1
  tp_suspend
  sleep 8
  assert_match 'waiting for one of 1 bridge address' "$(tp_logs)" "the check is waiting: $(tp_logs | tail -n 5)"
  tp_request req-sleep-1
  tp_wait_file /app/data/control/tor-restart-ack 15 '^request_id	req-sleep-1$' || fail "the request was not acknowledged promptly: $(tp_logs | tail -n 10)"
  ack="$TP_OUT"
  assert_eq 2 "$(tp_field generation "$ack")" "one respawn, the request's"
  assert_match 'a restart was asked during the check; it serves the sleep' "$(tp_logs)" "the check gave way"
  sleep 11
  tp_wait_file /app/data/control/tor-generation 2 '^generation	2$'
  assert_rc 0 "$?" "and made no second respawn"
}

# tp_torlog_case <repo>: Tor's own log is on the data volume (owner-only); a
# respawn and a container restart both keep the previous run's (every earlier
# stall left no trace: the log lived in /tmp and was truncated at each launch).
tp_torlog_case() {
  tp_setup "$1"
  tp_supervised
  tp_wait_file /app/data/tor.log 30 'Bootstrapped 100%' || fail "no tor log on the data volume: $(podman logs "$TP_CTR" 2>&1 | tail -n 10)"
  tp_pm exec "$TP_CTR" stat -c %a /app/data/tor.log
  assert_eq 600 "$TP_OUT" "the log is owner-only (it names bridges)"
  tp_pm exec "$TP_CTR" test -e /tmp/tor.log
  assert_nonzero "$TP_RC" "nothing is written to /tmp/tor.log any more"
  tp_pm exec "$TP_CTR" touch /tmp/tor-restart-flag
  tp_wait_file /app/data/control/tor-restart-ack 40 '^generation	2$' || fail "tor was not respawned: $(podman logs "$TP_CTR" 2>&1 | tail -n 10)"
  tp_wait_file /app/data/tor.log.prev 10 'Bootstrapped 100%'
  assert_rc 0 "$?" "the previous run's log is kept as tor.log.prev"
  tp_pm exec "$TP_CTR" sh -c 'echo marker-of-the-run-before-the-restart >>/app/data/tor.log'
  tp_pm restart -t 5 "$TP_CTR"
  assert_rc 0 "$TP_RC" "the container restarts on the same data: $TP_OUT"
  tp_wait_file /app/data/tor.log.prev 30 'marker-of-the-run-before-the-restart'
  assert_rc 0 "$?" "a container restart keeps the run before it as tor.log.prev"
}

# tp_wait_file <path> <seconds> [ERE]: wait until the file exists in the
# container (and, if given, has a line matching ERE).
tp_wait_file() {
  local i=0 max=$(( $2 * 2 ))
  while [ "$i" -lt "$max" ]; do
    tp_pm exec "$TP_CTR" cat "$1"
    if [ "$TP_RC" -eq 0 ] && { [ -z "${3:-}" ] || printf '%s\n' "$TP_OUT" | grep -Eq -- "$3"; }; then return 0; fi
    i=$((i + 1)); sleep 0.5
  done
  return 1
}

tp_field() { printf '%s\n' "$2" | awk -F '\t' -v k="$1" '$1 == k { print $2; exit }'; }

tp_request() {
  # shellcheck disable=SC2016
  tp_pm exec "$TP_CTR" sh -c 'printf "%s\n" "$1" >/app/data/control/tor-restart-request.tmp && mv /app/data/control/tor-restart-request.tmp /app/data/control/tor-restart-request' sh "$1"
  assert_rc 0 "$TP_RC" "restart request written: $TP_OUT"
}

tp_pid_of() { tp_pm exec "$TP_CTR" pidof "$1"; printf '%s\n' "$TP_OUT"; }

# tp_healthcheck_rc: run the image's own HEALTHCHECK in the running container
# (podman healthcheck run); TP_RC is its verdict (0 healthy). Fails the case
# when the image's healthcheck is not the verifying route probe, so
# "unhealthy" can never be an error about a missing or unverified check.
tp_healthcheck_rc() {
  local hc
  hc="$(podman image inspect -f '{{.Config.Healthcheck}}' "$TP_IMG" 2>/dev/null | grep -v -- "$TP_WARN")"
  assert_match 'nice-dns-route-probe' "$hc" "image $TP_IMG carries its HEALTHCHECK, the verifying route probe ($hc)"
  tp_pm healthcheck run "$TP_CTR"
}

# tp_slow_start <delay seconds>: a TCP responder on 127.0.0.1 inside the
# namespace that answers each chunk it reads with "PONG:<chunk>" after the
# delay, keeping the connection open (a slow Tor round trip on a reused
# upstream session). Sets TP_SLOW_PORT. Stopped by the namespace teardown and
# its own 600 s limit.
tp_slow_start() {
  local d="$CASE_DIR/slow" i=0
  mkdir -m 700 "$d" || fail "cannot create $d"
  # shellcheck disable=SC2016
  podman unshare nsenter -t "$TP_NSPID" -n python3 -c '
import os, socket, sys, threading, time
delay, state = float(sys.argv[1]), sys.argv[2]
def serve(c):
    try:
        while True:
            data = c.recv(256)
            if not data:
                return
            time.sleep(delay)
            c.sendall(b"PONG:" + data)
    except OSError:
        pass
    finally:
        c.close()
def watchdog(owner=os.getppid(), end=time.monotonic() + 600):
    while os.getppid() == owner and time.monotonic() < end:
        time.sleep(0.5)
    os._exit(0)
threading.Thread(target=watchdog, daemon=True).start()
s = socket.socket()
s.bind(("127.0.0.1", 0))
s.listen(16)
open(os.path.join(state, "port"), "w").write("%d\n" % s.getsockname()[1])
while True:
    c, _ = s.accept()
    threading.Thread(target=serve, args=(c,), daemon=True).start()
' "$1" "$d" >"$d/log" 2>&1 </dev/null &
  while [ ! -s "$d/port" ]; do
    i=$((i + 1))
    [ "$i" -le 200 ] || fail "slow responder did not start: $(cat "$d/log")"
    sleep 0.05
  done
  TP_SLOW_PORT="$(cat "$d/port")"
}

# tp_exchange_twice <port> <idle seconds>: on ONE connection, send "A" and
# wait up to 15 s for PONG:A, stay idle, then send "B" and wait for PONG:B.
# TP_OUT is what came back ("PONG:A PONG:B" when both arrived).
tp_exchange_twice() {
  # shellcheck disable=SC2016
  tp_ns python3 -c '
import socket, sys, time
s = socket.create_connection(("127.0.0.1", int(sys.argv[1])), timeout=5)
got = []
for msg, pause in ((b"A", 0), (b"B", float(sys.argv[2]))):
    time.sleep(pause)
    try:
        s.sendall(msg)
        s.settimeout(15)
        got.append(s.recv(64).decode() or "EOF")
    except OSError as e:
        got.append("ERR:%s" % type(e).__name__)
print(" ".join(got))' "$1" "$2"
}
