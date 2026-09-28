# shellcheck shell=bash
# Group live/install-lifecycle (Sub-plan 4, Task 2.3; ARCH-06, ARCH-08,
# ARCH-09). Run by `tests/run.sh live install-lifecycle --targets FILE
# --variants representative` (and by `plan installers`).
#
# One representative cell per platform: the proxy each designated disposable
# target runs now, with the standard Pi-hole, installed by the product's own
# entrypoint from this checkout's committed HEAD (`git archive`, sent inline;
# tests/live/target.sh install-cell). Both platforms run concurrently.
#
#   t_1_before              snapshot and report the target as found (the
#                           legacy, unrecorded install on both targets)
#   t_2_upgrade_from_legacy install the branch over it while the host's
#                           resolver is sampled every 2 s: the resolver never
#                           leaves the stack; then the deployment is checked
#   t_3_state_survives      mark the Tor and anchor state and add an operator
#                           allow rule, reinstall: every mark is still there
#   t_4_uninstall_restores  uninstall: the DNS state recorded before nice-dns
#                           is back (legacy: the distribution default), the
#                           instance state and owned schedules are gone, a
#                           schedule nice-dns does not own is left alone
#   t_5_final_install       install again: the targets end on this branch's
#                           stack (user decision 2026-09-28), checked like t_2
#   t_6_evidence_is_private the evidence holds no bridge material, session or
#                           password
#
# A deployment is checked (il_check_deployed) for: the generation's images are
# the ones running, the controller is installed, the state volumes exist, the
# anchor and Tor state are present, the Pi-hole lists volume is on the image's
# seed, the admin API refuses anonymous and wrong-password requests and
# accepts the deployment's password (read on the target, never sent back),
# the password file is private, Linux publishes :53 on loopback only, and the
# macOS sudoers rule allows exactly the agent's three helper verbs.
#
# Evidence: $ARTIFACT_DIR/install-lifecycle/<alias>/. The installer's own
# output may hold bridge lines: it stays in install-*.log, which t_6 checks.
# NICE_DNS_TARGET_ADAPTER replaces target.sh only for the dry run
# (integration/install-lifecycle-dryrun, NICE_DNS_IL_DRY_RUN=1); a live run
# refuses it.

IL_TG="${NICE_DNS_TARGET_ADAPTER:-$NICE_DNS_ROOT/tests/live/target.sh}"

il_dir() { printf '%s\n' "$ARTIFACT_DIR/install-lifecycle/$1"; }
il_platforms() {
  local p="${NICE_DNS_OPT_PLATFORMS:-all}"
  if [ "$p" = all ]; then printf 'linux macos\n'; else printf '%s\n' "$p" | tr ',' ' '; fi
}

il_selection() {
  local x
  if [ -n "${NICE_DNS_TARGET_ADAPTER:-}" ]; then
    [ "${NICE_DNS_IL_DRY_RUN:-0}" = 1 ] || fail "live runs use the real guarded adapter (NICE_DNS_TARGET_ADAPTER is for the dry run only)"
  fi
  assert_ne "" "${NICE_DNS_OPT_TARGETS:-}" "--targets FILE"
  case "${NICE_DNS_OPT_VARIANTS:-representative}" in representative) ;; *) fail "--variants must be representative (one cell per platform; the other cells are the gate's)" ;; esac
  for x in $(il_platforms); do
    case "$x" in linux|macos) ;; *) fail "unknown --platforms value '$x' (all, linux, macos)" ;; esac
  done
}

# il_alias <platform>: IL_ALIAS, the one target of that platform.
il_alias() {
  local rows
  rows="$(bash "$IL_TG" validate --targets "$NICE_DNS_OPT_TARGETS" | awk -F '\t' -v p="$1" '$2 == p { print $1 }')"
  assert_eq 1 "$(printf '%s' "$rows" | grep -c .)" "exactly one $1 target in $NICE_DNS_OPT_TARGETS"
  IL_ALIAS="$rows"
}

# il_t <alias> <op> [args]: one target operation, logged to the alias's ops.log.
il_t() {
  local a="$1" op="$2"
  shift 2
  printf '== %s %s %s\n' "$(date -u +%H:%M:%S)" "$op" "$*" >>"$(il_dir "$a")/ops.log"
  ARTIFACT_DIR="$ARTIFACT_DIR" RUN_ID="$RUN_ID" bash "$IL_TG" "$op" "$a" --targets "$NICE_DNS_OPT_TARGETS" "$@"
}

il_report() { il_t "$1" lifecycle-report >"$(il_dir "$1")/$2.tsv" 2>>"$(il_dir "$1")/ops.log"; }
il_sec() { awk -F '\t' -v s="$2" '$1 == "section" { on = ($2 == s); next } on' "$1"; }
il_val() { il_sec "$1" "$2" | awk -F '\t' -v k="$3" '$1 == k { print $2; exit }'; }
il_val3() { il_sec "$1" "$2" | awk -F '\t' -v k="$3" -v c="$4" '$1 == k && $2 == c { print $3; exit }'; }

il_proxy() { il_sec "$1" running | awk -F '\t' '$1 == "running" && $2 ~ /^tor-/ { sub(/^tor-/, "", $2); print $2; exit }'; }
il_sha() { git -C "$NICE_DNS_ROOT" rev-parse HEAD; }

# il_each <fn>: <fn> <platform> <alias> for every selected platform at once.
il_each() {
  local fn="$1" p a pids="" rc bad=""
  for p in $(il_platforms); do
    il_alias "$p"; a="$IL_ALIAS"
    mkdir -p "$(il_dir "$a")"
    if [ "$fn" != il_before ] && [ ! -f "$(il_dir "$a")/cell.tsv" ]; then
      printf 'ASSERT FAIL: %s: no cell recorded (t_1_before failed); %s not run\n' "$a" "$fn" >"$CASE_DIR/$p.log"
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

il_cell() { awk -F '\t' -v k="$2" '$1 == k { print $2; exit }' "$(il_dir "$1")/cell.tsv"; }

# il_install <alias> <label> <install|uninstall>: the entrypoint from the
# archive, with the resolver sampled for the whole run.
il_install() {
  local a="$1" label="$2" act="$3" d w rc
  d="$(il_dir "$a")"
  NICE_DNS_WATCH_SECS=3600 il_t "$a" watch-dns >"$d/watch-$label.tsv" 2>>"$d/ops.log" &
  w=$!
  il_t "$a" "$act-cell" --cell "$(il_cell "$a" proxy)/standard" --source-sha "$(il_cell "$a" source_sha)" >"$d/install-$label.log" 2>&1
  rc=$?
  kill "$w" 2>/dev/null; wait "$w" 2>/dev/null
  printf '%s\t%s\t%s\n' "$label" "$act" "$rc" >>"$d/steps.tsv"
  return "$rc"
}

# il_pinned_sample <platform> <sample>: 0 when every resolver setting in the
# sample points at the stack.
il_pinned_sample() {
  if [ "$1" = linux ]; then
    case "$2" in 'file;127.0.0.1 ') return 0 ;; *) return 1 ;; esac
  fi
  printf '%s\n' "$2" | tr ';' '\n' | grep . | awk -F '=' '$2 != "172.31.240.250" { bad = 1 } END { exit bad }'
}

# il_watch_pinned <platform> <file> <all|after-first>: all: every sample is
# pinned; after-first: once pinned, it stays pinned.
il_watch_pinned() {
  local plat="$1" f="$2" mode="$3" n=0 seen=0 t s
  while IFS="$(printf '\t')" read -r t s; do
    [ -n "$t" ] || continue
    n=$((n + 1))
    if il_pinned_sample "$plat" "$s"; then seen=1
    elif [ "$mode" = all ] || [ "$seen" = 1 ]; then
      fail "the host resolver left the stack at $(date -u -d "@$t" +%H:%M:%S 2>/dev/null || echo "$t"): $s"
    fi
  done <"$f"
  [ "$n" -ge 3 ] || fail "too few resolver samples ($n) in $f"
  [ "$seen" = 1 ] || fail "the resolver was never pinned during the install ($f)"
}

# il_check_deployed <platform> <report>: the deployment is what was installed.
il_check_deployed() {
  local plat="$1" r="$2" proxy="$3" c role img want got v
  assert_ne none "$(il_val "$r" generation current)" "a generation is current"
  assert_eq yes "$(il_val "$r" resolution resolves)" "the host resolves through the stack"
  for c in pi-hole unbound "tor-$proxy"; do
    case "$c" in tor-*) role=proxy ;; *) role="$c" ;; esac
    img="$(il_val3 "$r" running running "$c")"
    assert_ne "" "$img" "$c runs"
    want="$(il_sec "$r" generation | awk -F '\t' -v k="$role" '$1 == "image" && $2 == k { print $4; exit }' | sed 's/^sha256://')"
    got="${img#sha256:}"
    assert_eq "$want" "$got" "$c runs the generation's $role image"
  done
  assert_match 'entrypoint' "$(il_sec "$r" controller)" "the controller's install record"
  v="$(il_sec "$r" volumes | cut -f2 | LC_ALL=C sort | tr '\n' ' ')"
  assert_match 'nice-dns-pihole-lists' "$v" "the Pi-hole lists volume"
  assert_match 'nice-dns-unbound-anchor' "$v" "the anchor volume"
  [ "$plat" = linux ] && assert_match "nice-dns-tor-$proxy" "$v" "the Tor state volume"
  assert_eq present "$(il_val "$r" state anchor_file)" "the anchor is in its volume"
  assert_eq present "$(il_val3 "$r" state tor_state_file "tor-$proxy")" "Tor keeps state in its volume"
  got="$(il_sec "$r" state | awk -F '\t' '$1 == "lists_seed" { print ($2 != "" && $2 == $3) ? "same" : "differ:" $2 "/" $3 }')"
  assert_eq same "$got" "the lists volume is on the image's seed"
  assert_eq 401 "$(il_val "$r" admin anonymous)" "the admin API refuses an anonymous request"
  assert_eq '"valid":false' "$(il_val "$r" admin wrong)" "and a wrong password"
  assert_eq '"valid":true' "$(il_val "$r" admin right)" "and accepts the deployment's password"
  assert_eq '-rw-------' "$(il_val "$r" admin admin_secret_mode)" "the password file is private"
  if [ "$plat" = linux ]; then
    got="$(il_sec "$r" listeners | awk -F '\t' '$1 == "listen"')"
    assert_ne "" "$got" "something listens on :53"
    assert_eq "" "$(printf '%s\n' "$got" | awk -F '\t' '$3 !~ /^127\./')" "and only on loopback (host-only DNS)"
  else
    got="$(il_sec "$r" privilege | awk -F '\t' '$1 == "sudoers" { print $2 }')"
    assert_eq 1 "$(printf '%s\n' "$got" | grep -c .)" "one sudoers rule"
    assert_eq "post pre repair-dnsnet" "$(printf '%s\n' "${got#*NOPASSWD: }" | tr ',' '\n' | sed 's/^ *//' \
      | awk '{ if ($1 != "/usr/local/sbin/start-container-root.sh" || NF != 2) print "OTHER:" $0; else print $2 }' | LC_ALL=C sort | tr '\n' ' ' | sed 's/ $//')" \
      "the agent may run exactly the helper's pre, post and repair-dnsnet"
  fi
}

il_agents() { il_sec "$1" schedules | awk -F '\t' '$1 == "agent" { print $2 }' | LC_ALL=C sort; }
IL_OWNED_AGENTS='org.nice-dns.start-container org.nice-dns.health org.nice-dns.health-bridges org.nice-dns.bridge-eval'
il_unowned_agents() { il_agents "$1" | while IFS= read -r x; do case " $IL_OWNED_AGENTS " in *" $x "*) ;; *) printf '%s\n' "$x" ;; esac; done; }

# ─────────────────────────── steps ───────────────────────────────────────────

il_before() {
  local plat="$1" a="$2" d proxy dirty
  d="$(il_dir "$a")"
  dirty="$(GIT_OPTIONAL_LOCKS=0 git -C "$NICE_DNS_ROOT" status --porcelain --untracked-files=no)"
  if [ "${NICE_DNS_IL_DRY_RUN:-0}" = 1 ]; then
    echo "dry run: the committed-checkout check is skipped"
  else
    assert_eq "" "$dirty" "the checkout is committed (the archive is of HEAD)"
  fi
  il_t "$a" snapshot >>"$d/ops.log" 2>&1 || fail "snapshot $a"
  il_report "$a" before || fail "lifecycle-report $a: $(tail -n 5 "$d/ops.log")"
  proxy="$(il_proxy "$d/before.tsv")"
  if [ -z "$proxy" ]; then
    # Nothing installed (e.g. after an uninstall): --proxies names the cell.
    case "${NICE_DNS_OPT_PROXIES:-}" in haproxy|socat) proxy="$NICE_DNS_OPT_PROXIES" ;; esac
  fi
  assert_match '^(haproxy|socat)$' "$proxy" "$a runs a proxy now, or --proxies names one"
  printf 'cell\t%s/%s/standard\nproxy\t%s\nsource_sha\t%s\nadapter\t%s\n' "$plat" "$proxy" "$proxy" "$(il_sha)" \
    "$( [ -n "${NICE_DNS_TARGET_ADAPTER:-}" ] && echo fake || echo real)" >"$d/cell.tsv"
}

il_upgrade() {
  local plat="$1" a="$2" d
  d="$(il_dir "$a")"
  il_install "$a" upgrade install || fail "the install over the legacy deployment failed: $(tail -n 20 "$d/install-upgrade.log")"
  # Over a running deployment the resolver never leaves the stack; over none,
  # once pinned it stays pinned.
  if [ -n "$(il_proxy "$d/before.tsv")" ]; then il_watch_pinned "$plat" "$d/watch-upgrade.tsv" all
  else il_watch_pinned "$plat" "$d/watch-upgrade.tsv" after-first; fi
  il_report "$a" after-upgrade || fail "lifecycle-report"
  il_check_deployed "$plat" "$d/after-upgrade.tsv" "$(il_cell "$a" proxy)"
  assert_eq "" "$(comm -23 <(il_unowned_agents "$d/before.tsv") <(il_agents "$d/after-upgrade.tsv"))" "no schedule nice-dns does not own was removed"
}

il_state() {
  local plat="$1" a="$2" d m r
  d="$(il_dir "$a")"
  m="nd-live-$RUN_ID"
  il_t "$a" mark-state >>"$d/ops.log" 2>&1 || fail "mark-state: $(tail -n 5 "$d/ops.log")"
  il_report "$a" marked || fail "lifecycle-report"
  assert_eq "$m" "$(il_val "$d/marked.tsv" state anchor_marker)" "the anchor volume holds the mark"
  il_install "$a" reinstall install || fail "the reinstall failed: $(tail -n 20 "$d/install-reinstall.log")"
  il_watch_pinned "$plat" "$d/watch-reinstall.tsv" all
  il_report "$a" after-reinstall || fail "lifecycle-report"
  r="$d/after-reinstall.tsv"
  il_check_deployed "$plat" "$r" "$(il_cell "$a" proxy)"
  assert_ne "$(il_val "$d/after-upgrade.tsv" generation current)" "$(il_val "$r" generation current)" "the reinstall made a new generation"
  assert_eq "$m" "$(il_val "$r" state anchor_marker)" "the anchor state survived the reinstall"
  assert_eq "$m" "$(il_val3 "$r" state tor_marker "tor-$(il_cell "$a" proxy)")" "the Tor state survived the reinstall"
  # Pi-hole stores domains in lower case (live, 2026-09-28: the run id's T and
  # Z came back as t and z).
  assert_match "$(printf '%s' "$m" | tr '[:upper:]' '[:lower:]')\\.example" "$(il_val "$r" state lists_marker_rules)" "the operator's allow rule survived the reinstall"
}

il_uninstall() {
  local plat="$1" a="$2" d r
  d="$(il_dir "$a")"
  il_install "$a" uninstall uninstall || fail "the uninstall failed: $(tail -n 20 "$d/install-uninstall.log")"
  il_report "$a" after-uninstall || fail "lifecycle-report"
  r="$d/after-uninstall.tsv"
  assert_eq yes "$(il_val "$r" resolution resolves)" "the host resolves after the uninstall (live 2026-09-28: mint did not)"
  assert_eq "" "$(il_sec "$r" volumes)" "no nice-dns volume is left"
  assert_eq "" "$(il_val "$r" admin admin_secret_mode)" "the admin password is gone"
  assert_eq "" "$(il_sec "$r" running | awk -F '\t' '$1 == "running"')" "no stack container runs"
  if [ "$plat" = linux ]; then
    # Legacy record: the distribution default, the systemd-resolved stub.
    assert_match '^resolv\.conf	/run/systemd/resolve/stub-resolv\.conf$' "$(il_sec "$r" dns)" "resolv.conf is the systemd-resolved stub again"
    assert_match '^systemd-resolved	active$' "$(il_sec "$r" dns)" "and systemd-resolved runs"
    assert_eq "" "$(il_sec "$r" schedules | awk -F '\t' '$1 == "unit"')" "no nice-dns unit is left"
  else
    # Legacy record: every pinned service back to Empty (DHCP).
    assert_eq "" "$(il_sec "$r" dns | awk -F '\t' 'NF >= 2 && $2 ~ /172\.31\.240\.250/')" "no network service points at the stack any more"
    assert_eq "" "$(il_agents "$r" | grep -E '^org\.nice-dns\.(start-container|health|health-bridges|bridge-eval)$')" "the owned agents are gone"
    assert_eq "" "$(comm -23 <(il_unowned_agents "$d/before.tsv") <(il_agents "$r"))" "an agent nice-dns does not own is left alone"
  fi
}

il_final() {
  local plat="$1" a="$2" d
  d="$(il_dir "$a")"
  il_install "$a" final install || fail "the final install failed: $(tail -n 20 "$d/install-final.log")"
  # From the restored state: once pinned, the resolver stays on the stack.
  il_watch_pinned "$plat" "$d/watch-final.tsv" after-first
  il_report "$a" after-final || fail "lifecycle-report"
  il_check_deployed "$plat" "$d/after-final.tsv" "$(il_cell "$a" proxy)"
}

t_1_before() { il_selection; il_each il_before; }
t_2_upgrade_from_legacy() { il_selection; il_each il_upgrade; }
t_3_state_survives() { il_selection; il_each il_state; }
t_4_uninstall_restores() { il_selection; il_each il_uninstall; }
t_5_final_install() { il_selection; il_each il_final; }

t_6_evidence_is_private() {
  local d="$ARTIFACT_DIR/install-lifecycle"
  il_selection
  assert_eq "" "$(grep -rlE 'cert=[A-Za-z0-9+/]{20}|(^|[^0-9A-Fa-f])[0-9A-F]{40}([^0-9A-Fa-f]|$)|PRIVATE KEY|"sid":|pwhash|BRIDGE[0-9]+=' "$d" --include='*.tsv' 2>/dev/null)" \
    "no report, sample or step record holds bridge material, a session or a hash"
}
