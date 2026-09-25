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
