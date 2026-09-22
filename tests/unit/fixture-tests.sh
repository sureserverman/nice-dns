# shellcheck shell=bash
# Group unit/fixtures (sub-plan 01, Task 1.2; ARCH-09).
#
# Sourced by tests/run.sh, which provides the assert_* helpers and exports
# NICE_DNS_ROOT, RUN_ID, ARTIFACT_DIR and CASE_DIR. Each case starts its own
# loopback-only fixture (fresh keys and certificates) and stops it on exit.
#
# The validator here is delv (BIND), independent of the product's Unbound, so
# these cases prove what the fixture serves, not how nice-dns handles it.
# Requires: python3, openssl, dig/delv 9.18+ (dig +tls).

# shellcheck source=tests/fixtures/fixture.sh
. "$NICE_DNS_ROOT/tests/fixtures/fixture.sh"

ft_start() {
  fx_start "$CASE_DIR/fx" "$@" || fail "fixture did not start: $(cat "$CASE_DIR/fx/fixture.log" 2>/dev/null)"
  trap 'fx_stop "$CASE_DIR/fx"' EXIT
}

ft_delv() {
  # ft_delv <name> <type>: validate against the fixture's own trust anchor.
  FT_OUT="$(delv @127.0.0.1 -p "$(fx_port "$CASE_DIR/fx" dns)" -a "$CASE_DIR/fx/anchor.bind" \
    +root=fixture.test. "$1" "$2" 2>&1)"
  FT_RC=$?
}

ft_dig() {
  FT_OUT="$(dig @127.0.0.1 -p "$(fx_port "$CASE_DIR/fx" dns)" +tries=1 +time=3 "$@" 2>&1)"
  FT_RC=$?
}

ft_dot() {
  # ft_dot <variant> <verify|noverify>: one A query over TLS to that variant.
  local port
  port="$(fx_port "$CASE_DIR/fx" "dot-$1")"
  if [ "$2" = verify ]; then
    FT_OUT="$(dig +tls +tls-ca="$CASE_DIR/fx/pki/ca.pem" +tls-hostname=dns.fixture.test \
      @127.0.0.1 -p "$port" +tries=1 +time=3 +short signed.fixture.test A 2>&1)"
  else
    FT_OUT="$(dig +tls @127.0.0.1 -p "$port" +tries=1 +time=3 +short signed.fixture.test A 2>&1)"
  fi
  FT_RC=$?
}

t_signed_answer_fully_validates() {
  ft_start
  ft_delv signed.fixture.test A
  assert_match '^; fully validated' "$FT_OUT" "signed name must validate from the fixture anchor"
  assert_match 'signed\.fixture\.test\..*IN[[:space:]]+A[[:space:]]+192\.0\.2\.1' "$FT_OUT" "signed A record"
}

t_bogus_is_delivered_by_fixture() {
  # The bad signature must come from the fixture itself, so a later rejection
  # cannot be an upstream resolver's rejection masquerading as local validation.
  ft_start
  ft_dig +dnssec +cd bogus.fixture.test A +noall +answer
  assert_rc 0 "$FT_RC" "dig +cd bogus"
  assert_match 'bogus\.fixture\.test\..*IN[[:space:]]+A[[:space:]]+192\.0\.2\.66' "$FT_OUT" "bogus A is served"
  assert_match 'bogus\.fixture\.test\..*IN[[:space:]]+RRSIG[[:space:]]+A 13 ' "$FT_OUT" "bogus RRSIG is served"
}

t_bogus_is_rejected_by_validator() {
  ft_start
  ft_delv bogus.fixture.test A
  assert_match 'resolution failed' "$FT_OUT" "bogus must not resolve"
  assert_match 'RRSIG failed to verify|no valid signature' "$FT_OUT" "failure must be the signature"
  assert_not_match '^; fully validated' "$FT_OUT" "bogus must never validate"
}

t_unsigned_delegation_is_insecure() {
  ft_start
  ft_delv host.unsigned.fixture.test A
  assert_match '^; unsigned answer' "$FT_OUT" "insecure delegation proven by signed NSEC"
  assert_match 'host\.unsigned\.fixture\.test\..*IN[[:space:]]+A[[:space:]]+192\.0\.2\.7' "$FT_OUT" "unsigned A record"
}

t_ds_denial_for_unsigned_child_is_signed() {
  ft_start
  ft_dig +dnssec unsigned.fixture.test DS +noall +authority
  assert_match 'unsigned\.fixture\.test\.[[:space:]].*IN[[:space:]]+NSEC[[:space:]]+[^[:space:]]+ NS RRSIG NSEC$' "$FT_OUT" "NSEC at the cut lists exactly NS RRSIG NSEC (no DS)"
  assert_match 'unsigned\.fixture\.test\..*RRSIG[[:space:]]+NSEC 13 ' "$FT_OUT" "NSEC is signed"
}

t_nxdomain_is_validated_negative() {
  ft_start
  ft_dig nx.fixture.test A +noall +comments
  assert_match 'status: NXDOMAIN' "$FT_OUT" "rcode NXDOMAIN"
  ft_delv nx.fixture.test A
  assert_match 'negative response, fully validated' "$FT_OUT" "NXDOMAIN proof validates"
}

t_nodata_is_validated_negative() {
  ft_start
  ft_delv signed.fixture.test AAAA
  assert_match 'negative response, fully validated' "$FT_OUT" "NODATA proof validates"
}

t_udp_truncates_and_tcp_answers() {
  ft_start
  ft_dig +ignore tc.fixture.test TXT +noall +comments
  assert_match 'flags: qr aa tc' "$FT_OUT" "UDP answer sets TC"
  assert_match 'ANSWER: 0' "$FT_OUT" "UDP carries no answer"
  ft_dig +tcp tc.fixture.test TXT +noall +comments +answer
  assert_not_match 'flags: qr aa tc' "$FT_OUT" "TCP answer is not truncated"
  assert_match 'tc\.fixture\.test\..*IN[[:space:]]+TXT' "$FT_OUT" "TCP carries the TXT answer"
  ft_dig tc.fixture.test TXT +short
  assert_match 't000' "$FT_OUT" "dig retries over TCP after TC and gets the answer"
}

t_out_of_zone_is_refused() {
  # The fixture never recurses or forwards; nothing leaves the loopback.
  ft_start
  ft_dig example.com A +noall +comments
  assert_match 'status: REFUSED' "$FT_OUT" "out-of-zone query refused"
}

t_dot_matching_cert_verifies() {
  ft_start --tls
  ft_dot good verify
  assert_rc 0 "$FT_RC" "verifying DoT to the matching certificate"
  assert_eq "192.0.2.1" "$FT_OUT" "answer over verified TLS"
}

t_dot_wrong_name_rejected() {
  ft_start --tls
  ft_dot wrongname verify
  assert_match 'hostname mismatch' "$FT_OUT" "wrong-name certificate rejected for the name"
  assert_not_match '^192\.0\.2\.1$' "$FT_OUT" "no answer through a wrong-name certificate"
}

t_dot_expired_rejected() {
  ft_start --tls
  ft_dot expired verify
  assert_match 'certificate has expired' "$FT_OUT" "expired certificate rejected"
  assert_not_match '^192\.0\.2\.1$' "$FT_OUT" "no answer through an expired certificate"
}

t_dot_untrusted_rejected() {
  ft_start --tls
  ft_dot untrusted verify
  assert_match 'unable to get local issuer certificate' "$FT_OUT" "certificate from an unknown CA rejected"
  assert_not_match '^192\.0\.2\.1$' "$FT_OUT" "no answer through an untrusted certificate"
}

t_dot_every_variant_serves_without_verification() {
  # Proves each rejection above is caused by the certificate, not a dead listener.
  local v
  ft_start --tls
  for v in good wrongname expired untrusted; do
    ft_dot "$v" noverify
    assert_eq "192.0.2.1" "$FT_OUT" "unverified DoT answer from variant $v"
  done
}

t_keys_are_fresh_and_private() {
  local k1 k2 c1 c2 f
  fx_start "$CASE_DIR/a" --tls || fail "fixture a did not start"
  fx_start "$CASE_DIR/b" --tls || { fx_stop "$CASE_DIR/a"; fail "fixture b did not start"; }
  trap 'fx_stop "$CASE_DIR/a"; fx_stop "$CASE_DIR/b"' EXIT
  k1="$(dig @127.0.0.1 -p "$(fx_port "$CASE_DIR/a" dns)" +short fixture.test DNSKEY)"
  k2="$(dig @127.0.0.1 -p "$(fx_port "$CASE_DIR/b" dns)" +short fixture.test DNSKEY)"
  assert_match '^257 3 13 ' "$k1" "DNSKEY served"
  assert_ne "$k1" "$k2" "each fixture start signs with a new key"
  c1="$(openssl x509 -in "$CASE_DIR/a/pki/good.pem" -noout -fingerprint -sha256)"
  c2="$(openssl x509 -in "$CASE_DIR/b/pki/good.pem" -noout -fingerprint -sha256)"
  assert_ne "$c1" "$c2" "each fixture start issues new certificates"
  for f in "$CASE_DIR"/a/zsk.pem "$CASE_DIR"/a/pki/*.key; do
    assert_eq 600 "$(fx_mode "$f")" "private key $f is owner-only"
  done
  assert_eq 700 "$(fx_mode "$CASE_DIR/a")" "fixture state dir is owner-only"
}

t_fixture_state_stays_in_artifacts() {
  ft_start --tls
  case "$CASE_DIR/fx" in
    "$NICE_DNS_ROOT"/*) fail "fixture state is inside the checkout" ;;
  esac
  assert_match "^$ARTIFACT_DIR/" "$CASE_DIR/fx" "fixture state under the run's artifact dir"
  assert_eq "" "$(find "$NICE_DNS_ROOT/tests" \( -name '*.pem' -o -name '*.key' -o -name '*.csr' \) -print)" "no key material written into the checkout"
}

t_stop_ends_the_server() {
  local pid
  fx_start "$CASE_DIR/fx" || fail "fixture did not start"
  pid="$(cat "$CASE_DIR/fx/pid")"
  kill -0 "$pid" 2>/dev/null
  assert_rc 0 $? "fixture process alive after start"
  fx_stop "$CASE_DIR/fx"
  kill -0 "$pid" 2>/dev/null
  assert_nonzero $? "fixture process gone after stop"
}

t_unbound_anchor_matches_served_key() {
  # Later tasks point Unbound at anchor.unbound; it must carry the served key.
  local served anchored
  ft_start
  served="$(dig @127.0.0.1 -p "$(fx_port "$CASE_DIR/fx" dns)" +short fixture.test DNSKEY | cut -d' ' -f4- | tr -d ' ')"
  assert_match '^trust-anchor: "fixture\.test\. DNSKEY 257 3 13 ' "$(cat "$CASE_DIR/fx/anchor.unbound")" "unbound anchor line"
  anchored="$(sed -n 's/^trust-anchor: "fixture\.test\. DNSKEY 257 3 13 \(.*\)"$/\1/p' "$CASE_DIR/fx/anchor.unbound" | tr -d ' ')"
  assert_ne "" "$served" "served DNSKEY"
  assert_eq "$served" "$anchored" "unbound anchor carries the served public key"
}
