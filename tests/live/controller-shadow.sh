# shellcheck shell=bash
# Group live/controller-shadow (Sub-plan 3, Task 2.3; ARCH-09).
# Run by `tests/run.sh live controller-shadow --targets FILE --platforms all`.
#
# Deploys this checkout's controller in observation mode on the designated
# disposable target of each platform, on the cell that target already runs,
# with the proxy image built there from the sibling checkout (Sub-plan 2), and
# compares what the controller would do against controlled faults. Nothing
# the controller runs may change the stack: shadow mode records only.
#
#   t_1_deploy_shadow        quiesce the legacy agents, install the controller
#                            with --shadow, build and run the proxy from
#                            source, wait for an answering route
#   t_2_steady_state         one shadow pass per minute for 6 minutes on a
#                            healthy chain: no recovery intent, no mutation
#                            (proxy generation, bridge set, active state), the
#                            HAProxy summary once a minute (BL-003)
#   t_3_primary_only_outage  the shadow's current route fails while the others
#                            work: it would switch route, never restart Tor
#   t_4_whole_outage         Tor frozen (every route fails): it would restart
#                            Tor after the grace; a cached answer never counts
#                            as upstream health; nothing is restarted
#   t_5_evidence_is_private  the collected evidence holds no bridge material
#
# The cases run in name order; each runs both platforms concurrently (two
# hosts) and fails when either does. Evidence lands in
# $ARTIFACT_DIR/controller-shadow/<alias>/. Every target operation goes through
# tests/live/target.sh (allow-listed operations, pinned host keys, a snapshot
# before any mutation). The targets are left running the source-built proxy
# with the controller installed in shadow mode and the legacy agents stopped.

# shellcheck source=tests/live/controller-lib.sh
. "$NICE_DNS_ROOT/tests/live/controller-lib.sh"



cs_dir() { printf '%s\n' "$ARTIFACT_DIR/controller-shadow/$1"; }





# cs_journal <report> <since>: shadow journal rows at or after <since>.
cs_journal() { cs_jrows "$1" journal-shadow "$2"; }


# cs_each <fn>: <fn> <platform> <alias> for every selected platform at once.
cs_each() {
  local fn="$1" p a pids="" rc bad=""
  for p in $(cs_platforms); do
    cs_alias "$p"; a="$CS_ALIAS"
    mkdir -p "$(cs_dir "$a")"
    if [ "$fn" != cs_deploy ] && [ ! -f "$(cs_dir "$a")/cell.tsv" ]; then
      # A platform whose deploy failed is not exercised on a broken target.
      printf 'ASSERT FAIL: %s: not deployed in this run (t_1_deploy_shadow failed); %s not run\n' "$a" "$fn" >"$CASE_DIR/$p.log"
      ( exit 1 ) &
    else
      ( "$fn" "$p" "$a" ) >"$CASE_DIR/$p.log" 2>&1 &
    fi
    pids="$pids $p:$!"
  done
  for p in $pids; do
    wait "${p#*:}"; rc=$?
    if [ "$rc" -ne 0 ]; then
      bad="$bad ${p%%:*}"
      printf '%s\n' "--- ${p%%:*} (exit $rc) ---"; tail -n 25 "$CASE_DIR/${p%%:*}.log"
    fi
  done
  assert_eq "" "$bad" "$fn passed on every platform (failed:$bad)"
}


# ─────────────────────────── deploy ─────────────────────────────────────────



cs_deploy() {
  local plat="$1" a="$2" d proxy pihole sha psha out
  d="$(cs_dir "$a")"
  sha="$(git -C "$NICE_DNS_ROOT" rev-parse HEAD)"
  cs_t "$a" snapshot >>"$d/ops.log" 2>&1 || fail "$a: snapshot"
  out="$(cs_t "$a" config 2>>"$d/ops.log")" || fail "$a: config"
  pihole="$(printf '%s\n' "$out" | awk -F '\t' '$1 == "pihole_variant" { print $2; exit }')"
  proxy="$(printf '%s\n' "$out" | awk -F '\t' '$1 == "proxy_component" { print $2; exit }')"
  case "$proxy" in tor-haproxy|tor-socat) ;; *) fail "$a: no running proxy found (got '$proxy')" ;; esac
  case "$pihole" in standard|hardened) ;; *) fail "$a: Pi-hole variant unknown (got '$pihole')" ;; esac
  assert_eq "" "$(cs_clean "$CS_SIBS/$proxy")" "$a: the $proxy sibling is committed (the image is built from HEAD)"
  psha="$(git -C "$CS_SIBS/$proxy" rev-parse HEAD)"
  cs_t "$a" quiesce-agents >"$d/quiesce.tsv" 2>>"$d/ops.log" || fail "$a: quiesce-agents: $(cat "$d/quiesce.tsv")"
  assert_not_match '^loaded	org\.nice-dns\.(health|bridge-eval|health-bridges)$' "$(cat "$d/quiesce.tsv")" "$a: no legacy mutating agent is loaded"
  cs_t "$a" install-controller --source-sha "$sha" --mode shadow >"$d/install.log" 2>&1 || fail "$a: install-controller: $(tail -n 5 "$d/install.log")"
  assert_match '^receipt	mode	shadow$' "$(cat "$d/install.log")" "$a: the controller is installed in shadow mode"
  cs_t "$a" build-proxy --component "$proxy" --source-sha "$psha" >"$d/build.log" 2>&1 || fail "$a: build-proxy: $(tail -n 8 "$d/build.log")"
  cs_t "$a" recreate-proxy --component "$proxy" >"$d/recreate.log" 2>&1 || fail "$a: recreate-proxy: $(tail -n 5 "$d/recreate.log")"
  assert_eq "$(awk -F '\t' '$1 == "candidate" { print $3 }' "$d/build.log")" "$(awk -F '\t' '$1 == "image" { print $3 }' "$d/recreate.log")" \
    "$a: $proxy now runs the image built from $psha"
  cs_wait "$a" deployed 900 cs_route_up || fail "$a: no route answered within 15 minutes of the recreate"
  {
    printf 'target\t%s\nplatform\t%s\nproxy\t%s\npihole\t%s\n' "$a" "$plat" "${proxy#tor-}" "$pihole"
    printf 'nice_dns\t%s\nproxy_source\t%s\t%s\n' "$sha" "$proxy" "$psha"
    printf 'image\t%s\n' "$(awk -F '\t' '$1 == "candidate" { print $3 }' "$d/build.log")"
    printf 'bundle\t%s\n' "$(awk -F '\t' '$1 == "receipt" && $2 == "bundle" { print $3 }' "$d/install.log")"
  } >"$d/cell.tsv"
}

t_1_deploy_shadow() {
  cs_selection
  cs_each cs_deploy
}

# ─────────────────────────── steady state ───────────────────────────────────

cs_steady() {
  local plat="$1" a="$2" d r0 r1 since n bad gaps c0 c1 dt
  d="$(cs_dir "$a")"; r0="$d/steady-0.tsv"; r1="$d/steady-1.tsv"
  cs_report "$a" steady-0 || fail "$a: report"
  since="$(cs_now "$r0")"
  sleep 390
  cs_report "$a" steady-1 || fail "$a: report"
  assert_eq shadow "$(cs_sec "$r1" install | awk -F '\t' '$1 == "mode" { print $2 }')" "$a: installed in shadow mode"
  cs_ticks "$r1" "$since" >"$d/steady-ticks.txt"
  n="$(grep -c . "$d/steady-ticks.txt")"
  [ "$n" -ge 5 ] || fail "$a: at least 5 passes in 6.5 minutes (got $n): $(cat "$d/steady-ticks.txt")"
  assert_eq "" "$(awk '$2 != "shadow"' "$d/steady-ticks.txt")" "$a: every pass is a shadow pass"
  gaps="$(awk 'NR > 1 { g = $1 - p; if (g < 30 || g > 120) print g } { p = $1 }' "$d/steady-ticks.txt")"
  assert_eq "" "$gaps" "$a: one pass a minute (gaps outside 30..120 s)"
  bad="$(awk '$3 == "restart-component" || $3 == "repair-runtime" || $3 == "escalate"' "$d/steady-ticks.txt")"
  assert_eq "" "$bad" "$a: no recovery intent while the chain is healthy"
  assert_eq "" "$(awk '$5 != "none" && $5 != "shadow"' "$d/steady-ticks.txt")" "$a: shadow passes record, they never act"
  # No mutation.
  assert_eq "$(cs_gen "$r0")" "$(cs_gen "$r1")" "$a: the proxy was not restarted"
  assert_eq "$(cs_bridges "$r0")" "$(cs_bridges "$r1")" "$a: the bridge set is unchanged"
  assert_eq "$(cs_sec "$r0" state-active)" "$(cs_sec "$r1" state-active)" "$a: the active controller state is untouched"
  assert_eq "$(cs_sec "$r0" journal-active)" "$(cs_sec "$r1" journal-active)" "$a: no active journal row"
  # CT-PROBES: the observations of a working chain.
  for c in runtime dns-owner local-service filtering local-cache; do
    assert_eq healthy "$(cs_obs "$r1" "$c")" "$a: $c observed healthy on the working chain"
  done
  [ "$(cs_routes_healthy "$r1")" -ge 1 ] || fail "$a: at least one route answers"
  { printf 'window\t%s\t%s\npasses\t%s\n' "$since" "$(cs_now "$r1")" "$n"
    cs_sec "$r1" observe; } >"$d/probes.txt"
  # BL-003: the HAProxy summary once a minute, in the route-aware format.
  if [ "$(cs_proxy "$r1")" = tor-haproxy ]; then
    c0="$(cs_field "$r0" summary count)"; c1="$(cs_field "$r1" summary count)"
    dt=$(( $(cs_now "$r1") - $(cs_now "$r0") ))
    awk -v c0="$c0" -v c1="$c1" -v dt="$dt" 'BEGIN { n = c1 - c0; e = dt / 60; exit !(n >= e - 1 && n <= e + 1) }' \
      || fail "$a: $((c1 - c0)) summary lines in ${dt} s; one a minute expected"
    assert_match '^line	backends primary=[^ ]+ backup=[^ ]+ sessions=[0-9]+ routes=cloudflare-onion/[0-9]+,cloudflare-exit/[0-9]+,quad9-exit/[0-9]+$' \
      "$(cs_sec "$r1" summary | tail -n 1)" "$a: the summary names every route (the source-built image)"
    { printf 'lines\t%s\nseconds\t%s\n' "$((c1 - c0))" "$dt"; cs_sec "$r1" summary | grep '^line'; } >"$d/summary.txt"
  fi
}

t_2_steady_state() {
  cs_selection
  cs_each cs_steady
}

# ─────────────────────────── primary-only outage ────────────────────────────

cs_route_selected() { case "$(cs_field "$1" state-shadow route)" in ''|-) return 1 ;; esac; }
cs_switched() {
  cs_journal "$1" "$CS_SINCE" | awk -F '\t' -v r="$CS_ROUTE" '$4 == "shadow" && $5 ~ /^would switch-route / { split($5, w, " "); sub(/:$/, "", w[3]); if (w[3] != r) f = 1 } END { exit !f }'
}

cs_primary_only() {
  local plat="$1" a="$2" d r proxy g0 f
  d="$(cs_dir "$a")"
  cs_wait "$a" primary-0 420 cs_route_selected || fail "$a: the shadow never selected a route"
  r="$(cs_field "$d/primary-0.tsv" state-shadow route)"; proxy="$(cs_proxy "$d/primary-0.tsv")"; g0="$(cs_gen "$d/primary-0.tsv")"
  CS_ROUTE="$r" CS_SINCE="$(cs_now "$d/primary-0.tsv")"
  cs_t "$a" fault-route --component "$proxy" --route "$r" >"$d/fault.log" 2>&1 || fail "$a: fault-route $r: $(cat "$d/fault.log")"
  f=0
  cs_wait "$a" primary-1 420 cs_switched || f=1
  cs_t "$a" heal-route --component "$proxy" --route "$r" >>"$d/fault.log" 2>&1 || fail "$a: heal-route $r: $(cat "$d/fault.log")"
  [ "$f" -eq 0 ] || fail "$a: no shadow switch away from $r within 7 minutes: $(cs_journal "$d/primary-1.tsv" "$CS_SINCE")"
  assert_eq unhealthy "$(cs_obs "$d/primary-1.tsv" "route:$r")" "$a: the faulted route $r is observed down"
  [ "$(cs_routes_healthy "$d/primary-1.tsv")" -ge 1 ] || fail "$a: the other routes still answer"
  assert_eq "" "$(cs_journal "$d/primary-1.tsv" "$CS_SINCE" | awk -F '\t' '$5 ~ /^would (restart-component|repair-runtime|escalate)/')" \
    "$a: a working route means no Tor restart intent"
  assert_eq "$g0" "$(cs_gen "$d/primary-1.tsv")" "$a: the proxy was not restarted"
  { printf 'faulted\t%s\n' "$r"; cs_journal "$d/primary-1.tsv" "$CS_SINCE"; } >"$d/primary-only.txt"
}

t_3_primary_only_outage() {
  cs_selection
  cs_each cs_primary_only
}

# ─────────────────────────── whole outage ───────────────────────────────────

cs_all_down() { [ "$(cs_routes "$1")" -ge 1 ] && [ "$(cs_routes_healthy "$1")" -eq 0 ]; }
cs_restart_intent() {
  cs_journal "$1" "$CS_SINCE" | awk -F '\t' '$4 == "shadow" && $5 ~ /^would restart-component tor/ { f = 1 } END { exit !f }'
}

cs_whole() {
  local plat="$1" a="$2" d proxy g0 f=0 cache="" os
  d="$(cs_dir "$a")"
  cs_report "$a" whole-0 || fail "$a: report"
  proxy="$(cs_proxy "$d/whole-0.tsv")"; g0="$(cs_gen "$d/whole-0.tsv")"
  CS_SINCE="$(cs_now "$d/whole-0.tsv")"
  NICE_DNS_FREEZE_MAX_SECS=1200 cs_t "$a" freeze-upstream --component "$proxy" >"$d/freeze.log" 2>&1 || fail "$a: freeze-upstream: $(cat "$d/freeze.log")"
  # CT-CACHE-VS-UPSTREAM: early in the outage Pi-hole may still answer from
  # cache; that answer must not count as upstream health.
  cs_wait "$a" whole-1 240 cs_all_down || f=1
  if [ "$f" -eq 0 ]; then
    cache="$(cs_obs "$d/whole-1.tsv" local-cache)"
    cs_wait "$a" whole-2 720 cs_restart_intent || f=2
  fi
  cs_t "$a" thaw-upstream --component "$proxy" >>"$d/freeze.log" 2>&1 || fail "$a: thaw-upstream: $(cat "$d/freeze.log")"
  [ "$f" -ne 1 ] || fail "$a: the routes were never all observed down with Tor frozen"
  [ "$f" -ne 2 ] || fail "$a: no shadow Tor restart intent within 12 minutes: $(cs_journal "$d/whole-2.tsv" "$CS_SINCE")"
  # The clock starts on the first pass after the routes went down (the
  # sample itself may precede that pass by up to a minute).
  os="$(cs_field "$d/whole-2.tsv" state-shadow outage_since)"
  assert_match '^[0-9]+$' "$os" "$a: the outage clock runs whatever the cache answers (local-cache: $cache)"
  [ "$os" -le $(( $(cs_now "$d/whole-1.tsv") + 120 )) ] \
    || fail "$a: the outage clock ($os) started more than one pass after every route was observed down ($(cs_now "$d/whole-1.tsv"))"
  assert_eq "$g0" "$(cs_gen "$d/whole-2.tsv")" "$a: shadow restarted nothing (same proxy generation)"
  assert_match '(^| )T( |$)' "$(cs_field "$d/whole-2.tsv" proxy tor_state)" "$a: Tor stayed frozen until the test thawed it"
  assert_eq "$(cs_sec "$d/whole-0.tsv" journal-active)" "$(cs_sec "$d/whole-2.tsv" journal-active)" "$a: no active journal row"
  { printf 'local_cache_during_outage\t%s\noutage_since\t%s\n' "$cache" "$os"
    cs_journal "$d/whole-2.tsv" "$CS_SINCE"; } >"$d/whole-outage.txt"
  cs_wait "$a" whole-3 600 cs_route_up || fail "$a: no route answered within 10 minutes of the thaw"
}

t_4_whole_outage() {
  cs_selection
  cs_each cs_whole
}

# ─────────────────────────── evidence ───────────────────────────────────────

t_5_evidence_is_private() {
  local p a
  cs_selection
  for p in $(cs_platforms); do
    cs_alias "$p"; a="$CS_ALIAS"
    assert_file "$(cs_dir "$a")/whole-outage.txt" "$a: the run reached the whole-outage evidence"
  done
  assert_eq "" "$(grep -rlE 'cert=[A-Za-z0-9+/]{20}|(^|[^0-9A-Fa-f])[0-9A-F]{40}([^0-9A-Fa-f]|$)|PRIVATE KEY|pwhash|BRIDGE[0-9]+=' "$ARTIFACT_DIR/controller-shadow" "$ARTIFACT_DIR/cases" 2>/dev/null)" \
    "no bridge line, certificate, fingerprint, key or password hash in the evidence"
}
