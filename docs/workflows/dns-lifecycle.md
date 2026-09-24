# nice-dns DNS lifecycle workflows

Behavior contracts for the nice-dns stack. Sub-plan 01, Task 1.1 of the
2026-09-19 stability, latency and security plan.

- Contract sources: the approved design and architecture (ARCH-01 to ARCH-09)
  in the vault at `Portfolio/containers/nice-dns/plans/2026-09-19-stability-latency-security-*.md`.
- Baseline source: this repository at commit
  `d6c1a1f9387144872589d8a42c631b8f0a146c58`. Citations are `path:line` at that commit.
  The eight-cell baseline receipt measured b85bc9b. The document was first
  written against 337fb15; sub-plan 01 then landed product fixes (c8ecd70,
  fcc3f6c, fc5e6ec, b85bc9b), and the citations were re-derived. Sub-plan 02
  re-pins after each change to a cited file (Task 1.1: 04b98cf, Unbound
  anchor and control; Task 1.3: d6c1a1f, Pi-hole HealthCmd). `check-contracts` fails when a cited file changes
  after this commit.
- Checked by `bash tests/run.sh check-contracts docs/workflows/dns-lifecycle.md`.
  The check needs every workflow ID below, every operation ID in
  `tests/manifests/privacy-ops.tsv`, and each workflow's required subsections.

## How to read this document

Each workflow has two halves.

- **Contract (target, per ARCH)** is the behavior the plan must deliver. It
  is not a claim about today's code.
- **Current baseline (observed in source)** records what the code at the
  commit above does. Every statement cites `file:line`. A statement tagged
  `baseline: unverified` is a gap or open question. Nobody has shown it
  working. Source reading is not runtime evidence.

Invariants carry operation tags such as [SEC-TLS-NAME]. The tags are defined
in the table below. The manifest `tests/manifests/privacy-ops.tsv` is the
authority for their wording.

Behavior inside the sibling images (tor-haproxy, tor-socat, hardened-unbound,
pi-hole-hardened) was not read for this document. Claims about it are marked
`baseline: unverified`.

## Privacy and security operations

| ID | Meaning |
|---|---|
| [SEC-TLS-NAME] | Every upstream DoT session authenticates the documented TLS name of the selected provider route. Unbound is the only upstream TLS client. |
| [SEC-TLS-WRONGNAME] | A certificate whose name does not match the route's authentication name is rejected. No answer from that session is served. |
| [SEC-TLS-UNTRUSTED] | A certificate that does not chain to the configured trust store is rejected. |
| [SEC-TLS-EXPIRED] | An expired or not-yet-valid certificate is rejected. |
| [PRIV-ROUTE-IDENTITY] | An identity-bound route never hands a session to a provider other than the one whose name it authenticates. |
| [SEC-DNSSEC-ANCHOR] | The root trust anchor is wired into the effective Unbound config from an owned writable location. A missing or unusable anchor fails clearly and is never reported healthy. |
| [SEC-DNSSEC-BOGUS] | A bogus answer from a controlled signer is rejected (SERVFAIL) by local Unbound validation, not by an upstream resolver. |
| [SEC-DNSSEC-SIGNED] | A correctly signed answer validates through local Unbound (AD set). |
| [SEC-DNSSEC-UNSIGNED] | An answer from an unsigned zone is still answered (insecure, not bogus). |
| [PRIV-NO-DIRECT] | No ordinary client query reaches a direct public resolver during normal operation, failure, recovery or maintenance. |
| [PRIV-NO-HOST-PUBLIC] | No lifecycle step (install, reinstall, upgrade, recovery) rewrites the host resolver to public DNS. |
| [PRIV-BOOTSTRAP-DECLARED] | Bootstrap traffic (image and package pulls, build-time DNS, bridge fetch) is listed as a declared exception. It never serves client queries. |
| [PRIV-NO-QUERY-HISTORY] | Evidence, logs and diagnostics hold no client query history. Probes use controlled names only. |
| [PRIV-NO-SECRETS] | Portable evidence carries no credentials, private keys or bridge certificates. |
| [SEC-CONTROL-LOCAL] | Resolver management uses a restricted local control channel with per-instance credentials. There is no network control listener with image-shared keys. |
| [SEC-OWNED-RESTORE] | Installers snapshot only the DNS state they own. They restore exactly that snapshot on failure or uninstall. |
| [REC-ACK-READINESS] | Every recovery action records a request, an acknowledgement and a separate later readiness observation. A flag write is not an acknowledgement. |
| [EVD-CACHE-NOT-UPSTREAM] | A cached or stale local answer never certifies upstream health. Cache and upstream states are recorded separately. |
| [EVD-FAILURES-COUNTED] | Every attempted query, including errors and timeouts, stays in the denominators. Missing rows or skipped cells are BLOCKED, never green. |

## WF-DNS-001 Routing and privacy

### Trigger

A client sends a DNS query to Pi-hole. On Linux that is the host's port 53.
On macOS it is 172.31.240.250:53 on the `dnsnet` bridge.

### Contract (target, per ARCH)

Sources: ARCH-04, ARCH-06, design "Data flow".

#### Steps

1. Pi-hole applies filtering and its cache. It forwards only to Unbound.
2. Unbound answers from cache or validates with DNSSEC against a persistent
   root anchor.
3. Unbound forwards over TLS to exactly one selected, identity-bound route.
   It uses one generated root forwarding include, `forward-tls-upstream` on,
   and no direct recursive fallback.
4. The routes are `cloudflare-onion` (port 18531), `cloudflare-exit` (18532)
   and `quad9-exit` (18533). Linux uses 127.0.0.1 inside the pod. macOS uses
   the proxy container address. None is published on the host.
5. The proxy carries the TCP stream through Tor to the provider bound to that
   route. It never switches the stream to another provider.
6. NXDOMAIN and other valid negative answers count as successful transport.

#### Invariants

- Unbound is the only upstream TLS client. Every session verifies the
  route's provider name [SEC-TLS-NAME].
- Wrong-name, untrusted and expired certificates are rejected
  [SEC-TLS-WRONGNAME] [SEC-TLS-UNTRUSTED] [SEC-TLS-EXPIRED].
- A route bound to one provider's name never reaches another provider
  [PRIV-ROUTE-IDENTITY].
- Local validation rejects bogus answers, validates signed ones and answers
  unsigned ones. The anchor is present and usable, or the resolver is
  reported unhealthy [SEC-DNSSEC-BOGUS] [SEC-DNSSEC-SIGNED]
  [SEC-DNSSEC-UNSIGNED] [SEC-DNSSEC-ANCHOR].
- No client query reaches a direct public resolver [PRIV-NO-DIRECT].
- Diagnostics and evidence use controlled names and keep no client query
  history [PRIV-NO-QUERY-HISTORY].

### Current baseline (observed in source)

- Pi-hole forwards only to Unbound. dnsmasq has `no-resolv`
  (pihole/etc/dnsmasq.conf:27) and `server=127.0.0.1#5335`
  (pihole/etc/dnsmasq.conf:33). FTL upstreams are `127.0.0.1#5335`
  (pihole/etc/pihole.toml:12-14). The Linux quadlet sets
  `DNS1=127.0.0.1#5335` (deb/quadlet/pi-hole.container:26).
- On macOS the installer and LaunchAgent override the upstream to
  `172.31.240.251#5335` (install-mac.sh:269-270, mac/start-container.sh:409-410).
- Pi-hole query logging is off in the shipped config
  (pihole/etc/pihole.toml:197). dnsmasq `log-queries` is commented out
  (pihole/etc/dnsmasq.conf:48). baseline: unverified at runtime for both
  Pi-hole images.
- Unbound forwards the root zone over TLS to a single address
  `127.0.0.1@853#tor.cloudflare-dns.com` (unbound/etc/unbound.conf:136-140).
  It uses `tls-cert-bundle: "/etc/ssl/cert.pem"` (unbound/etc/unbound.conf:132).
  The file sets no `forward-first`. baseline: unverified that the effective
  runtime config has no recursion fallback.
- The macOS installer edits the build copy of unbound.conf. It binds 0.0.0.0,
  allows 172.31.240.248/29 and forwards to `172.31.240.252@853`
  (install-mac.sh:220-225).
- Provider identity is mixed today. Unbound authenticates
  `tor.cloudflare-dns.com` (unbound/etc/unbound.conf:140). The health script
  describes the proxy backends as the onion primary, a 1.1.1.1 backup and a
  9.9.9.9 fallback via Tor exit (health/nice-dns-health:353-356). A Quad9
  backend would receive a Cloudflare-named TLS session. That breaks
  [PRIV-ROUTE-IDENTITY]. baseline: unverified. The proxy config lives in the
  sibling repos and was not read here.
- Unbound validates against the root anchor in
  `auto-trust-anchor-file: "/var/lib/unbound/root.key"`
  (unbound/etc/unbound.conf:30-34). That directory is persistent state owned
  by the unbound user, 0700 (unbound/Containerfile:29-31). The image carries a
  read-only seed. Its trust root is the DS set compiled into unbound-anchor.
  Every root DNSKEY in the dnssec-root package must match one of those DS
  records and is kept. A required KSK (20326, 38696) that the package lacks
  is seeded as its builtin DS line, so the image also builds on the published
  base, whose package carries only KSK-2017. The build fails on a DNSKEY that
  matches no builtin DS, a required tag unknown to both, or an empty tag list
  (unbound/start.sh:86-116, unbound/Containerfile:28). The entrypoint reads
  the anchor path from the effective config. It seeds a missing anchor from
  the seed. It exits with a `FATAL` message, before Unbound starts, when the
  anchor or its directory is unusable: symlinked, not owned by unbound, not
  writable (including a read-only mount), empty, malformed, or without a
  trusted root key (unbound/start.sh:118-144). [SEC-DNSSEC-ANCHOR]
- Proven on the built images by `integration/resolver-state`. Through a
  controlled signer, the product Unbound sets AD on a signed answer, answers
  an insecure delegation without AD, and returns SERVFAIL for a bogus
  signature whose record `+cd` still retrieves
  [SEC-DNSSEC-SIGNED] [SEC-DNSSEC-UNSIGNED] [SEC-DNSSEC-BOGUS].
  Persistence across container re-creation needs a volume on
  /var/lib/unbound. The quadlets and macOS scripts do not mount one yet, so
  each new container re-seeds from the image (owned by a later sub-plan).
- Resolver management is a Unix socket, `/run/unbound/control.sock`, with
  `control-use-cert: no` and no TCP listener or key files
  (unbound/etc/unbound.conf:163-166). The entrypoint keeps `/run/unbound`
  owned by unbound and closed to others (unbound/start.sh:146-158). Unbound
  creates the socket with mode 0660. Operators run
  `podman exec --user unbound unbound unbound-control ...`; other uids are
  refused. The nice-dns image deletes any control keys an older published
  base still carries (unbound/Containerfile:23-25) [SEC-CONTROL-LOCAL].
- Unbound does not use IPv6 (`do-ip6: no`, unbound/etc/unbound.conf:19).
  Linux installs disable IPv6 through sysctl (install-deb.sh:68-74).
- The Linux pod publishes port 53 TCP/UDP with no host address, so on every
  host interface (deb/quadlet/nice-dns.pod:13-14). The admin UI is on
  127.0.0.1:8880 (deb/quadlet/nice-dns.pod:15).
- Pod members resolve through `DNS=1.1.1.1` (deb/quadlet/nice-dns.network:5).
  The stated reason is bootstrap (deb/quadlet/nice-dns.pod:7-11). This is
  container-level traffic, not client traffic. Which in-pod processes use it
  at runtime is baseline: unverified [PRIV-BOOTSTRAP-DECLARED].
- The health check probes real public names: `cloudflare.com` and
  `doubleclick.net` (health/nice-dns-health:193, health/nice-dns-health:204).
  Its failure dump copies the last 50 log lines of every container
  (health/nice-dns-health:246-247). Whether those lines can contain client
  query names is baseline: unverified [PRIV-NO-QUERY-HISTORY].

### Platform notes

- Linux: Pi-hole, Unbound and the Tor proxy share one Podman pod network
  namespace (`Pod=nice-dns.pod`, deb/quadlet/unbound.container:16), so
  loopback addresses work between them. Unbound listens only on 127.0.0.1
  (unbound/etc/unbound.conf:5).
- macOS: Apple `container` gives each container its own address on `dnsnet`.
  The configs hardcode .250/.251/.252 (mac/start-container.sh:24-26). The
  LaunchAgent refuses a stack whose addresses do not match
  (mac/start-container.sh:168-176, mac/start-container.sh:635-643).

## WF-DNS-002 Recovery

### Trigger

A scheduled health observation, a start or login, or a wake finds local
service, upstream or runtime degraded.

### Contract (target, per ARCH)

Sources: ARCH-02, ARCH-03, ARCH-07, design "Health and recovery".

#### Steps

1. Once a minute, `observe` takes a bounded reading: local service, DNS
   ownership, runtime, and authenticated DNS per route. Each reading is
   healthy, unhealthy or indeterminate, with a duration and a reason.
2. `decide` uses the readings, the history and the time. It returns one of:
   no-op, switch-route, refresh-bridges, restart-component, repair-runtime,
   escalate.
3. One lock covers destructive actions. State is versioned by generation and
   is never sourced as shell.
4. A full upstream outage becomes eligible for action after a 5-minute grace.
   The grace starts after the startup allowance. A 5-minute cooldown separates
   actions. A usable fallback route prevents a Tor restart.
5. `request_recovery` records a request ID. It then checks for an
   acknowledgement: a new process or container generation. Readiness is a
   separate, later observation.
6. If the controller is absent, the last route stays in place and the control
   state shows as stale.

#### Invariants

- No action is logged as completed without an acknowledgement. Readiness is
  observed separately [REC-ACK-READINESS].
- A cached or stale answer never counts as upstream health
  [EVD-CACHE-NOT-UPSTREAM].
- Recovery never adds a direct public resolver and never rewrites the host
  resolver [PRIV-NO-DIRECT] [PRIV-NO-HOST-PUBLIC].
- Every probe attempt, including failures, is kept in the record
  [EVD-FAILURES-COUNTED].
- Diagnostics use controlled names and hold no client query history or
  secrets [PRIV-NO-QUERY-HISTORY] [PRIV-NO-SECRETS].

### Current baseline (observed in source)

- No installer installs the health checker. `nice-dns-health` appears in no
  installer. It is installed by hand (health/nice-dns-health:11). Whether it
  runs on a deployed host is baseline: unverified.
- Schedule: a systemd user timer with `OnBootSec=2min` and
  `OnUnitActiveSec=30min` (health/nice-dns-health:496-497), or launchd
  `StartInterval` 1800 (health/nice-dns-health:523-524).
- Grace is `RESTART_GRACE_SECS` = 300 (health/nice-dns-health:361). With
  30-minute polling, the first action comes on the second failing run, about
  30 minutes after onset. It cannot be five-minute recovery.
- The checks use the same logic on both platforms. They require
  `nameserver 127.0.0.1` in /etc/resolv.conf (health/nice-dns-health:149-157)
  and query `@127.0.0.1` (health/nice-dns-health:130). On macOS, Pi-hole is at
  172.31.240.250 (mac/start-container.sh:24). Whether these checks can pass on
  macOS is baseline: unverified.
- The action is `nice-dns-fetch-bridges --force`
  (health/nice-dns-health:449-452). Then it runs
  `<runtime> exec tor-<variant> touch /tmp/tor-restart-flag`
  (health/nice-dns-health:392). A successful exec is logged as "triggered"
  (health/nice-dns-health:455-456). There is no acknowledgement check
  [REC-ACK-READINESS]. The outage marker is removed right after the action
  (health/nice-dns-health:469). No readiness check follows. The design notes
  that tor-socat has no consumer for that flag. baseline: unverified here,
  because it is sibling source.
- If the exec cannot run, the fallback is
  `systemctl --user restart tor-<variant>.service` or
  `launchctl kickstart -k` of the start-container agent
  (health/nice-dns-health:399-414).
- The only persisted state is the outage marker
  (health/nice-dns-health:359). nice-dns-health keeps no lock and no cooldown.
- On macOS the start-container agent and bridge-eval share a `mkdir` stack lock
  (mac/start-container.sh:57, mac/start-container.sh:247, mac/start-container.sh:509).
  A holder whose stored PID fails `kill -0` is taken over. After a crash, a reused
  PID in that persistent state file blocks the start for up to 600 s. Two waiters
  can also both take over a dead holder. This is carried to Sub-plan 3
  (state.sh owns locks) [REC-ACK-READINESS].
- Cache masking: Unbound serves expired answers for up to 24 h
  (unbound/etc/unbound.conf:99-101). dnsmasq has `use-stale-cache=3600`
  (pihole/etc/dnsmasq.conf:58). The `chain-resolves` check on `cloudflare.com`
  (health/nice-dns-health:193-201) can therefore pass while the upstream is
  down. This is the BL-018 blind spot [EVD-CACHE-NOT-UPSTREAM]. Reproduced by
  the baseline receipt (run 20260923T214611Z-a97c6844): with tor stopped in
  the proxy container for 120 s, every Linux quadlet cell kept pi-hole, unbound
  and the proxy `healthy` while 0/5 uncached queries were answered and 5/5
  cached ones were. No restart fired. Every macOS cell answered cached names
  the same way.
- Linux container health checks only test that a port is open: `nc -z` on
  853 and 5335 (deb/quadlet/tor-haproxy.container:54,
  deb/quadlet/unbound.container:22). Pi-hole's check is a `pi.hole` lookup
  that needs an answer line (deb/quadlet/pi-hole.container:28). Until
  sub-plan 02 it trusted dig's exit status, which is 0 on a SERVFAIL and
  `dig +short` prints its errors on stdout. All use `HealthOnFailure=restart`
  (deb/quadlet/tor-haproxy.container:76).
- macOS LaunchAgent: `RunAtLoad` true and `KeepAlive` false
  (mac/org.nice-dns.start-container.plist:9, mac/org.nice-dns.start-container.plist:27).
  It runs at load or login only. What runs after a wake is baseline:
  unverified.
- The macOS fast path exits when the addresses are correct and a probe
  resolves (mac/start-container.sh:574-578). The comment admits that a warm
  cache can satisfy the probe (mac/start-container.sh:567-573).
- A wedged datapath is detected by a probe between containers
  (mac/start-container.sh:209-218). The fix is a runtime restart
  (mac/start-container.sh:587-595).
- The stack is rebuilt once only when Tor never bootstrapped
  (mac/start-container.sh:680-690). If the chain is unhealthy but Tor did
  bootstrap, the script exits without pinning DNS
  (mac/start-container.sh:669-679).

### Platform notes

- Linux: scheduling comes from systemd user units and quadlet
  `Restart=on-failure` (deb/quadlet/tor-haproxy.container:79). The target is
  one installed controller entrypoint that the timer calls (ARCH-03).
- macOS: the LaunchAgent is the only start-time recovery path. It uses sudo
  for a fixed set of helper verbs only (mac/start-container.sudoers:7). The
  target must include post-wake scheduling. Timer intervals that match
  across platforms do not prove the same wake behavior (ARCH-07).

## WF-DNS-003 Install and restore

### Trigger

An operator runs `install-deb.sh`, `install-deb-hardened.sh`, `install-mac.sh`
or `install-mac-hardened.sh` with a variant, a reinstall, or `uninstall`.

### Contract (target, per ARCH)

Sources: ARCH-06, ARCH-08, design "Installers and persistence".

#### Steps

1. Prepare: fetch or build images from recorded immutable inputs. Validate
   them before touching the working DNS.
2. Snapshot only the DNS state the installer owns. This includes
   platform-specific settings and symlinks. It excludes unrelated VPN and
   network configuration.
3. Activate the candidate. Test the deployed DNS path. Switch the host
   resolver only after readiness.
4. On failure, restore the prior working deployment and the owned-state
   snapshot. Uninstall restores the snapshot exactly.
5. Keep Tor state, operator settings, credentials and resolver cache across
   repair and upgrade.

#### Invariants

- No lifecycle step points the host resolver at public DNS
  [PRIV-NO-HOST-PUBLIC] [PRIV-NO-DIRECT].
- Only owned state is changed, and it is restored exactly
  [SEC-OWNED-RESTORE].
- Build and bootstrap network use is declared and never becomes a client
  path [PRIV-BOOTSTRAP-DECLARED].
- Resolver management uses a restricted local channel. No image-shared keys
  [SEC-CONTROL-LOCAL].
- Credentials are delivered without printing them. Evidence carries no
  secrets [PRIV-NO-SECRETS].

### Current baseline (observed in source)

- Linux reinstall and uninstall rewrite the host resolver to public DNS.
  When /etc/resolv.conf holds `nameserver 127.0.0.1`, `teardown` writes
  9.9.9.9, 1.1.1.1 and 1.0.0.1 (install-deb.sh:138-143). Every install runs
  teardown first (install-deb.sh:209). The hardened installer does the same
  (install-deb-hardened.sh:157-160, install-deb-hardened.sh:204). This
  violates [PRIV-NO-HOST-PUBLIC]. Both teardowns first disable custom-dns-deb and
  remove the NetworkManager pin hook (install-deb.sh:135-136,
  install-deb-hardened.sh:154-155). The swap therefore holds for the whole
  install and stays after a failed one. Before b85bc9b the hook usually put
  127.0.0.1 back within seconds, and the install failed closed.
- Teardown removes the running containers, images and network
  (install-deb.sh:162-178) before new images are built
  (install-deb.sh:436-439). DNS is down for the whole build.
- Builds resolve through `--dns 1.1.1.1` (install-deb.sh:436-437,
  install-mac.sh:256-257) [PRIV-BOOTSTRAP-DECLARED]. The proxy image is a
  floating `:latest` tag (install-deb.sh:438,
  deb/quadlet/tor-haproxy.container:14). Inputs are not immutable.
- The standard and hardened installers have drifted. install-deb.sh builds
  with `--pull=newer --no-cache` (install-deb.sh:436-437).
  install-deb-hardened.sh does not (install-deb-hardened.sh:364,
  install-deb-hardened.sh:373). The same gap exists on macOS
  (install-mac.sh:256-257 against install-mac-hardened.sh:196,
  install-mac-hardened.sh:200-201). The macOS hardened teardown does not unload
  the bridge-eval agent (install-mac-hardened.sh:44-67). The standard
  teardown does (install-mac.sh:32-36).
- Linux resolver pin: `custom-dns-deb` stops and disables systemd-resolved
  (deb/custom-dns-deb:10-16). It writes `nameserver 127.0.0.1` and keeps a
  timestamped backup (deb/custom-dns-deb:18-36). NetworkManager gets
  `dns=none` and a dispatcher hook (install-deb.sh:50-65).
- Uninstall deletes those files (install-deb.sh:181-189). It does not
  re-enable systemd-resolved or restore the backup, so it leaves the public
  resolvers written by teardown. Exact restore is not implemented
  [SEC-OWNED-RESTORE].
- Linux pins the resolver without a readiness gate. The pod is restarted
  (deb/persistent-podman.sh:292). The pin is then applied at once
  (install-deb.sh:444-451), with no resolution check in between.
- macOS teardown sets every network service's DNS to `Empty`
  (install-mac.sh:106-111, install-mac-hardened.sh:62-65). Queries during
  install then go to whatever DHCP supplies. That may be a public or ISP
  resolver [PRIV-NO-HOST-PUBLIC]. baseline: unverified per network.
- macOS waits for the chain to resolve before pinning
  (install-mac.sh:326-341). It pins through the root helper
  (install-mac.sh:349). The helper sets every service to 172.31.240.250
  (mac/start-container-root.sh:28-32). No snapshot of the prior per-service
  DNS is taken. Uninstall sets `Empty` rather than restoring the prior values
  [SEC-OWNED-RESTORE].
- The macOS helper boots out and re-bootstraps Mullvad
  (mac/start-container-root.sh:35-39, mac/start-container-root.sh:46-51).
  That is VPN state the installer does not own (ARCH-06).
- Unbound remote control is a Unix socket at `/run/unbound/control.sock`
  with no keys and no network listener (unbound/etc/unbound.conf:163-166).
  Neither image carries control keys; the hardened-unbound base no longer
  generates them at build [SEC-CONTROL-LOCAL]. Installers do not yet mount a
  persistent volume for /var/lib/unbound (WF-DNS-001).
- All four entrypoints refuse to run as root (install-deb.sh:13,
  install-deb-hardened.sh:31, install-mac.sh:13, install-mac-hardened.sh:28). The macOS agent may run only three helper verbs
  under sudo (mac/start-container.sudoers:7).

### Platform notes

- Linux: persistence comes from Podman quadlets under
  `~/.config/containers/systemd` (deb/persistent-podman.sh:84-88) and linger
  (deb/persistent-podman.sh:44-45). The resolver pin is a system oneshot
  (deb/custom-dns-deb.service:6-9).
- macOS: persistence comes from the LaunchAgents installed by `mac/persist.sh`
  (mac/persist.sh:39-56) and helpers in `/usr/local/sbin`
  (mac/persist.sh:24-36). It requires macOS 26+ on arm64
  (mac/check-runtime.sh:18-31).
- The four entrypoints stay public (ARCH-01). The target moves their shared
  lifecycle into `lib/install.sh` behind them.

## WF-DNS-004 Bridge selection

### Trigger

The daily schedule fires. Or the bridge pool is missing or incomplete. Or a
sustained full-upstream failure makes a refreshed selection eligible.

### Contract (target, per ARCH)

Sources: ARCH-07, design "Bridge lifecycle".

#### Steps

1. Refresh daily, outside the startup critical path, when a usable set
   exists.
2. On a fetch or probe failure, keep the previous usable pool and selection.
3. Validate the new selection and replace it atomically. An unchanged
   selection triggers nothing.
4. A changed selection waits while DNS works. It is applied during a
   sustained failure or at the next natural start. Tor data is kept.
5. On macOS, selection runs on `dnsnet` only.
6. Evidence and logs redact bridge certificates.

#### Invariants

- Bridge fetch traffic is a declared bootstrap exception. It never serves
  client queries [PRIV-BOOTSTRAP-DECLARED] [PRIV-NO-DIRECT].
- Bridge lines and certificates never enter portable evidence
  [PRIV-NO-SECRETS].
- Applying a selection is a recovery action with an acknowledgement and a
  readiness check [REC-ACK-READINESS].

### Current baseline (observed in source)

- `scripts/fetch-bridges.sh` fetches the Moat builtin list. It resolves
  `bridges.torproject.org` directly against 1.1.1.1, 9.9.9.9 and 8.8.8.8
  (scripts/fetch-bridges.sh:105-117). This is a bootstrap exception
  [PRIV-BOOTSTRAP-DECLARED].
- It writes the file atomically with mode 600
  (scripts/fetch-bridges.sh:187-199). On a fetch failure it keeps the
  existing file (scripts/fetch-bridges.sh:127-132). Without `--force` it
  skips when three or more valid lines exist
  (scripts/fetch-bridges.sh:65-89).
- Linux: `nice-dns-fetch-bridges.service` runs bridge-eval in manage mode
  inside the tor image (deb/persistent-podman.sh:159-163). It is a oneshot
  with `RemainAfterExit=yes` (deb/persistent-podman.sh:149) and no timer, so
  it runs once per boot. It also runs at install
  (deb/persistent-podman.sh:286).
- Exit 1 is tolerated (deb/persistent-podman.sh:167). A missing `BRIDGE1`
  fails loudly (deb/persistent-podman.sh:173).
- The Linux proxy reads `bridges.env` through `EnvironmentFile=` at
  container start (deb/quadlet/tor-haproxy.container:23). A changed selection
  takes effect only on the next container start.
- Health recovery runs `nice-dns-fetch-bridges --force`
  (health/nice-dns-health:449-452). That installed script is the raw Moat
  fetcher (deb/persistent-podman.sh:130). It writes the same `bridges.env`
  that bridge-eval writes its evaluated set to
  (scripts/fetch-bridges.sh:49-51, deb/persistent-podman.sh:163). Recovery can
  therefore replace an evaluated set with an unranked pool. baseline:
  unverified at runtime.
- The Linux tor quadlet declares no `Volume=` for Tor data
  (deb/quadlet/tor-haproxy.container:12-23). Whether Tor state survives
  container recreation on Linux is baseline: unverified (ARCH-06).
- macOS: the bridge-eval agent has `RunAtLoad` and `StartInterval` 86400
  (mac/org.nice-dns.bridge-eval.plist:17-19). It runs on `dnsnet`, and only
  after the stack is up on its own addresses (mac/bridge-eval.sh:102-117). It
  holds the stack lock while its probe container exists
  (mac/bridge-eval.sh:119-135), and it runs the probe on `dnsnet`
  (mac/bridge-eval.sh:153-160). It redacts `cert=`
  in its log (mac/bridge-eval.sh:162). It keeps the existing file on failure
  (mac/bridge-eval.sh:171-174).
- The macOS LaunchAgent refetches only when the pool is missing or
  incomplete, or after a failed bootstrap (mac/start-container.sh:523-544).
  It recreates Tor only when the bridge fingerprint changed
  (mac/start-container.sh:426-442). On a change it drops the guard sample
  and keeps the cache (mac/start-container.sh:116-118). Tor's DataDirectory
  persists (mac/start-container.sh:42, mac/start-container.sh:446).
- The macOS installer runs the fetcher without `--force`
  (install-mac.sh:280). It requires at least three bridges
  (install-mac.sh:301-304).

### Platform notes

- Linux: bridge-eval runs host-side through `podman run --userns=keep-id`
  (deb/persistent-podman.sh:159). The target adds a daily timer and keeps
  the out-of-band selection model.
- macOS: a second container on another vmnet network wedges `dnsnet`
  (mac/bridge-eval.sh:77-90). Selection must stay on `dnsnet`.
