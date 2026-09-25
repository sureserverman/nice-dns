# shellcheck shell=bash
# Group integration/recovery-actions (Sub-plan 3, Task 1.3; ARCH-02, ARCH-03,
# ARCH-04, ARCH-07; REC-ACK-READINESS).
#
# Sourced by tests/run.sh (assert_* helpers; NICE_DNS_ROOT, CASE_DIR, RUN_ID).
# Two kinds of case:
#   * t_image_*: the proxy images built from the sibling checkouts
#     (tests/fixtures/transport.sh: containers nd-test-tp-<run>-*, --network
#     none, a stand-in tor), driven through lib/recovery.sh with the Linux
#     adapter aimed at that test container. --proxies all|haproxy|socat
#     (NICE_DNS_OPT_PROXIES, default all) picks the images.
#   * the rest: lib/recovery.sh against PATH stubs for podman, container,
#     systemctl and launchctl (both platform adapters), so no host runtime,
#     scheduler or container is touched.
# The production pod, its images and the host's schedulers are never touched.

. "$NICE_DNS_ROOT/tests/fixtures/transport.sh"

RA_TOOLS="awk basename bash cat chmod cp cut date dirname env find grep head id kill ln ls mkdir mktemp mv ps readlink rm sed sh sleep sort tail touch tr wc"

ra_proxies() {
  local p="${NICE_DNS_OPT_PROXIES:-all}" x out=""
  [ "$p" = all ] && { printf 'haproxy socat\n'; return 0; }
  for x in $(printf '%s' "$p" | tr ',' ' '); do
    case "$x" in haproxy|socat) out="$out $x" ;; *) fail "unknown --proxies value '$x' (all, haproxy, socat)" ;; esac
  done
  printf '%s\n' "$out"
}

# ra_stubs <bindir>: fakes whose behaviour comes from files in $FAKE; every
# call is appended to $FAKE_LOG. The runtime fake serves as podman (Linux)
# and container (macOS).
ra_stubs() {
  local b="$1" s
  mkdir -p "$b"
  cat >"$b/podman" <<'STUB'
#!/bin/sh
me="$(basename "$0")"
l="$me"; for a in "$@"; do l="$l $a"; done; printf '%s\n' "$l" >>"$FAKE_LOG"
if [ -f "$FAKE/hang" ]; then exec sleep "$(cat "$FAKE/hang")"; fi
ctl="$FAKE/ctl"
case "$1" in
  ps) cat "$FAKE/running" ;;
  ls)
    printf 'ID           IMAGE            OS     ARCH   STATE    IP                 CPUS  MEMORY  STARTED\n'
    while IFS= read -r n; do
      [ -n "$n" ] && printf '%-12s %-16s linux  arm64  running  172.31.240.25x/29  1     256 MB  %s\n' "$n" "$n:latest" "$(cat "$FAKE/started")"
    done <"$FAKE/running"
    if [ "$2" = -a ] && [ -f "$FAKE/stopped" ]; then
      while IFS= read -r n; do
        [ -n "$n" ] && printf '%-12s %-16s linux  arm64  stopped  -                  1     256 MB  -\n' "$n" "$n:latest"
      done <"$FAKE/stopped"
    fi ;;
  inspect) printf 'id-1 %s running\n' "$(cat "$FAKE/started")" ;;
  system) : >"$FAKE/system-started" ;;
  exec)
    if [ "$2" = --user ]; then a1="$1"; shift 3; set -- "$a1" "$@"; fi
    c="$2"; shift 2
    grep -qx "$c" "$FAKE/running" || { echo "Error: no such container $c" >&2; exit 125; }
    [ -f "$FAKE/slow" ] && sleep "$(cat "$FAKE/slow")"
    case "$1" in
      /usr/local/bin/nice-dns-unbound-start) exit "$(cat "$FAKE/unbound_probe_rc" 2>/dev/null || echo 0)" ;;
      test) exit "$(cat "$FAKE/cap_rc" 2>/dev/null || echo 0)" ;;
      cat) f="$ctl/$(basename "$2")"; [ -f "$f" ] || exit 1; cat "$f" ;;
      sh)
        id="$5"
        printf '%s\n' "$id" >"$ctl/tor-restart-request"
        if [ -f "$FAKE/ack" ]; then
          g="$(awk -F '\t' '$1 == "generation" { print $2 }' "$ctl/tor-generation")"
          case "$(cat "$FAKE/ack")" in
            new) g=$((g + 1)); p=$((1000 + g)) ;;
            same) p="$(awk -F '\t' '$1 == "tor_pid" { print $2 }' "$ctl/tor-generation")" ;;
            refused) p=0 ;;
          esac
          st=respawned; [ "$(cat "$FAKE/ack")" = refused ] && st=refused
          printf 'request_id\t%s\nstatus\t%s\ngeneration\t%s\ntor_pid\t%s\nutc\tx\n' "$id" "$st" "$g" "$p" >"$ctl/tor-restart-ack"
          printf 'generation\t%s\ntor_pid\t%s\n' "$g" "$p" >"$ctl/tor-generation"
        fi ;;
    esac ;;
esac
exit 0
STUB
  cp "$b/podman" "$b/container"
  cat >"$b/systemctl" <<'STUB'
#!/bin/sh
l=systemctl; for a in "$@"; do l="$l $a"; done; printf '%s\n' "$l" >>"$FAKE_LOG"
case "$2" in
  restart)
    [ -f "$FAKE/restart_changes" ] && echo "t$(date +%s)-new" >"$FAKE/started"
    [ -f "$FAKE/restart_brings_up" ] && ! grep -qx tor-haproxy "$FAKE/running" && echo tor-haproxy >>"$FAKE/running" ;;
  start) [ -f "$FAKE/start_brings_up" ] && printf 'pi-hole\nunbound\ntor-haproxy\n' >"$FAKE/running" ;;
esac
exit 0
STUB
  cat >"$b/launchctl" <<'STUB'
#!/bin/sh
l=launchctl; for a in "$@"; do l="$l $a"; done; printf '%s\n' "$l" >>"$FAKE_LOG"
if [ "$2" = -k ]; then [ -f "$FAKE/restart_changes" ] && echo "t$(date +%s)-new" >"$FAKE/started"
  [ -f "$FAKE/restart_brings_up" ] && ! grep -qx tor-haproxy "$FAKE/running" && echo tor-haproxy >>"$FAKE/running"
else [ -f "$FAKE/start_brings_up" ] && printf 'pi-hole\nunbound\ntor-haproxy\n' >"$FAKE/running"; fi
exit 0
STUB
  chmod 755 "$b/podman" "$b/container" "$b/systemctl" "$b/launchctl"
  for s in $RA_TOOLS; do ln -sf "$(command -v "$s")" "$b/$s"; done
}

# ra_fake <linux|macos>: a fresh fake world and the libraries for that
# platform, sourced into this case's shell.
ra_fake() {
  export FAKE="$CASE_DIR/fake-$1" FAKE_LOG="$CASE_DIR/fake-$1/calls.log"
  rm -rf "$FAKE"; mkdir -p "$FAKE/ctl" "$FAKE/bin"
  ra_stubs "$FAKE/bin"
  printf 'pi-hole\nunbound\ntor-haproxy\n' >"$FAKE/running"
  echo t0-old >"$FAKE/started"
  printf 'generation\t1\ntor_pid\t1001\n' >"$FAKE/ctl/tor-generation"
  : >"$FAKE_LOG"
  export HOME="$CASE_DIR/home-$1" XDG_CONFIG_HOME="$CASE_DIR/home-$1/.config"
  mkdir -p "$XDG_CONFIG_HOME/containers/systemd"
  export PATH="$FAKE/bin" ND_PLATFORM="$1" ND_STATE_DIR="$CASE_DIR/state-$1" ND_BOOT_ID=boot-a
  export ND_ROUTES_FILE="$NICE_DNS_ROOT/routes/providers.tsv" ND_ROUTE_DIR="$CASE_DIR/route-$1"
  export ND_CONTAINER_FALLBACK=/nonexistent CONTAINER_BIN="$FAKE/bin/container"
  export ND_RECOVERY_ACK_S=3 ND_RECOVERY_SERVICE_S=6 ND_RECOVERY_CMD_DEADLINE=5 TMPDIR="$CASE_DIR/tmp"
  unset ND_PROXY_CONTAINER
  mkdir -p "$TMPDIR"
  if declare -F nd_platform_name >/dev/null && [ "$(nd_platform_name)" != "$1" ]; then
    fail "ra_fake $1: this shell already loaded the $(nd_platform_name) adapter; run each platform in its own subshell"
  fi
  # shellcheck source=lib/recovery.sh
  . "$NICE_DNS_ROOT/lib/recovery.sh" || fail "cannot source lib/recovery.sh"
  assert_eq "$1" "$(nd_platform_name)" "the $1 adapter is the one loaded"
  nd_state_init || fail "state init"
}

ra_journal() { awk -F '\t' 'NR > 1 { print $3 " " $4 }' "$ND_STATE_DIR/recovery.tsv" 2>/dev/null; }
ra_field() { printf '%s\n' "$2" | awk -F '\t' -v k="$1" '$1 == k { v = $2 } END { print v }'; }

# ra_obs <file> <route state for every identity route> [compat state]
ra_obs() {
  { printf 'schema\tnice-dns-observations/1\n'
    printf 'obs\truntime\thealthy\t5\trunning: pi-hole unbound tor-haproxy\n'
    printf 'obs\troute:cloudflare-onion\t%s\t900\tprobe\nobs\troute:cloudflare-exit\t%s\t900\tprobe\n' "$2" "$2"
    printf 'obs\troute:quad9-exit\t%s\t900\tprobe\nobs\troute:cloudflare-legacy\t%s\t900\tprobe\n' "$2" "${3:-$2}"; } >"$1"
}

# ra_outage_state: committed state with a full outage well past every timer.
ra_outage_state() {
  local tok now
  now="$(date +%s)"
  printf 'schema\tnice-dns-controller-state/1\nboot_id\tboot-a\nupdated\t%s\nstarted\t%s\nroute\tcloudflare-exit\noutage_since\t%s\noutage_restarts\t0\nlast_action\t-\nlast_action_at\t-\nrecovery_at\t-\n' \
    "$((now - 60))" "$((now - 7200))" "$((now - 3600))" >"$CASE_DIR/seed"
  tok="$(nd_state_lock)" || fail "lock for seeding"
  nd_state_commit "$tok" 0 "$CASE_DIR/seed" >/dev/null || fail "seed commit"
  nd_state_unlock "$tok"
}

# ─────────────────────────── proxy images ────────────────────────────────────

t_image_restart_request_is_acknowledged_with_new_generation() {
  local p out
  for p in $(ra_proxies); do
    tp_setup "tor-$p"
    tp_supervised
    out="$(ND_PLATFORM=linux ND_PROXY_CONTAINER="$TP_CTR" ND_STATE_DIR="$CASE_DIR/state-$p" ND_BOOT_ID=boot-a TMPDIR="$CASE_DIR" \
      bash -c '. "$1/lib/recovery.sh" && nd_state_init && request_recovery tor "ra-img-1"' _ "$NICE_DNS_ROOT" 2>&1)"
    assert_rc 0 $? "$p: the image acknowledges the controller's request: $out"
    assert_eq acknowledged "$(ra_field result "$out")" "$p: result"
    assert_eq 1 "$(ra_field generation_before "$out")" "$p: generation before"
    assert_eq 2 "$(ra_field generation "$out")" "$p: the acknowledgement carries the new generation"
    assert_eq "tor requested
tor acknowledged" "$(ND_STATE_DIR="$CASE_DIR/state-$p" ra_journal)" "$p: journal: requested, then acknowledged; readiness is not part of it"
    tp_cleanup
    rm -rf "$CASE_DIR/socks"
  done
}

t_image_silence_is_not_acknowledged() {
  local p out
  for p in $(ra_proxies); do
    tp_setup "tor-$p"
    tp_supervised
    # Freeze the container right after the request is written: the image
    # cannot answer, so no acknowledgement may be reported.
    out="$(ND_PLATFORM=linux ND_PROXY_CONTAINER="$TP_CTR" ND_STATE_DIR="$CASE_DIR/state-$p" ND_BOOT_ID=boot-a TMPDIR="$CASE_DIR" \
      ND_RECOVERY_ACK_S=4 ND_RECOVERY_CMD_DEADLINE=5 bash -c '. "$1/lib/recovery.sh" && nd_state_init \
        && nd_recovery_checkpoint() { podman pause "$2" >/dev/null 2>&1; } && request_recovery tor "ra-img-2"' _ "$NICE_DNS_ROOT" "$TP_CTR" 2>&1)"
    assert_rc 1 $? "$p: a frozen image is not acknowledged: $out"
    assert_eq not-acknowledged "$(ra_field result "$out")" "$p: result"
    assert_not_match 'acknowledged$' "$(ND_STATE_DIR="$CASE_DIR/state-$p" ra_journal | grep -v not-acknowledged)" "$p: nothing in the journal claims an acknowledgement"
    podman unpause "$TP_CTR" >/dev/null 2>&1
    tp_cleanup
    rm -rf "$CASE_DIR/socks"
  done
}

# ─────────────────────────── fakes: acknowledgement ─────────────────────────

t_request_write_is_never_an_acknowledgement() {
  local plat out rc
  for plat in linux macos; do
    (
      ra_fake "$plat"
      out="$(request_recovery tor ra-1)"; rc=$?
      assert_rc 1 "$rc" "$plat: an unanswered request: $out"
      assert_eq not-acknowledged "$(ra_field result "$out")" "$plat: result"
      assert_eq ra-1 "$(cat "$FAKE/ctl/tor-restart-request")" "$plat: the request reached the image's control directory"
      assert_eq "$(printf 'tor requested\ntor not-acknowledged')" "$(ra_journal)" "$plat: requested, then not acknowledged"
      echo same >"$FAKE/ack"
      out="$(request_recovery tor ra-2)"
      assert_eq not-acknowledged "$(ra_field result "$out")" "$plat: an answer without a new generation and pid is not an acknowledgement"
      echo refused >"$FAKE/ack"
      out="$(request_recovery tor ra-3)"
      assert_eq not-acknowledged "$(ra_field result "$out")" "$plat: a refused answer is not an acknowledgement"
      echo new >"$FAKE/ack"
      out="$(request_recovery tor ra-4)"
      assert_eq acknowledged "$(ra_field result "$out")" "$plat: a new generation and pid is"
      assert_eq 2 "$(ra_field generation "$out")" "$plat: generation 1 -> 2"
      assert_not_match 'tor-restart-flag' "$(cat "$FAKE_LOG")" "$plat: the flag interface is never used"
      out="$(request_recovery tor 'bad id;rm')"; rc=$?
      assert_rc 2 "$rc" "$plat: an unsafe request id is refused"
      out="$(request_recovery tor legacy)"; rc=$?
      assert_rc 2 "$rc" "$plat: the reserved id is refused"
    ) || exit 1
  done
}

t_unsupported_image_falls_back_once_to_a_verified_service_restart() {
  local plat out rc
  for plat in linux macos; do
    (
      ra_fake "$plat"
      echo 1 >"$FAKE/cap_rc"
      : >"$FAKE/restart_changes"
      printf 'schema\tnice-dns-decision/1\naction\trestart-component\ntarget\ttor\nreason\ttest\n' >"$CASE_DIR/dec"
      out="$(nd_recovery_apply "$CASE_DIR/dec" ra-5 7)"; rc=$?
      assert_rc 0 "$rc" "$plat: the fallback is acknowledged: $out"
      assert_match '^result	unsupported$' "$out" "$plat: the image without control is reported unsupported first"
      assert_eq acknowledged "$(ra_field result "$out")" "$plat: then the service restart is acknowledged"
      assert_eq "$(printf 'tor unsupported\nservice requested\nservice acknowledged')" "$(ra_journal)" "$plat: journal phases"
      if [ "$plat" = macos ]; then
        assert_eq 1 "$(grep -c '^launchctl kickstart -k gui/[0-9]*/org.nice-dns.start-container$' "$FAKE_LOG")" "$plat: exactly one service restart"
      assert_match 'stack restart for tor-haproxy' "$(cat "$ND_STATE_DIR/recovery.tsv")" "$plat: the journal says the macOS fallback restarts the stack"
      else
        assert_eq 1 "$(grep -c '^systemctl --user restart tor-haproxy.service$' "$FAKE_LOG")" "$plat: exactly one service restart"
      assert_match 'proxy restart for tor-haproxy' "$(cat "$ND_STATE_DIR/recovery.tsv")" "$plat: the Linux fallback restarts the proxy only"
      fi
      # A service restart that never brings a new container start is not
      # acknowledged, and nothing further is attempted in the same pass.
      rm -f "$FAKE/restart_changes"
      out="$(nd_recovery_apply "$CASE_DIR/dec" ra-6 8)"; rc=$?
      assert_rc 1 "$rc" "$plat: an unverified service restart fails"
      assert_eq not-acknowledged "$(ra_field result "$out")" "$plat: result"
    ) || exit 1
  done
}

t_hung_runtime_is_bounded_and_cleaned() {
  local plat out start el
  for plat in linux macos; do
    (
      ra_fake "$plat"
      echo 971 >"$FAKE/hang"
      ND_RECOVERY_CMD_DEADLINE=2
      start="$(date +%s)"
      out="$(request_recovery tor ra-7)"
      el=$(( $(date +%s) - start ))
      assert_not_match '^result	acknowledged$' "$out" "$plat: no acknowledgement from a hung runtime"
      assert_match '^result	(unreachable|not-acknowledged|unsupported)$' "$out" "$plat: reported as not done"
      [ "$el" -le 12 ] || fail "$plat: the hung runtime held the request for ${el}s"
      sleep 1
      # shellcheck disable=SC2009  # pgrep is not in the stub PATH
      assert_eq 0 "$(ps -eo args 2>/dev/null | grep -c '^sleep 971$')" "$plat: no hung child is left behind"
    ) || exit 1
  done
}

# ─────────────────────────── fakes: runtime repair ──────────────────────────

t_runtime_repair_acts_only_on_its_fault() {
  local out rc
  (
  ra_fake linux
  out="$(repair_runtime runtime-down ra-8)"; rc=$?
  assert_rc 3 "$rc" "linux: a silent rootless runtime has no repair here"
  assert_eq "" "$(grep -v '^podman ps' "$FAKE_LOG")" "linux: nothing was run for it"
  printf 'pi-hole\n' >"$FAKE/running"; : >"$FAKE/start_brings_up"
  out="$(repair_runtime containers-missing ra-9)"; rc=$?
  assert_rc 0 "$rc" "linux: missing containers are started and seen running: $out"
  assert_match '^systemctl --user start pi-hole.service$' "$(cat "$FAKE_LOG")" "linux: through pi-hole.service"
  assert_not_match 'restart|exec|kill' "$(cat "$FAKE_LOG")" "linux: nothing running is restarted"
  ) || exit 1
  (
  ra_fake macos
  out="$(repair_runtime runtime-down ra-10)"; rc=$?
  assert_rc 0 "$rc" "macos: container system start, then the runtime answers: $out"
  assert_match '^container system start$' "$(cat "$FAKE_LOG")" "macos: container system start"
  assert_not_match 'launchctl' "$(cat "$FAKE_LOG")" "macos: no stack restart for a runtime fault"
  printf 'pi-hole\n' >"$FAKE/running"; : >"$FAKE/start_brings_up"; : >"$FAKE_LOG"
  out="$(repair_runtime containers-missing ra-11)"; rc=$?
  assert_rc 0 "$rc" "macos: the agent recreates what is missing: $out"
  assert_match '^launchctl kickstart gui/[0-9]+/org.nice-dns.start-container$' "$(cat "$FAKE_LOG")" "macos: kickstart without -k"
  out="$(repair_runtime reboot-everything ra-12)"; rc=$?
  assert_rc 2 "$rc" "an unknown fault is refused"
  ) || exit 1
}

# ─────────────────────────── fakes: controller pass ─────────────────────────

t_route_switch_is_applied_without_touching_tor() {
  local out rc
  ra_fake linux
  apply_route() { printf 'result\tapplied\nroute\t%s\ngeneration\t%s\n' "$1" "$2"; printf '%s %s\n' "$1" "$2" >>"$CASE_DIR/applied"; return 0; }
  printf 'schema\tnice-dns-decision/1\naction\tswitch-route\ntarget\tcloudflare-exit\nreason\ttest\n' >"$CASE_DIR/dec"
  out="$(nd_recovery_apply "$CASE_DIR/dec" ra-13 9)"; rc=$?
  assert_rc 0 "$rc" "switch applied: $out"
  assert_eq "cloudflare-exit 9" "$(cat "$CASE_DIR/applied")" "apply_route got the target and generation"
  assert_eq "" "$(cat "$FAKE_LOG")" "no runtime command: Tor is not restarted for a route switch"
  assert_eq "$(printf 'route:cloudflare-exit requested\nroute:cloudflare-exit acknowledged')" "$(ra_journal)" "journal phases, per route"
}

t_tick_shadow_records_but_never_acts() {
  local out
  ra_fake linux
  ND_STATE_DIR="$ND_STATE_DIR/shadow" nd_state_init
  ND_STATE_DIR="$ND_STATE_DIR/shadow" ra_outage_state
  ra_obs "$CASE_DIR/o" unhealthy
  echo new >"$FAKE/ack"
  out="$(nd_recovery_tick shadow "$CASE_DIR/o")"
  assert_rc 0 $? "shadow pass: $out"
  assert_eq restart-component "$(ra_field action "$out")" "the decision is the restart"
  assert_eq shadow "$(ra_field result "$out")" "recorded as shadow"
  assert_eq "" "$(cat "$FAKE_LOG")" "no runtime, scheduler or route command ran"
  assert_eq "controller shadow" "$(ND_STATE_DIR="$ND_STATE_DIR/shadow" ra_journal)" "the shadow journal holds what it would do"
  assert_no_path "$ND_STATE_DIR/state.tsv" "the active state is untouched"
}

t_tick_active_records_request_acknowledgement_then_readiness() {
  local out
  ra_fake linux
  ra_outage_state
  ra_obs "$CASE_DIR/o" unhealthy
  echo new >"$FAKE/ack"
  out="$(nd_recovery_tick active "$CASE_DIR/o")"
  assert_rc 0 $? "active pass: $out"
  assert_eq restart-component "$(ra_field action "$out")" "restart decided"
  assert_eq acknowledged "$(ra_field result "$out")" "and acknowledged by the image"
  assert_eq "tor requested
tor acknowledged" "$(ra_journal)" "no readiness in the acknowledging pass"
  # Next pass: still failing inside the readiness window -> nothing recorded.
  out="$(nd_recovery_tick active "$CASE_DIR/o")"
  assert_eq "tor requested
tor acknowledged" "$(ra_journal)" "still failing: readiness is not claimed"
  ra_obs "$CASE_DIR/o" healthy
  out="$(nd_recovery_tick active "$CASE_DIR/o")"
  assert_eq "tor requested
tor acknowledged
tor ready" "$(ra_journal)" "a later healthy observation records readiness"
  out="$(nd_recovery_tick active "$CASE_DIR/o")"
  assert_eq 1 "$(ra_journal | grep -c 'tor ready')" "readiness is recorded once"
  assert_match '^generation	[0-9]+$' "$out" "every pass commits a generation"
}

t_tick_readiness_times_out_as_not_ready() {
  ra_fake linux
  ra_outage_state
  ra_obs "$CASE_DIR/o" unhealthy
  echo new >"$FAKE/ack"
  nd_recovery_tick active "$CASE_DIR/o" >/dev/null
  ND_RECOVERY_READY_S=0 nd_recovery_tick active "$CASE_DIR/o" >/dev/null
  assert_match 'tor not-ready$' "$(ra_journal)" "an acknowledged restart that never works is recorded not-ready"
}

t_tick_skips_while_another_pass_holds_the_lock() {
  local out rc sleeper
  ra_fake linux
  sleep 30 & sleeper=$!
  ln -s "nd-lock:$sleeper:boot-a:$(date +%s):other" "$ND_STATE_DIR/lock"
  ra_obs "$CASE_DIR/o" unhealthy
  out="$(nd_recovery_tick active "$CASE_DIR/o")"; rc=$?
  kill "$sleeper" 2>/dev/null; wait "$sleeper" 2>/dev/null
  assert_rc 3 "$rc" "a held lock skips the pass"
  assert_eq busy "$(ra_field result "$out")" "reported busy"
  assert_eq "" "$(cat "$FAKE_LOG")" "nothing was run"
}

t_no_code_path_writes_the_unacknowledged_flag() {
  local hits
  # Class sweep: every shipped script, not only the health CLI.
  hits="$(grep -rnE '(touch|>)[[:space:]]*/tmp/tor-restart-flag' "$NICE_DNS_ROOT/health" "$NICE_DNS_ROOT/lib" "$NICE_DNS_ROOT/mac" \
    "$NICE_DNS_ROOT/deb" "$NICE_DNS_ROOT/scripts" "$NICE_DNS_ROOT"/install-*.sh 2>/dev/null | grep -v ':[0-9]*:[[:space:]]*#')"
  assert_eq "" "$hits" "no shipped code touches the flag interface"
}

# ─────────────────────────── gate remediation 1 ─────────────────────────────

t_unreachable_proxy_gets_the_verified_service_restart() {
  local plat out rc
  for plat in linux macos; do
    (
      ra_fake "$plat"
      # The proxy container is not running (exec into it fails), or on macOS
      # does not exist at all: the restart path still falls back once.
      printf 'pi-hole\nunbound\n' >"$FAKE/running"
      : >"$FAKE/restart_changes"; : >"$FAKE/restart_brings_up"
      [ "$plat" = linux ] && : >"$XDG_CONFIG_HOME/containers/systemd/tor-haproxy.container"
      printf 'schema\tnice-dns-decision/1\naction\trestart-component\ntarget\ttor\nreason\ttest\n' >"$CASE_DIR/dec"
      out="$(nd_recovery_apply "$CASE_DIR/dec" ra-20 3)"; rc=$?
      assert_rc 0 "$rc" "$plat: an unreachable proxy is restarted by the service fallback: $out"
      assert_match '^result	unreachable$' "$out" "$plat: the in-image request reports unreachable first"
      assert_eq acknowledged "$(ra_field result "$out")" "$plat: the fallback is acknowledged by the container coming back"
      assert_match 'service acknowledged' "$(ra_journal)" "$plat: journal"
    ) || exit 1
  done
}

t_lost_lock_stops_every_action_before_it_changes_anything() {
  local plat out rc
  for plat in linux macos; do
    (
      ra_fake "$plat"
      export ND_RECOVERY_LOCK_TOKEN=not-the-holder
      out="$(request_recovery tor ra-21)"; rc=$?
      assert_rc 5 "$rc" "$plat: request refused without the lock"
      assert_no_path "$FAKE/ctl/tor-restart-request" "$plat: no request was written"
      : >"$FAKE/restart_changes"
      out="$(nd_recovery_restart_service ra-22)"; rc=$?
      assert_rc 5 "$rc" "$plat: service restart refused without the lock"
      assert_not_match 'systemctl|launchctl' "$(cat "$FAKE_LOG")" "$plat: no service command ran"
      out="$(repair_runtime containers-missing ra-23)"; rc=$?
      assert_rc 5 "$rc" "$plat: repair refused without the lock"
      assert_eq 3 "$(ra_journal | grep -c 'lock-lost$')" "$plat: each stop is journalled"
    ) || exit 1
  done
}

t_waits_are_bounded_in_wall_clock_seconds() {
  local out start el
  ra_fake linux
  # Every exec takes 2 s; the acknowledgement wait is 3 s. Counting passes
  # (not seconds) would wait 3 x (2 + 1) s for the answer loop alone.
  echo 2 >"$FAKE/slow"
  export ND_RECOVERY_ACK_S=3
  start="$(date +%s)"
  out="$(request_recovery tor ra-24)"
  el=$(( $(date +%s) - start ))
  assert_eq not-acknowledged "$(ra_field result "$out")" "no answer"
  # test + cat generation + write + one or two reads, each 2 s, then stop.
  [ "$el" -le 13 ] || fail "the acknowledgement wait took ${el}s; it must stop at its wall-clock budget"
}

ra_route_state() {
  local tok now
  now="$(date +%s)"
  printf 'schema\tnice-dns-controller-state/1\nboot_id\tboot-a\nupdated\t%s\nstarted\t%s\nroute\tcloudflare-onion\noutage_since\t-\noutage_restarts\t0\nlast_action\t-\nlast_action_at\t-\nrecovery_at\t-\nstreak\tcloudflare-onion\t9\t1\t1\n' \
    "$((now - 60))" "$((now - 7200))" >"$CASE_DIR/seed"
  tok="$(nd_state_lock)" || fail "seed lock"
  nd_state_commit "$tok" 0 "$CASE_DIR/seed" >/dev/null || fail "seed commit"
  nd_state_unlock "$tok"
}

ra_obs_onion_down() {
  { printf 'schema\tnice-dns-observations/1\nobs\truntime\thealthy\t5\trunning: x\n'
    printf 'obs\troute:cloudflare-onion\tunhealthy\t900\tp\nobs\troute:cloudflare-exit\thealthy\t900\tp\n'
    printf 'obs\troute:quad9-exit\thealthy\t900\tp\nobs\troute:cloudflare-legacy\thealthy\t900\tp\n'; } >"$1"
}

# apply_route is replaced per step; nd_recovery_apply calls it.
# shellcheck disable=SC2329
t_tick_records_a_route_only_once_applied() {
  local out
  ra_fake linux
  ra_route_state
  ra_obs_onion_down "$CASE_DIR/o"
  # No route directory mounted: route control is unavailable.
  apply_route() { echo called >>"$CASE_DIR/applied"; printf 'result\tapplied\n'; return 0; }
  out="$(nd_recovery_tick active "$CASE_DIR/o")"
  assert_eq switch-route "$(ra_field action "$out")" "the policy wants the exit"
  assert_eq unmanaged "$(ra_field result "$out")" "without a route directory nothing is attempted"
  assert_no_path "$CASE_DIR/applied" "apply_route was not called"
  assert_eq cloudflare-onion "$(nd_state_load | awk -F '\t' '$1 == "route" { print $2 }')" "the state keeps the route that runs"
  assert_eq "" "$(ra_journal)" "nothing is journalled for an unavailable route control"
  # A route directory exists and the switch fails: not recorded, retried.
  mkdir -m 700 "$ND_ROUTE_DIR"
  printf 'schema\tnice-dns-route-desired/1\nroute\tcloudflare-onion\ngeneration\t50\n' >"$ND_ROUTE_DIR/desired.tsv"
  apply_route() { printf '%s %s\n' "$1" "$2" >>"$CASE_DIR/applied"; printf 'result\trestored\n'; return 1; }
  out="$(nd_recovery_tick active "$CASE_DIR/o")"
  assert_eq restored "$(ra_field result "$out")" "the failed switch is reported"
  assert_eq cloudflare-onion "$(nd_state_load | awk -F '\t' '$1 == "route" { print $2 }')" "a failed switch is not recorded as selected"
  assert_match '^cloudflare-exit 5[1-9]$' "$(head -n 1 "$CASE_DIR/applied")" "the route generation is above the route layer's own (50)"
  out="$(nd_recovery_tick active "$CASE_DIR/o")"
  assert_eq 2 "$(wc -l <"$CASE_DIR/applied" | tr -d ' ')" "the next pass tries the switch again"
  apply_route() { printf '%s %s\n' "$1" "$2" >>"$CASE_DIR/applied"; printf 'result\tapplied\n'; return 0; }
  out="$(nd_recovery_tick active "$CASE_DIR/o")"
  assert_eq applied "$(ra_field result "$out")" "applied"
  assert_eq cloudflare-exit "$(nd_state_load | awk -F '\t' '$1 == "route" { print $2 }')" "only an applied switch is recorded"
}

t_readiness_is_per_request_and_corroborated_by_unbound() {
  local now
  ra_fake linux
  now="$(date +%s)"
  # Two actions acknowledged before either became ready, plus one whose
  # route stays down.
  { printf 'schema\tnice-dns-recovery-journal/1\n'
    printf '%s\tnd-1\ttor\tacknowledged\tx\n' "$((now - 30))"
    printf '%s\tnd-2\troute:cloudflare-exit\tacknowledged\tx\n' "$((now - 20))"
    printf '%s\tnd-3\troute:quad9-exit\tacknowledged\tx\n' "$((now - 10))"; } >"$ND_STATE_DIR/recovery.tsv"
  { printf 'schema\tnice-dns-observations/1\nobs\truntime\thealthy\t5\trunning: x\n'
    printf 'obs\troute:cloudflare-onion\tunhealthy\t9\tp\nobs\troute:cloudflare-exit\thealthy\t9\tp\n'
    printf 'obs\troute:quad9-exit\tunhealthy\t9\tp\nobs\troute:cloudflare-legacy\thealthy\t9\tp\n'; } >"$CASE_DIR/o"
  echo 1 >"$FAKE/unbound_probe_rc"
  _nd_rec_readiness "$CASE_DIR/o" "$now"
  assert_not_match 'nd-1	tor	ready' "$(cat "$ND_STATE_DIR/recovery.tsv")" "Tor is not ready while Unbound cannot resolve over its route"
  assert_match 'nd-2	route:cloudflare-exit	ready' "$(cat "$ND_STATE_DIR/recovery.tsv")" "the switched-to route is ready: it answers"
  assert_not_match 'nd-3	route:quad9-exit	ready' "$(cat "$ND_STATE_DIR/recovery.tsv")" "a route switch waits for its own route, not any route"
  echo 0 >"$FAKE/unbound_probe_rc"
  _nd_rec_readiness "$CASE_DIR/o" "$now"
  assert_match 'nd-1	tor	ready	observed working .*Unbound resolves over its route' "$(cat "$ND_STATE_DIR/recovery.tsv")" "the earlier Tor restart gets its readiness, corroborated"
  assert_eq 1 "$(grep -c 'nd-2	route:cloudflare-exit	ready' "$ND_STATE_DIR/recovery.tsv")" "readiness is recorded once per request"
  printf '%s\tnd-4\ttor\tacknowledged\tx\n' "$now" >>"$ND_STATE_DIR/recovery.tsv"
  echo 127 >"$FAKE/unbound_probe_rc"
  _nd_rec_readiness "$CASE_DIR/o" "$now"
  assert_match 'nd-4	tor	ready	.*uncorroborated' "$(cat "$ND_STATE_DIR/recovery.tsv")" "an Unbound image without probe-route is ready but marked uncorroborated"
  # The compat route answering is not evidence for Tor's identity routes.
  { printf 'schema\tnice-dns-observations/1\nobs\truntime\thealthy\t5\trunning: x\n'
    printf 'obs\troute:cloudflare-onion\tunhealthy\t9\tp\nobs\troute:cloudflare-exit\tunhealthy\t9\tp\n'
    printf 'obs\troute:quad9-exit\tunhealthy\t9\tp\nobs\troute:cloudflare-legacy\thealthy\t9\tp\n'; } >"$CASE_DIR/o2"
  printf '%s\tnd-5\ttor\tacknowledged\tx\n' "$now" >>"$ND_STATE_DIR/recovery.tsv"
  echo 0 >"$FAKE/unbound_probe_rc"
  _nd_rec_readiness "$CASE_DIR/o2" "$now"
  assert_not_match 'nd-5	tor	ready' "$(cat "$ND_STATE_DIR/recovery.tsv")" "only an identity route counts for Tor readiness"
}

t_two_processes_racing_one_tick_wins() {
  local a b
  ra_fake linux
  ra_outage_state
  ra_obs "$CASE_DIR/o" unhealthy
  echo new >"$FAKE/ack"; echo 2 >"$FAKE/slow"
  for a in 1 2; do
    bash -c '. "$1/lib/recovery.sh" && nd_recovery_tick active "$2"' _ "$NICE_DNS_ROOT" "$CASE_DIR/o" >"$CASE_DIR/tick.$a" 2>&1 &
    sleep 1
  done
  wait
  a="$(ra_field result "$(cat "$CASE_DIR/tick.1")")"; b="$(ra_field result "$(cat "$CASE_DIR/tick.2")")"
  assert_eq busy "$b" "the second process finds the lock held: $(cat "$CASE_DIR/tick.2")"
  assert_ne busy "$a" "the first process acts: $(cat "$CASE_DIR/tick.1")"
  assert_eq 1 "$(grep -c ' exec tor-haproxy sh -c ' "$FAKE_LOG")" "one restart request written in total"
}
