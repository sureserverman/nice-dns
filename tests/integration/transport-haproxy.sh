# shellcheck shell=bash
# Group integration/transport-haproxy (sub-plan 02, Task 1.2; ARCH-04,
# ARCH-08, ARCH-09).
#
# Proves the tor-haproxy image's route contract on the ACTUAL image, built
# from the sibling checkout (${NICE_DNS_SIBLINGS_DIR:-..}/tor-haproxy):
#
#   port   route              SOCKS destinations (provider)
#   18531  cloudflare-onion   10.192.0.1:853 (Tor MapAddress -> Cloudflare .onion)
#   18532  cloudflare-exit    1.1.1.1:853, 1.0.0.1:853 (Cloudflare, Tor exit)
#   18533  quad9-exit         9.9.9.9:853, 149.112.112.112:853 (Quad9, Tor exit)
#   853    legacy             onion preferred, Cloudflare exit backup; no Quad9
#
# Tor is replaced by tests/fixtures/socksfixture.py on 127.0.0.1:9050 inside
# a --network none namespace, so every "destination" is only recorded. Each
# stream carries a unique marker; the fixture logs marker and destination.
# The supervision cases run the image's own start.sh with a stand-in `tor`
# (a script that logs "Bootstrapped 100%" and waits) mounted over /usr/bin/tor.
#
# Restart contract (start.sh): the host writes a request id to
# /app/data/control/tor-restart-request; the image restarts only tor and answers in
# /app/data/control/tor-restart-ack (request_id, status, generation, tor_pid, utc).
# /app/data/control/tor-generation always names the current tor generation and pid.
# Readiness is a later, separate observation.

# shellcheck source=tests/fixtures/transport.sh
. "$NICE_DNS_ROOT/tests/fixtures/transport.sh"

TH_ROUTES="18531 18532 18533"

th_provider_set() {
  case "$1" in
    18531) printf '10.192.0.1:853\n' ;;
    18532) printf '1.0.0.1:853\n1.1.1.1:853\n' ;;
    18533) printf '149.112.112.112:853\n9.9.9.9:853\n' ;;
    853) printf '1.1.1.1:853\n10.192.0.1:853\n' ;;
  esac
}

# th_haproxy: the image's haproxy with the image's config, in the namespace,
# with the SOCKS fixture standing in for Tor.
th_haproxy() {
  tp_holder
  tp_socks_start
  tp_run haproxy --entrypoint /usr/sbin/haproxy "$TP_IMG" -f /etc/haproxy/haproxy.cfg -db
  tp_wait_listen 853 20 || fail "haproxy never listened on 853: $(podman logs "$TP_CTR" 2>&1 | tail -n 20)"
}

th_admin() {
  # shellcheck disable=SC2016
  tp_pm exec "$TP_CTR" sh -c 'printf "%s\n" "$1" | socat -t 5 - UNIX-CONNECT:/tmp/haproxy.sock' sh "$1"
}

# th_backend_addrs <backend>: sorted "addr:port" of its servers, from the
# running haproxy (show servers state, format version 1 as printed by haproxy
# 3.2: $2 be_name, $5 srv_addr, $19 srv_port). A changed layout fails the
# equality asserts; it cannot pass vacuously.
th_backend_addrs() {
  th_admin "show servers state $1"
  printf '%s\n' "$TP_OUT" | awk -v b="$1" '$2 == b { print $5 ":" $19 }' | LC_ALL=C sort -u
}

t_config_is_valid() {
  tp_setup tor-haproxy
  tp_pm run --rm --health-interval=disable --network none --entrypoint /usr/sbin/haproxy "$TP_IMG" -c -f /etc/haproxy/haproxy.cfg
  assert_rc 0 "$TP_RC" "haproxy -c accepts the image config: $TP_OUT"
  # Negative control: the same check rejects a broken config (haproxy 3.x
  # prints nothing on success, so the exit status is the signal).
  tp_pm run --rm --health-interval=disable --network none --entrypoint /bin/sh "$TP_IMG" -c \
    'cp /etc/haproxy/haproxy.cfg /tmp/bad.cfg && echo "backend broken" >>/tmp/bad.cfg && echo "    server x" >>/tmp/bad.cfg && haproxy -c -f /tmp/bad.cfg'
  assert_nonzero "$TP_RC" "haproxy -c rejects a broken copy of the config"
}

t_route_ports_unused_before_and_bound_after_start() {
  local p
  tp_setup tor-haproxy
  tp_holder
  tp_ns ss -Hltn
  for p in $TH_ROUTES; do
    assert_not_match ":$p([^0-9]|\$)" "$TP_OUT" "port $p is free in the fresh namespace"
  done
  tp_socks_start
  tp_run haproxy --entrypoint /usr/sbin/haproxy "$TP_IMG" -f /etc/haproxy/haproxy.cfg -db
  for p in 853 $TH_ROUTES; do
    tp_wait_listen "$p" 20
    assert_rc 0 "$?" "haproxy listens on $p"
  done
  tp_ns ss -Hltnp
  for p in $TH_ROUTES; do
    assert_match "\\*:$p |0\\.0\\.0\\.0:$p " "$TP_OUT" "route $p listens on every address (macOS reaches it on the container IP)"
  done
}

t_route_backends_hold_only_their_provider() {
  tp_setup tor-haproxy
  th_haproxy
  assert_eq "$(th_provider_set 18531)" "$(th_backend_addrs route_cloudflare_onion)" "cloudflare-onion backend servers"
  assert_eq "$(th_provider_set 18532)" "$(th_backend_addrs route_cloudflare_exit)" "cloudflare-exit backend servers"
  assert_eq "$(th_provider_set 18533)" "$(th_backend_addrs route_quad9_exit)" "quad9-exit backend servers"
}

t_status_summary_reports_every_backend_each_interval() {
  # BL-003 (Sub-plan 3 Task 2.3): one "backends ..." line per interval with
  # the legacy servers, its sessions and every route backend's sessions, each
  # field one word. NICE_DNS_SUMMARY_SECS=2 stands in for the 60 s default;
  # the live controller-shadow group measures the real cadence.
  local lines re
  tp_setup tor-haproxy
  tp_holder
  tp_socks_start
  tp_run haproxy -e NICE_DNS_SUMMARY_SECS=2 --entrypoint /usr/sbin/haproxy "$TP_IMG" -f /etc/haproxy/haproxy.cfg -db
  tp_wait_listen 853 20 || fail "haproxy never listened on 853: $(podman logs "$TP_CTR" 2>&1 | tail -n 20)"
  sleep 7
  lines="$(podman logs "$TP_CTR" 2>&1 | grep '^backends ')"
  re='^backends primary=[A-Za-z_]+[^ ]* backup=[A-Za-z_]+[^ ]* sessions=[0-9]+ routes=cloudflare-onion/[0-9]+,cloudflare-exit/[0-9]+,quad9-exit/[0-9]+$'
  [ "$(printf '%s\n' "$lines" | grep -c .)" -ge 2 ] || fail "at least two summary lines in 7 s at a 2 s interval; got: $lines"
  assert_eq "" "$(printf '%s\n' "$lines" | grep -vE "$re")" "every summary line has the stable one-word-per-field shape (got: $lines)"
  assert_match '^[1-9][0-9]*$' "$(grep -c 'NICE_DNS_SUMMARY_SECS' "$TP_SRC/status-summary.lua")" "the interval override is the image's own"
  assert_match 'return 60$' "$(grep -E '^[[:space:]]*return 60$' "$TP_SRC/status-summary.lua")" "the default interval is 60 s"
}

t_each_route_reaches_only_its_provider() {
  local p i got
  tp_setup tor-haproxy
  th_haproxy
  tp_socks_mode accept
  for p in $TH_ROUTES; do
    for i in 1 2 3 4 5 6; do tp_send "$p" "M-$p-$i"; done
  done
  for p in $TH_ROUTES; do
    got="$(for i in 1 2 3 4 5 6; do tp_dests "M-$p-$i"; done | LC_ALL=C sort -u)"
    assert_ne "" "$got" "route $p carried its streams through SOCKS"
    assert_eq "" "$(printf '%s\n' "$got" | grep -vxF -f <(th_provider_set "$p"))" "route $p reached only its provider (got: $got)"
  done
}

t_route_never_switches_provider_when_its_provider_fails() {
  local p i ips
  tp_setup tor-haproxy
  th_haproxy
  for p in $TH_ROUTES; do
    # This provider's destinations are refused; every other destination is
    # accepted and logs its payload, so a switched stream would show here.
    ips="$(th_provider_set "$p" | cut -d: -f1 | tr '\n' ' ')"
    # shellcheck disable=SC2086  # one word per IP
    tp_socks_mode reject $ips
    for i in 1 2 3; do tp_send "$p" "F-$p-$i"; done
    sleep 1
    for i in 1 2 3; do
      assert_eq "" "$(tp_dests "F-$p-$i")" "route $p stream $i went nowhere else while its provider failed"
    done
    assert_match "reject" "$(awk -F '\t' '$4 == "reject"' "$TP_SOCKS/connects.tsv")" "route $p attempts reached the refusing provider"
  done
}

t_legacy_853_is_cloudflare_only() {
  local i got
  tp_setup tor-haproxy
  th_haproxy
  assert_eq "$(th_provider_set 853)" "$(th_backend_addrs dns_resolvers)" "legacy backend holds only the Cloudflare onion and Cloudflare exit"
  tp_socks_mode reject 10.192.0.1 1.1.1.1
  for i in 1 2 3; do tp_send 853 "L-$i"; done
  sleep 1
  for i in 1 2 3; do
    assert_eq "" "$(tp_dests "L-$i")" "legacy stream $i did not fall over to another provider"
  done
}

t_route_frontends_are_bounded() {
  local fe slim
  tp_setup tor-haproxy
  th_haproxy
  th_admin "show stat"
  for fe in fe_route_cloudflare_onion fe_route_cloudflare_exit fe_route_quad9_exit dns_dot; do
    slim="$(printf '%s\n' "$TP_OUT" | awk -F, -v f="$fe" '$1 == f && $2 == "FRONTEND" { print $7 }')"
    assert_match '^[1-9][0-9]*$' "$slim" "frontend $fe reports a connection limit (slim=$slim)"
    # haproxy always reports some limit (its global default when none is
    # configured), so require an explicit, small one.
    [ "$slim" -le 1024 ] 2>/dev/null
    assert_rc 0 "$?" "frontend $fe is bounded by an explicit maxconn <= 1024 (slim=$slim)"
  done
}

# ─────────────────────────── supervision (start.sh) ──────────────────────────

t_restart_request_acknowledged_with_new_generation() {
  local gen0 pid0 hap0 ack
  tp_setup tor-haproxy
  tp_supervised
  gen0="$(tp_field generation "$TP_OUT")"; pid0="$(tp_field tor_pid "$TP_OUT")"
  assert_eq 1 "$gen0" "first tor is generation 1"
  assert_match '^[1-9][0-9]*$' "$pid0" "generation file names the tor pid"
  # haproxy starts once a stream works (Sub-plan 5 Task 1.4, fix B), a second
  # or two after the generation file.
  tp_wait_listen 853 20 || fail "haproxy never listened on 853: $(podman logs "$TP_CTR" 2>&1 | tail -n 20)"
  hap0="$(tp_pid_of haproxy)"
  assert_match '^[1-9]' "$hap0" "haproxy runs"
  tp_request req-ack-1
  tp_wait_file /app/data/control/tor-restart-ack 40 '^request_id	req-ack-1$' || fail "no acknowledgement for req-ack-1: $(podman logs "$TP_CTR" 2>&1 | tail -n 20)"
  ack="$TP_OUT"
  assert_eq respawned "$(tp_field status "$ack")" "request acknowledged as a respawn"
  assert_eq 2 "$(tp_field generation "$ack")" "the acknowledgement carries the new generation"
  assert_ne "$pid0" "$(tp_field tor_pid "$ack")" "a new tor process"
  assert_match '^[1-9][0-9]*$' "$(tp_field tor_pid "$ack")" "the new tor pid is recorded"
  assert_eq "$hap0" "$(tp_pid_of haproxy)" "haproxy kept running across the tor restart"
  tp_wait_file /app/data/control/tor-generation 5 '^generation	2$'
  assert_rc 0 "$?" "the generation file follows the acknowledgement"
  tp_pm exec "$TP_CTR" test -e /app/data/control/tor-restart-request
  assert_nonzero "$TP_RC" "the request was consumed"
}

t_invalid_restart_request_rejected() {
  local pid0
  tp_setup tor-haproxy
  tp_supervised
  pid0="$(tp_field tor_pid "$TP_OUT")"
  tp_request 'bad id; rm -rf /'
  tp_wait_file /app/data/control/tor-restart-rejected 30 '^status	rejected$' || fail "no rejection record: $(podman logs "$TP_CTR" 2>&1 | tail -n 20)"
  assert_eq 1 "$(tp_field generation "$TP_OUT")" "a rejected request does not start a generation"
  assert_eq invalid "$(tp_field request_id "$TP_OUT")" "the unsafe id is not echoed back"
  tp_pm exec "$TP_CTR" test -e /app/data/control/tor-restart-ack
  assert_nonzero "$TP_RC" "a rejection never writes the acknowledgement file"
  # "legacy" is reserved for the flag interface's acknowledgements.
  tp_pm exec "$TP_CTR" rm -f /app/data/control/tor-restart-rejected
  tp_request legacy
  tp_wait_file /app/data/control/tor-restart-rejected 30 '^status	rejected$'
  assert_rc 0 "$?" "a request that claims the reserved id legacy is rejected"
  sleep 6
  tp_wait_file /app/data/control/tor-generation 2
  assert_eq "$pid0" "$(tp_field tor_pid "$TP_OUT")" "tor was not restarted"
}

t_legacy_restart_flag_acknowledged() {
  tp_setup tor-haproxy
  tp_supervised
  tp_pm exec "$TP_CTR" touch /tmp/tor-restart-flag
  tp_wait_file /app/data/control/tor-restart-ack 40 '^request_id	legacy$' || fail "no acknowledgement for the legacy flag: $(podman logs "$TP_CTR" 2>&1 | tail -n 20)"
  assert_eq respawned "$(tp_field status "$TP_OUT")" "legacy flag restarts tor"
  assert_eq 2 "$(tp_field generation "$TP_OUT")" "legacy restart advances the generation"
}

t_unrequested_tor_exit_tears_container_down() {
  local rc
  tp_setup tor-haproxy
  tp_supervised
  tp_pm exec "$TP_CTR" pkill -x tor
  rc="$(timeout 30 podman wait "$TP_CTR" 2>/dev/null | grep -E '^[0-9]+$' | tail -1)"
  assert_match '^[0-9]+$' "$rc" "the container exited after tor died unrequested"
  assert_ne 0 "$rc" "an unrequested tor exit is a failure exit"
}

t_image_healthcheck_fails_when_upstream_drops_streams() {
  # Every SOCKS destination refused: haproxy accepts the client's TCP
  # connection and then closes it. dig +tls exits 0 on that, so a healthcheck
  # trusting dig's exit status reported a dead chain healthy.
  tp_setup tor-haproxy
  tp_supervised
  tp_wait_listen 853 30 || fail "haproxy never listened on 853"
  tp_socks_mode reject
  tp_healthcheck_rc
  assert_nonzero "$TP_RC" "the image healthcheck reports unhealthy when no upstream answers ($TP_OUT)"
  assert_match 'unhealthy' "$TP_OUT" "podman's verdict is unhealthy, not an error"
}

t_route_carries_slow_answers_and_idle_reuse() {
  # A Tor round trip of several seconds, then the same upstream session
  # reused after an idle gap (Unbound keeps DoT sessions for 120 s). An
  # inactivity timeout shorter than either drops a valid answer.
  tp_setup tor-haproxy
  tp_supervised
  tp_wait_listen 18532 30 || fail "no route listener"
  tp_slow_start 5
  tp_socks_mode relay "$TP_SLOW_PORT"
  tp_exchange_twice 18532 25
  assert_eq "PONG:A PONG:B" "$TP_OUT" "a 5 s answer, then a reuse after 25 s idle, both arrive through the route"
}

t_restart_control_is_private_to_the_image_user() {
  # Only the image's own user can request a restart or write its answers:
  # the control files live in a 0700 directory, not in the shared /tmp,
  # and /tmp carries the sticky bit.
  tp_setup tor-haproxy
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

t_stop_ends_every_child_promptly() {
  # SIGTERM reaches start.sh through tini; its cleanup must end tor, haproxy,
  # the probe and the watcher so the runtime never needs SIGKILL.
  local rc t0 t1
  tp_setup tor-haproxy
  tp_supervised
  tp_wait_listen 853 30 || fail "haproxy never listened on 853"
  t0="$(date +%s)"
  podman stop -t 15 "$TP_CTR" >/dev/null 2>&1
  t1="$(date +%s)"
  rc="$(podman inspect -f '{{.State.ExitCode}}' "$TP_CTR" 2>/dev/null)"
  assert_ne 137 "$rc" "the container stopped without SIGKILL"
  assert_match '^([0-9]|1[0-3])$' "$((t1 - t0))" "stop completed before the kill deadline ($((t1 - t0))s)"
}

t_primary_probe_measures_milliseconds() {
  # probe-primary.sh times a SOCKS connect to the .onion and compares it with
  # SLOW_THRESHOLD_MS. The stand-in Tor grants each stream after 1.5 s, so
  # the probe must report about 1500 ms (busybox date has no sub-second
  # format: a date-based timer reports 1 or 2 and never counts as slow).
  local line t i=0
  tp_setup tor-haproxy
  tp_holder
  tp_socks_start
  tp_socks_mode delay 1.5
  tp_supervised -e PROBE_INTERVAL_S=1 -e SLOW_THRESHOLD_MS=1000
  while [ "$i" -lt 60 ]; do
    line="$(podman logs "$TP_CTR" 2>&1 | grep -E '^primary-probe t=[0-9]+ms' | tail -n 1)"
    [ -n "$line" ] && break
    i=$((i + 1)); sleep 0.5
  done
  assert_match '^primary-probe t=[0-9]+ms' "$line" "the primary probe logged a timing"
  t="$(printf '%s\n' "$line" | sed -n 's/^primary-probe t=\([0-9]*\)ms.*/\1/p')"
  [ "$t" -ge 1200 ] && [ "$t" -le 5000 ] || fail "primary probe reported t=${t}ms for a 1.5 s SOCKS grant (not milliseconds)"
  assert_match 'streak=slow/' "$line" "a 1.5 s connect is slow against a 1000 ms threshold"
}

# Sub-plan 5 Task 1.4 (fix B): readiness is a working stream; Tor's log is kept.
t_readiness_waits_for_a_working_stream() { tp_readiness_case tor-haproxy; }
t_tor_log_is_kept_on_the_data_volume() { tp_torlog_case tor-haproxy; }
t_readiness_through_the_onion_alone() { tp_readiness_onion_case tor-haproxy; }
t_stop_during_a_stall_is_prompt() { tp_stop_during_stall_case tor-haproxy; }
t_restart_request_during_a_stall_is_acknowledged() { tp_restart_during_stall_case tor-haproxy; }
