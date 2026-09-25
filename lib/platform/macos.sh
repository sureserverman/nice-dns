# shellcheck shell=bash
# nice-dns macOS platform adapter (ARCH-02): route operations. Sourced by
# lib/recovery.sh; Bash 3.2 compatible (macOS /bin/bash). Sub-plan 3 adds
# health and recovery operations here.
#
# Apple `container` gives each container its own address on dnsnet, so the
# route listeners are on the proxy container's address (TOR_IP in
# mac/start-container.sh).
#
#   ND_ROUTE_DIR           host directory mounted at /etc/unbound/route
#                          (default ~/Library/Application Support/nice-dns/unbound-route)
#   ND_UNBOUND_CONTAINER   Unbound container name (default unbound)
#   CONTAINER_BIN          the container CLI (default container)

nd_platform_name() { printf 'macos\n'; }

nd_platform_route_addr() { printf '172.31.240.252\n'; }

nd_platform_route_dir() {
  printf '%s\n' "${ND_ROUTE_DIR:-${HOME:?HOME is unset}/Library/Application Support/nice-dns/unbound-route}"
}

# nd_platform_unbound_exec <cmd...>: run cmd in the Unbound container as the
# unbound user (the only uid the control socket admits).
nd_platform_unbound_exec() {
  "${CONTAINER_BIN:-container}" exec --user unbound "${ND_UNBOUND_CONTAINER:-unbound}" "$@"
}
