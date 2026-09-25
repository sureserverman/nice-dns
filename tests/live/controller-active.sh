# shellcheck shell=bash
# Group live/controller-active (Sub-plan 3, Task 2.3's test-only activation
# and final-gate scenarios; ARCH-09). Run by the Stage 2 gate:
#   tests/run.sh plan controller --fresh-fixtures --include-slow --live \
#     --targets FILE --matrix all
#
# The controller acts here (install-controller --mode active), on the
# designated disposable targets only, with the proxy image built there from
# the sibling checkout. Per cell (all four of a platform with --matrix all,
# each installed fresh with the product's installer at origin/main and the
# target's original cell last; otherwise the cell the target runs):
#   CT-PROBES            the observations of a working chain; one active pass
#                        a minute
#   CT-PRIMARY-ONLY      the preferred route fails while the others work: no
#                        Tor restart, no repair
#   CT-RECOVERY-ACK      Tor frozen, then thawed when the image claims the
#                        restart request: requested -> acknowledged (a new tor
#                        generation in the same container) -> ready; Tor left
#                        frozen: the in-image restart is not acknowledged and
#                        the one service fallback is (a new container start;
#                        macOS restarts the whole stack) -> ready
#   CT-CACHE-VS-UPSTREAM a cached answer during the outage never stops the
#                        outage clock
#   CT-RUNTIME-WEDGE     macOS: a container on the default network wedges
#                        dnsnet; Linux: pi-hole.service stops. The controller
#                        recovers the chain on its own
#   CT-BRIDGES           (first, before the proxy is recreated) the bridge
#                        refresh applies or keeps the set without restarting
#                        the proxy; the recreate then starts Tor on it
# Then, once per platform on its final cell:
#   CT-WAKE              the user sleeps and wakes the target by hand (the
#                        case waits up to an hour for the sleep counter): the
#                        schedule runs again on wake, one pass a minute, with
#                        no recovery caused by the time jump
# t_3_receipt assembles <artifact root>/receipts/controller/RUN_ID/ from the
# cells of this run and verifies it (--require-platforms all, the transport
# receipt linked; --require-matrix all under --matrix all).

# shellcheck source=tests/live/controller-lib.sh
. "$NICE_DNS_ROOT/tests/live/controller-lib.sh"

CA_ROOT_DIR="" CA_CELL_DIR=""
cs_dir() { printf '%s\n' "$CA_CELL_DIR"; }

ca_matrix_all() { [ "${NICE_DNS_OPT_MATRIX:-}" = all ]; }

# ca_observe <scenario> <file>: a passed scenario of the current cell.
ca_observe() { printf '%s\tpass\t%s\n' "$1" "$2" >>"$CA_CELL_DIR/observations.tsv"; }

# ca_rows <report> <since> <component> <phase>: active journal rows.
ca_rows() { cs_jrows "$1" journal-active "$2" | awk -F '\t' -v c="$3" -v p="$4" '$3 == c && $4 == p'; }

ca_up() { cs_route_up "$1" && [ "$(cs_obs "$1" local-service)" = healthy ]; }

# ─────────────────────────── one cell ────────────────────────────────────────

ca_deploy() {
  local a="$1" x="$2" h="$3" fresh="$4" d="$CA_CELL_DIR" sha psha base args
  sha="$(git -C "$NICE_DNS_ROOT" rev-parse HEAD)"
  assert_eq "" "$(cs_clean "$CS_SIBS/tor-$x")" "$a: the tor-$x sibling is committed"
  psha="$(git -C "$CS_SIBS/tor-$x" rev-parse HEAD)"
  if [ "$fresh" = 1 ]; then
    base="$(git -C "$NICE_DNS_ROOT" rev-parse origin/main)"
    args=(--cell "$x/$h" --source-sha "$base")
    [ "$h" = hardened ] && args+=(--hardened-sha "$(git -C "$CS_SIBS/pi-hole-hardened" rev-parse HEAD)")
    # The installer's output may carry bridge lines: it stays out of the evidence.
    cs_t "$a" install-cell "${args[@]}" >"$CASE_DIR/install-$x-$h.log" 2>&1 \
      || fail "$a $x/$h: install-cell failed: $(grep -E '^(installer_exit|github_main)' "$CASE_DIR/install-$x-$h.log" | tr '\n' ' ')"
    printf 'installed\t%s/%s\t%s\n' "$x" "$h" "$base" >>"$d/deploy.tsv"
  fi
  cs_t "$a" quiesce-agents >"$d/quiesce.tsv" 2>>"$d/ops.log" || fail "$a: quiesce-agents"
  cs_t "$a" install-controller --source-sha "$sha" --mode active >"$d/install.log" 2>&1 || fail "$a: install-controller: $(tail -n 5 "$d/install.log")"
  assert_match '^receipt	mode	active$' "$(cat "$d/install.log")" "$a: the controller is installed active (test-only activation)"
  # CT-BRIDGES before the proxy is recreated: the refresh restarts nothing,
  # and the recreate then starts Tor on the freshly evaluated set (live run
  # 20260925T200235Z-e3b4de89: mint's Tor lost its thin set minutes after a
  # recreate, which took every route down mid-scenario).
  ca_bridges "$a"
  cs_t "$a" build-proxy --component "tor-$x" --source-sha "$psha" >"$d/build.log" 2>&1 || fail "$a: build-proxy: $(tail -n 5 "$d/build.log")"
  cs_t "$a" recreate-proxy --component "tor-$x" >"$d/recreate.log" 2>&1 || fail "$a: recreate-proxy: $(tail -n 5 "$d/recreate.log")"
  assert_eq "$(awk -F '\t' '$1 == "candidate" { print $3 }' "$d/build.log")" "$(awk -F '\t' '$1 == "image" { print $3 }' "$d/recreate.log")" \
    "$a: tor-$x runs the image built from $psha"
  cs_wait "$a" up 900 ca_up || fail "$a $x/$h: the chain did not answer within 15 minutes"
  {
    printf 'target\t%s\ncell\t%s/%s/%s\nimage_gen\ttor-%s=%s\n' "$a" "$CA_PLAT" "$x" "$h" "$x" "$(awk -F '\t' '$1 == "candidate" { print $3 }' "$d/build.log")"
    printf 'nice_dns\t%s\nproxy_source\ttor-%s\t%s\n' "$sha" "$x" "$psha"
    printf 'bundle\t%s\n' "$(awk -F '\t' '$1 == "receipt" && $2 == "bundle" { print $3 }' "$d/install.log")"
  } >"$d/cell.tsv"
}

ca_probes() {
  local a="$1" d="$CA_CELL_DIR" since c n
  since="$(cs_now "$d/up.tsv")"
  sleep 150
  cs_report "$a" probes || fail "$a: report"
  assert_eq active "$(cs_sec "$d/probes.tsv" install | awk -F '\t' '$1 == "mode" { print $2 }')" "$a: installed active"
  cs_ticks "$d/probes.tsv" "$since" >"$d/probes-ticks.txt"
  n="$(awk '$2 == "active"' "$d/probes-ticks.txt" | grep -c .)"
  [ "$n" -ge 2 ] || fail "$a: at least 2 active passes in 150 s (got $n)"
  for c in runtime dns-owner local-service filtering local-cache; do
    assert_eq healthy "$(cs_obs "$d/probes.tsv" "$c")" "$a: $c observed healthy on the working chain"
  done
  [ "$(cs_routes_healthy "$d/probes.tsv")" -ge 1 ] || fail "$a: at least one route answers"
  { printf 'mode\tactive\npasses\t%s\n' "$n"; cs_sec "$d/probes.tsv" observe; } >"$d/probes.txt"
  ca_observe CT-PROBES probes.txt
}

ca_primary_only() {
  local a="$1" d="$CA_CELL_DIR" x="$2" since g0
  cs_report "$a" primary-0 || fail "$a: report"
  since="$(cs_now "$d/primary-0.tsv")"; g0="$(cs_gen "$d/primary-0.tsv")"
  cs_t "$a" fault-route --component "tor-$x" --route cloudflare-onion >"$d/fault.log" 2>&1 || fail "$a: fault-route: $(cat "$d/fault.log")"
  sleep 240
  cs_report "$a" primary-1 || fail "$a: report"
  cs_t "$a" heal-route --component "tor-$x" --route cloudflare-onion >>"$d/fault.log" 2>&1 || fail "$a: heal-route: $(cat "$d/fault.log")"
  assert_eq unhealthy "$(cs_obs "$d/primary-1.tsv" route:cloudflare-onion)" "$a: the faulted route is observed down"
  [ "$(cs_routes_healthy "$d/primary-1.tsv")" -ge 1 ] || fail "$a: the other routes still answer"
  assert_eq "" "$(cs_jrows "$d/primary-1.tsv" journal-active "$since" | awk -F '\t' '($3 == "tor" || $3 == "service" || $3 == "runtime") && $4 == "requested"')" \
    "$a: a working route means no Tor restart and no repair"
  assert_eq "$g0" "$(cs_gen "$d/primary-1.tsv")" "$a: the proxy was not restarted"
  { printf 'faulted\tcloudflare-onion\nseconds\t240\n'; cs_jrows "$d/primary-1.tsv" journal-active "$since"; } >"$d/primary-only.txt"
  ca_observe CT-PRIMARY-ONLY primary-only.txt
}

ca_all_down() { [ "$(cs_routes "$1")" -ge 1 ] && [ "$(cs_routes_healthy "$1")" -eq 0 ]; }
ca_tor_acked() { [ -n "$(ca_rows "$1" "$CA_SINCE" tor acknowledged)$(ca_rows "$1" "$CA_SINCE" service acknowledged)" ]; }
ca_ready() { [ -n "$(ca_rows "$1" "$CA_SINCE" "$CA_COMP" ready)" ] && ca_up "$1"; }

ca_recovery() {
  local a="$1" x="$2" d="$CA_CELL_DIR" g0 os cache tp trc id
  # 1. In-image: freeze, thaw when the image claims the request.
  cs_t "$a" hold-bridge-refresh >"$d/hold.log" 2>&1 || fail "$a: hold-bridge-refresh: $(cat "$d/hold.log")"
  cs_report "$a" ack-0 || fail "$a: report"
  CA_SINCE="$(cs_now "$d/ack-0.tsv")"; g0="$(cs_gen "$d/ack-0.tsv")"
  NICE_DNS_FREEZE_MAX_SECS=1500 cs_t "$a" freeze-upstream --component "tor-$x" >"$d/freeze.log" 2>&1 || fail "$a: freeze-upstream: $(cat "$d/freeze.log")"
  NICE_DNS_FREEZE_MAX_SECS=1200 cs_t "$a" thaw-on-request --component "tor-$x" >"$d/thaw.log" 2>&1 &
  tp=$!
  cs_wait "$a" ack-1 240 ca_all_down || { wait "$tp"; fail "$a: the routes were never all observed down with Tor frozen"; }
  cache="$(cs_obs "$d/ack-1.tsv" local-cache)"
  cs_wait "$a" ack-2 1080 ca_tor_acked || { wait "$tp"; fail "$a: no acknowledged Tor restart within 18 minutes: $(cs_jrows "$d/ack-2.tsv" journal-active "$CA_SINCE")"; }
  wait "$tp"; trc=$?
  assert_rc 0 "$trc" "$a: Tor was thawed when the image claimed the request: $(cat "$d/thaw.log")"
  assert_match '^thawed	([2-9][0-9]{2}|[1-9][0-9]{3})$' "$(cat "$d/thaw.log")" "$a: the request came after the grace, not from a stale file"
  assert_ne "" "$(ca_rows "$d/ack-2.tsv" "$CA_SINCE" tor requested)" "$a: the restart was requested"
  assert_match 'generation [0-9]+ -> [0-9]+, tor pid' "$(ca_rows "$d/ack-2.tsv" "$CA_SINCE" tor acknowledged)" "$a: acknowledged by a new tor generation (in-image)"
  assert_eq "" "$(ca_rows "$d/ack-2.tsv" "$CA_SINCE" service requested)" "$a: no service fallback when the image acknowledged"
  assert_eq "$g0" "$(cs_gen "$d/ack-2.tsv")" "$a: the in-image restart kept the container"
  os="$(cs_field "$d/ack-2.tsv" state-active outage_since)"
  CA_COMP=tor
  cs_wait "$a" ack-3 900 ca_ready || fail "$a: no readiness within 15 minutes of the acknowledgement"
  { printf 'path\tin-image\n'; cs_jrows "$d/ack-3.tsv" journal-active "$CA_SINCE"; } >"$d/recovery-ack.txt"
  # CT-CACHE-VS-UPSTREAM: the recorded clock of the restart that followed.
  id="$(ca_rows "$d/ack-2.tsv" "$CA_SINCE" tor requested | head -n 1 | cut -f2)"
  { printf 'local_cache_while_every_route_down\t%s\nrestart_request\t%s\n' "$cache" "$id"
    cs_jrows "$d/ack-2.tsv" journal-active "$CA_SINCE" | head -n 2; } >"$d/cache.txt"
  assert_match '^nd-[0-9]+-[0-9]+$' "$id" "$a: the restart (and so the outage clock) ran whatever the cache answered (local-cache: $cache, outage_since: $os)"
  ca_observe CT-CACHE-VS-UPSTREAM cache.txt
  # 2. Service fallback: Tor stays frozen; the refresh is not held.
  cs_report "$a" svc-0 || fail "$a: report"
  CA_SINCE="$(cs_now "$d/svc-0.tsv")"; g0="$(cs_gen "$d/svc-0.tsv")"
  NICE_DNS_FREEZE_MAX_SECS=1500 cs_t "$a" freeze-upstream --component "tor-$x" >>"$d/freeze.log" 2>&1 || fail "$a: freeze-upstream: $(cat "$d/freeze.log")"
  cs_wait "$a" svc-1 1200 ca_tor_acked || fail "$a: no acknowledged restart within 20 minutes: $(cs_jrows "$d/svc-1.tsv" journal-active "$CA_SINCE")"
  assert_ne "" "$(ca_rows "$d/svc-1.tsv" "$CA_SINCE" service acknowledged)" "$a: the service fallback was acknowledged (a frozen Tor cannot acknowledge in-image)"
  assert_ne "" "$(ca_rows "$d/svc-1.tsv" "$CA_SINCE" tor not-acknowledged)$(ca_rows "$d/svc-1.tsv" "$CA_SINCE" tor adopting)" \
    "$a: the fallback followed an unacknowledged in-image request, or adopted a refreshed bridge set"
  assert_ne "$g0" "$(cs_gen "$d/svc-1.tsv")" "$a: the fallback started a new container"
  CA_COMP=service
  cs_wait "$a" svc-2 900 ca_ready || fail "$a: no readiness within 15 minutes of the fallback"
  { printf 'path\tservice-fallback\n'; cs_jrows "$d/svc-2.tsv" journal-active "$CA_SINCE"; } >>"$d/recovery-ack.txt"
  ca_observe CT-RECOVERY-ACK recovery-ack.txt
}

ca_wedged() { [ "$(cs_routes_healthy "$1")" -eq 0 ] || [ "$(cs_obs "$1" local-service)" != healthy ] || [ "$(cs_obs "$1" runtime)" != healthy ]; }
ca_recovered() {
  cs_jrows "$1" journal-active "$CA_SINCE" | awk -F '\t' '($3 == "runtime" || $3 == "service" || $3 == "tor") && $4 == "ready" { f = 1 } END { exit !f }' && ca_up "$1"
}

ca_wedge() {
  local a="$1" d="$CA_CELL_DIR"
  cs_report "$a" wedge-0 || fail "$a: report"
  CA_SINCE="$(cs_now "$d/wedge-0.tsv")"
  cs_t "$a" wedge-runtime >"$d/wedge.log" 2>&1 || fail "$a: wedge-runtime: $(cat "$d/wedge.log")"
  cs_wait "$a" wedge-1 240 ca_wedged || { cs_t "$a" heal-runtime >>"$d/wedge.log" 2>&1; fail "$a: the wedge fault was never observed"; }
  if ! cs_wait "$a" wedge-2 1500 ca_recovered; then
    cs_t "$a" heal-runtime >>"$d/wedge.log" 2>&1
    fail "$a: the controller did not recover the wedged runtime within 25 minutes: $(cs_jrows "$d/wedge-2.tsv" journal-active "$CA_SINCE")"
  fi
  cs_t "$a" heal-runtime >>"$d/wedge.log" 2>&1 || fail "$a: heal-runtime"
  { printf 'fault\t%s\n' "$CA_PLAT"; cs_sec "$d/wedge-1.tsv" observe | grep -E '^obs	(runtime|local-service|route:)'
    cs_jrows "$d/wedge-2.tsv" journal-active "$CA_SINCE"; } >"$d/wedge.txt"
  ca_observe CT-RUNTIME-WEDGE wedge.txt
}

ca_bridges() {
  local a="$1" d="$CA_CELL_DIR" g0 res up0=0
  cs_report "$a" br-0 || fail "$a: report"
  g0="$(cs_gen "$d/br-0.tsv")"
  ca_up "$d/br-0.tsv" && up0=1
  cs_t "$a" bridges-refresh >"$d/bridges.log" 2>&1 || fail "$a: bridges-refresh: $(tail -n 5 "$d/bridges.log")"
  res="$(awk -F '\t' '$1 == "result" { r = $2 } END { print r }' "$d/bridges.log")"
  case "$res" in applied|unchanged) ;; *) fail "$a: the refresh gave '$res' (applied or unchanged expected): $(tail -n 5 "$d/bridges.log")" ;; esac
  cs_report "$a" br-1 || fail "$a: report"
  assert_eq "$g0" "$(cs_gen "$d/br-1.tsv")" "$a: the refresh restarted nothing"
  assert_match '^[3-9]/|^[1-9][0-9]+/' "$(cs_bridges "$d/br-1.tsv")" "$a: a usable set of at least 3 bridges"
  [ "$up0" = 0 ] || ca_up "$d/br-1.tsv" || fail "$a: the chain answered before the refresh and does not after it"
  printf 'result\t%s\nset\t%s -> %s\nproxy_generation\tunchanged\n' "$res" "$(cs_bridges "$d/br-0.tsv")" "$(cs_bridges "$d/br-1.tsv")" >"$d/bridges.txt"
  ca_observe CT-BRIDGES bridges.txt
}

ca_cell() {
  local a="$1" x="$2" h="$3" fresh="$4"
  CA_CELL_DIR="$CA_ROOT_DIR/$CA_PLAT-$x-$h"
  mkdir -p "$CA_CELL_DIR" && : >"$CA_CELL_DIR/observations.tsv"
  printf '== cell %s/%s/%s %s\n' "$CA_PLAT" "$x" "$h" "$(date -u +%H:%M:%S)"
  ca_deploy "$a" "$x" "$h" "$fresh"
  ca_probes "$a"
  ca_primary_only "$a" "$x"
  ca_recovery "$a" "$x"
  ca_wedge "$a"
}

# ca_platform <platform> <alias>: every cell of the platform, the target's
# original cell last, each in its own subshell (a failed cell does not stop
# the others; the case fails).
ca_platform() {
  local a="$2" out x0 h0 cells c bad=""
  CA_PLAT="$1"
  CA_CELL_DIR="$CA_ROOT_DIR/$CA_PLAT-setup"; mkdir -p "$CA_CELL_DIR"
  cs_t "$a" snapshot >>"$CA_CELL_DIR/ops.log" 2>&1 || fail "$a: snapshot"
  out="$(cs_t "$a" config 2>>"$CA_CELL_DIR/ops.log")" || fail "$a: config"
  x0="$(printf '%s\n' "$out" | awk -F '\t' '$1 == "proxy_component" { sub(/^tor-/, "", $2); print $2; exit }')"
  h0="$(printf '%s\n' "$out" | awk -F '\t' '$1 == "pihole_variant" { print $2; exit }')"
  case "$x0/$h0" in haproxy/standard|haproxy/hardened|socat/standard|socat/hardened) ;; *) fail "$a: unknown current cell '$x0/$h0'" ;; esac
  printf 'original\t%s/%s\n' "$x0" "$h0" >"$CA_ROOT_DIR/$CA_PLAT-original.tsv"
  if ca_matrix_all; then
    cells="$(awk -F '\t' -v p="$CA_PLAT" -v o="$x0/$h0" '!/^#/ && $1 == p && $2 "/" $3 != o { print $2 "/" $3 }' "$NICE_DNS_ROOT/tests/manifests/matrix.tsv") $x0/$h0"
    for c in $cells; do ( ca_cell "$a" "${c%/*}" "${c#*/}" 1 ) || bad="$bad $c"; done
  else
    ( ca_cell "$a" "$x0" "$h0" 0 ) || bad="$bad $x0/$h0"
  fi
  assert_eq "" "$bad" "$a: every cell passed (failed:$bad)"
}

t_1_cells() {
  local p a pids="" rc bad=""
  cs_selection
  CA_ROOT_DIR="$ARTIFACT_DIR/controller-active"
  for p in $(cs_platforms); do
    cs_alias "$p"; a="$CS_ALIAS"
    ( ca_platform "$p" "$a" ) >"$CASE_DIR/$p.log" 2>&1 &
    pids="$pids $p:$!"
  done
  for p in $pids; do
    wait "${p#*:}"; rc=$?
    if [ "$rc" -ne 0 ]; then bad="$bad ${p%%:*}"; printf '%s\n' "--- ${p%%:*} (exit $rc) ---"; grep -E 'ASSERT FAIL|^== cell' "$CASE_DIR/${p%%:*}.log" | tail -n 20; fi
  done
  assert_eq "" "$bad" "every platform's cells passed (failed:$bad)"
}

# ─────────────────────────── wake (by hand) ─────────────────────────────────

ca_woke() {
  local n
  n="$(cs_sleeps "$1")"
  case "$n" in ''|*[!0-9]*) return 1 ;; esac
  [ "$n" -gt "$CA_SLEEPS0" ] || return 1
  # Three passes after the gap the sleep left in the tick lines.
  cs_ticks "$1" "$CA_SINCE" | awk 'NR > 1 && $1 - p >= 120 { g = NR } { p = $1; n = NR } END { exit !(g && n - g >= 2) }'
}

ca_wake() {
  local plat="$1" a="$2" d
  CA_CELL_DIR="$CA_ROOT_DIR/wake-$a"; d="$CA_CELL_DIR"; mkdir -p "$d"
  cs_report "$a" wake-0 || fail "$a: report"
  CA_SINCE="$(cs_now "$d/wake-0.tsv")"; CA_SLEEPS0="$(cs_sleeps "$d/wake-0.tsv")"
  case "$CA_SLEEPS0" in ''|*[!0-9]*) fail "$a: no sleep counter in the report" ;; esac
  # The operator is asked through this marker (the session relays it).
  printf '%s\t%s\tsleep the machine for at least 3 minutes, then wake it\n' "$(date -u +%H:%M:%S)" "$a" >"$ARTIFACT_DIR/WAKE-REQUEST-$a"
  printf 'ACTION NEEDED: sleep %s for at least 3 minutes, then wake it (waiting up to 60 minutes)\n' "$a"
  cs_wait "$a" wake-1 3600 ca_woke || fail "$a: no sleep and wake with three later passes within 60 minutes"
  rm -f "$ARTIFACT_DIR/WAKE-REQUEST-$a"
  cs_ticks "$d/wake-1.tsv" "$CA_SINCE" >"$d/wake-ticks.txt"
  assert_eq "" "$(awk 'NR > 1 { g = $1 - p; if (g >= 120) seen = 1; else if (seen && (g < 30 || g > 120)) print g } { p = $1 }' "$d/wake-ticks.txt")" \
    "$a: after the wake, one pass a minute again"
  assert_eq "" "$(cs_jrows "$d/wake-1.tsv" journal-active "$CA_SINCE" | awk -F '\t' '$4 == "requested"')" "$a: the time jump caused no recovery action"
  ca_up "$d/wake-1.tsv" || fail "$a: the chain answers after the wake"
  { printf 'target\t%s\nplatform\t%s\nsleeps\t%s -> %s\n' "$a" "$plat" "$CA_SLEEPS0" "$(cs_sleeps "$d/wake-1.tsv")"
    awk 'NR > 1 && $1 - p >= 120 { printf "gap\t%s s before the pass at %s\n", $1 - p, $1 } { p = $1 }' "$d/wake-ticks.txt"; } >"$d/wake.txt"
}

t_2_wake() {
  local p
  cs_selection
  CA_ROOT_DIR="$ARTIFACT_DIR/controller-active"
  # One target at a time: the operator handles one machine, then the next.
  for p in $(cs_platforms); do
    cs_alias "$p"
    ( ca_wake "$p" "$CS_ALIAS" ) || fail "wake on $CS_ALIAS failed (see the case log)"
  done
  cat "$CA_ROOT_DIR"/wake-*/wake.txt >"$CA_ROOT_DIR/wake.txt"
}

# ─────────────────────────── receipt ────────────────────────────────────────

t_3_receipt() {
  local root out r t repo cd st d key gen cell id f n=0 v req
  CA_ROOT_DIR="$ARTIFACT_DIR/controller-active"
  root="$(dirname "$(dirname "$ARTIFACT_DIR")")"
  out="$root/receipts/controller/$RUN_ID"; r="$out/receipt.tsv"
  t="$(for t in "$root"/receipts/transport/*/receipt.tsv; do [ -f "$t" ] && printf '%s\n' "$t"; done | LC_ALL=C sort | tail -1)"
  assert_ne "" "$t" "a transport receipt exists to link"
  assert_file "$CA_ROOT_DIR/wake.txt" "the wake scenario ran in this run"
  assert_no_path "$out" "this run has no controller receipt yet"
  mkdir -p "$out/cells" || fail "cannot create $out"
  {
    printf '# schema\tnice-dns-receipt/1\n'
    printf 'receipt\tcontroller\nrun_id\t%s\ncreated_utc\t%s\n' "$RUN_ID" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    for repo in nice-dns tor-haproxy tor-socat hardened-unbound pi-hole-hardened; do
      if [ "$repo" = nice-dns ]; then cd="$NICE_DNS_ROOT"; else cd="$CS_SIBS/$repo"; fi
      if [ -n "$(cs_clean "$cd")" ]; then st=dirty; else st=clean; fi
      printf 'source\t%s\t%s\t%s\n' "$repo" "$(git -C "$cd" rev-parse HEAD)" "$st"
    done
    for repo in tor-haproxy tor-socat hardened-unbound pi-hole-hardened; do
      printf 'arch\t%s\t%s\t%s\n' "$repo" "$(git -C "$CS_SIBS/$repo" rev-parse HEAD)" \
        "$(git -C "$CS_SIBS/$repo" show HEAD:.github/workflows/main.yml |
          awk '/^ *platform: *$/ { on = 1; next } on && /^ *- *linux\// { sub(/^ *- */, ""); print; next } on { on = 0 }' |
          sort | paste -sd, -)"
    done
    printf 'requires\ttransport\t%s\t%s\n' "$t" "$(sha256sum "$t" | cut -d' ' -f1)"
  } >"$r"
  cp "$CA_ROOT_DIR/wake.txt" "$out/CT-WAKE.txt"
  printf 'scenario\tCT-WAKE\t-\tpass\tCT-WAKE.txt\t%s\t-\n' "$(sha256sum "$out/CT-WAKE.txt" | cut -d' ' -f1)" >>"$r"
  for d in "$CA_ROOT_DIR"/*-*-*/; do
    [ -f "$d/cell.tsv" ] || continue
    cell="$(awk -F '\t' '$1 == "cell" { print $2 }' "$d/cell.tsv")"
    key="$(printf '%s' "$cell" | tr / -)"
    gen="$(awk -F '\t' '$1 == "image_gen" { print $2 }' "$d/cell.tsv")"
    [ "$(grep -c pass "$d/observations.tsv")" -eq 6 ] || continue
    n=$((n + 1))
    mkdir -p "$out/cells/$key"
    for f in cell.tsv observations.tsv; do cp "$d/$f" "$out/cells/$key/"; done
    printf 'cell\t%s\t%s\t%s\t%s\t%s\tobserved\n' "${cell%%/*}" "$(printf '%s' "$cell" | cut -d/ -f2)" "${cell##*/}" \
      "$(awk -F '\t' '$1 == "target" { print $2 }' "$d/cell.tsv")" "$gen" >>"$r"
    while IFS="$(printf '\t')" read -r id st f; do
      cp "$d/$f" "$out/cells/$key/$f"
      printf 'scenario\t%s\t%s\t%s\tcells/%s/%s\t%s\t%s\n' "$id" "$cell" "$st" "$key" "$f" "$(sha256sum "$out/cells/$key/$f" | cut -d' ' -f1)" "$gen" >>"$r"
    done <"$d/observations.tsv"
  done
  assert_match '^[1-9]' "$n" "at least one fully passed cell"
  req=(--require-platforms all --require-dep transport)
  ca_matrix_all && req+=(--require-matrix all)
  v="$(bash "$NICE_DNS_ROOT/tests/reports/verify.sh" check "$r" "${req[@]}" 2>&1)"
  assert_rc 0 "$?" "the controller receipt verifies: $v"
  assert_eq "" "$(grep -rlE 'cert=[A-Za-z0-9+/]{20}|(^|[^0-9A-Fa-f])[0-9A-F]{40}([^0-9A-Fa-f]|$)|PRIVATE KEY|pwhash|BRIDGE[0-9]+=' "$out" "$CA_ROOT_DIR" 2>/dev/null)" \
    "no bridge line, certificate, fingerprint, key or password hash in the receipt or the evidence"
  printf 'receipt\t%s\n' "$r" >"$CASE_DIR/receipt-path.tsv"
}
