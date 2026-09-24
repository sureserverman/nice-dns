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
# /tmp/tor-restart-request; the image restarts only tor and answers in
# /tmp/tor-restart-ack (request_id, status, generation, tor_pid, utc).
# /tmp/tor-generation always names the current tor generation and pid.
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
  for fe in route_cloudflare_onion route_cloudflare_exit route_quad9_exit dns_dot; do
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
  hap0="$(tp_pid_of haproxy)"
  assert_match '^[1-9]' "$hap0" "haproxy runs"
  tp_request req-ack-1
  tp_wait_file /tmp/tor-restart-ack 40 '^request_id	req-ack-1$' || fail "no acknowledgement for req-ack-1: $(podman logs "$TP_CTR" 2>&1 | tail -n 20)"
  ack="$TP_OUT"
  assert_eq respawned "$(tp_field status "$ack")" "request acknowledged as a respawn"
  assert_eq 2 "$(tp_field generation "$ack")" "the acknowledgement carries the new generation"
  assert_ne "$pid0" "$(tp_field tor_pid "$ack")" "a new tor process"
  assert_match '^[1-9][0-9]*$' "$(tp_field tor_pid "$ack")" "the new tor pid is recorded"
  assert_eq "$hap0" "$(tp_pid_of haproxy)" "haproxy kept running across the tor restart"
  tp_wait_file /tmp/tor-generation 5 '^generation	2$'
  assert_rc 0 "$?" "the generation file follows the acknowledgement"
  tp_pm exec "$TP_CTR" test -e /tmp/tor-restart-request
  assert_nonzero "$TP_RC" "the request was consumed"
}

t_invalid_restart_request_rejected() {
  local pid0
  tp_setup tor-haproxy
  tp_supervised
  pid0="$(tp_field tor_pid "$TP_OUT")"
  tp_request 'bad id; rm -rf /'
  tp_wait_file /tmp/tor-restart-ack 30 '^status	rejected$' || fail "no rejection acknowledgement: $(podman logs "$TP_CTR" 2>&1 | tail -n 20)"
  assert_eq 1 "$(tp_field generation "$TP_OUT")" "a rejected request does not start a generation"
  assert_eq invalid "$(tp_field request_id "$TP_OUT")" "the unsafe id is not echoed back"
  # "legacy" is reserved for the flag interface's acknowledgements.
  tp_pm exec "$TP_CTR" rm -f /tmp/tor-restart-ack
  tp_request legacy
  tp_wait_file /tmp/tor-restart-ack 30 '^status	rejected$'
  assert_rc 0 "$?" "a request that claims the reserved id legacy is rejected"
  sleep 6
  tp_wait_file /tmp/tor-generation 2
  assert_eq "$pid0" "$(tp_field tor_pid "$TP_OUT")" "tor was not restarted"
}

t_legacy_restart_flag_acknowledged() {
  tp_setup tor-haproxy
  tp_supervised
  tp_pm exec "$TP_CTR" touch /tmp/tor-restart-flag
  tp_wait_file /tmp/tor-restart-ack 40 '^request_id	legacy$' || fail "no acknowledgement for the legacy flag: $(podman logs "$TP_CTR" 2>&1 | tail -n 20)"
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
