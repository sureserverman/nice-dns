# shellcheck shell=bash
# Group live/route-apply (Sub-plan 5, Task 1.2; ARCH-04, ARCH-05; DEC-010).
# Run with `tests/run.sh live route-apply --live --targets FILE
# --platforms all`: both platforms at once, each on the proxy it runs now,
# with the standard Pi-hole.
#
# The route directory is mounted and seeded by the installers, and the
# deployed controller's route layer switches Unbound between identity routes
# on a real host:
#
#   install     this checkout's HEAD (`git archive`, target.sh install-cell),
#               the host's resolver never leaving the stack; the deployment
#               is checked as in live/install-lifecycle
#   seeded      the installer seeded cloudflare-exit (or kept the route a
#               host already had); what runs then is an identity route,
#               possibly the controller's first choice (its schedules run
#               until the quiesce), read by Unbound from the host's
#               directory (the mount), running as recorded (control-socket
#               readback); probe-route passes (so a Tor restart's readiness
#               is corroborated through Unbound, DEC-006) and a fresh name
#               resolves through Pi-hole
#   switch      with the controller's schedules quiesced (so it cannot race
#               the switch), the bundle's apply_route moves to quad9-exit
#               while cached names are queried through Pi-hole every 250 ms
#               (none may fail: reload_keep_cache), then back to
#               cloudflare-exit at the next generation; each is read back and
#               probed
#   reinstall   the installer keeps the route the controller holds (its
#               generation, not the seed's 1; the restarted controller may
#               already have promoted the onion) and starts the schedules again
#
# Evidence: $ARTIFACT_DIR/route-apply/<alias>/. The installer's output may
# hold bridge lines: it stays in install-*.log (private, like
# live/install-lifecycle); the *.tsv reports hold none (t_2).

# shellcheck source=tests/live/install-lifecycle.sh
. "$NICE_DNS_ROOT/tests/live/install-lifecycle.sh"
unset -f t_1_before t_2_upgrade_from_legacy t_3_state_survives t_4_uninstall_restores t_5_final_install t_6_evidence_is_private

il_dir() { printf '%s\n' "$ARTIFACT_DIR/route-apply/$1"; }
IL_FIRST_STEPS=ra_cell

ra_report() { il_t "$1" route-report >"$(il_dir "$1")/route-$2.tsv" 2>>"$(il_dir "$1")/ops.log"; }
ra_val() { awk -F '\t' -v k="$2" '$1 == "section" { on = ($2 == "route"); next } on && $1 == k { print $2; exit }' "$1"; }
ra_addr() { if [ "$1" = linux ]; then echo 127.0.0.1; else echo 172.31.240.252; fi; }

# ra_check <platform> <report> <route> <generation> <label>: after a switch
# made here, with the controller's schedules quiesced.
ra_check() {
  local plat="$1" r="$2" route="$3" gen="$4" l="$5" port
  case "$route" in cloudflare-exit) port=18532 ;; quad9-exit) port=18533 ;; *) port=18531 ;; esac
  assert_eq 755 "$(ra_val "$r" dir_mode)" "$l: the route directory is 0755"
  assert_eq "route=$route generation=$gen" "$(ra_val "$r" include)" "$l: the include selects $route generation $gen"
  assert_match "^$(ra_addr "$plat")@$port#" "$(ra_val "$r" forwarder)" "$l: forwarding to the platform's $route listener"
  assert_eq "$route $gen" "$(ra_val "$r" desired)" "$l: recorded as desired"
  assert_eq yes "$(ra_val "$r" container_sees_host)" "$l: Unbound reads the host's include (the mount)"
  assert_eq "$route $gen $(ra_addr "$plat")" "$(ra_val "$r" readback)" "$l: and runs that route (control-socket readback)"
  assert_eq 0 "$(ra_val "$r" probe_route)" "$l: probe-route resolves over it in a fresh TLS session"
  assert_match '^(NOERROR|NXDOMAIN)$' "$(ra_val "$r" client_fresh)" "$l: a fresh name resolves through Pi-hole"
}

# ra_check_kept <platform> <report> <generation> <label>: the reinstall kept
# the controller's route: not the seed (generation 1) but <generation> or a
# later one the restarted controller chose (it promotes the onion once it
# has been healthy for ND_POLICY_PROMOTE observations), running as recorded.
ra_check_kept() {
  local plat="$1" r="$2" gen="$3" l="$4" inc route g
  inc="$(ra_val "$r" include)"
  route="$(printf '%s\n' "$inc" | sed -n 's/^route=\([a-z0-9-]*\) generation=[0-9]*$/\1/p')"
  g="$(printf '%s\n' "$inc" | sed -n 's/^route=[a-z0-9-]* generation=\([0-9]*\)$/\1/p')"
  assert_match '^(cloudflare-onion|cloudflare-exit|quad9-exit)$' "$route" "$l: an identity route runs ($inc)"
  assert_eq 1 "$(( g >= gen ))" "$l: at generation $g, not reseeded (the controller's was $gen)"
  # desired.tsv may be at a later generation of the same route: a same-route
  # selection is recorded without a reload (live mint 2026-09-28: desired
  # cloudflare-exit 86 over include generation 1).
  assert_eq "$route" "$(ra_val "$r" desired | cut -d' ' -f1)" "$l: recorded as desired"
  assert_eq 755 "$(ra_val "$r" dir_mode)" "$l: the route directory is 0755"
  assert_eq "$route $g $(ra_addr "$plat")" "$(ra_val "$r" readback)" "$l: and running"
  assert_eq yes "$(ra_val "$r" container_sees_host)" "$l: through the mount"
  assert_eq 0 "$(ra_val "$r" probe_route)" "$l: probe-route passes"
}

# ra_apply <alias> <route> <label>: GEN, the generation applied.
ra_apply() {
  local a="$1" f
  f="$(il_dir "$a")/apply-$3.tsv"
  il_t "$a" route-apply --route "$2" >"$f" 2>>"$(il_dir "$a")/ops.log" || fail "$a: route-apply $2: $(cat "$f")"
  assert_eq applied "$(awk -F '\t' '$1 == "result" { print $2 }' "$f")" "$a: $2 is applied: $(cat "$f")"
  GEN="$(awk -F '\t' '$1 == "generation" { print $2 }' "$f")"
}

ra_cell() {
  local plat="$1" a="$2" d proxy r g1 g2 w
  d="$(il_dir "$a")"
  if [ "${NICE_DNS_IL_DRY_RUN:-0}" != 1 ]; then
    assert_eq "" "$(GIT_OPTIONAL_LOCKS=0 git -C "$NICE_DNS_ROOT" status --porcelain --untracked-files=no)" "the checkout is committed (the archive is of HEAD)"
  fi
  il_t "$a" snapshot >>"$d/ops.log" 2>&1 || fail "snapshot $a"
  il_report "$a" before || fail "lifecycle-report $a: $(tail -n 5 "$d/ops.log")"
  proxy="$(il_proxy "$d/before.tsv")"
  assert_match '^(haproxy|socat)$' "$proxy" "$a runs a deployment"
  printf 'cell\t%s/%s/standard\nproxy\t%s\nsource_sha\t%s\n' "$plat" "$proxy" "$proxy" "$(il_sha)" >"$d/cell.tsv"
  printf 'target_id\t%s\nplatform\t%s\nproxy\t%s\npihole\tstandard\nsource_rev\t%s\nimages\tgeneration-of-%s\n' \
    "$a" "$plat" "$proxy" "$(il_sha)" "$(il_sha)" >"$d/identity.tsv"

  il_install "$a" candidate install || fail "the install failed: $(tail -n 20 "$d/install-candidate.log")"
  il_watch_pinned "$plat" "$d/watch-candidate.tsv" all
  il_t "$a" quiesce-agents >"$d/quiesce.tsv" 2>>"$d/ops.log" || fail "$a: quiesce-agents: $(cat "$d/quiesce.tsv")"
  il_report "$a" after-install || fail "lifecycle-report"
  il_check_deployed "$plat" "$d/after-install.tsv" "$proxy"
  # The installer says whether it seeded (a host without the directory) or
  # kept the route. The controller's schedules run from the end of the
  # install until the quiesce, so its first pass may already have moved the
  # route (live mac 2026-09-28: it applied cloudflare-onion generation 149,
  # the onion having been healthy for days, 4 s before the quiesce); what
  # runs is then checked for consistency, not for the seed.
  r="$(grep -ho "Unbound's route is seeded: [a-z0-9-]*\|Unbound keeps its route" "$d/install-candidate.log" | tail -n 1)"
  assert_match "^(Unbound's route is seeded: cloudflare-exit|Unbound keeps its route)\$" "$r" "$a: the installer seeded the identity exit route or kept the one there"
  printf 'install_route\t%s\n' "$r" >>"$d/cell.tsv"
  ra_report "$a" seeded || fail "route-report: $(tail -n 5 "$d/ops.log")"
  ra_check_kept "$plat" "$d/route-seeded.tsv" 1 "$a after the install"
  assert_match '^(NOERROR|NXDOMAIN)$' "$(ra_val "$d/route-seeded.tsv" client_fresh)" "$a after the install: a fresh name resolves through Pi-hole"

  # The switch, under cached-name load through Pi-hole.
  il_t "$a" collect --workload warm --count 1 --identity "$d/identity.tsv" >/dev/null 2>>"$d/ops.log" || true
  il_t "$a" collect --workload warm --count 80 --pause-ms 250 --identity "$d/identity.tsv" >"$d/warm-switch.tsv" 2>>"$d/ops.log" &
  w=$!
  sleep 3
  ra_apply "$a" quad9-exit switch; g1="$GEN"
  wait "$w"; r=$?
  assert_eq 0 "$r" "$a: every cached name answered through Pi-hole during the switch (collect exit $r)"
  assert_eq 80 "$(bash "$NICE_DNS_ROOT/tests/reports/stats.sh" "$d/warm-switch.tsv" | awk -F '\t' '$1 == "warm" { print $2 }')" "$a: all 80 attempts are counted"
  ra_report "$a" switched || fail "route-report"
  ra_check "$plat" "$d/route-switched.tsv" quad9-exit "$g1" "$a switched"
  ra_apply "$a" cloudflare-exit back; g2="$GEN"
  assert_eq "$((g1 + 1))" "$g2" "$a: the next change takes the next generation"
  ra_report "$a" back || fail "route-report"
  ra_check "$plat" "$d/route-back.tsv" cloudflare-exit "$g2" "$a back"

  # A reinstall keeps the controller's route and restarts its schedules.
  il_install "$a" reinstall install || fail "the reinstall failed: $(tail -n 20 "$d/install-reinstall.log")"
  il_watch_pinned "$plat" "$d/watch-reinstall.tsv" all
  il_report "$a" after-reinstall || fail "lifecycle-report"
  il_check_deployed "$plat" "$d/after-reinstall.tsv" "$proxy"
  ra_report "$a" reinstalled || fail "route-report"
  ra_check_kept "$plat" "$d/route-reinstalled.tsv" "$g2" "$a reinstalled"
  if [ "$plat" = macos ]; then
    assert_match 'org\.nice-dns\.health' "$(il_agents "$d/after-reinstall.tsv")" "$a: the controller's agent is loaded again"
  else
    assert_match '^unit	nice-dns-health\.timer	enabled$' "$(il_sec "$d/after-reinstall.tsv" schedules)" "$a: the controller's timer is enabled again"
  fi
  printf 'route-apply\t%s\tpass\n' "$plat/$proxy/standard" >"$d/route.tsv"
}

t_1_route_apply() { il_selection; il_each ra_cell; }

t_2_evidence_is_private() {
  il_selection
  assert_eq "" "$(grep -rlE 'cert=[A-Za-z0-9+/]{20}|(^|[^0-9A-Fa-f])[0-9A-F]{40}([^0-9A-Fa-f]|$)|PRIVATE KEY|"sid":|pwhash|BRIDGE[0-9]+=' "$ARTIFACT_DIR/route-apply" --include='*.tsv' 2>/dev/null)" \
    "no report, sample or step record holds bridge material, a session or a hash"
}
