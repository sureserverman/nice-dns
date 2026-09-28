# shellcheck shell=bash
# Group integration/route-mount (Sub-plan 5, Task 1.2; ARCH-04, ARCH-05;
# DEC-010). The host route directory (lib/platform/*.sh nd_platform_route_dir)
# is mounted into Unbound at /etc/unbound/route, and the installers seed it.
#
# Behaviour:
#   * Every entrypoint seeds the directory with an identity route
#     (cloudflare-exit, generation 1; ARCH-04: an authenticated exit while the
#     onion is cold, which the controller promotes later) before Unbound
#     first starts, never the `compat` route (DEC-005).
#   * A route already there is the controller's: a reinstall, a proxy switch
#     and an upgrade keep it. A deployment from before the mount existed gets
#     one on its upgrade.
#   * A failed install rolls the directory back with the rest of the
#     deployment: absent again after a failed first install, as it was after
#     a failed reinstall.
#   * The directory is instance state: only an uninstall that gave host DNS
#     back removes it (as 7a403df does for the rest).
#   * An unusable directory (a symlink, writable by others) fails the install
#     in preparation, before anything changes; nothing falls back to the
#     image's default route. A mounted directory
#     without a usable include makes the image itself refuse to start
#     (integration/route-transition, t_direct_fallback_refused).
#   * The Linux quadlet and both macOS launch paths mount the directory, not
#     the single file (ARCH-04), read-only.
#
# Options: --entrypoints (tests/fixtures/install-fakes.sh) and --platforms
# all|linux|macos (entrypoints of the selected platforms).

. "$NICE_DNS_ROOT/tests/fixtures/install-fakes.sh"

RM_SEED='route=cloudflare-exit generation=1'

rm_dir() { printf '%s/.local/state/nice-dns/unbound-route\n' "$IP_HOME"; }
rm_marker() { sed -n 's/.*"\(route=[^"]*\)".*/\1/p' "$(rm_dir)/forward-route.conf" 2>/dev/null; }
rm_sum() { (cd "$(rm_dir)" 2>/dev/null && cat forward-route.conf desired.tsv 2>/dev/null) | cksum; }

# rm_install <ep> [args...]: an install from a new source commit, so two
# installs in one second never share a generation id (lifecycle-transitions).
rm_install() {
  RM_N=$(( ${RM_N:-0} + 1 ))
  printf '%012x%s\n' "$RM_N" eeeeeeeeeeeeeeeeeeeeeeeeeeee >"$FAKE/git_head"
  ip_install "$@"
}

# rm_eps: the selected entrypoints of the selected platforms.
rm_eps() {
  local ep out=""
  ip_select
  dt_select_platforms
  for ep in $IP_EPS; do
    case " $DT_PLATS " in *" $(ip_platform "$ep") "*) out="$out $ep" ;; esac
  done
  [ -n "$out" ] || fail "--entrypoints and --platforms select nothing together"
  RM_EPS="$out"
}

# rm_starts_ok <label>: every Unbound start so far read the expected include.
rm_starts_ok() {
  local want="${2:-$RM_SEED}"
  assert_ne "" "$(cat "$FAKE/unbound-starts" 2>/dev/null)" "$1: Unbound was started"
  assert_eq "" "$(grep -v " $want\$" "$FAKE/unbound-starts" 2>/dev/null || true)" "$1: every Unbound start read $want"
}

# rm_set_route <route> <generation>: stands in for a route change the
# controller made (apply_route) after the install.
rm_set_route() {
  local d
  d="$(rm_dir)"
  sed -i.bak "s/route=[a-z0-9-]* generation=[0-9]*/route=$1 generation=$2/" "$d/forward-route.conf" && rm -f "$d/forward-route.conf.bak"
  printf 'schema\tnice-dns-route-desired/1\nroute\t%s\ngeneration\t%s\n' "$1" "$2" >"$d/desired.tsv"
}

t_every_entrypoint_seeds_the_route_before_unbound_starts() {
  local ep
  rm_eps
  for ep in $RM_EPS; do
    (
      local d addr
      dt_world "$ep" "$(dt_fresh_state "$ep")"
      rm_install "$ep" socat
      assert_rc 0 "$IP_RC" "$ep: install: $IP_OUT"
      d="$(rm_dir)"
      assert_file "$d/forward-route.conf" "$ep: the route include is seeded"
      assert_eq "$RM_SEED" "$(rm_marker)" "$ep: with the identity exit route, generation 1"
      if [ "$(ip_platform "$ep")" = linux ]; then addr=127.0.0.1; else addr=172.31.240.252; fi
      assert_match "forward-addr: $addr@18532#one\\.one\\.one\\.one\$" "$(cat "$d/forward-route.conf")" "$ep: forwarding to the platform's route listener, authenticated as one.one.one.one"
      assert_not_match '@853#' "$(cat "$d/forward-route.conf")" "$ep: never the compat :853 route (DEC-005)"
      assert_eq "$(printf 'schema\tnice-dns-route-desired/1\nroute\tcloudflare-exit\ngeneration\t1')" "$(cat "$d/desired.tsv")" "$ep: and recorded as desired for the controller"
      assert_eq 755 "$(ip_mode "$d")" "$ep: the directory is 0755 (Unbound reads it; only the user writes it)"
      assert_eq 644 "$(ip_mode "$d/forward-route.conf")" "$ep: the include 0644"
      rm_starts_ok "$ep"
    ) || exit 1
  done
}

t_every_launch_path_mounts_the_directory_read_only() {
  local ep
  rm_eps
  for ep in $RM_EPS; do
    (
      local line
      dt_world "$ep" "$(dt_fresh_state "$ep")"
      rm_install "$ep" haproxy
      assert_rc 0 "$IP_RC" "$ep: install: $IP_OUT"
      if [ "$(ip_platform "$ep")" = macos ]; then
        line="$(grep -E '^container run -d --name unbound ' "$FAKE_LOG" | tail -n 1)"
        assert_match " -v $(rm_dir):/etc/unbound/route:ro " "$line" "$ep: the installer's Unbound mounts the directory read-only"
        # The agent's launch (compared argument by argument with the
        # installer's in integration/lifecycle-transitions).
        assert_match '^[[:space:]]*-v "\$\{ND_ROUTE_DIR\}:/etc/unbound/route:ro" \\$' "$(cat "$NICE_DNS_ROOT/mac/start-container.sh")" "$ep: so does the agent's"
        assert_eq "$(rm_dir)" "$(env -i HOME="$IP_HOME" XDG_STATE_HOME="$IP_HOME/.local/state" bash -c '. "$1/lib/platform/macos.sh"; nd_platform_route_dir' _ "$NICE_DNS_ROOT")" "$ep: the directory the controller manages"
        assert_eq "$(rm_dir)" "$(env -i HOME="$IP_HOME" XDG_STATE_HOME="$IP_HOME/.local/state" bash -c "$(grep -E '^ND_ROUTE_DIR=' "$NICE_DNS_ROOT/mac/start-container.sh"); printf '%s\\n' \"\$ND_ROUTE_DIR\"")" "$ep: is the one the agent mounts"
      else
        assert_match '^Volume=__ROUTE_DIR__:/etc/unbound/route:ro$' "$(cat "$NICE_DNS_ROOT/deb/quadlet/unbound.container")" "$ep: the quadlet mounts the directory read-only (persistent-podman.sh fills in the path)"
      fi
    ) || exit 1
  done
}

# The real persistent-podman.sh: it seeds a missing directory itself (it is
# also run on its own) and the generated Unbound unit mounts it.
t_linux_quadlet_mounts_the_seeded_directory() {
  dt_select_platforms
  case " $DT_PLATS " in *" linux "*) ;; *) return 0 ;; esac
  (
    local f q gen
    dt_world install-deb resolved
    mkdir -p "$IP_W/real"
    for f in deb mac scripts health lib routes; do cp -R "$NICE_DNS_ROOT/$f" "$IP_W/real/"; done
    mkdir -p "$IP_W/run/systemd/generator" && : >"$IP_W/run/systemd/generator/nice-dns-pod.service"
    : >"$FAKE_ROOT/.systemd/NetworkManager-wait-online.unit"
    ip_run "$IP_W/real/deb/persistent-podman.sh" socat standard
    assert_rc 0 "$IP_RC" "persistent-podman.sh: $IP_OUT"
    assert_eq "$RM_SEED" "$(rm_marker)" "persistent-podman.sh on its own seeds the route"
    for q in /usr/libexec/podman/quadlet /usr/lib/podman/quadlet; do [ -x "$q" ] && break; done
    [ -x "$q" ] || fail "no quadlet generator on this host"
    gen="$(QUADLET_UNIT_DIRS="$IP_HOME/.config/containers/systemd" "$q" -dryrun -user 2>/dev/null \
      | awk '$0 == "---unbound.service---" { f = 1; next } /^---.*---$/ { f = 0 } f && /^ExecStart=/')"
    assert_match " -v $(rm_dir):/etc/unbound/route:ro " "$gen " "the generated Unbound unit mounts the directory read-only"
    assert_eq "" "$(grep -rl '__ROUTE_DIR__' "$IP_HOME/.config/containers/systemd" || true)" "no placeholder is left in the installed quadlets"
  ) || exit 1
}

t_reinstall_switch_and_upgrade_keep_the_controllers_route() {
  local ep
  rm_eps
  for ep in $RM_EPS; do
    (
      local sum
      dt_world "$ep" "$(dt_fresh_state "$ep")"
      rm_install "$ep" socat
      assert_rc 0 "$IP_RC" "$ep: install: $IP_OUT"
      rm_set_route quad9-exit 7
      sum="$(rm_sum)"
      : >"$FAKE/unbound-starts"
      rm_install "$ep" socat
      assert_rc 0 "$IP_RC" "$ep: reinstall: $IP_OUT"
      rm_install "$ep" haproxy
      assert_rc 0 "$IP_RC" "$ep: proxy switch: $IP_OUT"
      rm_install "$ep" haproxy
      assert_rc 0 "$IP_RC" "$ep: upgrade: $IP_OUT"
      assert_eq "$sum" "$(rm_sum)" "$ep: the route the controller chose is kept"
      rm_starts_ok "$ep" 'route=quad9-exit generation=7'
    ) || exit 1
  done
}

# A deployment from before the mount (Sub-plan 4 and earlier) has no route
# directory: its upgrade seeds one.
t_upgrade_of_a_deployment_without_the_directory_seeds_it() {
  local ep
  rm_eps
  for ep in $RM_EPS; do
    (
      local d
      dt_world "$ep" "$(dt_fresh_state "$ep")"
      dt_installed "$ep"
      d="$(rm_dir)"
      rm -rf "${d:?}"
      : >"$FAKE/unbound-starts"
      rm_install "$ep"
      assert_rc 0 "$IP_RC" "$ep: upgrade: $IP_OUT"
      assert_eq "$RM_SEED" "$(rm_marker)" "$ep: the upgrade seeds the route"
      rm_starts_ok "$ep"
    ) || exit 1
  done
}

t_failed_install_rolls_the_directory_back() {
  local ep
  rm_eps
  for ep in $RM_EPS; do
    (
      local sum
      # A failed first install: no directory afterwards.
      dt_world "$ep" "$(dt_fresh_state "$ep")"
      : >"$FAKE/never_ready"
      rm_install "$ep" socat
      assert_nonzero "$IP_RC" "$ep: the first install fails: $IP_OUT"
      assert_no_path "$(rm_dir)" "$ep: and leaves no route directory"
      # A failed reinstall: the route from before, exactly.
      rm -f "$FAKE/never_ready"
      rm_install "$ep" socat
      assert_rc 0 "$IP_RC" "$ep: install: $IP_OUT"
      rm_set_route quad9-exit 4
      sum="$(rm_sum)"
      : >"$FAKE/never_ready"
      rm_install "$ep" socat
      assert_nonzero "$IP_RC" "$ep: the reinstall fails: $IP_OUT"
      assert_eq "$sum" "$(rm_sum)" "$ep: the route from before is back"
      # A failed upgrade of a deployment without the directory: none again.
      rm -f "$FAKE/never_ready"
      rm -rf "$(rm_dir)"
      : >"$FAKE/never_ready"
      rm_install "$ep" socat
      assert_nonzero "$IP_RC" "$ep: the upgrade fails: $IP_OUT"
      assert_no_path "$(rm_dir)" "$ep: and takes its new route directory with it"
    ) || exit 1
  done
}

t_uninstall_removes_the_directory_only_once_dns_is_back() {
  local ep
  rm_eps
  for ep in $RM_EPS; do
    (
      local plat
      plat="$(ip_platform "$ep")"
      if [ "$plat" = linux ]; then dt_world "$ep" file; else dt_world "$ep" fresh; fi
      rm_install "$ep"
      assert_rc 0 "$IP_RC" "$ep: install: $IP_OUT"
      if [ "$plat" = linux ]; then rm -f "$(dirname "$(dt_receipt linux)")/resolv.conf.orig"
      else printf '^networksetup -setdnsservers Ethernet\n' >"$FAKE/fail"; fi
      ip_install "$ep" uninstall
      assert_nonzero "$IP_RC" "$ep: the uninstall whose restore failed fails: $IP_OUT"
      assert_eq "$RM_SEED" "$(rm_marker)" "$ep: and keeps the route"
      if [ "$plat" = linux ]; then cp "$FAKE_ROOT/etc/resolv.conf" "$(dirname "$(dt_receipt linux)")/resolv.conf.orig" 2>/dev/null || true
      else rm -f "$FAKE/fail"; fi
      ip_install "$ep" uninstall
      assert_rc 0 "$IP_RC" "$ep: the retry succeeds: $IP_OUT"
      assert_no_path "$(rm_dir)" "$ep: and removes the route directory"
    ) || exit 1
  done
}

t_unusable_directory_fails_the_install() {
  local ep
  rm_eps
  for ep in $RM_EPS; do
    (
      local d
      # A symlinked directory.
      dt_world "$ep" "$(dt_fresh_state "$ep")"
      d="$(rm_dir)"
      mkdir -p "$IP_W/elsewhere" "$(dirname "$d")"
      ln -s "$IP_W/elsewhere" "$d"
      rm_install "$ep" socat
      assert_nonzero "$IP_RC" "$ep: a symlinked route directory fails the install: $IP_OUT"
      assert_match 'route' "$IP_OUT" "$ep: and says why"
      assert_eq "" "$(ls -A "$IP_W/elsewhere")" "$ep: nothing is written through the link"
      [ -L "$d" ] || fail "$ep: and the link itself is left alone"
      assert_eq "" "$(ip_lines "$FAKE_LOG" "$IP_BUILD_PULL")" "$ep: it fails in preparation, before any build or pull"
      assert_eq "" "$(cat "$FAKE/unbound-starts" 2>/dev/null)" "$ep: Unbound never starts on the image default"
      # A directory others can write to.
      dt_world "$ep" "$(dt_fresh_state "$ep")"
      d="$(rm_dir)"
      mkdir -p "$d" && chmod 777 "$d"
      rm_install "$ep" socat
      assert_nonzero "$IP_RC" "$ep: a route directory others can write fails the install: $IP_OUT"
      assert_eq "" "$(cat "$FAKE/unbound-starts" 2>/dev/null)" "$ep: Unbound never starts on the image default"
    ) || exit 1
  done
}
