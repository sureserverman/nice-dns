# shellcheck shell=bash
# Group integration/transport-interaction (sub-plan 02, Stage 1 gate;
# ARCH-04, ARCH-06, ARCH-09). The Stage 1 outputs working together:
#
#   product Unbound --DoT--> proxy route listener --SOCKS--> stand-in Tor
#     (candidate image)      (candidate tor-haproxy / tor-socat)   |
#                                                                  relay
#                                                                    v
#                                         DoT fixture (tests/fixtures/dnsfixture.py)
#
# All in one --network none namespace. Unbound runs its shipped config plus a
# TEST-ONLY overlay: the fixture CA as tls-cert-bundle, the fixture trust
# anchor, and a forward-zone for fixture.test to 127.0.0.1@<route>#
# dns.fixture.test with forward-tls-upstream. So the product's own TLS client
# authenticates the name through the route, and its own validator checks
# DNSSEC. The stand-in Tor relays every stream to one DoT fixture listener
# (good, wrongname, expired or untrusted certificate) and records the
# destination the proxy asked for, so each case also proves route identity.
# Only controlled fixture names are queried.

# shellcheck source=tests/fixtures/transport.sh
. "$NICE_DNS_ROOT/tests/fixtures/transport.sh"
# shellcheck source=tests/fixtures/unbound-image.sh
. "$NICE_DNS_ROOT/tests/fixtures/unbound-image.sh"
# shellcheck source=tests/fixtures/fixture.sh
. "$NICE_DNS_ROOT/tests/fixtures/fixture.sh"

TI_ONION=dns4torpnlfs2ifuz2s2yf3fc7rdmsbhm6rw75euj35pac6ap25zgqad.onion

# ti_provider_set <proxy> <route port>: destinations that route may request.
ti_provider_set() {
  case "$2" in
    18531) if [ "$1" = tor-haproxy ]; then printf '10.192.0.1:853\n'; else printf '%s:853\n' "$TI_ONION"; fi ;;
    18532) printf '1.0.0.1:853\n1.1.1.1:853\n' ;;
    18533) printf '149.112.112.112:853\n9.9.9.9:853\n' ;;
  esac
}

ti_cleanup() {
  [ -f "$CASE_DIR/fx/pypid" ] && kill "$(cat "$CASE_DIR/fx/pypid")" 2>/dev/null
  if [ -n "${TI_FX_WRAP:-}" ]; then kill "$TI_FX_WRAP" 2>/dev/null; wait "$TI_FX_WRAP" 2>/dev/null; fi
  tp_cleanup
}

# ti_stack <proxy repo>: namespace, DoT fixture (with TLS variants), stand-in
# Tor, the proxy's own start.sh, and the candidate Unbound image built.
ti_stack() {
  local d="$CASE_DIR/fx" i=0
  tp_setup "$1"
  TI_FX_WRAP=""
  trap ti_cleanup EXIT
  ub_images
  tp_holder
  mkdir -m 700 "$d" || fail "cannot create $d"
  python3 "$FX_PY" pki --out "$d/pki" >"$d/pki.log" 2>&1 || fail "fixture pki failed: $(cat "$d/pki.log")"
  chmod 644 "$d/pki/ca.pem"
  podman unshare nsenter -t "$TP_NSPID" -n sh -c 'echo $$ >"$1/pypid"; d=$1; shift; exec python3 "$@"' \
    sh "$d" "$FX_PY" serve --state "$d" --max-seconds "${FX_MAX_SECONDS:-600}" \
    --tls "good:$d/pki/good.pem:$d/pki/good.key" --tls "wrongname:$d/pki/wrongname.pem:$d/pki/wrongname.key" \
    --tls "expired:$d/pki/expired.pem:$d/pki/expired.key" --tls "untrusted:$d/pki/untrusted.pem:$d/pki/untrusted.key" \
    >"$d/fixture.log" 2>&1 </dev/null &
  TI_FX_WRAP=$!
  while [ ! -f "$d/ports.tsv" ]; do
    i=$((i + 1))
    [ "$i" -le 300 ] || fail "DoT fixture did not start: $(cat "$d/fixture.log")"
    sleep 0.05
  done
  tp_socks_start
  tp_supervised
  for i in 853 18531 18532 18533; do
    tp_wait_listen "$i" 30 || fail "$1 never listened on $i: $(podman logs "$TP_CTR" 2>&1 | tail -n 20)"
  done
  TI_PROXY="$1"
}

# ti_unbound <route port>: a fresh product Unbound forwarding fixture.test
# over TLS to that route (fresh per call: no cached upstream state).
ti_unbound() {
  local f="$CASE_DIR/overlay-$1.conf" n="$TP_PFX-ub-$1-$RANDOM" i=0
  tp_pm run --rm --network none --entrypoint /bin/cat "$UB_IMG" /etc/unbound/unbound.conf
  assert_rc 0 "$TP_RC" "product config readable from the image"
  {
    printf '%s\n' "$TP_OUT"
    printf '\n# ---- TEST-ONLY overlay (tests/integration/transport-interaction.sh) ----\n'
    printf 'server:\n    tls-cert-bundle: "/fx/ca.pem"\n    local-zone: "test." nodefault\n    '
    cat "$CASE_DIR/fx/anchor.unbound"
    printf 'forward-zone:\n    name: "fixture.test."\n    forward-tls-upstream: yes\n'
    printf '    forward-addr: 127.0.0.1@%s#dns.fixture.test\n' "$1"
  } >"$f"
  chmod 644 "$f"
  TP_CTRS="$TP_CTRS $n"
  tp_pm run -d --health-interval=disable --name "$n" --network "container:$TP_HOLDER" \
    -v "$f:/etc/unbound/unbound.conf:ro" -v "$CASE_DIR/fx/pki/ca.pem:/fx/ca.pem:ro" "$UB_IMG"
  assert_rc 0 "$TP_RC" "product Unbound started: $TP_OUT"
  while [ "$i" -lt 60 ]; do
    tp_ns dig @127.0.0.1 -p 5335 +time=1 +tries=1 localhost A
    case "$TP_OUT" in *'status: NOERROR'*) TI_UB="$n"; return 0 ;; esac
    i=$((i + 1)); sleep 0.5
  done
  fail "product Unbound never answered: $(podman logs "$n" 2>&1 | tail -n 10)"
}

ti_query() {
  tp_ns dig @127.0.0.1 -p 5335 +time=30 +tries=1 +adflag "$1" A
}

# ti_relay <variant>: the stand-in Tor relays every stream to that DoT listener.
ti_relay() { tp_socks_mode relay "$(fx_port "$CASE_DIR/fx" "dot-$1")"; }

ti_route_dests_ok() {
  local got
  # Only the product's sessions (SNI = its authentication name); the legacy
  # 853 health probes share the stand-in Tor and carry no such SNI.
  got="$(awk -F '\t' '$4 == "relay" && $5 == "sni:dns.fixture.test" { print $2 ":" $3 }' "$TP_SOCKS/connects.tsv" | LC_ALL=C sort -u)"
  assert_ne "" "$got" "$TI_PROXY route $1 carried the TLS stream through SOCKS"
  assert_eq "" "$(printf '%s\n' "$got" | grep -vxF -f <(ti_provider_set "$TI_PROXY" "$1"))" "$TI_PROXY route $1 asked only for its provider (got: $got)"
  : >"$TP_SOCKS/connects.tsv"
}

ti_authenticated_routes() {
  local r
  ti_stack "$1"
  ti_relay good
  for r in 18531 18532 18533; do
    ti_unbound "$r"
    ti_query "n$r$RANDOM.fixture.test"
    assert_match 'status: NXDOMAIN' "$TP_OUT" "$1 route $r: authenticated TLS session answered (signed NXDOMAIN)"
    assert_match 'flags: qr rd ra ad;' "$TP_OUT" "$1 route $r: the product Unbound validated the answer (AD)"
    ti_query signed.fixture.test
    assert_match 'signed\.fixture\.test\..*IN[[:space:]]+A[[:space:]]+192\.0\.2\.1' "$TP_OUT" "$1 route $r: signed answer through the route"
    assert_match 'flags: qr rd ra ad;' "$TP_OUT" "$1 route $r: signed answer validated (AD)"
    ti_route_dests_ok "$r"
    podman rm -f -t 0 "$TI_UB" >/dev/null 2>&1
  done
}

ti_rejects_bad_certificates() {
  local v
  ti_stack "$1"
  for v in wrongname expired untrusted; do
    ti_relay "$v"
    ti_unbound 18532
    ti_query "n$v$RANDOM.fixture.test"
    assert_match 'status: SERVFAIL' "$TP_OUT" "$1: the product Unbound refuses a $v certificate on the route"
    assert_not_match 'ANSWER SECTION' "$TP_OUT" "$1: no answer served from a $v session"
    ti_route_dests_ok 18532
    podman rm -f -t 0 "$TI_UB" >/dev/null 2>&1
  done
}

t_haproxy_routes_carry_authenticated_tls() { ti_authenticated_routes tor-haproxy; }
t_socat_routes_carry_authenticated_tls() { ti_authenticated_routes tor-socat; }
t_haproxy_route_tls_rejects_bad_certificates() { ti_rejects_bad_certificates tor-haproxy; }
t_socat_route_tls_rejects_bad_certificates() { ti_rejects_bad_certificates tor-socat; }

t_stage_covers_every_proxy_variant() {
  # The interaction stage must not silently omit a proxy: every proxy in the
  # eight-cell matrix has its transport group in stage transport-images.
  local p rows
  rows="$(awk -F '\t' '$1 == "transport-images" { print $2 "/" $3 }' "$NICE_DNS_ROOT/tests/manifests/stages.tsv")"
  # shellcheck disable=SC2013  # one word per proxy name
  for p in $(awk -F '\t' '!/^#/ && NF == 3 { print $2 }' "$NICE_DNS_ROOT/tests/manifests/matrix.tsv" | LC_ALL=C sort -u); do
    assert_match "^integration/transport-$p\$" "$rows" "stage transport-images runs the $p transport group"
  done
  assert_match '^integration/transport-interaction$' "$rows" "stage transport-images runs the interaction group"
  assert_match '^integration/resolver-state$' "$rows" "stage transport-images runs the resolver group"
}
