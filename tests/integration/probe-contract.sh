# shellcheck shell=bash
# Group integration/probe-contract (sub-plan 02, Task 2.2; ARCH-05, ARCH-08,
# ARCH-09). Qualifies the probe INSTALLED in each candidate proxy image
# (/usr/local/bin/nice-dns-route-probe) and the interfaces the image
# declares:
#
#   nice-dns-route-probe PORT TLS_NAME [QNAME [QTYPE]]
#     --TLS--> route listener (haproxy / socat) --SOCKS--> stand-in Tor
#                                                            | relay
#                                                            v
#                            DoT fixture (good / wrongname / expired / untrusted)
#
# The probe must authenticate the route's TLS name against its CA store,
# read the DNS response code (NOERROR and NXDOMAIN are working transport,
# SERVFAIL/REFUSED are DNS errors, no response is no-answer) and travel the
# route it names (the stand-in Tor records each stream's destination and TLS
# SNI). The image HEALTHCHECK and tor-socat's legacy failover must decide
# with the same probe. The image labels must match what it listens on and
# nice-dns routes/providers.tsv; each case writes the capability receipt
# (capabilities.tsv) into its case dir.
#
# All in one --network none namespace; containers are nd-test-tp-<run id>-*.
# The test CA and TLS name reach the probe only through its documented
# environment (NICE_DNS_PROBE_CA, NICE_DNS_HEALTH_TLS_NAME,
# NICE_DNS_PROBE_QNAME). Only controlled fixture names are queried.

# shellcheck source=tests/fixtures/transport.sh
. "$NICE_DNS_ROOT/tests/fixtures/transport.sh"
# shellcheck source=tests/fixtures/fixture.sh
. "$NICE_DNS_ROOT/tests/fixtures/fixture.sh"

PC_PROBE=/usr/local/bin/nice-dns-route-probe
PC_ONION=dns4torpnlfs2ifuz2s2yf3fc7rdmsbhm6rw75euj35pac6ap25zgqad.onion

# pc_provider_set <proxy> <port>: destinations that listener may request.
pc_provider_set() {
  case "$2" in
    853) if [ "$1" = tor-haproxy ]; then printf '10.192.0.1:853\n1.1.1.1:853\n'; else printf '%s:853\n1.1.1.1:853\n' "$PC_ONION"; fi ;;
    18531) if [ "$1" = tor-haproxy ]; then printf '10.192.0.1:853\n'; else printf '%s:853\n' "$PC_ONION"; fi ;;
    18532) printf '1.0.0.1:853\n1.1.1.1:853\n' ;;
    18533) printf '149.112.112.112:853\n9.9.9.9:853\n' ;;
  esac
}

pc_cleanup() {
  [ -f "$CASE_DIR/fx/pypid" ] && kill "$(cat "$CASE_DIR/fx/pypid")" 2>/dev/null
  if [ -n "${PC_FX_WRAP:-}" ]; then kill "$PC_FX_WRAP" 2>/dev/null; wait "$PC_FX_WRAP" 2>/dev/null; fi
  tp_cleanup
}

# pc_stack <proxy repo> [podman run args]: namespace, DoT fixture with all
# certificate variants, stand-in Tor relaying to the good listener, and the
# image's own start.sh with the fixture CA and name in the probe environment.
# Background probes that also use SOCKS (haproxy's primary probe, socat's
# legacy check) run once an hour unless the caller overrides.
pc_stack() {
  local d="$CASE_DIR/fx" i=0 repo="$1" p
  shift
  tp_setup "$repo"
  PC_FX_WRAP=""
  trap pc_cleanup EXIT
  tp_holder
  mkdir -m 700 "$d" || fail "cannot create $d"
  python3 "$FX_PY" pki --out "$d/pki" >"$d/pki.log" 2>&1 || fail "fixture pki failed: $(cat "$d/pki.log")"
  chmod 644 "$d/pki/ca.pem"
  podman unshare nsenter -t "$TP_NSPID" -n sh -c 'echo $$ >"$1/pypid"; d=$1; shift; exec python3 "$@"' \
    sh "$d" "$FX_PY" serve --state "$d" --max-seconds "${FX_MAX_SECONDS:-600}" \
    --tls "good:$d/pki/good.pem:$d/pki/good.key" --tls "wrongname:$d/pki/wrongname.pem:$d/pki/wrongname.key" \
    --tls "expired:$d/pki/expired.pem:$d/pki/expired.key" --tls "untrusted:$d/pki/untrusted.pem:$d/pki/untrusted.key" \
    >"$d/fixture.log" 2>&1 </dev/null &
  PC_FX_WRAP=$!
  while [ ! -f "$d/ports.tsv" ]; do
    i=$((i + 1))
    [ "$i" -le 300 ] || fail "DoT fixture did not start: $(cat "$d/fixture.log")"
    sleep 0.05
  done
  tp_socks_start
  pc_relay good
  tp_supervised -v "$d/pki/ca.pem:/fx/ca.pem:ro" -e NICE_DNS_PROBE_CA=/fx/ca.pem \
    -e NICE_DNS_HEALTH_TLS_NAME=dns.fixture.test -e NICE_DNS_PROBE_QNAME=signed.fixture.test \
    -e PROBE_INTERVAL_S=3600 -e LEGACY_CHECK_INTERVAL=3600 "$@"
  for p in 853 18531 18532 18533; do
    tp_wait_listen "$p" 30 || fail "$repo never listened on $p: $(podman logs "$TP_CTR" 2>&1 | tail -n 20)"
  done
}

pc_relay() { tp_socks_mode relay "$(fx_port "$CASE_DIR/fx" "dot-$1")"; }

# pc_probe <port> <name> [qname]: the installed probe; TP_OUT its line, TP_RC its exit.
pc_probe() { tp_pm exec "$TP_CTR" "$PC_PROBE" "$@"; }

# pc_probe_dests: destinations of the probe's own sessions (its SNI), then clear the log.
pc_probe_dests() {
  awk -F '\t' -v s="sni:$1" '$4 == "relay" && $5 == s { print $2 ":" $3 }' "$TP_SOCKS/connects.tsv" | LC_ALL=C sort -u
  : >"$TP_SOCKS/connects.tsv"
}

# ─────────────────────────── probe behaviour ─────────────────────────────────

pc_authenticates_and_follows_route() {
  local p got
  pc_stack "$1"
  : >"$TP_SOCKS/connects.tsv"
  for p in 853 18531 18532 18533; do
    pc_probe "$p" dns.fixture.test signed.fixture.test
    assert_rc 0 "$TP_RC" "$1 probe on $p through an authenticated session: $TP_OUT"
    assert_match "^port=$p name=dns\\.fixture\\.test result=ok rcode=NOERROR ms=[0-9]+\$" "$TP_OUT" "$1 probe line on $p"
    got="$(pc_probe_dests dns.fixture.test)"
    assert_ne "" "$got" "$1 probe on $p travelled through SOCKS"
    assert_eq "" "$(printf '%s\n' "$got" | grep -vxF -f <(pc_provider_set "$1" "$p"))" "$1 probe on $p reached only that route's provider (got: $got)"
  done
  pc_probe 18532 dns.fixture.test "n$RANDOM.fixture.test"
  assert_rc 0 "$TP_RC" "a valid NXDOMAIN is working transport: $TP_OUT"
  assert_match 'result=ok rcode=NXDOMAIN' "$TP_OUT" "$1 probe reports NXDOMAIN as ok"
  pc_probe 18532 other.fixture.test signed.fixture.test
  assert_rc 1 "$TP_RC" "a certificate for another name is refused: $TP_OUT"
  assert_match 'result=no-answer rcode=-' "$TP_OUT" "$1 probe: name mismatch is no-answer"
}

pc_rejects_bad_certificates() {
  local v p
  pc_stack "$1"
  for v in wrongname expired untrusted; do
    pc_relay "$v"
    for p in 853 18532; do
      pc_probe "$p" dns.fixture.test signed.fixture.test
      assert_rc 1 "$TP_RC" "$1 probe on $p refuses a $v certificate: $TP_OUT"
      assert_match "^port=$p name=dns\\.fixture\\.test result=no-answer rcode=- " "$TP_OUT" "$1 probe line for $v on $p"
    done
  done
  # The system store alone does not trust the fixture CA.
  pc_relay good
  tp_pm exec "$TP_CTR" env -u NICE_DNS_PROBE_CA "$PC_PROBE" 18532 dns.fixture.test signed.fixture.test
  assert_rc 1 "$TP_RC" "$1 probe with the image CA store refuses the fixture CA: $TP_OUT"
}

pc_parses_dns_errors() {
  local ms
  pc_stack "$1"
  pc_probe 18533 dns.fixture.test servfail.fixture.test
  assert_rc 1 "$TP_RC" "SERVFAIL is not healthy: $TP_OUT"
  assert_match 'result=dns-error rcode=SERVFAIL' "$TP_OUT" "$1 probe reports SERVFAIL"
  pc_probe 18533 dns.fixture.test example.com
  assert_rc 1 "$TP_RC" "REFUSED is not healthy: $TP_OUT"
  assert_match 'result=dns-error rcode=REFUSED' "$TP_OUT" "$1 probe reports REFUSED"
  tp_pm exec "$TP_CTR" env NICE_DNS_PROBE_TIMEOUT=2 "$PC_PROBE" 18533 dns.fixture.test drop.fixture.test
  assert_rc 1 "$TP_RC" "an unanswered query is not healthy: $TP_OUT"
  assert_match 'result=no-answer rcode=-' "$TP_OUT" "$1 probe reports a dropped query as no-answer"
  tp_socks_mode reject
  pc_probe 18533 dns.fixture.test signed.fixture.test
  assert_rc 1 "$TP_RC" "a refused Tor stream is not healthy: $TP_OUT"
  assert_match 'result=no-answer rcode=-' "$TP_OUT" "$1 probe reports a dead route as no-answer"
  # ms is milliseconds: a Tor stream granted after 1.5 s reads as about 1500
  # (busybox date has no sub-second format; a date-based timer printed 1).
  tp_socks_mode delay 1.5
  pc_probe 18533 dns.fixture.test signed.fixture.test
  ms="$(printf '%s\n' "$TP_OUT" | sed -n 's/.* ms=\([0-9]*\).*/\1/p')"
  [ "${ms:-0}" -ge 1200 ] && [ "$ms" -le 6000 ] || fail "$1 probe ms=$ms for a 1.5 s Tor stream is not in milliseconds ($TP_OUT)"
  pc_probe 18533 dns.fixture.test 'bad name;x'
  assert_rc 2 "$TP_RC" "an unsafe query name is a usage error: $TP_OUT"
  pc_probe 0x35 dns.fixture.test
  assert_rc 2 "$TP_RC" "a non-numeric port is a usage error: $TP_OUT"
}

pc_bounds_a_silent_upstream() {
  # A frozen Tor: the listener accepts, the SOCKS stream is never granted.
  # NICE_DNS_PROBE_TIMEOUT bounds the whole probe (dig 9.20 applies +time per
  # stage, so a silent TLS peer took 3 x the timeout), and the verdict is
  # no-answer, which the host counts as unhealthy, never a host-deadline kill
  # (no verdict). Live evidence: Sub-plan 3 Task 2.3, mint, Tor SIGSTOPped.
  local t0 el
  pc_stack "$1"
  tp_socks_mode delay 120
  t0="$(date +%s)"
  tp_pm exec "$TP_CTR" env NICE_DNS_PROBE_TIMEOUT=3 "$PC_PROBE" 18532 dns.fixture.test signed.fixture.test
  el=$(( $(date +%s) - t0 ))
  assert_rc 1 "$TP_RC" "$1: a silent upstream is not healthy: $TP_OUT"
  assert_match 'result=no-answer rcode=- ms=[0-9]+ error=timeout$' "$TP_OUT" "$1: a silent upstream is no-answer, marked as the probe's own timeout"
  [ "$el" -le 5 ] || fail "$1: the probe took ${el} s with NICE_DNS_PROBE_TIMEOUT=3 ($TP_OUT)"
  assert_match '^[0-9]+$' "$(grep -c 'ND_HEALTH_PROBE_DEADLINE:-15' "$NICE_DNS_ROOT/lib/health.sh")" "the host deadline (15 s) stays above the probe's default bound (10 s)"
}

pc_healthcheck_uses_probe() {
  pc_stack "$1"
  tp_healthcheck_rc
  assert_rc 0 "$TP_RC" "$1 HEALTHCHECK passes through an authenticated legacy session: $TP_OUT"
  pc_relay wrongname
  tp_healthcheck_rc
  assert_nonzero "$TP_RC" "$1 HEALTHCHECK fails when the legacy session presents a wrong-name certificate"
  pc_relay untrusted
  tp_healthcheck_rc
  assert_nonzero "$TP_RC" "$1 HEALTHCHECK fails on an untrusted certificate"
  pc_relay good
  tp_healthcheck_rc
  assert_rc 0 "$TP_RC" "$1 HEALTHCHECK recovers with the good certificate: $TP_OUT"
}

# ─────────────────────────── capabilities ────────────────────────────────────

# pc_label <key>: an image label.
pc_label() { podman image inspect -f "{{index .Config.Labels \"$1\"}}" "$TP_IMG" 2>/dev/null | grep -v -- "$TP_WARN"; }

pc_capabilities() {
  local routes want listen fxports p r dig
  pc_stack "$1"
  assert_eq "nice-dns-transport/2" "$(pc_label org.nice-dns.transport.interface)" "$1 declares the transport interface version"
  routes="$(pc_label org.nice-dns.transport.routes)"
  want="$(awk -F '\t' '!/^#/ && NF == 5 && $1 != "schema" { print $1 "=" $2 }' "$NICE_DNS_ROOT/routes/providers.tsv" | LC_ALL=C sort | tr '\n' ' ' | sed 's/ $//')"
  assert_eq "$want" "$(printf '%s\n' "$routes" | tr ' ' '\n' | LC_ALL=C sort | tr '\n' ' ' | sed 's/ $//')" "$1 route label matches nice-dns routes/providers.tsv"
  assert_eq "$PC_PROBE" "$(pc_label org.nice-dns.transport.probe)" "$1 names its probe"
  assert_eq "control-dir-ack" "$(pc_label org.nice-dns.transport.restart)" "$1 names its restart contract"
  # What the container listens on = the routes it declares. Fixture ports
  # (stand-in Tor 9050, DoT fixture) are excluded by number.
  fxports="$(cut -f2 "$CASE_DIR/fx/ports.tsv"; printf '9050\n')"
  tp_ns ss -Hltn
  listen="$(printf '%s\n' "$TP_OUT" | awk '{ n = split($4, a, ":"); print a[n] }' | grep -vxF -f <(printf '%s\n' "$fxports") | LC_ALL=C sort -un | tr '\n' ' ' | sed 's/ $//')"
  assert_eq "853 18531 18532 18533" "$listen" "$1 listens on exactly its declared route ports"
  for r in $routes; do
    p="${r#*=}"
    case " $listen " in *" $p "*) ;; *) fail "$1 declares $r but does not listen on $p" ;; esac
  done
  tp_pm exec "$TP_CTR" dig -v
  dig="$TP_OUT"
  tp_pm exec "$TP_CTR" "$PC_PROBE" --capabilities
  assert_rc 0 "$TP_RC" "$1 probe reports its capabilities: $TP_OUT"
  assert_match '^verify	tls-ca tls-hostname$' "$TP_OUT" "$1 probe verifies certificates and names"
  {
    printf 'schema\tnice-dns-transport-capabilities/1\n'
    printf 'image\t%s\n' "$TP_IMG"
    printf 'image_id\t%s\n' "$(podman image inspect -f '{{.Id}}' "$TP_IMG" 2>/dev/null | grep -v -- "$TP_WARN")"
    printf 'source\t%s\t%s\n' "$1" "$(git -C "$TP_SRC" rev-parse HEAD)"
    # The image is built from the working tree (tp_setup); a receipt from
    # uncommitted source must say so.
    if git -C "$TP_SRC" status --porcelain | grep -vq '^?? bridge-eval/bridge-eval$'; then
      printf 'source_dirty\tyes\n'
    else
      printf 'source_dirty\tno\n'
    fi
    printf 'interface\t%s\n' "$(pc_label org.nice-dns.transport.interface)"
    printf 'routes\t%s\n' "$routes"
    printf 'listening\t%s\n' "$listen"
    printf 'restart\t%s\n' "$(pc_label org.nice-dns.transport.restart)"
    printf 'probe\t%s\n' "$(pc_label org.nice-dns.transport.probe)"
    printf 'probe_dig\t%s\n' "$dig"
    printf '%s\n' "$TP_OUT" | sed 's/^/probe_/'
  } >"$CASE_DIR/capabilities.tsv"
  assert_file "$CASE_DIR/capabilities.tsv" "$1 capability receipt written"
}

t_haproxy_probe_authenticates_and_follows_route() { pc_authenticates_and_follows_route tor-haproxy; }
t_socat_probe_authenticates_and_follows_route() { pc_authenticates_and_follows_route tor-socat; }
t_haproxy_probe_rejects_bad_certificates() { pc_rejects_bad_certificates tor-haproxy; }
t_socat_probe_rejects_bad_certificates() { pc_rejects_bad_certificates tor-socat; }
t_haproxy_probe_parses_dns_errors() { pc_parses_dns_errors tor-haproxy; }
t_socat_probe_parses_dns_errors() { pc_parses_dns_errors tor-socat; }
t_haproxy_probe_bounds_a_silent_upstream() { pc_bounds_a_silent_upstream tor-haproxy; }
t_socat_probe_bounds_a_silent_upstream() { pc_bounds_a_silent_upstream tor-socat; }
t_haproxy_healthcheck_uses_verifying_probe() { pc_healthcheck_uses_probe tor-haproxy; }
t_socat_healthcheck_uses_verifying_probe() { pc_healthcheck_uses_probe tor-socat; }
t_haproxy_capabilities_match_listeners() { pc_capabilities tor-haproxy; }
t_socat_capabilities_match_listeners() { pc_capabilities tor-socat; }

t_socat_legacy_failover_uses_verifying_probe() {
  local i=0
  # A legacy session with a wrong-name certificate must count as a failure.
  pc_stack tor-socat -e LEGACY_CHECK_INTERVAL=1 -e LEGACY_FAIL_THRESHOLD=2
  # Control: with the good certificate the check passes and nothing switches.
  sleep 5
  assert_not_match 'health check failed|exceeded failure threshold' "$(podman logs "$TP_CTR" 2>&1)" "the legacy check passes on an authenticated session"
  pc_relay wrongname
  while [ "$i" -lt 60 ]; do
    case "$(podman logs "$TP_CTR" 2>&1)" in *'PRIMARY exceeded failure threshold'*) break ;; esac
    i=$((i + 1)); sleep 0.5
  done
  assert_match 'PRIMARY health check failed' "$(podman logs "$TP_CTR" 2>&1)" "the legacy check fails on a wrong-name certificate"
  assert_match 'PRIMARY exceeded failure threshold, switching' "$(podman logs "$TP_CTR" 2>&1)" "the legacy tier fails over"
}
