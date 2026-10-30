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

# nd_platform_installed_variant [deadline]: the installed Tor proxy variant
# when none is running (its quadlet), else nothing. Reads files only, so the
# deadline the macOS adapter honours is not needed here.
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
  v="$(nd_platform_installed_variant "$1")" || return 1
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

# nd_platform_restart_unbound <deadline> <tmp>: Unbound's service alone;
# pi-hole only Wants= it and the proxy does not depend on it, so both keep
# running. ExecStartPre=route-start finds the tick's lock busy and keeps the
# persisted route, which is the wanted result on a warm proxy (BL-039 item 2).
nd_platform_restart_unbound() {
  nd_bounded "$1" "$2/svc" "$2/svc.err" systemctl --user restart unbound.service
}

# nd_platform_restart_stack <deadline> <tmp>: the whole pod. Each member has
# BindsTo= on it, and it Wants= each member, so all three stop and start with it.
nd_platform_restart_stack() {
  nd_bounded "$1" "$2/svc" "$2/svc.err" systemctl --user restart nice-dns-pod.service
}

# nd_platform_runtime_repairs: the runtime faults nd_platform_repair_runtime
# can repair here; the policy escalates any other (ND_POLICY_RUNTIME_REPAIRS).
nd_platform_runtime_repairs() { printf 'containers-missing\n'; }

# nd_platform_repair_runtime <fault> <deadline> <tmp> [missing name...]: 0
# issued; 3 no repair exists for this fault here. Rootless podman has no daemon
# to restart, so a runtime that does not answer is escalated, not repaired (it
# is not in nd_platform_runtime_repairs). Missing containers are started by name:
# their failed state is cleared first, and running units are left alone. Starting
# pi-hole.service to pull the others through Wants= did nothing while Pi-hole ran
# (214 times on mint, 2026-10-29). With no usable name (no variant is known) that
# start is still the only thing to try.
# A unit that exited 126 or 125 means podman could not start it. Exit 126 with
# "systemd/private: connection refused" kept a proxy down for 20 hours until a
# reboot; reproduced on mint with a stale socket, and a re-exec makes the manager
# bind it again. Exit 125 ("pod cgroup is not set") follows when podman's tmp went
# too and it reset its state; only a pod restart clears that. Neither needs a
# reboot (2026-10-30). Exit 125 has persistent causes as well (an image that cannot
# be pulled), and a pod restart costs a running Pi-hole its service, so it runs at
# most once per ND_POLICY_RETRY_S (1800 s) within a boot: a new boot or a clock that
# moved back forgets the last one, as the policy's timers do, or a dead RTC could
# hold the repair that DNS, and so NTP, needs. The whole repair spends at most twice
# <deadline>, so it stays inside the tick's timeout and the lock's lease. What it
# did is left in <tmp>/rep.note for the journal.
nd_platform_repair_runtime() {
  local fault="$1" dl="$2" tmp="$3" n rc=0 named=0 stuck=0 end now mark last b boot
  shift 3
  [ "$fault" = containers-missing ] || return 3
  end=$(( $(date +%s) + dl * 2 ))
  # _nd_rep_left [most]: the seconds this repair may still spend on one call.
  _nd_rep_left() {
    local l=$(( end - $(date +%s) ))
    [ "$l" -le "${1:-$dl}" ] || l="${1:-$dl}"
    [ "$l" -gt 0 ] || l=0
    printf '%s\n' "$l"
  }
  for n in "$@"; do
    case "$n" in pi-hole|unbound|tor-haproxy|tor-socat) ;; *) continue ;; esac
    [ "$(_nd_rep_left 5)" -gt 0 ] || break
    nd_bounded "$(_nd_rep_left 5)" "$tmp/rep" "$tmp/rep.err" systemctl --user show -p ExecMainStatus --value "$n.service"
    case "$(head -n 1 "$tmp/rep" 2>/dev/null)" in 125|126) stuck=1 ;; esac
  done
  if [ "$stuck" = 1 ] && [ "$(_nd_rep_left 15)" -gt 0 ]; then
    nd_bounded "$(_nd_rep_left 15)" "$tmp/rep" "$tmp/rep.err" systemctl --user daemon-reexec
    printf 'daemon-reexec (exit %s); ' "$?" >>"$tmp/rep.note"
  fi
  for n in "$@"; do
    case "$n" in pi-hole|unbound|tor-haproxy|tor-socat) ;; *) continue ;; esac
    named=1
    [ "$(_nd_rep_left)" -gt 0 ] || { rc=124; break; }
    nd_bounded "$(_nd_rep_left 5)" "$tmp/rep" "$tmp/rep.err" systemctl --user reset-failed "$n.service"
    [ "$(_nd_rep_left)" -gt 0 ] || { rc=124; break; }
    nd_bounded "$(_nd_rep_left)" "$tmp/rep" "$tmp/rep.err" systemctl --user start "$n.service" || rc=$?
  done
  [ "$named" = 1 ] || nd_bounded "$(_nd_rep_left)" "$tmp/rep" "$tmp/rep.err" systemctl --user start pi-hole.service || rc=$?
  if [ "$rc" -ne 0 ] && [ "$stuck" = 1 ] && [ "$(_nd_rep_left)" -gt 0 ]; then
    mark="$(nd_platform_state_dir)/pod-repair-at"; now="$(date +%s)"
    boot="${ND_BOOT_ID:-$(nd_platform_boot_id)}"
    last=0
    if [ -f "$mark" ]; then
      IFS=' ' read -r b last <"$mark" || true
      case "$last" in ''|*[!0-9]*) last=0 ;; esac
      if [ "$b" != "$boot" ] || [ "$last" -gt "$now" ]; then last=0; fi
    fi
    if [ $((now - last)) -ge "${ND_POLICY_RETRY_S:-1800}" ]; then
      (umask 077 && printf '%s %s\n' "$boot" "$now" >"$mark")
      rc=0
      nd_bounded "$(_nd_rep_left)" "$tmp/rep" "$tmp/rep.err" systemctl --user restart nice-dns-pod.service || rc=$?
      printf 'restart nice-dns-pod.service (exit %s); ' "$rc" >>"$tmp/rep.note"
    else
      printf 'pod restart held, last %s s ago; ' "$((now - last))" >>"$tmp/rep.note"
    fi
  fi
  return "$rc"
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

# ─── Install drift (BL-045) ────────────────────────────────────────────────
# Reads files only; never re-renders or restarts anything.
#
#   ND_INSTALL_STATE_DIR   the installer's state (default
#                          $XDG_STATE_HOME/nice-dns-install, lib/install.sh)
#   ND_QUADLET_DIR         the installed quadlets (default
#                          $XDG_CONFIG_HOME/containers/systemd)

nd_platform_install_state_dir() {
  printf '%s\n' "${ND_INSTALL_STATE_DIR:-${XDG_STATE_HOME:-${HOME:?HOME is unset}/.local/state}/nice-dns-install}"
}

nd_platform_quadlet_dir() {
  printf '%s\n' "${ND_QUADLET_DIR:-${XDG_CONFIG_HOME:-${HOME:?HOME is unset}/.config}/containers/systemd}"
}

# nd_platform_install_generation: the generation `current` names when it is a
# well-formed id with its manifest; status 1 (nothing printed) otherwise.
nd_platform_install_generation() {
  local sd g=""
  sd="$(nd_platform_install_state_dir)"
  [ -f "$sd/current" ] && [ ! -L "$sd/current" ] || return 1
  IFS= read -r g <"$sd/current" || true
  printf '%s\n' "$g" | grep -Eq '^[0-9]{8}T[0-9]{6}Z-([0-9a-f]{12}|nogit0000000)$' || return 1
  [ -f "$sd/generations/$g/prepare.tsv" ] && [ ! -L "$sd/generations/$g/prepare.tsv" ] || return 1
  printf '%s\n' "$g"
}

# nd_platform_install_pending: an install is under way: no generation is
# current, and the newest generation has neither activated nor rolled back
# (its controller already runs while the stack comes up). Prints it.
nd_platform_install_pending() {
  local sd d g=""
  sd="$(nd_platform_install_state_dir)"
  for d in "$sd"/generations/*/; do
    d="${d%/}"; d="${d##*/}"
    printf '%s\n' "$d" | grep -Eq '^[0-9]{8}T[0-9]{6}Z-([0-9a-f]{12}|nogit0000000)$' && g="$d"
  done
  [ -n "$g" ] && [ -f "$sd/generations/$g/prepare.tsv" ] && [ ! -e "$sd/generations/$g/activated" ] || return 1
  awk -F '\t' '$1 == "status" { s = $2 } END { exit (s ~ /^rolled-back/) }' "$sd/generations/$g/prepare.tsv" || return 1
  printf '%s\n' "$g"
}

# The quadlets nice-dns installs (deb/persistent-podman.sh), and their
# drop-in directories (quadlet merges <unit>.d/*.conf into the unit).
ND_PLATFORM_QUADLETS="nice-dns.pod nice-dns.network pi-hole.container unbound.container tor-haproxy.container tor-socat.container"

# nd_platform_dns_publishes: "file<TAB>host<TAB>value" for each host port 53
# the installed nice-dns quadlets and their drop-ins declare: PublishPort=,
# PodmanArgs --publish/-p (host empty: every address; a host port range that
# holds 53 counts), and Network=host (host "host": the stack's own 53 on
# every address). Declarations only: a pod not restarted since an edit runs
# what it ran.
nd_platform_dns_publishes() {
  local q u f
  q="$(nd_platform_quadlet_dir)"
  for u in $ND_PLATFORM_QUADLETS; do
    for f in "$q/$u" "$q/$u.d"/*.conf; do
      [ -f "$f" ] || continue
      awk -v f="${f#"$q"/}" '
        function chk(v,   p, host, hp, i, rest, n, a, r) {
          p = v; sub(/\/.*/, "", p)
          host = ""; hp = ""
          if (substr(p, 1, 1) == "[") {
            i = index(p, "]"); if (!i) { print f "\t?\t" v; return }
            host = substr(p, 2, i - 2); rest = substr(p, i + 2)
            n = split(rest, a, ":"); if (n >= 2) hp = a[1]
          } else {
            n = split(p, a, ":")
            if (n == 3) { host = a[1]; hp = a[2] } else if (n == 2) hp = a[1]
          }
          if (hp == "53") { print f "\t" host "\t" v; return }
          if (hp ~ /^[0-9]+-[0-9]+$/) { split(hp, r, "-"); if (r[1] + 0 <= 53 && r[2] + 0 >= 53) print f "\t" host "\t" v }
        }
        { line = $0; sub(/^[[:space:]]+/, "", line) }
        line ~ /^PublishPort[[:space:]]*=/ { v = line; sub(/^[^=]*=[[:space:]]*/, "", v); sub(/[[:space:]]+$/, "", v); chk(v) }
        line ~ /^Network[[:space:]]*=[[:space:]]*host([[:space:]]|$)/ { print f "\thost\tNetwork=host" }
        line ~ /^PodmanArgs[[:space:]]*=/ {
          v = line; sub(/^[^=]*=[[:space:]]*/, "", v)
          n = split(v, w, /[[:space:]]+/)
          for (i = 1; i <= n; i++) {
            if (w[i] ~ /^(--publish|-p)$/ && i < n) chk(w[i + 1])
            else if (w[i] ~ /^--publish=/) { x = w[i]; sub(/^--publish=/, "", x); chk(x) }
            else if (w[i] ~ /^-p[^-]/) { x = substr(w[i], 3); chk(x) }
            else if (w[i] ~ /^--network(=|$)/ && (w[i] == "--network=host" || (w[i] == "--network" && w[i + 1] == "host"))) print f "\thost\tPodmanArgs " w[i] (w[i] == "--network" ? " host" : "")
          }
        }' "$f"
    done
  done
}

# nd_platform_install_drift <deadline> <tmp>: "verdict<TAB>reason" for the
# installed deployment as its files declare it: unhealthy
# (install-security-drift) when no generation is recorded (an install from
# before generations, which is never upgraded in place) or the installed
# quadlets declare host port 53 off loopback (an open resolver for the
# network; installs before 57db2a3 published 0.0.0.0:53); indeterminate
# while an install is under way or when no nice-dns.pod is installed (nothing
# to judge); else healthy.
nd_platform_install_drift() {
  local g bad
  if ! g="$(nd_platform_install_generation)"; then
    if g="$(nd_platform_install_pending)"; then
      printf 'indeterminate\tinstall under way: generation %s is not active yet\n' "$g"; return 0
    fi
    printf 'unhealthy\tinstall-security-drift: no install generation is recorded (an install from before generations; reinstall)\n'; return 0
  fi
  if [ ! -f "$(nd_platform_quadlet_dir)/nice-dns.pod" ]; then
    printf 'indeterminate\tgeneration %s; no nice-dns.pod quadlet in %s to read\n' "$g" "$(nd_platform_quadlet_dir)"; return 0
  fi
  bad="$(nd_platform_dns_publishes | awk -F '\t' '
    $2 !~ /^(127\.[0-9.]+|::1|localhost)$/ { printf "%s%s (%s %s)", s, ($2 == "" ? "every address" : ($2 == "host" ? "the host network" : $2)), $1, $3; s = ", " }')"
  if [ -n "$bad" ]; then
    printf 'unhealthy\tinstall-security-drift: the quadlets declare :53 on %s\n' "$bad"; return 0
  fi
  printf 'healthy\tgeneration %s; the quadlets declare :53 on loopback only\n' "$g"
}
