# shellcheck shell=bash
# Group integration/route-transition (sub-plan 02, Task 2.1; ARCH-03,
# ARCH-04, ARCH-06, ARCH-09). Proves route selection on the ACTUAL candidate
# Unbound image, driven by the host library (lib/recovery.sh, Linux adapter):
#
#   apply_route --stage--> route dir (host) --mounted ro--> /etc/unbound/route
#       |  check-route (image)   rename   reload_keep_cache   readback (marker)
#       v
#   product Unbound --DoT--> 127.0.0.1:{853,18531,18532,18533} route stand-in
#                            (tests/fixtures/routerelay.py records the port)
#                                   --> DoT fixture (dns.fixture.test, good cert)
#
# All in one --network none namespace. Unbound runs its shipped config plus a
# TEST-ONLY overlay (fixture CA as tls-cert-bundle, fixture trust anchor); the
# root forward-zone is the managed include and nothing else. The route table
# is a test copy of routes/providers.tsv whose TLS names are the fixture's,
# so Unbound's own TLS client authenticates every session it forwards. The
# production pod, its containers and images are never touched; containers
# are named nd-test-rt-<run id>-<case>-*. Only controlled fixture names are
# queried.
#
# Interruption cases replace nd_route_checkpoint (the library's step hook) in
# a subshell: "exit" simulates a crash at that step, "return 1" a failed step.

# shellcheck source=tests/fixtures/fixture.sh
. "$NICE_DNS_ROOT/tests/fixtures/fixture.sh"
# shellcheck source=tests/fixtures/unbound-image.sh
. "$NICE_DNS_ROOT/tests/fixtures/unbound-image.sh"
# shellcheck source=lib/recovery.sh
ND_PLATFORM=linux . "$NICE_DNS_ROOT/lib/recovery.sh"

RT_WARN="level=warning msg=\"The storage 'driver' option"
RT_RELAY_PY="$NICE_DNS_ROOT/tests/fixtures/routerelay.py"
RT_CTL=/usr/share/nice-dns/control.conf
RT_START=/usr/local/bin/nice-dns-unbound-start

# ─────────────────────────── plumbing ────────────────────────────────────────

rt_pm() {
  RT_OUT="$(podman "$@" 2>&1)"
  RT_RC=$?
  RT_OUT="$(printf '%s\n' "$RT_OUT" | grep -v -- "$RT_WARN")"
}

rt_ns() { rt_pm unshare nsenter -t "$RT_NSPID" -n "$@"; }

# rt_setup: images, names, the library's environment and the cleanup trap.
rt_setup() {
  RT_PFX="nd-test-rt-$RUN_ID-$(basename "$CASE_DIR" | tr '_' '-')"
  RT_CTRS="" RT_WRAPS="" RT_NSPID=""
  trap rt_cleanup EXIT
  ub_images
  ND_ROUTE_DIR="$CASE_DIR/route" ND_ROUTES_FILE="$CASE_DIR/providers.tsv" ND_UNBOUND_CONTAINER="$RT_PFX-ub"
  # apply_route proves a new route resolves with this name (the fixture
  # refuses the default ".").
  ND_ROUTE_PROBE_NAME=signed.fixture.test
  export ND_ROUTE_DIR ND_ROUTES_FILE ND_UNBOUND_CONTAINER ND_ROUTE_PROBE_NAME
  # The shipped table with the fixture's TLS name on every route.
  awk -F '\t' 'BEGIN { OFS = "\t" } /^#/ || NF != 5 || $1 == "schema" { print; next } { $3 = "dns.fixture.test"; print }' \
    "$NICE_DNS_ROOT/routes/providers.tsv" >"$ND_ROUTES_FILE"
  assert_eq 5 "$(grep -cv '^#' "$ND_ROUTES_FILE")" "test route table has the schema row and four routes"
}

rt_cleanup() {
  local c rev="" p
  for p in "$CASE_DIR"/fx/pypid "$CASE_DIR"/relay/pypid; do [ -f "$p" ] && kill "$(cat "$p")" 2>/dev/null; done
  for p in $RT_WRAPS; do kill "$p" 2>/dev/null; wait "$p" 2>/dev/null; done
  for c in $RT_CTRS; do rev="$c $rev"; done
  for c in $rev; do podman rm -f -t 0 "$c" >/dev/null 2>&1; done
  return 0
}

rt_holder() {
  local n="$RT_PFX-ns"
  RT_CTRS="$RT_CTRS $n"
  rt_pm run -d --name "$n" --network none --entrypoint /bin/sleep "$UB_IMG" 900
  assert_rc 0 "$RT_RC" "network namespace holder starts: $RT_OUT"
  RT_HOLDER="$n"
  RT_NSPID="$(podman inspect -f '{{.State.Pid}}' "$n" 2>/dev/null)"
  assert_match '^[1-9][0-9]*$' "$RT_NSPID" "holder has a pid"
}

# rt_bg <dir> <cmd...>: a host process inside the namespace; its pid in <dir>/pypid.
rt_bg() {
  local d="$1"
  shift
  podman unshare nsenter -t "$RT_NSPID" -n sh -c 'echo $$ >"$1/pypid"; shift; exec "$@"' sh "$d" "$@" \
    >"$d/log" 2>&1 </dev/null &
  RT_WRAPS="$RT_WRAPS $!"
}

# rt_fixture: the DoT fixture (good certificate) and the route stand-in on
# 853 and 18531-18533, relaying to it.
rt_fixture() {
  local d="$CASE_DIR/fx" r="$CASE_DIR/relay" i=0
  mkdir -m 700 "$d" "$r" || fail "cannot create fixture dirs"
  python3 "$FX_PY" pki --out "$d/pki" >"$d/pki.log" 2>&1 || fail "fixture pki failed: $(cat "$d/pki.log")"
  chmod 644 "$d/pki/ca.pem"
  rt_bg "$d" python3 "$FX_PY" serve --state "$d" --max-seconds "${FX_MAX_SECONDS:-600}" --tls "good:$d/pki/good.pem:$d/pki/good.key"
  while [ ! -f "$d/ports.tsv" ]; do
    i=$((i + 1)); [ "$i" -le 300 ] || fail "DoT fixture did not start: $(cat "$d/log")"; sleep 0.05
  done
  rt_bg "$r" python3 "$RT_RELAY_PY" --state "$r" --target "$(fx_port "$d" dot-good)" --listen 853,18531,18532,18533 --max-seconds 600
  i=0
  while [ ! -f "$r/ready" ]; do
    i=$((i + 1)); [ "$i" -le 300 ] || fail "route stand-in did not start: $(cat "$r/log")"; sleep 0.05
  done
}

# rt_overlay: TEST-ONLY config = the product config from the image plus the
# fixture CA and trust anchor. The managed include stays the only root zone.
rt_overlay() {
  RT_OVERLAY="$CASE_DIR/overlay.conf"
  rt_pm run --rm --network none --entrypoint /bin/cat "$UB_IMG" /etc/unbound/unbound.conf
  assert_rc 0 "$RT_RC" "product config readable from the image"
  {
    printf '%s\n' "$RT_OUT"
    printf '\n# ---- TEST-ONLY overlay (tests/integration/route-transition.sh) ----\n'
    printf 'server:\n    tls-cert-bundle: "/fx/ca.pem"\n    local-zone: "test." nodefault\n    '
    cat "$CASE_DIR/fx/anchor.unbound"
  } >"$RT_OVERLAY"
  chmod 644 "$RT_OVERLAY"
}

# rt_unbound: the product image on the overlay with the route dir mounted
# read-only; waits until it answers.
rt_unbound() {
  local i=0
  RT_CTRS="$RT_CTRS $ND_UNBOUND_CONTAINER"
  rt_pm run -d --name "$ND_UNBOUND_CONTAINER" --network "container:$RT_HOLDER" \
    -v "$RT_OVERLAY:/etc/unbound/unbound.conf:ro" -v "$CASE_DIR/fx/pki/ca.pem:/fx/ca.pem:ro" \
    -v "$ND_ROUTE_DIR:/etc/unbound/route:ro" "$UB_IMG"
  assert_rc 0 "$RT_RC" "product Unbound created: $RT_OUT"
  while [ "$i" -lt 60 ]; do
    rt_ns dig @127.0.0.1 -p 5335 +time=1 +tries=1 localhost A
    case "$RT_OUT" in *'status: NOERROR'*) return 0 ;; esac
    if [ "$(podman inspect -f '{{.State.Running}}' "$ND_UNBOUND_CONTAINER" 2>/dev/null)" != true ]; then
      fail "product Unbound exited: $(podman logs "$ND_UNBOUND_CONTAINER" 2>&1 | grep -v -- "$RT_WARN" | tail -n 10)"
    fi
    i=$((i + 1)); sleep 0.5
  done
  fail "product Unbound never answered: $(podman logs "$ND_UNBOUND_CONTAINER" 2>&1 | tail -n 10)"
}

# rt_stack <route> <generation>: namespace, fixture, seeded route, Unbound.
rt_stack() {
  rt_setup
  rt_holder
  rt_fixture
  rt_call seed_route "$1" "$2"
  assert_rc 0 "$RT_RRC" "route $1 seeded: $RT_RES"
  rt_overlay
  rt_unbound
}

# rt_call <function args...>: RT_RES (its key<TAB>value output), RT_RRC.
rt_call() { RT_RES="$("$@" 2>&1)"; RT_RRC=$?; }
rt_f() { printf '%s\n' "$RT_RES" | awk -F '\t' -v k="$1" '$1 == k { print $2; exit }'; }

rt_query() { rt_ns dig @127.0.0.1 -p 5335 +time=20 +tries=1 +adflag "$1" A; }

# rt_resolves_via <port>: a fresh name resolves (validated NXDOMAIN) and only
# that route port carried it.
rt_resolves_via() {
  : >"$CASE_DIR/relay/connects.tsv"
  rt_query "n$RANDOM$RANDOM.fixture.test"
  assert_match 'status: NXDOMAIN' "$RT_OUT" "a fresh name resolves through the selected route"
  assert_match 'flags: qr rd ra ad;' "$RT_OUT" "the answer through the route is validated (AD)"
  assert_eq "$1" "$(sort -u "$CASE_DIR/relay/connects.tsv" | tr '\n' ' ' | sed 's/ $//')" "only route port $1 carried the query"
}

rt_ctl() { rt_pm exec --user unbound "$ND_UNBOUND_CONTAINER" unbound-control -c "$RT_CTL" "$@"; }

rt_queries() {
  rt_ctl stats_noreset
  printf '%s\n' "$RT_OUT" | awk -F= '$1 == "total.num.queries" { print $2 }'
}

rt_sha() { if [ -f "$1" ]; then sha256sum <"$1" | cut -d' ' -f1; else printf 'absent\n'; fi; }

# rt_state: active include + desired + running route, for before/after comparison.
rt_state() {
  printf '%s|%s|%s\n' "$(rt_sha "$ND_ROUTE_DIR/forward-route.conf")" "$(rt_sha "$ND_ROUTE_DIR/desired.tsv")" "$(route_readback)"
}

# ─────────────────────────── cases: selection and activation ─────────────────

t_seeded_route_carries_queries_and_reads_back() {
  rt_stack cloudflare-onion 1
  assert_eq "cloudflare-onion	1	127.0.0.1" "$(route_readback)" "runtime readback names the seeded route"
  rt_resolves_via 18531
}

t_route_change_applies_through_reload_keep_cache() {
  local before after o
  rt_stack cloudflare-onion 1
  rt_query signed.fixture.test
  assert_match 'signed\.fixture\.test\..*IN[[:space:]]+A[[:space:]]+192\.0\.2\.1' "$RT_OUT" "signed answer cached on the first route"
  before=""
  for o in num-threads msg-cache-size rrset-cache-size neg-cache-size control-interface interface port outgoing-num-tcp so-rcvbuf; do
    rt_ctl get_option "$o"; before="$before$o=$RT_OUT;"
  done
  rt_call apply_route quad9-exit 2
  assert_rc 0 "$RT_RRC" "apply_route succeeds: $RT_RES"
  assert_eq applied "$(rt_f result)" "result is applied"
  assert_eq "127.0.0.1@18533#dns.fixture.test" "$(rt_f forwarder)" "forwarder is the table's quad9-exit route"
  assert_eq "quad9-exit	2	127.0.0.1" "$(route_readback)" "runtime readback names the new route and generation"
  assert_eq 0 "$(rt_queries)" "the change was a reload (query counters reset)"
  after=""
  for o in num-threads msg-cache-size rrset-cache-size neg-cache-size control-interface interface port outgoing-num-tcp so-rcvbuf; do
    rt_ctl get_option "$o"; after="$after$o=$RT_OUT;"
  done
  assert_eq "$before" "$after" "socket, thread and cache settings are unchanged by the route change"
  rt_ctl dump_cache
  assert_match '^signed\.fixture\.test\.' "$RT_OUT" "the message/RRset cache survived the reload"
  : >"$CASE_DIR/relay/connects.tsv"
  rt_query signed.fixture.test
  assert_match 'signed\.fixture\.test\..*192\.0\.2\.1' "$RT_OUT" "cached answer served after the change"
  assert_eq "" "$(cat "$CASE_DIR/relay/connects.tsv")" "the cached answer needed no upstream session"
  rt_resolves_via 18533
  assert_no_path "$ND_ROUTE_DIR/.forward-route.conf.staged" "no staged file left behind"
  assert_file "$ND_ROUTE_DIR/.forward-route.conf.prev" "the previous include is kept for rollback"
}

t_unchanged_route_is_not_reloaded() {
  local n
  rt_stack cloudflare-exit 1
  rt_resolves_via 18532
  n="$(rt_queries)"
  assert_match '^[1-9][0-9]*$' "$n" "queries were counted before the call"
  rt_call apply_route cloudflare-exit 2
  assert_rc 0 "$RT_RRC" "re-applying the running route succeeds: $RT_RES"
  assert_eq unchanged "$(rt_f result)" "result is unchanged"
  assert_eq 1 "$(rt_f generation)" "the running generation is still the seeded one"
  assert_eq 2 "$(rt_f desired_generation)" "the request is recorded as desired"
  assert_eq "$n" "$(rt_queries)" "no reload happened (query counters not reset)"
  assert_no_path "$ND_ROUTE_DIR/.forward-route.conf.prev" "no file was replaced"
}

t_every_listed_route_applies_and_carries_queries() {
  local r p g=1
  rt_stack cloudflare-legacy 1
  rt_resolves_via 853
  for r in cloudflare-onion:18531 cloudflare-exit:18532 quad9-exit:18533 cloudflare-legacy:853; do
    g=$((g + 1)); p="${r#*:}"; r="${r%%:*}"
    rt_call apply_route "$r" "$g"
    assert_eq applied "$(rt_f result)" "$r applies: $RT_RES"
    assert_eq "$r	$g	127.0.0.1" "$(route_readback)" "$r reads back"
    rt_resolves_via "$p"
  done
}

# ─────────────────────────── cases: refusals ─────────────────────────────────

t_unlisted_route_refused() {
  local s
  rt_stack cloudflare-onion 1
  s="$(rt_state)"
  for r in evil-exit direct 'cloudflare-onion;x' ''; do
    rt_call apply_route "$r" 2
    assert_rc 2 "$RT_RRC" "route '$r' is refused: $RT_RES"
    assert_eq refused "$(rt_f result)" "result is refused for '$r'"
  done
  assert_eq "$s" "$(rt_state)" "include, desired state and running route are unchanged"
  rt_resolves_via 18531
}

t_missing_tls_name_refused() {
  local s
  rt_stack cloudflare-onion 1
  s="$(rt_state)"
  # A table row without a TLS name makes the whole table unusable.
  awk -F '\t' 'BEGIN { OFS = "\t" } $1 == "quad9-exit" { $3 = "" } { print }' "$ND_ROUTES_FILE" >"$CASE_DIR/t2" && mv "$CASE_DIR/t2" "$ND_ROUTES_FILE"
  rt_call apply_route quad9-exit 2
  assert_rc 2 "$RT_RRC" "a route with no TLS name is refused: $RT_RES"
  assert_match 'missing or invalid TLS name' "$(rt_f detail)" "the refusal names the missing TLS name"
  rt_call apply_route cloudflare-exit 2
  assert_rc 2 "$RT_RRC" "any route from a table with a nameless row is refused: $RT_RES"
  assert_eq "$s" "$(rt_state)" "nothing changed"
  # The image refuses an include whose forwarder has no TLS name.
  _nd_route_render cloudflare-exit 3 "127.0.0.1@18532" >"$ND_ROUTE_DIR/.forward-route.conf.staged"
  chmod 644 "$ND_ROUTE_DIR/.forward-route.conf.staged"
  rt_pm exec --user unbound "$ND_UNBOUND_CONTAINER" "$RT_START" check-route /etc/unbound/route/.forward-route.conf.staged
  assert_rc 1 "$RT_RC" "check-route refuses a forwarder without #name: $RT_OUT"
  assert_match 'forward-addr ADDR@PORT#TLS-NAME' "$RT_OUT" "the refusal names the TLS name rule"
}

# rt_check_refuses <label> <include text> <ERE>: check-route in the running
# image refuses the text, naming the rule.
rt_check_refuses() {
  printf '%s\n' "$2" >"$ND_ROUTE_DIR/.forward-route.conf.staged"
  chmod 644 "$ND_ROUTE_DIR/.forward-route.conf.staged"
  rt_pm exec --user unbound "$ND_UNBOUND_CONTAINER" "$RT_START" check-route /etc/unbound/route/.forward-route.conf.staged
  assert_rc 1 "$RT_RC" "check-route refuses $1: $RT_OUT"
  assert_match "$3" "$RT_OUT" "the refusal for $1 names the rule"
}

t_direct_fallback_refused() {
  local good
  rt_stack cloudflare-onion 1
  good="$(cat "$ND_ROUTE_DIR/forward-route.conf")"
  rt_check_refuses "forward-first yes" "$(printf '%s\n' "$good" | sed 's/forward-first: no/forward-first: yes/')" 'forward-first: no is required|not allowed'
  rt_check_refuses "no forward-first line" "$(printf '%s\n' "$good" | grep -v 'forward-first')" 'forward-first: no is required'
  rt_check_refuses "no forward-zone (direct recursion)" "$(printf '%s\n' "$good" | sed '/^forward-zone:/,$d')" 'exactly one forward-zone'
  rt_check_refuses "TLS off" "$(printf '%s\n' "$good" | sed 's/forward-tls-upstream: yes/forward-tls-upstream: no/')" 'forward-tls-upstream: yes is required|not allowed'
  rt_check_refuses "two forwarders" "$(printf '%s\n    forward-addr: 127.0.0.1@18532#dns.fixture.test\n' "$good")" 'exactly one forward-addr'
  rt_check_refuses "an out-of-range port" "$(printf '%s\n' "$good" | sed 's/@18531#/@185310#/')" 'exactly one forward-addr'
  rt_check_refuses "a non-root zone name" "$(printf '%s\n' "$good" | sed 's/name: "\."/name: "fixture.test."/')" 'must be for the root|not allowed'
  rt_check_refuses "a server option" "$(printf '%s\nserver:\n    num-threads: 4\n' "$good")" 'not allowed in the route include'
  rt_check_refuses "no route marker" "$(printf '%s\n' "$good" | grep -v 'nice-dns-route')" 'route marker'
  rt_pm exec --user unbound "$ND_UNBOUND_CONTAINER" "$RT_START" check-route '/tmp/a#b'
  assert_rc 1 "$RT_RC" "check-route refuses a path it cannot safely substitute: $RT_OUT"
  assert_match 'unsafe route include path' "$RT_OUT" "the refusal names the unsafe path"
  # The entrypoint refuses to START Unbound on an include without a forward-zone.
  printf '%s\n' "$good" | sed '/^forward-zone:/,$d' >"$CASE_DIR/nofwd.conf"
  mkdir -m 755 "$CASE_DIR/nofwd" && cp "$CASE_DIR/nofwd.conf" "$CASE_DIR/nofwd/forward-route.conf" && chmod 644 "$CASE_DIR/nofwd/forward-route.conf"
  rt_pm run --rm --network none -v "$CASE_DIR/nofwd:/etc/unbound/route:ro" "$UB_IMG"
  assert_rc 1 "$RT_RC" "Unbound is not started on an include without a forward-zone"
  assert_match 'FATAL: route include /etc/unbound/route/forward-route.conf refused' "$RT_OUT" "the entrypoint names the refused include"
  # ...and on a main config carrying its own root forward-zone.
  { cat "$RT_OVERLAY"; printf 'stub-zone:\n    name: "."\n    stub-addr: 192.0.2.53\n'; } >"$CASE_DIR/rootstub.conf"
  chmod 644 "$CASE_DIR/rootstub.conf"
  rt_pm run --rm --network none -v "$CASE_DIR/rootstub.conf:/etc/unbound/unbound.conf:ro" \
    -v "$CASE_DIR/fx/pki/ca.pem:/fx/ca.pem:ro" -v "$ND_ROUTE_DIR:/etc/unbound/route:ro" "$UB_IMG"
  assert_rc 1 "$RT_RC" "Unbound is not started with a second root zone in the main config"
  assert_match 'defines a root zone outside' "$RT_OUT" "the entrypoint names the second root zone"
}

t_stale_generation_conflicts() {
  local s
  rt_stack cloudflare-onion 1
  rt_call apply_route quad9-exit 5
  assert_eq applied "$(rt_f result)" "generation 5 applies: $RT_RES"
  assert_eq "schema	nice-dns-route-desired/1" "$(head -n 1 "$ND_ROUTE_DIR/desired.tsv")" "desired.tsv names its schema"
  s="$(rt_state)"
  rt_call apply_route cloudflare-exit 3
  assert_rc 4 "$RT_RRC" "an older generation conflicts: $RT_RES"
  rt_call apply_route cloudflare-exit 5
  assert_rc 4 "$RT_RRC" "the same generation for another route conflicts: $RT_RES"
  for g in 0 -1 07 abc ''; do
    rt_call apply_route cloudflare-exit "$g"
    assert_rc 2 "$RT_RRC" "generation '$g' is refused: $RT_RES"
  done
  assert_eq "$s" "$(rt_state)" "nothing changed"
}

t_refused_when_unbound_is_not_running() {
  local inc
  rt_stack cloudflare-onion 1
  inc="$(rt_sha "$ND_ROUTE_DIR/forward-route.conf")"
  podman stop -t 2 "$ND_UNBOUND_CONTAINER" >/dev/null 2>&1
  rt_call apply_route quad9-exit 2
  assert_rc 2 "$RT_RRC" "no change without a running Unbound to validate it: $RT_RES"
  assert_eq "$inc" "$(rt_sha "$ND_ROUTE_DIR/forward-route.conf")" "the active include is untouched"
  assert_no_path "$ND_ROUTE_DIR/.forward-route.conf.staged" "the staged file is removed"
  rt_call reconcile_route
  assert_rc 3 "$RT_RRC" "reconcile escalates while control is unreachable: $RT_RES"
  assert_eq "$inc" "$(rt_sha "$ND_ROUTE_DIR/forward-route.conf")" "reconcile touched nothing"
}

t_unsafe_route_directory_refused() {
  local real="$CASE_DIR/real-route"
  rt_setup
  ND_ROUTE_DIR="$real" rt_call seed_route cloudflare-onion 1
  assert_rc 0 "$RT_RRC" "seed into a fresh directory: $RT_RES"
  ln -s "$real" "$CASE_DIR/link-route"
  ND_ROUTE_DIR="$CASE_DIR/link-route" rt_call apply_route quad9-exit 2
  assert_rc 2 "$RT_RRC" "a symlinked route directory is refused: $RT_RES"
  assert_match 'symlink' "$(rt_f detail)" "the refusal names the symlink"
  chmod 0775 "$real"
  ND_ROUTE_DIR="$real" rt_call apply_route quad9-exit 2
  assert_rc 2 "$RT_RRC" "a group-writable route directory is refused: $RT_RES"
  chmod 0755 "$real"
  chmod 0664 "$real/forward-route.conf"
  ND_ROUTE_DIR="$real" rt_call apply_route quad9-exit 2
  assert_rc 2 "$RT_RRC" "a group-writable include is refused: $RT_RES"
  assert_match 'forward-route.conf is writable by group or others' "$(rt_f detail)" "the refusal names the include's mode"
  chmod 0644 "$real/forward-route.conf"
  mv "$real/forward-route.conf" "$real/elsewhere.conf" && ln -s elsewhere.conf "$real/forward-route.conf"
  ND_ROUTE_DIR="$real" rt_call apply_route quad9-exit 2
  assert_rc 2 "$RT_RRC" "a symlinked include is refused: $RT_RES"
  ND_ROUTE_DIR="$real" rt_call seed_route cloudflare-onion 1
  assert_rc 2 "$RT_RRC" "seeding over an existing include is refused: $RT_RES"
}

# ─────────────────────────── cases: the route at start ───────────────────────
# Sub-plan 5 Task 1.4 (fix A, ARCH-04's startup rule): before Unbound starts,
# a persisted onion include is demoted to the seed exit, so the first queries
# after a restart never wait for a cold rendezvous (mac 2026-09-29: 56 s,
# until the controller's next tick). Unbound is not running yet: files only,
# under the controller's state lock.

rt_start_setup() {
  rt_setup
  ND_STATE_DIR="$CASE_DIR/state" ND_BOOT_ID=boot-a
  export ND_STATE_DIR ND_BOOT_ID
  # The proxy container's generation line, as the platform reads it; unset:
  # no proxy container is readable (the macOS agent creates it after Unbound).
  RT_PGEN=""
  nd_platform_container_generation() { [ -n "$RT_PGEN" ] && printf '%s\n' "$RT_PGEN"; }
}

# rt_recorded_proxy <generation line>: the controller's state records that
# proxy generation (its hash), as a pass does.
rt_recorded_proxy() {
  nd_state_init
  { _nd_state_default; printf 'proxy_gen\t%s\n' "$(nd_generation_hash "$1")"; } >"$ND_STATE_DIR/state.tsv"
  nd_state_load >/dev/null
  assert_rc 0 $? "the state with a proxy_gen is valid"
}

t_start_demotes_a_persisted_onion_to_the_exit() {
  local onion
  rt_start_setup
  rt_call seed_route cloudflare-onion 7
  assert_rc 0 "$RT_RRC" "an onion include, as the controller left it: $RT_RES"
  onion="$(cat "$ND_ROUTE_DIR/forward-route.conf")"
  rt_call start_route
  assert_rc 0 "$RT_RRC" "the start demotes the onion: $RT_RES"
  assert_eq applied "$(rt_f result)" "result"
  assert_eq cloudflare-exit "$(rt_f route)" "the seed exit is selected"
  assert_eq 8 "$(rt_f generation)" "at the next generation"
  assert_eq "cloudflare-exit	8	127.0.0.1@18532#dns.fixture.test" "$(_nd_route_file_info "$ND_ROUTE_DIR/forward-route.conf")" "the include names the exit"
  assert_eq "$(printf 'schema\tnice-dns-route-desired/1\nroute\tcloudflare-exit\ngeneration\t8')" "$(cat "$ND_ROUTE_DIR/desired.tsv")" "desired follows"
  assert_eq 644 "$(stat -c %a "$ND_ROUTE_DIR/forward-route.conf")" "the include stays readable by Unbound"
  assert_eq "$onion" "$(cat "$ND_ROUTE_DIR/.forward-route.conf.prev")" "the onion include is kept as the previous one"
  assert_no_path "$ND_STATE_DIR/lock" "the state lock is released"
  # Unbound then starts on the exit and resolves through it.
  rt_holder
  rt_fixture
  rt_overlay
  rt_unbound
  assert_eq "cloudflare-exit	8	127.0.0.1" "$(route_readback)" "Unbound runs the exit"
  rt_resolves_via 18532
}

# Tier-1 review I1: Unbound restarting alone (the proxy did not restart) keeps
# its onion; a demotion there would stick, since the controller's state
# would still say onion and nothing re-selects.
t_start_keeps_the_onion_of_a_proxy_that_did_not_restart() {
  local before
  rt_start_setup
  rt_call seed_route cloudflare-onion 7
  rt_recorded_proxy "abc123 2026-09-29T20:00:00Z running"
  RT_PGEN="abc123 2026-09-29T20:00:00Z running"
  before="$(rt_sha "$ND_ROUTE_DIR/forward-route.conf")|$(rt_sha "$ND_ROUTE_DIR/desired.tsv")"
  rt_call start_route
  assert_rc 0 "$RT_RRC" "the same proxy: $RT_RES"
  assert_eq kept "$(rt_f result)" "kept"
  assert_match 'not fresh' "$(rt_f detail)" "the detail says why"
  assert_eq "$before" "$(rt_sha "$ND_ROUTE_DIR/forward-route.conf")|$(rt_sha "$ND_ROUTE_DIR/desired.tsv")" "include and desired untouched"
  assert_no_path "$ND_STATE_DIR/lock" "the state lock is released"
}

t_start_demotes_when_the_proxy_restarted() {
  rt_start_setup
  rt_call seed_route cloudflare-onion 7
  rt_recorded_proxy "abc123 2026-09-29T20:00:00Z running"
  RT_PGEN="def456 2026-09-29T21:00:00Z running"
  rt_call start_route
  assert_rc 0 "$RT_RRC" "a restarted proxy: $RT_RES"
  assert_eq applied "$(rt_f result)" "demoted"
  assert_eq "cloudflare-exit	8" "$(_nd_route_file_info "$ND_ROUTE_DIR/forward-route.conf" | cut -f1,2)" "to the exit"
  assert_match "generation $(nd_generation_hash "$RT_PGEN")" "$(rt_f detail)" "the detail names the fresh generation"
}

t_start_refuses_a_malformed_desired() {
  local before
  rt_start_setup
  rt_call seed_route cloudflare-onion 7
  printf 'not a desired file\n' >"$ND_ROUTE_DIR/desired.tsv"
  before="$(rt_sha "$ND_ROUTE_DIR/forward-route.conf")"
  rt_call start_route
  assert_rc 2 "$RT_RRC" "as apply_route refuses it: $RT_RES"
  assert_eq "$before" "$(rt_sha "$ND_ROUTE_DIR/forward-route.conf")" "the include is untouched"
  assert_no_path "$ND_STATE_DIR/lock" "the state lock is released"
}

t_start_keeps_an_exit_route() {
  local before
  rt_start_setup
  rt_call seed_route quad9-exit 3
  before="$(rt_sha "$ND_ROUTE_DIR/forward-route.conf")|$(rt_sha "$ND_ROUTE_DIR/desired.tsv")"
  rt_call start_route
  assert_rc 0 "$RT_RRC" "an exit route: $RT_RES"
  assert_eq kept "$(rt_f result)" "kept"
  assert_eq "$before" "$(rt_sha "$ND_ROUTE_DIR/forward-route.conf")|$(rt_sha "$ND_ROUTE_DIR/desired.tsv")" "the include and desired are untouched"
  assert_no_path "$ND_ROUTE_DIR/.forward-route.conf.prev" "no previous include is written"
}

t_start_without_an_include_changes_nothing() {
  rt_start_setup
  rt_call start_route
  assert_rc 0 "$RT_RRC" "no route directory: $RT_RES"
  assert_eq kept "$(rt_f result)" "nothing to demote"
  assert_no_path "$ND_ROUTE_DIR" "the directory is not created (seeding is the installers')"
}

t_start_goes_past_the_desired_generation() {
  rt_start_setup
  rt_call seed_route cloudflare-onion 7
  _nd_route_write_desired "$ND_ROUTE_DIR" cloudflare-onion 9
  rt_call start_route
  assert_rc 0 "$RT_RRC" "desired ahead of the include: $RT_RES"
  assert_eq 10 "$(rt_f generation)" "the new generation is past both"
}

t_start_skips_while_the_controller_holds_the_lock() {
  local tok before
  rt_start_setup
  rt_call seed_route cloudflare-onion 2
  before="$(rt_sha "$ND_ROUTE_DIR/forward-route.conf")"
  nd_state_init
  tok="$(nd_state_lock)"
  assert_ne "" "$tok" "the controller holds the lock"
  rt_call start_route
  assert_rc 3 "$RT_RRC" "busy: $RT_RES"
  assert_eq busy "$(rt_f result)" "result"
  assert_eq "$before" "$(rt_sha "$ND_ROUTE_DIR/forward-route.conf")" "the include is untouched"
  nd_state_lock_held "$tok"
  assert_rc 0 $? "the controller's lock is still its own"
  nd_state_unlock "$tok"
}

t_start_refuses_an_unsafe_directory() {
  local before
  rt_start_setup
  rt_call seed_route cloudflare-onion 2
  before="$(rt_sha "$ND_ROUTE_DIR/forward-route.conf")"
  chmod 0775 "$ND_ROUTE_DIR"
  rt_call start_route
  assert_rc 2 "$RT_RRC" "a group-writable directory: $RT_RES"
  assert_eq refused "$(rt_f result)" "result"
  assert_eq "$before" "$(rt_sha "$ND_ROUTE_DIR/forward-route.conf")" "the include is untouched"
  chmod 0755 "$ND_ROUTE_DIR"
}

# ─────────────────────────── cases: interruption and rollback ────────────────

t_interrupted_before_rename_keeps_route_then_reconciles() {
  local inc
  rt_stack cloudflare-onion 1
  inc="$(rt_sha "$ND_ROUTE_DIR/forward-route.conf")"
  RT_RES="$(nd_route_checkpoint() { [ "$1" != before-rename ] || exit 86; }; apply_route quad9-exit 2 2>&1)"
  assert_rc 86 "$?" "the change stopped (simulated crash) before the rename"
  assert_eq "$inc" "$(rt_sha "$ND_ROUTE_DIR/forward-route.conf")" "the active include is the old one"
  assert_eq "cloudflare-onion	1	127.0.0.1" "$(route_readback)" "the old route still runs"
  rt_resolves_via 18531
  rt_call reconcile_route
  assert_rc 0 "$RT_RRC" "reconcile applies the desired route: $RT_RES"
  assert_eq applied "$(rt_f result)" "reconcile result"
  assert_eq "quad9-exit	2	127.0.0.1" "$(route_readback)" "the desired route runs after reconcile"
  assert_no_path "$ND_ROUTE_DIR/.forward-route.conf.staged" "no staged leftover after reconcile"
  rt_resolves_via 18533
}

t_interrupted_after_rename_reconciles_by_reload() {
  rt_stack cloudflare-onion 1
  RT_RES="$(nd_route_checkpoint() { [ "$1" != after-rename ] || exit 86; }; apply_route cloudflare-exit 2 2>&1)"
  assert_rc 86 "$?" "the change stopped (simulated crash) after the rename, before the reload"
  assert_eq "cloudflare-exit	2	127.0.0.1@18532#dns.fixture.test" "$(_nd_route_file_info "$ND_ROUTE_DIR/forward-route.conf")" "the new include is in place"
  assert_eq "cloudflare-onion	1	127.0.0.1" "$(route_readback)" "the running route is still the old one (detectable by readback)"
  rt_call reconcile_route
  assert_rc 0 "$RT_RRC" "reconcile activates the renamed include: $RT_RES"
  assert_eq applied "$(rt_f result)" "reconcile result"
  assert_eq "cloudflare-exit	2	127.0.0.1" "$(route_readback)" "the desired route runs after reconcile"
  rt_resolves_via 18532
}

t_interrupted_after_reload_is_already_converged() {
  local n
  rt_stack cloudflare-onion 1
  RT_RES="$(nd_route_checkpoint() { [ "$1" != after-reload ] || exit 86; }; apply_route quad9-exit 2 2>&1)"
  assert_rc 86 "$?" "the change stopped (simulated crash) after the reload"
  rt_resolves_via 18533
  n="$(rt_queries)"
  rt_call reconcile_route
  assert_rc 0 "$RT_RRC" "reconcile: $RT_RES"
  assert_eq converged "$(rt_f result)" "reconcile finds the route converged"
  assert_eq "$n" "$(rt_queries)" "reconcile did not reload a converged route"
}

t_failed_activation_restores_previous_route() {
  rt_stack cloudflare-onion 1
  RT_RES="$(nd_route_checkpoint() { [ "$1" != after-reload ] || return 1; }; apply_route quad9-exit 2 2>&1)"
  RT_RRC=$?
  assert_rc 1 "$RT_RRC" "a failed activation reports restored: $RT_RES"
  assert_eq restored "$(rt_f result)" "result is restored"
  assert_eq "cloudflare-onion	1	127.0.0.1" "$(route_readback)" "the previous route runs again"
  assert_eq "cloudflare-onion	1	127.0.0.1@18531#dns.fixture.test" "$(_nd_route_file_info "$ND_ROUTE_DIR/forward-route.conf")" "the previous include is back in place"
  rt_resolves_via 18531
}

t_route_that_does_not_resolve_is_rolled_back() {
  # ARCH-04: a route is active only once it resolves. The probe query is
  # answered SERVFAIL by the fixture, so the new route must not stay.
  rt_stack cloudflare-onion 1
  ND_ROUTE_PROBE_NAME=servfail.fixture.test rt_call apply_route quad9-exit 2
  assert_rc 1 "$RT_RRC" "a route that does not resolve is rolled back: $RT_RES"
  assert_eq restored "$(rt_f result)" "result is restored"
  assert_match 'did not resolve.*SERVFAIL' "$(rt_f detail)" "the detail names the failed resolution"
  assert_eq "cloudflare-onion	1	127.0.0.1" "$(route_readback)" "the previous route runs again"
  rt_resolves_via 18531
}

t_failed_rollback_escalates_and_keeps_forwarding() {
  rt_stack cloudflare-onion 1
  RT_RES="$(nd_route_checkpoint() { case "$1" in after-reload|rollback-rename) return 1 ;; esac; }; apply_route quad9-exit 2 2>&1)"
  RT_RRC=$?
  assert_rc 3 "$RT_RRC" "a failed rollback escalates: $RT_RES"
  assert_eq escalate "$(rt_f result)" "result is escalate"
  assert_match 'interrupted before restoring' "$(rt_f detail)" "the detail names both failures"
  assert_eq "quad9-exit	2	127.0.0.1" "$(rt_f route)	$(rt_f generation)	$(rt_f forwarder)" "escalate reports what actually runs"
  rt_ctl list_forwards
  assert_eq 1 "$(printf '%s\n' "$RT_OUT" | grep -c '^\. IN forward ')" "the root forward-zone is still in place (no direct recursion)"
  rt_resolves_via 18533
}

# ─────────────────────────── cases: table and image contract ─────────────────

# shellcheck disable=SC2031  # r and d are loop variables of this shell, not the subshell's
t_rendered_routes_match_table_and_image_on_both_platforms() {
  local plat r want d exp ctr
  rt_setup
  mkdir -m 755 "$CASE_DIR/render"
  for plat in linux:127.0.0.1 macos:172.31.240.252; do
    for r in cloudflare-onion:18531:tor.cloudflare-dns.com cloudflare-exit:18532:one.one.one.one \
             quad9-exit:18533:dns.quad9.net cloudflare-legacy:853:tor.cloudflare-dns.com; do
      d="$CASE_DIR/render/${plat%%:*}-${r%%:*}"
      exp="${plat#*:}@$(printf '%s' "$r" | cut -d: -f2)#$(printf '%s' "$r" | cut -d: -f3)"
      RT_RES="$(
        unset -f nd_platform_name nd_platform_route_addr nd_platform_route_dir nd_platform_unbound_exec
        ND_PLATFORM="${plat%%:*}" ND_ROUTE_DIR="$d" ND_ROUTES_FILE="$NICE_DNS_ROOT/routes/providers.tsv"
        # shellcheck source=lib/recovery.sh
        . "$NICE_DNS_ROOT/lib/recovery.sh"
        seed_route "${r%%:*}" 1
      )"
      assert_eq "$exp" "$(rt_f forwarder)" "${plat%%:*} ${r%%:*} renders the shipped table's forwarder"
    done
  done
  # The image validates each rendering in a running container (check-route
  # runs where the anchor state exists, as apply_route uses it).
  ctr="$RT_PFX-render"
  RT_CTRS="$RT_CTRS $ctr"
  rt_pm run -d --name "$ctr" --network none -v "$CASE_DIR/render:/render:ro" "$UB_IMG"
  assert_rc 0 "$RT_RC" "product container with the renderings starts: $RT_OUT"
  for d in "$CASE_DIR"/render/*; do
    rt_pm exec --user unbound "$ctr" "$RT_START" check-route "/render/$(basename "$d")/forward-route.conf"
    assert_rc 0 "$RT_RC" "the image accepts the $(basename "$d") rendering: $RT_OUT"
  done
  assert_eq 8 "$(find "$CASE_DIR/render" -name forward-route.conf | grep -c .)" "eight renderings were checked"
  rt_pm exec "$ctr" cat /etc/unbound/route/forward-route.conf
  want="cloudflare-legacy	0	127.0.0.1@$(awk -F '\t' '$1 == "cloudflare-legacy" { print $2 "#" $3 }' "$NICE_DNS_ROOT/routes/providers.tsv")"
  printf '%s\n' "$RT_OUT" >"$CASE_DIR/image-default.conf"
  assert_eq "$want" "$(_nd_route_file_info "$CASE_DIR/image-default.conf")" "the image default is the table's legacy route"
  rt_pm exec --user unbound "$ctr" "$RT_START" check-route /etc/unbound/route/forward-route.conf
  assert_rc 0 "$RT_RC" "the image accepts its own default route: $RT_OUT"
}

t_shipped_table_is_valid_and_identity_bound() {
  local out
  out="$(ND_ROUTES_FILE="$NICE_DNS_ROOT/routes/providers.tsv" _nd_route_table quad9-exit 2>&1)"
  assert_rc 0 "$?" "the shipped table validates: $out"
  assert_eq "18533	dns.quad9.net	quad9	identity" "$out" "quad9-exit row"
  assert_eq "cloudflare-exit cloudflare-legacy cloudflare-onion quad9-exit" \
    "$(awk -F '\t' '!/^#/ && $1 != "schema" { print $1 }' "$NICE_DNS_ROOT/routes/providers.tsv" | LC_ALL=C sort | tr '\n' ' ' | sed 's/ $//')" \
    "exactly the three ARCH-04 routes plus the legacy endpoint"
  assert_eq "18531 18532 18533" \
    "$(awk -F '\t' '$5 == "identity" { print $2 }' "$NICE_DNS_ROOT/routes/providers.tsv" | LC_ALL=C sort | tr '\n' ' ' | sed 's/ $//')" \
    "identity routes use the ARCH-04 ports"
  printf 'schema\tnice-dns-routes/1\na\t18531\tx.test\tp\tidentity\nb\t18531\ty.test\tp\tidentity\n' >"$CASE_DIR/dup.tsv"
  out="$(ND_ROUTES_FILE="$CASE_DIR/dup.tsv" _nd_route_table a 2>&1)"
  assert_rc 2 "$?" "a port bound to two routes is refused: $out"
  printf 'a\t18531\tx.test\tp\tidentity\n' >"$CASE_DIR/noschema.tsv"
  out="$(ND_ROUTES_FILE="$CASE_DIR/noschema.tsv" _nd_route_table a 2>&1)"
  assert_rc 2 "$?" "a table without its schema row is refused: $out"
}

t_mac_installers_rewrite_the_route_include() {
  # Since Sub-plan 4 Task 1.1 the rewrite lives in lib/install.sh
  # (nd_install_macos_rewrite_tree), which both macOS entrypoints reach
  # through nd_install_macos_stage_tree.
  local f expr out d="$CASE_DIR/tree"
  for f in install-mac.sh install-mac-hardened.sh; do
    assert_eq 1 "$(grep -c '^nd_install_macos_stage_tree$' "$NICE_DNS_ROOT/$f")" "$f stages (and rewrites) its build tree"
  done
  expr="$(grep -o "'s|^    forward-addr: 127[^']*'" "$NICE_DNS_ROOT/lib/install.sh" | tr -d "'")"
  assert_eq 1 "$(printf '%s\n' "$expr" | grep -c .)" "lib/install.sh carries exactly one forward-address rewrite"
  mkdir -p "$d/unbound/etc" "$d/unbound/route"
  cp "$NICE_DNS_ROOT/unbound/etc/unbound.conf" "$d/unbound/etc/"
  cp "$NICE_DNS_ROOT/unbound/route/forward-route.conf" "$d/unbound/route/"
  # shellcheck source=/dev/null
  ( . "$NICE_DNS_ROOT/lib/install.sh" && nd_install_macos_rewrite_tree "$d" )
  assert_rc 0 "$?" "the macOS rewrite applies"
  out="$(cat "$d/unbound/route/forward-route.conf")"
  assert_match '^    forward-addr: 172\.31\.240\.252@853#tor\.cloudflare-dns\.com$' "$out" "the rewrite points the default route at the proxy container"
  assert_not_match '127\.0\.0\.1@' "$out" "no loopback forwarder is left"
}
