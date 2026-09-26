# shellcheck shell=bash
# nice-dns Linux platform adapter (ARCH-02): route operations. Sourced by
# lib/recovery.sh; Bash 3.2 compatible. Sub-plan 3 adds health and recovery
# operations here.
#
# Pi-hole, Unbound and the Tor proxy share one pod network namespace, so the
# proxy's route listeners are on the pod loopback.
#
#   ND_ROUTE_DIR           host directory mounted at /etc/unbound/route
#                          (default $XDG_STATE_HOME/nice-dns/unbound-route)
#   ND_UNBOUND_CONTAINER   Unbound container name (default unbound)

nd_platform_name() { printf 'linux\n'; }

nd_platform_route_addr() { printf '127.0.0.1\n'; }

nd_platform_route_dir() {
  printf '%s\n' "${ND_ROUTE_DIR:-${XDG_STATE_HOME:-${HOME:?HOME is unset}/.local/state}/nice-dns/unbound-route}"
}

# nd_platform_unbound_exec <cmd...>: run cmd in the Unbound container as the
# unbound user (the only uid the control socket admits).
nd_platform_unbound_exec() {
  podman exec --user unbound "${ND_UNBOUND_CONTAINER:-unbound}" "$@"
}

# ─── Health operations (Sub-plan 3, ARCH-02) ───────────────────────────────
# Used by lib/health.sh, which provides nd_bounded (a command run under a
# deadline) and the scratch directory $_ND_H_TMP.
#
#   ND_RESOLV_CONF   the host resolver file (default /etc/resolv.conf)

# nd_platform_dns_addr: where Pi-hole answers clients on this host (port 53):
# the pod publishes 53 on the host, and custom-dns-deb points the host
# resolver at 127.0.0.1.
nd_platform_dns_addr() { printf '127.0.0.1\n'; }

# nd_platform_runtime_bin: the runtime CLI, or 1 when it is not installed.
nd_platform_runtime_bin() { command -v podman 2>/dev/null; }

# nd_platform_runtime_list <deadline> <out>: names of the running containers,
# one per line, in <out>. 0 listed; 3 no CLI; 4 the runtime did not answer
# (the first error line is in <out>.err); 124 deadline.
nd_platform_runtime_list() {
  local bin rc
  bin="$(nd_platform_runtime_bin)" || return 3
  nd_bounded "$1" "$2.raw" "$2.err" "$bin" ps --format '{{.Names}}'
  rc=$?
  case "$rc" in 0) ;; 124) return 124 ;; *) [ -s "$2.err" ] || printf 'podman ps exited %s\n' "$rc" >"$2.err"; return 4 ;; esac
  grep -E '^[A-Za-z0-9][A-Za-z0-9_.-]*$' "$2.raw" >"$2"
  return 0
}

# nd_platform_installed_variant: the installed Tor proxy variant when none is
# running (its quadlet), else nothing.
nd_platform_installed_variant() {
  local v
  for v in haproxy socat; do
    if [ -f "${XDG_CONFIG_HOME:-${HOME:?HOME is unset}/.config}/containers/systemd/tor-$v.container" ]; then printf '%s\n' "$v"; return 0; fi
  done
  return 1
}

# nd_platform_proxy_exec <container> <cmd...>: run cmd in the proxy container.
nd_platform_proxy_exec() {
  local c="$1"
  shift
  podman exec "$c" "$@"
}

# nd_platform_dns_owner <deadline>: "verdict<TAB>reason" for the host
# resolver. Linux: every nameserver line of resolv.conf is 127.0.0.1 (a
# later public nameserver would take queries whenever Pi-hole is slow).
nd_platform_dns_owner() {
  local f="${ND_RESOLV_CONF:-/etc/resolv.conf}" ns
  if [ ! -e "$f" ]; then printf 'unhealthy\t%s is missing\n' "$f"; return 0; fi
  if [ ! -r "$f" ]; then printf 'indeterminate\t%s is unreadable\n' "$f"; return 0; fi
  ns="$(awk '$1 == "nameserver" { printf "%s%s", sep, $2; sep = " " }' "$f")"
  case "$ns" in
    127.0.0.1) printf 'healthy\t%s: nameserver 127.0.0.1 only\n' "$f" ;;
    '') printf 'unhealthy\t%s has no nameserver line\n' "$f" ;;
    '127.0.0.1 '*) printf 'unhealthy\t%s: later nameservers can take queries: %s\n' "$f" "$ns" ;;
    *) printf 'unhealthy\t%s: active nameserver is not 127.0.0.1: %s\n' "$f" "$ns" ;;
  esac
}

# ─── State operations (Sub-plan 3, ARCH-02 state.sh) ───────────────────────
#
#   ND_STATE_DIR   the controller state directory (default
#                  $XDG_STATE_HOME/nice-dns/controller)

nd_platform_state_dir() {
  printf '%s\n' "${ND_STATE_DIR:-${XDG_STATE_HOME:-${HOME:?HOME is unset}/.local/state}/nice-dns/controller}"
}

# nd_platform_boot_id: an identifier that changes on every boot.
nd_platform_boot_id() { cat /proc/sys/kernel/random/boot_id 2>/dev/null; }

# ─── Recovery operations (Sub-plan 3, Task 1.3; ARCH-02, ARCH-03) ──────────
# Used by lib/recovery.sh with nd_bounded (lib/health.sh). <tmp> is the
# caller's scratch directory.
#
#   ND_PROXY_CONTAINER   the Tor proxy container (default: the running
#                        tor-haproxy or tor-socat, else the installed one)

# nd_platform_proxy_container <deadline> <tmp>: the proxy container's name.
nd_platform_proxy_container() {
  local v
  if [ -n "${ND_PROXY_CONTAINER:-}" ]; then printf '%s\n' "$ND_PROXY_CONTAINER"; return 0; fi
  if nd_platform_runtime_list "$1" "$2/running" >/dev/null 2>&1; then
    for v in haproxy socat; do
      grep -qx "tor-$v" "$2/running" && { printf 'tor-%s\n' "$v"; return 0; }
    done
  fi
  v="$(nd_platform_installed_variant)" || return 1
  printf 'tor-%s\n' "$v"
}

# nd_platform_container_generation <container> <deadline> <tmp>: one line
# that changes whenever the container is recreated or restarted.
nd_platform_container_generation() {
  local bin
  bin="$(nd_platform_runtime_bin)" || return 3
  nd_bounded "$2" "$3/gen" "$3/gen.err" "$bin" inspect -f '{{.Id}} {{.State.StartedAt}} {{.State.Status}}' "$1" || return 1
  head -n 1 "$3/gen"
}

# nd_platform_restart_scope: what nd_platform_restart_proxy restarts.
nd_platform_restart_scope() { printf 'proxy\n'; }

# nd_platform_restart_proxy <container> <deadline> <tmp>: the service-level
# restart of the proxy alone (the quadlet service carries the container's
# name; pi-hole and unbound keep running).
nd_platform_restart_proxy() {
  nd_bounded "$2" "$3/svc" "$3/svc.err" systemctl --user restart "$1.service"
}

# nd_platform_repair_runtime <fault> <deadline> <tmp>: 0 issued; 3 no repair
# exists for this fault here. Rootless podman has no daemon to restart, so a
# runtime that does not answer is escalated, not repaired. Missing containers
# are started through pi-hole.service, whose Wants= pulls unbound and the
# proxy; running units are left alone.
nd_platform_repair_runtime() {
  case "$1" in
    containers-missing) nd_bounded "$2" "$3/rep" "$3/rep.err" systemctl --user start pi-hole.service ;;
    *) return 3 ;;
  esac
}

# ─── Bridge operations (Sub-plan 3, Task 2.2; ARCH-07) ─────────────────────
#
#   ND_BRIDGE_CONFIG_DIR   bridges.env and bridge-pool.tsv (default
#                          $XDG_CONFIG_HOME/nice-dns)

nd_platform_bridge_dir() { printf '%s\n' "${ND_BRIDGE_CONFIG_DIR:-${XDG_CONFIG_HOME:-${HOME:?HOME is unset}/.config}/nice-dns}"; }

# nd_platform_bridge_eval <variant> <candidate file name> <deadline> <tmp>:
# the proxy image's bridge-eval in manage mode (the same flags as the boot
# unit), writing its selection to <bridge dir>/<candidate>, never to
# bridges.env. It updates the persistent pool itself.
nd_platform_bridge_eval() {
  local d
  d="$(nd_platform_bridge_dir)"
  nd_bounded "$3" "$4/eval" "$4/eval.err" podman run --rm --userns=keep-id --pull=missing \
    -v "$d:/pool" --entrypoint /bin/bridge-eval "docker.io/sureserver/tor-$1:latest" \
    -pool /pool/bridge-pool.tsv -out "/pool/$2" -count 7 -window 150 -grace 20
}
