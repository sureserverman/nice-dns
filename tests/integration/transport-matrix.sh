# shellcheck shell=bash
# Group integration/transport-transitions (sub-plan 02, Task 2.3; ARCH-04,
# ARCH-06, ARCH-09). The whole candidate chain per Linux cell, both proxies x
# both Pi-hole frontends, then the transport receipt:
#
#   client --> Pi-hole (standard | hardened candidate) --> Unbound (candidate,
#   route include managed by lib/recovery.sh) --DoT--> proxy route listener
#   (tor-haproxy | tor-socat candidate) --SOCKS--> stand-in Tor --relay-->
#   DoT fixture (dns.fixture.test; good or wrong-name certificate)
#
# All in one --network none namespace, the Linux pod topology. TEST-ONLY
# configuration, and nothing else: Unbound gets the fixture CA and trust
# anchor (overlay), the route table carries the fixture's TLS name, and
# Pi-hole forwards fixture.test to Unbound (FTLCONF_misc_dnsmasq_lines;
# the shipped dnsmasq.conf answers every .test name locally). Only
# controlled fixture names are queried.
#
# Each cell case records evidence under $ARTIFACT_DIR/transport-cells/<cell>
# for the receipt scenarios (tests/manifests/transport.tsv):
#   TR-TLS-NAME        answers through Pi-hole; Unbound authenticated the route
#   TR-ROUTE-IDENTITY  every upstream session reached the route's provider
#   TR-DNSSEC          signed validates, unsigned answers, bogus SERVFAILs
#                      through Pi-hole; the anchor is the persistent one
#   TR-CONTROL         route readback over the Unix socket; no :8953 listener
#   TR-ROUTE-SWITCH    a route change under paced load (dnsload.py): warm
#                      queries to Unbound and fresh ones through Pi-hole;
#                      timeouts, errors, in-flight outcomes, cache hits after
#                      the reload and upstream sessions per query. Warm
#                      timeouts and errors must be 0 and the fresh timeout
#                      rate may not exceed the cell's frozen baseline cold
#                      rate (BL-TARGETS); failing that means revising ARCH-04,
#                      not loosening this check.
#   TR-TLS-NEGATIVE    a wrong-name certificate on the route: SERVFAIL through
#                      Pi-hole and Unbound
# t_zz_transport_receipt (sorted last) assembles
# <artifact root>/receipts/transport/<run id>/receipt.tsv from the four
# cells of this run (macOS cells recorded as blocked) and verifies it with
# tests/reports/verify.sh --require-proxies all --require-dep baseline.
#
# Options: --proxies all and --pihole all (the defaults). A narrower
# selection makes the unselected cells and the receipt fail: a missing
# variant is never green.

# shellcheck source=tests/fixtures/transport.sh
. "$NICE_DNS_ROOT/tests/fixtures/transport.sh"
# shellcheck source=tests/fixtures/unbound-image.sh
. "$NICE_DNS_ROOT/tests/fixtures/unbound-image.sh"
# shellcheck source=tests/fixtures/pihole-image.sh
. "$NICE_DNS_ROOT/tests/fixtures/pihole-image.sh"
# shellcheck source=tests/fixtures/fixture.sh
. "$NICE_DNS_ROOT/tests/fixtures/fixture.sh"
# shellcheck source=lib/recovery.sh
ND_PLATFORM=linux . "$NICE_DNS_ROOT/lib/recovery.sh"

TM_LOAD_PY="$NICE_DNS_ROOT/tests/fixtures/dnsload.py"
TM_CTL=/usr/share/nice-dns/control.conf
TM_ONION=dns4torpnlfs2ifuz2s2yf3fc7rdmsbhm6rw75euj35pac6ap25zgqad.onion
TM_WARM="signed.fixture.test,host.unsigned.fixture.test,w1.fixture.test,w2.fixture.test,w3.fixture.test,w4.fixture.test"

# tm_provider_set <proxy> <port>: destinations a route may request.
tm_provider_set() {
  case "$2" in
    18531) if [ "$1" = tor-haproxy ]; then printf '10.192.0.1:853\n'; else printf '%s:853\n' "$TM_ONION"; fi ;;
    18532) printf '1.0.0.1:853\n1.1.1.1:853\n' ;;
    18533) printf '149.112.112.112:853\n9.9.9.9:853\n' ;;
  esac
}

tm_cleanup() {
  [ -f "$CASE_DIR/fx/pypid" ] && kill "$(cat "$CASE_DIR/fx/pypid")" 2>/dev/null
  if [ -n "${TM_FX_WRAP:-}" ]; then kill "$TM_FX_WRAP" 2>/dev/null; wait "$TM_FX_WRAP" 2>/dev/null; fi
  if [ -n "${TM_LOAD:-}" ]; then kill "$TM_LOAD" 2>/dev/null; wait "$TM_LOAD" 2>/dev/null; fi
  tp_cleanup
}

tm_selected() {
  case ",${NICE_DNS_OPT_PROXIES:-all}," in *,all,*|*",${1#tor-},"*) ;; *) return 1 ;; esac
  case ",${NICE_DNS_OPT_PIHOLE:-all}," in *,all,*|*",$2,"*) ;; *) return 1 ;; esac
}

tm_id() { podman image inspect -f '{{.Id}}' "$1" 2>/dev/null | grep -v -- "$TP_WARN" | sed 's/^sha256://'; }

tm_dig() { tp_ns dig @127.0.0.1 -p "$1" +time=10 +tries=1 "${@:2}"; }

tm_sni_dests() {
  awk -F '\t' '$4 == "relay" && $5 == "sni:dns.fixture.test" { print $2 ":" $3 }' "$TP_SOCKS/connects.tsv" | LC_ALL=C sort -u
}

tm_stat() { printf '%s\n' "$2" | awk -F= -v k="$1" '$1 == k { print $2; exit }'; }
tm_kv() { printf '%s\n' "$1" | awk -F= -v k="$2" '$1 == k { print $2; exit }'; }

# tm_stack <proxy> <pihole>: the whole chain on route cloudflare-onion gen 1.
tm_stack() {
  local d="$CASE_DIR/fx" i=0 p
  tm_selected "$1" "$2" || fail "cell linux/${1#tor-}/$2 is not selected (--proxies ${NICE_DNS_OPT_PROXIES:-all} --pihole ${NICE_DNS_OPT_PIHOLE:-all}); an unselected cell is not a pass"
  tp_setup "$1"
  TM_FX_WRAP="" TM_LOAD=""
  trap tm_cleanup EXIT
  ub_images
  ph_image "$2"
  tp_holder
  mkdir -m 700 "$d" || fail "cannot create $d"
  python3 "$FX_PY" pki --out "$d/pki" >"$d/pki.log" 2>&1 || fail "fixture pki failed: $(cat "$d/pki.log")"
  chmod 644 "$d/pki/ca.pem"
  podman unshare nsenter -t "$TP_NSPID" -n sh -c 'echo $$ >"$1/pypid"; d=$1; shift; exec python3 "$@"' \
    sh "$d" "$FX_PY" serve --state "$d" --max-seconds "${FX_MAX_SECONDS:-900}" \
    --tls "good:$d/pki/good.pem:$d/pki/good.key" --tls "wrongname:$d/pki/wrongname.pem:$d/pki/wrongname.key" \
    >"$d/fixture.log" 2>&1 </dev/null &
  TM_FX_WRAP=$!
  while [ ! -f "$d/ports.tsv" ]; do
    i=$((i + 1)); [ "$i" -le 300 ] || fail "DoT fixture did not start: $(cat "$d/fixture.log")"; sleep 0.05
  done
  tp_socks_start
  tp_socks_mode relay "$(fx_port "$d" dot-good)"
  tp_supervised -e PROBE_INTERVAL_S=3600 -e LEGACY_CHECK_INTERVAL=3600
  for p in 18531 18532 18533; do
    tp_wait_listen "$p" 30 || fail "$1 never listened on $p: $(podman logs "$TP_CTR" 2>&1 | tail -n 20)"
  done
  # Route: the shipped table with the fixture's TLS name.
  ND_ROUTE_DIR="$CASE_DIR/route" ND_ROUTES_FILE="$CASE_DIR/providers.tsv" ND_UNBOUND_CONTAINER="$TP_PFX-ub"
  ND_ROUTE_PROBE_NAME=signed.fixture.test
  export ND_ROUTE_DIR ND_ROUTES_FILE ND_UNBOUND_CONTAINER ND_ROUTE_PROBE_NAME
  awk -F '\t' 'BEGIN { OFS = "\t" } /^#/ || NF != 5 || $1 == "schema" { print; next } { $3 = "dns.fixture.test"; print }' \
    "$NICE_DNS_ROOT/routes/providers.tsv" >"$ND_ROUTES_FILE"
  TM_RES="$(seed_route cloudflare-onion 1 2>&1)"
  assert_rc 0 "$?" "route seeded: $TM_RES"
  tp_pm run --rm --network none --entrypoint /bin/cat "$UB_IMG" /etc/unbound/unbound.conf
  {
    printf '%s\n' "$TP_OUT"
    printf '\n# ---- TEST-ONLY overlay (tests/integration/transport-matrix.sh) ----\n'
    printf 'server:\n    tls-cert-bundle: "/fx/ca.pem"\n    local-zone: "test." nodefault\n    '
    cat "$d/anchor.unbound"
  } >"$CASE_DIR/overlay.conf"
  chmod 644 "$CASE_DIR/overlay.conf"
  # NICE_DNS_ROUTE_WAIT=0: the transitions here start Unbound before the
  # proxy; the start's wait for the route is integration/route-transition's.
  tp_run ub -e NICE_DNS_ROUTE_WAIT=0 -v "$CASE_DIR/overlay.conf:/etc/unbound/unbound.conf:ro" -v "$d/pki/ca.pem:/fx/ca.pem:ro" \
    -v "$ND_ROUTE_DIR:/etc/unbound/route:ro" "$UB_IMG"
  i=0
  while :; do
    tm_dig 5335 localhost A
    case "$TP_OUT" in *'status: NOERROR'*) break ;; esac
    i=$((i + 1)); [ "$i" -le 60 ] || fail "Unbound never answered: $(podman logs "$TP_PFX-ub" 2>&1 | tail -n 10)"; sleep 0.5
  done
  tp_run ph -e TZ=Europe/London -e DNS1=127.0.0.1#5335 -e DISABLE_GITHUB_UPDATES=true \
    -e 'FTLCONF_misc_dnsmasq_lines=server=/fixture.test/127.0.0.1#5335' "$PH_IMG"
  i=0
  while :; do
    tm_dig 53 pi.hole A
    case "$TP_OUT" in *'status: NOERROR'*) break ;; esac
    i=$((i + 1)); [ "$i" -le 120 ] || fail "Pi-hole never answered: $(podman logs "$TP_PFX-ph" 2>&1 | tail -n 10)"; sleep 0.5
  done
  TM_CELL="linux/${1#tor-}/$2"
  TM_E="$ARTIFACT_DIR/transport-cells/linux-${1#tor-}-$2"
  mkdir -p "$TM_E" || fail "cannot create $TM_E"
  {
    printf 'cell\t%s\n' "$TM_CELL"
    # The runtime, not the host name (evidence carries no personal names).
    printf 'target\tfixture@%s-podman-%s\n' "$(uname -s)" "$(podman --version 2>/dev/null | awk '{ print $3 }')"
    printf 'image_gen\tpi-hole=sha256:%s,unbound=sha256:%s,%s=sha256:%s\n' "$(tm_id "$PH_IMG")" "$(tm_id "$UB_IMG")" "$1" "$(tm_id "$TP_IMG")"
    printf 'images\t%s\t%s\t%s\n' "$PH_IMG" "$UB_IMG" "$TP_IMG"
  } >"$TM_E/cell.tsv"
  : >"$TM_E/observations.tsv"
}

# tm_observe <scenario> <file>: record a passed scenario and its evidence.
tm_observe() {
  printf 'result=pass\n' >>"$TM_E/$2"
  printf '%s\tpass\t%s\n' "$1" "$2" >>"$TM_E/observations.tsv"
}

tm_baseline_cold_rate() {
  local root b
  root="$(dirname "$(dirname "$ARTIFACT_DIR")")"
  b="$(for b in "$root"/receipts/baseline/*/BL-TARGETS.txt; do [ -f "$b" ] && printf '%s\n' "$b"; done | LC_ALL=C sort | tail -1)"
  [ -n "$b" ] || fail "no baseline receipt with BL-TARGETS under $root/receipts/baseline"
  awk -F '\t' -v c="$1" '$1 == "cell" && $2 == c && $3 == "cold" { for (i = 4; i <= NF; i++) if ($i ~ /^timeout_rate=/) { sub(/^timeout_rate=/, "", $i); print $i } }' "$b"
}

tm_cell() {
  local proxy="$1" ph="$2" out got rt t0 t1 s st n i
  tm_stack "$proxy" "$ph"
  # The SOCKS log is kept from the stack's start: Unbound opens its upstream
  # session at startup and reuses it, so clearing it here would hide the
  # session that carries the first answers.

  # TR-TLS-NAME and TR-ROUTE-IDENTITY: the client path on the seeded route.
  tm_dig 53 signed.fixture.test A
  assert_match 'signed\.fixture\.test\..*IN[[:space:]]+A[[:space:]]+192\.0\.2\.1' "$TP_OUT" "$TM_CELL: signed answer through Pi-hole"
  out="$TP_OUT"
  tm_dig 5335 +adflag signed.fixture.test A
  assert_match 'flags: qr rd ra ad;' "$TP_OUT" "$TM_CELL: Unbound validated the answer from the authenticated route (AD)"
  got="$(tm_sni_dests)"
  assert_ne "" "$got" "$TM_CELL: the answer travelled through the route's TLS session"
  assert_eq "" "$(printf '%s\n' "$got" | grep -vxF -f <(tm_provider_set "$proxy" 18531))" "$TM_CELL: route cloudflare-onion reached only its provider (got: $got)"
  { printf 'route=cloudflare-onion\ntls_name=dns.fixture.test\npihole_answer=%s\nunbound_ad=yes\n' "$(printf '%s\n' "$out" | grep -c 'IN[[:space:]]*A[[:space:]]*192\.0\.2\.1')"; } >"$TM_E/tls-name.txt"
  tm_observe TR-TLS-NAME tls-name.txt
  printf 'route=cloudflare-onion\nport=18531\ndestinations=%s\n' "$(printf '%s' "$got" | tr '\n' ' ')" >"$TM_E/route-identity.txt"
  tm_observe TR-ROUTE-IDENTITY route-identity.txt

  # TR-DNSSEC through Pi-hole.
  tm_dig 53 bogus.fixture.test A
  assert_match 'status: SERVFAIL' "$TP_OUT" "$TM_CELL: bogus signature rejected (SERVFAIL through Pi-hole)"
  assert_not_match 'ANSWER SECTION' "$TP_OUT" "$TM_CELL: no bogus answer served"
  tm_dig 53 host.unsigned.fixture.test A
  assert_match 'IN[[:space:]]+A[[:space:]]+192\.0\.2\.7' "$TP_OUT" "$TM_CELL: unsigned zone answered"
  tp_pm exec --user unbound "$TP_PFX-ub" unbound-checkconf -o auto-trust-anchor-file
  assert_eq /var/lib/unbound/root.key "$TP_OUT" "$TM_CELL: the persistent anchor is in effect"
  printf 'bogus=SERVFAIL\nunsigned=answered\nsigned=validated\nanchor=/var/lib/unbound/root.key\n' >"$TM_E/dnssec.txt"
  tm_observe TR-DNSSEC dnssec.txt

  # TR-CONTROL.
  assert_eq "cloudflare-onion	1	127.0.0.1" "$(route_readback)" "$TM_CELL: route readback over the control socket"
  tp_ns ss -Hltn
  assert_not_match ':8953[[:space:]]' "$TP_OUT" "$TM_CELL: no network control listener"
  printf 'readback=cloudflare-onion 1 127.0.0.1\ncontrol_socket=/run/unbound/control.sock\nnetwork_control_listener=none\n' >"$TM_E/control.txt"
  tm_observe TR-CONTROL control.txt

  # TR-ROUTE-SWITCH: cloudflare-onion -> cloudflare-exit under paced load.
  for n in $(printf '%s' "$TM_WARM" | tr ',' ' '); do tm_dig 5335 "$n" A; done
  : >"$TP_SOCKS/connects.tsv"
  podman unshare nsenter -t "$TP_NSPID" -n python3 "$TM_LOAD_PY" --out "$TM_E/switch-samples.tsv" \
    --duration 8 --rate 10 --timeout 5 \
    --class "warm:127.0.0.1:5335:$TM_WARM" --class "fresh:127.0.0.1:53:fresh:fixture.test" \
    >"$CASE_DIR/load.log" 2>&1 </dev/null &
  TM_LOAD=$!
  sleep 2
  t0="$(date +%s%N)"
  TM_RES="$(apply_route cloudflare-exit 2 2>&1)"; st=$?
  t1="$(date +%s%N)"
  assert_rc 0 "$st" "$TM_CELL: route change under load: $TM_RES"
  wait "$TM_LOAD"; st=$?; TM_LOAD=""
  assert_rc 0 "$st" "$TM_CELL: load generator finished: $(cat "$CASE_DIR/load.log")"
  rt="$(route_readback)"
  assert_eq "cloudflare-exit	2	127.0.0.1" "$rt" "$TM_CELL: the new route runs"
  tp_pm exec --user unbound "$TP_PFX-ub" unbound-control -c "$TM_CTL" stats_noreset
  s="$TP_OUT"
  awk -F '\t' -v t0="$t0" -v t1="$t1" '
    NR <= 2 { next }
    { c = $1; att[c]++; if ($5 == "answered") ans[c]++; else if ($5 == "timeout") to[c]++; else er[c]++
      if ($3 < t1 && $4 > t0) { inf[c]++; if ($5 == "answered") infok[c]++ }
      if ($3 > t1 && $5 == "answered") after[c]++ }
    END {
      for (k = 1; k <= 2; k++) { c = (k == 1 ? "warm" : "fresh")
        printf "%s_attempted=%d\n%s_answered=%d\n%s_timeouts=%d\n%s_errors=%d\n%s_inflight=%d\n%s_inflight_answered=%d\n%s_answered_after_switch=%d\n",
          c, att[c], c, ans[c], c, to[c], c, er[c], c, inf[c], c, infok[c], c, after[c] }
    }' "$TM_E/switch-samples.tsv" >"$TM_E/route-switch.txt"
  {
    printf 'from=cloudflare-onion/1\nto=cloudflare-exit/2\napply_ms=%s\n' "$(( (t1 - t0) / 1000000 ))"
    printf 'cachehits_since_reload=%s\ncachemiss_since_reload=%s\n' "$(tm_stat total.num.cachehits "$s")" "$(tm_stat total.num.cachemiss "$s")"
    printf 'baseline_cold_timeout_rate=%s\n' "$(tm_baseline_cold_rate "$TM_CELL")"
  } >>"$TM_E/route-switch.txt"
  out="$(cat "$TM_E/route-switch.txt")"
  assert_match '^[1-9][0-9]*$' "$(tm_kv "$out" warm_attempted)" "$TM_CELL: warm load ran"
  assert_match '^[1-9][0-9]*$' "$(tm_kv "$out" fresh_attempted)" "$TM_CELL: fresh load ran"
  assert_eq 0 "$(tm_kv "$out" warm_timeouts)" "$TM_CELL: no warm timeout across the route change (frozen warm timeout_rate 0)"
  assert_eq 0 "$(tm_kv "$out" warm_errors)" "$TM_CELL: no warm error across the route change"
  assert_match '^[1-9][0-9]*$' "$(tm_kv "$out" warm_answered_after_switch)" "$TM_CELL: warm queries answered after the switch"
  [ "$(tm_kv "$out" cachehits_since_reload)" -ge "$(tm_kv "$out" warm_answered_after_switch)" ] \
    || fail "$TM_CELL: cache not retained: $(tm_kv "$out" cachehits_since_reload) cache hits since the reload for $(tm_kv "$out" warm_answered_after_switch) warm answers"
  printf 'cache_retained=yes\n' >>"$TM_E/route-switch.txt"
  awk -F= -v r="$(tm_kv "$out" baseline_cold_timeout_rate)" '
    $1 == "fresh_attempted" { a = $2 } $1 == "fresh_timeouts" { t = $2 }
    END { if (r == "" || a == 0 || t / a > r + 0) exit 1 }' "$TM_E/route-switch.txt" \
    || fail "$TM_CELL: fresh timeout rate $(tm_kv "$out" fresh_timeouts)/$(tm_kv "$out" fresh_attempted) exceeds the frozen baseline cold rate $(tm_kv "$out" baseline_cold_timeout_rate); route switching misses the frozen limit, so ARCH-04 must be revised"
  assert_eq 0 "$(tm_kv "$out" fresh_errors)" "$TM_CELL: no fresh query failed with an error across the change"
  got="$(tm_sni_dests)"
  assert_eq "" "$(printf '%s\n' "$got" | grep -vxF -f <( { tm_provider_set "$proxy" 18531; tm_provider_set "$proxy" 18532; } ))" "$TM_CELL: during the change sessions reached only the old or new route's provider (got: $got)"
  assert_ne "" "$(printf '%s\n' "$got" | grep -xF -f <(tm_provider_set "$proxy" 18532))" "$TM_CELL: the change opened a session to the new route's provider (got: $got)"
  # After the change: fresh names only reach the new provider; upstream TLS
  # sessions per query (connection reuse).
  : >"$TP_SOCKS/connects.tsv"
  for n in 1 2 3 4 5; do tm_dig 53 "after$n$RANDOM.fixture.test" A; assert_match 'status: NXDOMAIN' "$TP_OUT" "$TM_CELL: fresh name after the change"; done
  got="$(tm_sni_dests)"
  assert_eq "" "$(printf '%s\n' "$got" | grep -vxF -f <(tm_provider_set "$proxy" 18532))" "$TM_CELL: after the change only cloudflare-exit's provider is reached (got: $got)"
  printf 'after_queries=5\nafter_upstream_sessions=%s\n' "$(awk -F '\t' '$4 == "relay" && $5 == "sni:dns.fixture.test"' "$TP_SOCKS/connects.tsv" | grep -c .)" >>"$TM_E/route-switch.txt"
  tm_observe TR-ROUTE-SWITCH route-switch.txt

  # TR-TLS-NEGATIVE: a wrong-name certificate on the upstream. Selecting a
  # route there is refused: apply_route's resolution check fails and the
  # previous route is restored. Then Unbound restarts, so its sessions are
  # new, and clients get SERVFAIL, never an answer from that session.
  tp_socks_mode relay "$(fx_port "$CASE_DIR/fx" dot-wrongname)"
  TM_RES="$(apply_route quad9-exit 3 2>&1)"
  assert_rc 1 "$?" "$TM_CELL: a route presenting a wrong-name certificate is not activated: $TM_RES"
  assert_match '^result	restored$' "$TM_RES" "$TM_CELL: the previous route is restored"
  assert_eq "cloudflare-exit	2	127.0.0.1" "$(route_readback)" "$TM_CELL: cloudflare-exit runs again"
  tp_pm restart -t 2 "$TP_PFX-ub"
  assert_rc 0 "$TP_RC" "$TM_CELL: Unbound restarted: $TP_OUT"
  i=0
  while :; do
    tm_dig 5335 localhost A
    case "$TP_OUT" in *'status: NOERROR'*) break ;; esac
    i=$((i + 1)); [ "$i" -le 60 ] || fail "Unbound never answered after the restart"; sleep 0.5
  done
  tm_dig 53 "neg$RANDOM.fixture.test" A
  assert_match 'status: SERVFAIL' "$TP_OUT" "$TM_CELL: a wrong-name certificate yields SERVFAIL through Pi-hole"
  tm_dig 5335 "neg$RANDOM.fixture.test" A
  assert_match 'status: SERVFAIL' "$TP_OUT" "$TM_CELL: and through Unbound"
  assert_not_match 'ANSWER SECTION' "$TP_OUT" "$TM_CELL: nothing answered from the wrong-name session"
  printf 'cell=%s\nroute=cloudflare-exit\ncertificate=wrongname\napply=restored\npihole=SERVFAIL\nunbound=SERVFAIL\n' "$TM_CELL" >"$TM_E/tls-negative.txt"
  tm_observe TR-TLS-NEGATIVE-CELL tls-negative.txt
}

t_cell_linux_haproxy_standard() { tm_cell tor-haproxy standard; }
t_cell_linux_haproxy_hardened() { tm_cell tor-haproxy hardened; }
t_cell_linux_socat_standard() { tm_cell tor-socat standard; }
t_cell_linux_socat_hardened() { tm_cell tor-socat hardened; }

# ─────────────────────────── receipt ─────────────────────────────────────────

t_zz_transport_receipt() {
  local root out r base sib repo cd st key a s f gen cell p x y
  root="$(dirname "$(dirname "$ARTIFACT_DIR")")"
  out="$root/receipts/transport/$RUN_ID"
  r="$out/receipt.tsv"
  sib="${NICE_DNS_SIBLINGS_DIR:-$(dirname "$NICE_DNS_ROOT")}"
  for cell in haproxy-standard haproxy-hardened socat-standard socat-hardened; do
    assert_file "$ARTIFACT_DIR/transport-cells/linux-$cell/observations.tsv" "cell linux/${cell%-*}/${cell#*-} ran in this run"
    assert_eq 6 "$(grep -c 'pass' "$ARTIFACT_DIR/transport-cells/linux-$cell/observations.tsv")" "cell linux-$cell recorded all six scenarios"
  done
  base="$(for a in "$root"/receipts/baseline/*/receipt.tsv; do [ -f "$a" ] && printf '%s\n' "$a"; done | LC_ALL=C sort | tail -1)"
  assert_ne "" "$base" "a baseline receipt exists to link"
  assert_no_path "$out" "this run has no transport receipt yet"
  mkdir -p "$out/cells" || fail "cannot create $out"
  {
    printf '# schema\tnice-dns-receipt/1\n'
    printf 'receipt\ttransport\nrun_id\t%s\ncreated_utc\t%s\n' "$RUN_ID" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    for repo in nice-dns tor-haproxy tor-socat hardened-unbound pi-hole-hardened; do
      if [ "$repo" = nice-dns ]; then cd="$NICE_DNS_ROOT"; else cd="$sib/$repo"; fi
      # The proxies' untracked bridge-eval binary is not a build input (the
      # image compiles bridge-eval from source; tp_src_hash excludes it).
      if GIT_OPTIONAL_LOCKS=0 git -C "$cd" status --porcelain 2>/dev/null | grep -vq '^?? bridge-eval/bridge-eval$'; then st=dirty; else st=clean; fi
      printf 'source\t%s\t%s\t%s\n' "$repo" "$(git -C "$cd" rev-parse HEAD)" "$st"
    done
    for repo in tor-haproxy tor-socat hardened-unbound pi-hole-hardened; do
      printf 'arch\t%s\t%s\t%s\n' "$repo" "$(git -C "$sib/$repo" rev-parse HEAD)" \
        "$(git -C "$sib/$repo" show HEAD:.github/workflows/main.yml |
          awk '/^ *platform: *$/ { on = 1; next } on && /^ *- *linux\// { sub(/^ *- */, ""); print; next } on { on = 0 }' |
          sort | paste -sd, -)"
    done
    printf 'requires\tbaseline\t%s\t%s\n' "$base" "$(sha256sum "$base" | cut -d' ' -f1)"
    printf 'product\tnice-dns\t%s\n' "$(git -C "$NICE_DNS_ROOT" rev-parse HEAD)"
  } >"$r"
  : >"$out/TR-TLS-NEGATIVE.txt"
  for cell in haproxy-standard haproxy-hardened socat-standard socat-hardened; do
    s="$ARTIFACT_DIR/transport-cells/linux-$cell"
    key="$(awk -F '\t' '$1 == "cell" { print $2 }' "$s/cell.tsv")"
    gen="$(awk -F '\t' '$1 == "image_gen" { print $2 }' "$s/cell.tsv")"
    a="cells/linux-$cell"
    mkdir -p "$out/$a" && cp "$s"/* "$out/$a/"
    printf 'cell\t%s\t%s\t%s\t%s\t%s\tobserved\n' linux "${cell%-*}" "${cell#*-}" \
      "$(awk -F '\t' '$1 == "target" { print $2 }' "$s/cell.tsv")" "$gen" >>"$r"
    while IFS="$(printf '\t')" read -r x st f; do
      if [ "$x" = TR-TLS-NEGATIVE-CELL ]; then cat "$s/$f" >>"$out/TR-TLS-NEGATIVE.txt"; continue; fi
      printf 'scenario\t%s\t%s\t%s\t%s/%s\t%s\t%s\n' "$x" "$key" "$st" "$a" "$f" "$(sha256sum "$out/$a/$f" | cut -d' ' -f1)" "$gen" >>"$r"
    done <"$s/observations.tsv"
  done
  for p in haproxy socat; do for y in standard hardened; do
    printf 'cell\tmacos\t%s\t%s\tmac\tunqualified=-\tblocked\n' "$p" "$y" >>"$r"
  done; done
  printf 'result=pass\n' >>"$out/TR-TLS-NEGATIVE.txt"
  printf 'scenario\tTR-TLS-NEGATIVE\t-\tpass\tTR-TLS-NEGATIVE.txt\t%s\t-\n' "$(sha256sum "$out/TR-TLS-NEGATIVE.txt" | cut -d' ' -f1)" >>"$r"
  assert_eq 4 "$(grep -c '^certificate=wrongname$' "$out/TR-TLS-NEGATIVE.txt")" "the negative TLS evidence covers all four cells"
  a="$(bash "$NICE_DNS_ROOT/tests/reports/verify.sh" check "$r" --require-proxies all --require-dep baseline 2>&1)"
  assert_rc 0 "$?" "the transport receipt verifies: $a"
  assert_match 'receipt=transport cells=4 scenarios=21 errors=0' "$a" "receipt summary"
  printf 'receipt\t%s\n' "$r" >"$CASE_DIR/receipt-path.tsv"
}
