# shellcheck shell=bash
# Group live/controller-active (Sub-plan 3, Task 2.3's test-only activation
# and final-gate scenarios; ARCH-09). Run by the Stage 2 gate:
#   tests/run.sh plan controller --fresh-fixtures --include-slow --live \
#     --targets FILE --matrix all
#
# The controller acts here (install-controller --mode active), on the
# designated disposable targets only, with the proxy image built there from
# the sibling checkout. Cells, per platform (user decision 2026-09-26, the
# representative gate): with --matrix all, the other proxy with standard
# Pi-hole, installed fresh at origin/main and run with 30 s policy timers
# (set-tunables fast), then the target's original cell, reinstalled and run
# with the real timers; the hardened cells are Sub-plan 5's final matrix and
# are recorded blocked-by-scope in the receipt. Without --matrix all: the
# cell the target runs, real timers. Per cell:
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
# live/controller-wake then covers CT-WAKE, and live/controller-receipt
# assembles and verifies the controller receipt from this run's evidence.

# shellcheck source=tests/live/controller-lib.sh
. "$NICE_DNS_ROOT/tests/live/controller-lib.sh"

CA_ROOT_DIR="" CA_CELL_DIR=""
cs_dir() { printf '%s\n' "$CA_CELL_DIR"; }

ca_matrix_all() { [ "${NICE_DNS_OPT_MATRIX:-}" = all ]; }

# ca_observe <scenario> <file>: a passed scenario of the current cell.
ca_observe() { printf '%s\tpass\t%s\n' "$1" "$2" >>"$CA_CELL_DIR/observations.tsv"; }

# ca_rows <report> <since> <component> <phase>: active journal rows.
ca_rows() { cs_jrows "$1" journal-active "$2" | awk -F '\t' -v c="$3" -v p="$4" '$3 == c && $4 == p'; }


# ca_health <alias> <file>: the target's health op (Podman health and start
# time per container on Linux).
ca_health() { cs_t "$1" health >"$2" 2>>"$CA_CELL_DIR/ops.log"; }
ca_hstate() { awk -F '\t' -v c="podman:$2" '$1 == "health" && $2 == c { print $3; exit }' "$1"; }
ca_started() { awk -F '\t' -v c="podman:$2" '$1 == "started" && $2 == c { print $3; exit }' "$1"; }

# ca_quadlet_health <alias> <proxy>: Linux. The proxy's and Unbound's
# quadlet health checks verify the chain and only report (close-out B1): on
# the working chain both read healthy, and Podman never restarts them.
ca_quadlet_health() {
  local a="$1" x="$2" d="$CA_CELL_DIR" t0 c
  cs_t "$a" config >"$d/qh-config.tsv" 2>>"$d/ops.log" || fail "$a: config"
  for c in "tor-$x" unbound; do
    assert_match "^healthcheck	$c	.*	on_failure=none$" "$(grep "^healthcheck	$c	" "$d/qh-config.tsv")" "$a: $c's health check never restarts it"
  done
  assert_match "nice-dns-route-probe" "$(grep "^healthcheck	tor-$x	" "$d/qh-config.tsv")" "$a: the proxy's check is the verifying route probe"
  assert_match "probe-route" "$(grep "^healthcheck	unbound	" "$d/qh-config.tsv")" "$a: Unbound's check resolves over its route"
  t0="$(date +%s)"
  while :; do
    ca_health "$a" "$d/qh.tsv" || fail "$a: health"
    [ "$(ca_hstate "$d/qh.tsv" "tor-$x")" = healthy ] && [ "$(ca_hstate "$d/qh.tsv" unbound)" = healthy ] && break
    [ $(( $(date +%s) - t0 )) -lt 600 ] || fail "$a: tor-$x and unbound not both healthy within 10 minutes of the chain answering: $(grep -E '^health' "$d/qh.tsv" | tr '\n' ' ')"
    sleep 30
  done
  { grep -E "^healthcheck	(tor-$x|unbound)	" "$d/qh-config.tsv"; grep -E "^health	podman:(tor-$x|unbound)	" "$d/qh.tsv"; } >"$d/quadlet-health.txt"
}

# ─────────────────────────── one cell ────────────────────────────────────────

ca_deploy() {
  local a="$1" x="$2" h="$3" fresh="$4" d="$CA_CELL_DIR" sha psha base args ub
  sha="$(git -C "$NICE_DNS_ROOT" rev-parse HEAD)"
  assert_eq "" "$(cs_clean "$CS_SIBS/tor-$x")" "$a: the tor-$x sibling is committed"
  psha="$(git -C "$CS_SIBS/tor-$x" rev-parse HEAD)"
  if [ "$fresh" = 1 ]; then
    # Linux installs this checkout's commit: install-deb.sh runs from the
    # inline archive, so the quadlets and the Unbound image qualified are the
    # ones under test (Sub-plan 3 close-out B1, M2, M4). install-mac.sh
    # clones GitHub main itself, so macOS installs origin/main.
    if [ "$CA_PLAT" = linux ]; then base="$sha"; else base="$(git -C "$NICE_DNS_ROOT" rev-parse origin/main)"; fi
    args=(--cell "$x/$h" --source-sha "$base")
    [ "$h" = hardened ] && args+=(--hardened-sha "$(git -C "$CS_SIBS/pi-hole-hardened" rev-parse HEAD)")
    # The installer's output may carry bridge lines: it stays out of the evidence.
    cs_t "$a" install-cell "${args[@]}" >"$CASE_DIR/install-$x-$h.log" 2>&1 \
      || fail "$a $x/$h: install-cell failed: $(grep -E '^(installer_exit|github_main)' "$CASE_DIR/install-$x-$h.log" | tr '\n' ' ')"
    printf 'installed\t%s/%s\t%s\n' "$x" "$h" "$base" >>"$d/deploy.tsv"
  fi
  cs_t "$a" quiesce-agents >"$d/quiesce.tsv" 2>>"$d/ops.log" || fail "$a: quiesce-agents"
  if [ "$CA_PLAT" = macos ]; then
    # The LaunchAgent's script is part of what is qualified (the service
    # fallback runs it); a cell installed from origin/main has the old one.
    cs_t "$a" install-agent --source-sha "$sha" >"$d/agent.log" 2>&1 || fail "$a: install-agent: $(cat "$d/agent.log")"
    assert_eq "$(git -C "$NICE_DNS_ROOT" show "$sha:mac/start-container.sh" | sha256sum | cut -d' ' -f1)" "$(awk -F '\t' '$1 == "agent" { print $2 }' "$d/agent.log")" \
      "$a: the LaunchAgent runs this checkout's start-container.sh"
  fi
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
  # The real timers until the chain answers: with a 30 s grace, the
  # recreate's ordinary bootstrap outage would already trigger the outage
  # bridge refresh, and its pending set would route the in-image scenario's
  # restart to the service restart (live, mac socat, run
  # 20260926T190619Z-bcd92da5: "adopting").
  cs_t "$a" set-tunables --mode default >>"$d/ops.log" 2>&1 || fail "$a: set-tunables default"
  cs_wait "$a" up 900 ca_up || fail "$a $x/$h: the chain did not answer within 15 minutes"
  if [ "$CA_TIMERS" = fast ]; then cs_t "$a" set-tunables --mode fast >>"$d/ops.log" 2>&1 || fail "$a: set-tunables fast"; fi
  # The Unbound image the cell ran (M4: readiness corroboration depends on it).
  cs_t "$a" config >"$d/config.tsv" 2>>"$d/ops.log" || fail "$a: config"
  ub="$(awk -F '\t' '$1 == "image" && $2 == "unbound" { print $4; exit }' "$d/config.tsv")"
  [ -n "$ub" ] && [ "$ub" != - ] || fail "$a: no Unbound image identity in config"
  {
    printf 'target\t%s\ncell\t%s/%s/%s\nimage_gen\ttor-%s=%s;unbound=%s\n' "$a" "$CA_PLAT" "$x" "$h" "$x" "$(awk -F '\t' '$1 == "candidate" { print $3 }' "$d/build.log")" "$ub"
    printf 'nice_dns\t%s\nproxy_source\ttor-%s\t%s\n' "$sha" "$x" "$psha"
    printf 'bundle\t%s\n' "$(awk -F '\t' '$1 == "receipt" && $2 == "bundle" { print $3 }' "$d/install.log")"
    printf 'timers\t%s\n' "$CA_TIMERS"
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
  if [ "$CA_PLAT" = linux ]; then ca_quadlet_health "$a" "$CA_PROXY"; cat "$d/quadlet-health.txt" >>"$d/probes.txt"; fi
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
  if [ "$CA_TIMERS" = fast ]; then
    assert_match '^thawed	([2-9][0-9]|[1-9][0-9]{2,3})$' "$(cat "$d/thaw.log")" "$a: the request came after the 30 s grace, not from a stale file"
  else
    assert_match '^thawed	([2-9][0-9]{2}|[1-9][0-9]{3})$' "$(cat "$d/thaw.log")" "$a: the request came after the grace, not from a stale file"
  fi
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
  if [ "$CA_PLAT" = linux ]; then ca_health "$a" "$d/svc-h0.tsv" || fail "$a: health"; fi
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
  if [ "$CA_PLAT" = linux ]; then
    # Linux restarts the proxy alone (close-out M2: Wants=, not Requires=):
    # Unbound, with its cache, and Pi-hole keep running through it.
    ca_health "$a" "$d/svc-h1.tsv" || fail "$a: health"
    for c in unbound pi-hole; do
      assert_ne "" "$(ca_started "$d/svc-h0.tsv" "$c")" "$a: $c's start time is read"
      assert_eq "$(ca_started "$d/svc-h0.tsv" "$c")" "$(ca_started "$d/svc-h1.tsv" "$c")" "$a: the proxy's service restart did not restart $c"
      printf 'kept_running\t%s\t%s\n' "$c" "$(ca_started "$d/svc-h1.tsv" "$c")" >>"$d/recovery-ack.txt"
    done
  fi
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
  # A refresh exits non-zero when it keeps the last good set (not-applied):
  # the result row decides, not the exit status.
  cs_t "$a" bridges-refresh >"$d/bridges.log" 2>&1
  res="$(awk -F '\t' '$1 == "result" { r = $2 } END { print r }' "$d/bridges.log")"
  case "$res" in changed|unchanged|not-applied) ;; *) fail "$a: the refresh gave '$res' (changed, unchanged or not-applied: nd_bridges_apply's results): $(tail -n 5 "$d/bridges.log")" ;; esac
  cs_report "$a" br-1 || fail "$a: report"
  if [ "$res" = not-applied ]; then
    # Live (mac, run 20260926T161534Z-821061c1): "bridge-eval exit 1; the
    # last good set stays". Keeping the working set is the contract.
    assert_eq "$(cs_bridges "$d/br-0.tsv")" "$(cs_bridges "$d/br-1.tsv")" "$a: a refresh that is not applied keeps the running set"
  fi
  assert_eq "$g0" "$(cs_gen "$d/br-1.tsv")" "$a: the refresh restarted nothing"
  assert_match '^[3-9]/|^[1-9][0-9]+/' "$(cs_bridges "$d/br-1.tsv")" "$a: a usable set of at least 3 bridges"
  [ "$up0" = 0 ] || ca_up "$d/br-1.tsv" || fail "$a: the chain answered before the refresh and does not after it"
  printf 'result\t%s\nset\t%s -> %s\nproxy_generation\tunchanged\n' "$res" "$(cs_bridges "$d/br-0.tsv")" "$(cs_bridges "$d/br-1.tsv")" >"$d/bridges.txt"
  ca_observe CT-BRIDGES bridges.txt
}

ca_cell() {
  local a="$1" x="$2" h="$3" fresh="$4"
  CA_TIMERS="${5:-production}" CA_PROXY="$x"
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
    # The representative gate: the other proxy (standard Pi-hole) on fast
    # timers, then the original cell, reinstalled, on the real timers.
    cells="$(awk -F '\t' -v p="$CA_PLAT" -v o="$x0" '!/^#/ && $1 == p && $2 != o && $3 == "standard" { print $2 "/" $3 }' "$NICE_DNS_ROOT/tests/manifests/matrix.tsv")"
    # NICE_DNS_ACTIVE_CELLS (fix-scope only: a single group run, never a
    # plan): re-run just these cells, e.g. "socat/standard"; the original
    # cell is then reinstalled last only if it is listed too.
    for c in $cells; do
      case " ${NICE_DNS_ACTIVE_CELLS:-$c} " in *" $c "*) ( ca_cell "$a" "${c%/*}" "${c#*/}" 1 fast ) || bad="$bad $c" ;; esac
    done
    case " ${NICE_DNS_ACTIVE_CELLS:-$x0/$h0} " in *" $x0/$h0 "*) ( ca_cell "$a" "$x0" "$h0" 1 production ) || bad="$bad $x0/$h0" ;; esac
  else
    ( ca_cell "$a" "$x0" "$h0" 0 ) || bad="$bad $x0/$h0"
  fi
  assert_eq "" "$bad" "$a: every cell passed (failed:$bad)"
}

t_1_cells() {
  local p a pids="" rc bad=""
  cs_selection
  if [ -n "${NICE_DNS_ACTIVE_CELLS:-}" ]; then
    assert_eq 1 "$(awk -F '\t' '$1 == "command" && $2 ~ /run\.sh (live|integration|unit) / { f = 1 } END { print f + 0 }' "$ARTIFACT_DIR/receipt.tsv")" \
      "NICE_DNS_ACTIVE_CELLS narrows a single group run only, never a stage or plan"
  fi
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

