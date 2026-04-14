# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

nice-dns is a multi-container DNS privacy stack using Podman Compose. It chains Pi-hole (ad blocking) -> Unbound (recursive resolver) -> Tor proxy -> Cloudflare's hidden DNS resolver (.onion). All DNS queries leaving the machine are encrypted and routed through Tor.

## Architecture

Three containers on a shared Podman bridge network (`dnsnet`, subnet `172.31.240.248/29`):

| Container | IP | Role |
|---|---|---|
| Tor proxy (haproxy/socat) | 172.31.240.252 | Forwards DNS-over-TLS through Tor to Cloudflare's .onion resolver |
| Unbound | 172.31.240.251 | Recursive resolver on port 5335, forwards upstream via DoT to the Tor proxy |
| Pi-hole | 172.31.240.250 | Ad-blocking DNS on port 53, uses Unbound as upstream |

The Tor proxy container is a pre-built image from Docker Hub (`sureserver/tor-{haproxy,socat}`). Unbound and Pi-hole are built locally from their respective `Dockerfile`s.

## Proxy Variants

Two compose files select which Tor proxy variant to use:

- `compose.yaml` - tor-haproxy (default)
- `compose-socat.yaml` - tor-socat

Each compose file is self-contained with all three services. The only difference is the Tor proxy container.

## Installer Scripts

Four installer scripts, one per (platform x variant) combination:

| | haproxy (default) | socat |
|---|---|---|
| **Debian/Ubuntu** | `install-deb.sh` | `install-deb-socat.sh` |
| **macOS** | `install-mac.sh` | `install-mac-socat.sh` |

The variant installers are near-identical to the default; they differ only in which compose file is passed to `podman-compose -f`. All accept an optional branch argument (defaults to `main`).

Installers are idempotent: re-running tears down existing containers/images/network before a fresh install.

**Must run as unprivileged user** (not root/sudo) -- rootless Podman and user-mode systemd require this.

## Platform-Specific Persistence

### Debian/Ubuntu (`deb/`)
- `persistent-podman.sh` - Installs a user-mode systemd service (`persistent-containers.service`) that runs `podman restart -a` at boot
- `dns-deb.sh` - Installs a system-level systemd service (`custom-dns-deb.service`) that disables `systemd-resolved` and rewrites `/etc/resolv.conf` to `127.0.0.1`
- `custom-dns-deb` - The root script that `custom-dns-deb.service` calls

### macOS (`mac/`)
- `mac-rules-persist.sh` - Installs sudoers rules, LaunchDaemons (port 53 freeing, Mullvad pfctl workaround, loopback alias), and a LaunchAgent (`org.startpodman.plist`) for auto-starting the Podman VM + containers
- `dns-mac.sh` - Sets DNS to `127.0.0.1` on all network services and disables pfctl
- `start-podman.sh` / `start-podman-root.sh` - LaunchAgent scripts: start Podman VM, run privileged pre/post actions (stop/start Mullvad, set DNS), restart containers
- `test-mullvad-local-dns.sh` - Diagnostic tool for Mullvad VPN port 53 conflicts

The macOS flow handles Mullvad VPN integration: temporarily stopping Mullvad to free port 53 during container startup, then restarting it after.

## Common Commands

```bash
# Bring up the stack locally (after network exists)
PODMAN_COMPOSE_PROVIDER=podman-compose BUILDAH_FORMAT=docker \
  podman-compose --podman-run-args="--health-on-failure=restart" up -d

# Use a specific variant
podman-compose -f compose-socat.yaml --podman-run-args="--health-on-failure=restart" up -d

# Create the network (if it doesn't exist)
podman network create --driver bridge --subnet 172.31.240.248/29 --dns 1.1.1.1 dnsnet

# Check container health
podman ps --format "{{.Names}} {{.Status}}"

# Test DNS resolution through the stack
dig @127.0.0.1 cloudflare.com
```

## Key Configuration Files

- `.env` - Sets `WEBPORT` (default 8880) for Pi-hole web UI
- `unbound/etc/unbound.conf` - Unbound config; forwards DoT to `172.31.240.252@853` (the Tor proxy)
- `pihole/etc/dnsmasq.conf` - Pi-hole/dnsmasq config; upstream is `172.31.240.251#5335` (Unbound)
- `pihole/web/setupVars.conf` - Pi-hole initial setup variables

## Development Notes

- Branches: `main` (stable), `dev` (development). Install scripts accept branch name as argument.
- The `pihole/web.Dockerfile` exists as an alternative Pi-hole build that also copies `web/*` config.
- All health checks use `dig` to verify DNS resolution through the respective service.
- Container IPs are hardcoded across compose files, Unbound config, and dnsmasq config -- they must stay in sync.

<!-- vault-context:start -->
@.claude/vault-context.md
<!-- vault-context:end -->
