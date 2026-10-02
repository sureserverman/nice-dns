# shellcheck shell=bash
# Group integration/transport-socat (sub-plan 02, Task 1.3; ARCH-04, ARCH-08,
# ARCH-09). The tor-socat image must offer the same route contract as
# tor-haproxy (integration/transport-haproxy):
#
#   port   route              SOCKS4A destination (provider)
#   18531  cloudflare-onion   dns4torpnlfs...zgqad.onion:853 (Cloudflare .onion)
#   18532  cloudflare-exit    1.1.1.1:853 (Cloudflare, Tor exit)
#   18533  quad9-exit         9.9.9.9:853 (Quad9, Tor exit)
#   853    legacy             onion, then Cloudflare exit; never Quad9
#
# and the same acknowledged tor restart (/app/data/control/tor-restart-request ->
# /app/data/control/tor-restart-ack, /app/data/control/tor-generation). Every case runs the image's own
# start.sh with a stand-in tor, and tests/fixtures/socksfixture.py in place
# of Tor's SocksPort inside a --network none namespace: destinations are only
# recorded. LEGACY_CHECK_INTERVAL / LEGACY_FAIL_THRESHOLD / LEGACY_RETRY_DELAY
# shorten the legacy tier loop so its failover order is observable.

# shellcheck source=tests/fixtures/transport.sh
. "$NICE_DNS_ROOT/tests/fixtures/transport.sh"

TS_ROUTES="18531 18532 18533"
TS_ONION=dns4torpnlfs2ifuz2s2yf3fc7rdmsbhm6rw75euj35pac6ap25zgqad.onion

ts_provider_set() {
  case "$1" in
    18531) printf '%s:853\n' "$TS_ONION" ;;
    18532) printf '1.0.0.1:853\n1.1.1.1:853\n' ;;
    18533) printf '149.112.112.112:853\n9.9.9.9:853\n' ;;
  esac
}

ts_up() {
  tp_setup tor-socat
  tp_supervised "$@"
  local p
  for p in 853 $TS_ROUTES; do
    tp_wait_listen "$p" 30 || fail "tor-socat never listened on $p: $(podman logs "$TP_CTR" 2>&1 | tail -n 20)"
  done
}

t_route_ports_unused_before_and_bound_after_start() {
  local p
  tp_setup tor-socat
  tp_holder
  tp_ns ss -Hltn
  for p in $TS_ROUTES; do
    assert_not_match ":$p([^0-9]|\$)" "$TP_OUT" "port $p is free in the fresh namespace"
  done
  tp_supervised
  for p in 853 $TS_ROUTES; do
    tp_wait_listen "$p" 30
    assert_rc 0 "$?" "tor-socat listens on $p"
  done
  tp_ns ss -Hltn
  for p in $TS_ROUTES; do
    assert_match "\\*:$p |0\\.0\\.0\\.0:$p " "$TP_OUT" "route $p listens on every address (macOS reaches it on the container IP)"
  done
}

t_each_route_reaches_only_its_provider() {
  local p i got
  ts_up
  tp_socks_mode accept
  for p in $TS_ROUTES; do
    for i in 1 2 3 4; do tp_send "$p" "M-$p-$i"; done
  done
  for p in $TS_ROUTES; do
    got="$(for i in 1 2 3 4; do tp_dests "M-$p-$i"; done | LC_ALL=C sort -u)"
    assert_ne "" "$got" "route $p carried its streams through SOCKS"
    assert_eq "" "$(printf '%s\n' "$got" | grep -vxF -f <(ts_provider_set "$p"))" "route $p reached only its provider (got: $got)"
  done
}

t_route_never_switches_provider_when_its_provider_fails() {
  local p i dests
  ts_up
  for p in $TS_ROUTES; do
    dests="$(ts_provider_set "$p" | cut -d: -f1 | tr '\n' ' ')"
    # shellcheck disable=SC2086  # one word per destination
    tp_socks_mode reject $dests
    for i in 1 2 3; do tp_send "$p" "F-$p-$i"; done
    sleep 1
    for i in 1 2 3; do
      assert_eq "" "$(tp_dests "F-$p-$i")" "route $p stream $i went nowhere else while its provider failed"
    done
  done
  assert_match "reject" "$(awk -F '\t' '$4 == "reject"' "$TP_SOCKS/connects.tsv")" "route attempts reached the refusing providers"
}

t_legacy_853_fails_over_within_cloudflare_only() {
  # Every destination refused: the legacy tier loop walks its whole failover
  # order and starts again. It must reach the Cloudflare exit and wrap back to
  # the onion without ever asking for Quad9.
  local i first_backup wrapped=""
  ts_up -e LEGACY_CHECK_INTERVAL=1 -e LEGACY_FAIL_THRESHOLD=1 -e LEGACY_RETRY_DELAY=1
  tp_socks_mode reject
  i=0
  while [ "$i" -lt 90 ]; do
    first_backup="$(awk -F '\t' '$2 == "1.1.1.1" && $3 == 853 { print NR; exit }' "$TP_SOCKS/connects.tsv")"
    if [ -n "$first_backup" ]; then
      wrapped="$(awk -F '\t' -v n="$first_backup" -v o="$TS_ONION" 'NR > n && $2 == o { print NR; exit }' "$TP_SOCKS/connects.tsv")"
      [ -n "$wrapped" ] && break
    fi
    i=$((i + 1)); sleep 1
  done
  assert_ne "" "$first_backup" "the legacy loop failed over to the Cloudflare exit"
  assert_ne "" "$wrapped" "the legacy loop exhausted its order and wrapped back to the onion"
  assert_eq "" "$(awk -F '\t' '$2 == "9.9.9.9" || $2 == "149.112.112.112"' "$TP_SOCKS/connects.tsv")" "legacy 853 never asked for Quad9"
}

t_route_listeners_are_bounded() {
  local p line n
  ts_up
  tp_pm exec "$TP_CTR" ps -o args
  for p in 853 $TS_ROUTES; do
    line="$(printf '%s\n' "$TP_OUT" | grep -E "^socat .*TCP4-LISTEN:$p," | head -1)"
    assert_ne "" "$line" "a socat listener for $p runs"
    n="$(printf '%s\n' "$line" | sed -n 's/.*max-children=\([0-9]*\).*/\1/p')"
    assert_match '^[1-9][0-9]*$' "$n" "listener $p caps its children (max-children=$n)"
    [ "$n" -le 1024 ]
    assert_rc 0 "$?" "listener $p cap is at most 1024 ($n)"
    assert_match '(^| )-T ?[0-9]+' "$line" "listener $p has an inactivity timeout"
  done
}

t_restart_request_acknowledged_with_new_generation() {
  local gen0 pid0 socat0 ack
  ts_up
  tp_wait_file /app/data/control/tor-generation 5
  gen0="$(tp_field generation "$TP_OUT")"; pid0="$(tp_field tor_pid "$TP_OUT")"
  assert_eq 1 "$gen0" "first tor is generation 1"
  assert_match '^[1-9][0-9]*$' "$pid0" "generation file names the tor pid"
  socat0="$(tp_pid_of socat | tr ' ' '\n' | LC_ALL=C sort | tr '\n' ' ')"
  assert_match '[1-9]' "$socat0" "socat listeners run"
  tp_request req-ack-1
  tp_wait_file /app/data/control/tor-restart-ack 40 '^request_id	req-ack-1$' || fail "no acknowledgement for req-ack-1: $(podman logs "$TP_CTR" 2>&1 | tail -n 20)"
  ack="$TP_OUT"
  assert_eq respawned "$(tp_field status "$ack")" "request acknowledged as a respawn"
  assert_eq 2 "$(tp_field generation "$ack")" "the acknowledgement carries the new generation"
  assert_ne "$pid0" "$(tp_field tor_pid "$ack")" "a new tor process"
  assert_eq "$socat0" "$(tp_pid_of socat | tr ' ' '\n' | LC_ALL=C sort | tr '\n' ' ')" "the socat listeners kept running across the tor restart"
  tp_pm exec "$TP_CTR" test -e /app/data/control/tor-restart-request
  assert_nonzero "$TP_RC" "the request was consumed"
}

t_invalid_restart_request_rejected() {
  local pid0
  ts_up
  tp_wait_file /app/data/control/tor-generation 5
  pid0="$(tp_field tor_pid "$TP_OUT")"
  tp_request 'bad id; rm -rf /'
  tp_wait_file /app/data/control/tor-restart-rejected 30 '^status	rejected$' || fail "no rejection record: $(podman logs "$TP_CTR" 2>&1 | tail -n 20)"
  assert_eq 1 "$(tp_field generation "$TP_OUT")" "a rejected request does not start a generation"
  assert_eq invalid "$(tp_field request_id "$TP_OUT")" "the unsafe id is not echoed back"
  tp_pm exec "$TP_CTR" test -e /app/data/control/tor-restart-ack
  assert_nonzero "$TP_RC" "a rejection never writes the acknowledgement file"
  tp_pm exec "$TP_CTR" rm -f /app/data/control/tor-restart-rejected
  tp_request legacy
  tp_wait_file /app/data/control/tor-restart-rejected 30 '^status	rejected$'
  assert_rc 0 "$?" "a request that claims the reserved id legacy is rejected"
  tp_wait_file /app/data/control/tor-generation 2
  assert_eq "$pid0" "$(tp_field tor_pid "$TP_OUT")" "tor was not restarted"
}

t_legacy_restart_flag_acknowledged() {
  ts_up
  tp_pm exec "$TP_CTR" touch /tmp/tor-restart-flag
  tp_wait_file /app/data/control/tor-restart-ack 40 '^request_id	legacy$' || fail "no acknowledgement for the legacy flag: $(podman logs "$TP_CTR" 2>&1 | tail -n 20)"
  assert_eq respawned "$(tp_field status "$TP_OUT")" "the legacy flag restarts tor"
  assert_eq 2 "$(tp_field generation "$TP_OUT")" "a legacy restart advances the generation"
}

t_unrequested_clean_tor_exit_fails_the_container() { tp_clean_exit_case tor-socat; }

t_unrequested_tor_exit_tears_container_down() {
  local rc
  ts_up
  tp_pm exec "$TP_CTR" pkill -x tor
  rc="$(timeout 30 podman wait "$TP_CTR" 2>/dev/null | grep -E '^[0-9]+$' | tail -1)"
  assert_match '^[0-9]+$' "$rc" "the container exited after tor died unrequested"
  assert_ne 0 "$rc" "an unrequested tor exit is a failure exit"
}

# Sub-plan 5 Task 2.1 (FQ-PROXY-CHILD-DEATH): any child the supervisor runs,
# not only tor, ends the container when it dies unrequested, so its runtime
# restarts the proxy whole instead of leaving a route without a listener.
t_unrequested_listener_exit_tears_container_down() {
  local rc
  ts_up
  tp_pm exec "$TP_CTR" pkill -f 'TCP4-LISTEN:18531'
  rc="$(timeout 30 podman wait "$TP_CTR" 2>/dev/null | grep -E '^[0-9]+$' | tail -1)"
  assert_match '^[0-9]+$' "$rc" "the container exited after the onion route's listener died"
  assert_ne 0 "$rc" "an unrequested listener exit is a failure exit"
  assert_match 'a socat listener, the legacy loop or the restart watcher exited' "$(podman logs "$TP_CTR" 2>&1)" "and says which kind of child"
}

t_stop_ends_every_child_promptly() {
  # SIGTERM reaches start.sh through tini; its cleanup must end tor, every
  # socat listener and the legacy loop (with its own socat) so the runtime
  # never needs SIGKILL.
  local rc t0 t1
  ts_up
  t0="$(date +%s)"
  podman stop -t 15 "$TP_CTR" >/dev/null 2>&1
  t1="$(date +%s)"
  rc="$(podman inspect -f '{{.State.ExitCode}}' "$TP_CTR" 2>/dev/null)"
  assert_ne 137 "$rc" "the container stopped without SIGKILL"
  [ $((t1 - t0)) -lt 14 ]
  assert_rc 0 "$?" "stop completed before the kill deadline ($((t1 - t0))s)"
}

t_image_healthcheck_fails_when_upstream_drops_streams() {
  # socat accepts the client's TCP connection, then the SOCKS refusal closes
  # it. dig +tls exits 0 on that, so a check trusting dig's exit status
  # reported a dead chain healthy (and the legacy failover never fired).
  ts_up
  tp_socks_mode reject
  tp_healthcheck_rc
  assert_nonzero "$TP_RC" "the image healthcheck reports unhealthy when no upstream answers ($TP_OUT)"
  assert_match 'unhealthy' "$TP_OUT" "podman's verdict is unhealthy, not an error"
}

t_route_carries_slow_answers_and_idle_reuse() {
  # A Tor round trip of several seconds, then the same upstream session
  # reused after an idle gap (Unbound keeps DoT sessions for 120 s). An
  # inactivity timeout shorter than either drops a valid answer.
  ts_up
  tp_slow_start 5
  tp_socks_mode relay "$TP_SLOW_PORT"
  tp_exchange_twice 18532 25
  assert_eq "PONG:A PONG:B" "$TP_OUT" "a 5 s answer, then a reuse after 25 s idle, both arrive through the route"
}

t_restart_control_is_private_to_the_image_user() {
  # Only the image's own user can request a restart or write its answers:
  # the control files live in a 0700 directory, not in the shared /tmp,
  # and /tmp carries the sticky bit.
  tp_setup tor-socat
  tp_supervised
  tp_pm exec "$TP_CTR" stat -c '%a %U %F' /app/data/control
  assert_eq '700 app directory' "$TP_OUT" "control directory is 0700 and owned by the image user"
  tp_pm exec "$TP_CTR" stat -c '%a' /tmp
  assert_eq 1777 "$TP_OUT" "/tmp has the sticky bit"
  tp_pm exec "$TP_CTR" sh -c 'printf "planted\n" >/tmp/tor-restart-request'
  sleep 7
  tp_pm exec "$TP_CTR" test -e /app/data/control/tor-restart-ack
  assert_nonzero "$TP_RC" "a request planted in /tmp is not honoured"
  tp_wait_file /app/data/control/tor-generation 2
  assert_eq 1 "$(tp_field generation "$TP_OUT")" "tor was not restarted by the planted request"
}

# Sub-plan 5 Task 1.4 (fix B): readiness is a working stream; Tor's log is kept.
t_readiness_waits_for_a_working_stream() { tp_readiness_case tor-socat; }
t_tor_log_is_kept_on_the_data_volume() { tp_torlog_case tor-socat; }
t_readiness_through_the_onion_alone() { tp_readiness_onion_case tor-socat; }
t_stop_during_a_stall_is_prompt() { tp_stop_during_stall_case tor-socat; }
t_restart_request_during_a_stall_is_acknowledged() { tp_restart_during_stall_case tor-socat; }
t_sleep_with_dead_streams_respawns_tor() { tp_suspend_respawn_case tor-socat; }
t_sleep_with_working_streams_keeps_tor() { tp_suspend_kept_case tor-socat; }
t_sleep_right_after_start_is_ignored() { tp_suspend_young_case tor-socat; }
t_clock_step_is_judged_by_running_time() { tp_suspend_clock_step_case tor-socat; }
t_sleep_check_survives_a_missing_generation_file() { tp_suspend_no_generation_case tor-socat; }
t_sleep_check_reads_the_bridges_and_is_bounded() { tp_suspend_bridges_case tor-socat; }
t_restart_request_during_the_sleep_check_is_served() { tp_suspend_request_case tor-socat; }
