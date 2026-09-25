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
