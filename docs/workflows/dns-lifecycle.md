# nice-dns DNS lifecycle workflows

Behavior contracts for the nice-dns stack. Sub-plan 01, Task 1.1 of the
2026-09-19 stability, latency and security plan.

- Contract sources: the approved design and architecture (ARCH-01 to ARCH-09)
  in the vault at `Portfolio/containers/nice-dns/plans/2026-09-19-stability-latency-security-*.md`.
- Baseline source: this repository at commit
  `66cd3402d7c4ccf15ce76489be8db89746cdd059`. Citations are `path:line` at that commit.
  The eight-cell baseline receipt measured b85bc9b. The document was first
  written against 337fb15; sub-plan 01 then landed product fixes (c8ecd70,
  fcc3f6c, fc5e6ec, b85bc9b), and the citations were re-derived. Sub-plan 02
  re-pins after each change to a cited file (Task 1.1: 04b98cf, Unbound
  anchor and control; Task 1.3: d6c1a1f, Pi-hole HealthCmd; Stage 1 gate: 80d6c18, control refusal; Task 2.1: 9e71d32, route include; Task 2.3: bc846b2, Unbound WORKDIR; Stage 2 gate: 94a9c60, route resolution check). Sub-plan 03 re-pins the same
  way (Task 1.1: ba144fd, health observations and platform adapters; Task 1.2: e81697f, state directory and boot identity appended to the platform adapters; Task 1.3: 6bf29f3, acknowledged recovery; Stage 1 gate: 4b11779, one controller pass; 20589e8, route recorded on success; Task 2.1: 3a4b4d6, bundle and minute schedules; Task 2.2: d934ed5, bridge lifecycle; Task 2.3: b8b9bb8, shadow install and privacy-safe failure dump; 93a9122, macOS exec reports a missing executable as 127; 674635f, the macOS fallback always rebuilds; 8f10ffe, it rebuilds the whole stack; e6436ad, restart ladder; dca5b57, a stopped macOS container has no generation; Stage 2 gate: 969945e, bridge refresh ownership; 5de0e7d, policy timers from tunables.tsv; close-out: a4eea01, the ladder waits out the first restart's readiness; ca16537, quadlet health checks verify and only report, Wants= not Requires=; c55ea50, probe-route bounded; 778df19, a failed macOS kickstart withdraws its request; 5dff7b7, a Linux adapter comment; 0efca9c, the macOS proxy lookup honours the recovery deadline; pre-merge review: 16d65cb, a runtime fault the platform cannot repair escalates). Sub-plan 4 re-pins the same way (Task 1.1: 509a6de, shared installer preparation in lib/install.sh; 7019cf0, the macOS hardened pi-hole build has no --pull; fdf6179, a first install migrates podman before its builds; Task 1.2: ec2b51c, owned DNS receipts and transactional cutover; Task 1.3: 495241e, immutable release inputs; Stage 1 gate: 58e6472, restores that cannot half-fail; Task 2.1: 57db2a3, private admin credential, host-only DNS, least privilege; Task 2.2: 3148e14, instance state kept across the lifecycle; Task 2.3: 66f1666, legacy profile pins restored and the macOS stack started on a fresh datapath; Stage 2 gate: 3fab8dd, the macOS cache flushed after each resolver change; 7a403df, uninstall removes instance state only after DNS is given back; 66cd340, a macOS rollback stops the builder and restarts the runtime). `check-contracts` fails when a cited file changes
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
  `DNS1=127.0.0.1#5335` (deb/quadlet/pi-hole.container:39).
- On macOS the installer and LaunchAgent override the upstream to
  `172.31.240.251#5335` (lib/install.sh:2164-2165, mac/start-container.sh:481-482).
- Pi-hole query logging is off in the shipped config
  (pihole/etc/pihole.toml:197). dnsmasq `log-queries` is commented out
  (pihole/etc/dnsmasq.conf:48). baseline: unverified at runtime for both
  Pi-hole images.
- Unbound forwards the root zone through one managed include,
  `include: "/etc/unbound/route/forward-route.conf"` (unbound/etc/unbound.conf:143).
  The image default is the legacy route: `forward-first: no`,
  `forward-tls-upstream: yes` and `127.0.0.1@853#tor.cloudflare-dns.com`
  (unbound/route/forward-route.conf:13-17), so an image paired with an older
  proxy keeps resolving. It uses `tls-cert-bundle: "/etc/ssl/cert.pem"`
  (unbound/etc/unbound.conf:132). The entrypoint refuses to start Unbound
  unless the include holds exactly one root forward-zone over TLS with one
  `ADDR@PORT#TLS-NAME` forwarder and `forward-first: no`, plus the route
  marker, and unless the main config names no other root forward-zone or
  stub-zone (unbound/start.sh:140-183, unbound/start.sh:286-289)
  [PRIV-NO-DIRECT] [SEC-TLS-NAME].
- Route selection (ARCH-03 `apply_route`): routes/providers.tsv binds each
  route to its port and TLS name (routes/providers.tsv:13-17). The host
  library records the desired route, stages the include, has the image
  validate it (`nice-dns-unbound-start check-route`: the shape above, then
  `unbound-checkconf` on the complete candidate config,
  unbound/start.sh:187-204), keeps the previous include, renames the staged
  file into place, runs `reload_keep_cache` and reads back the
  `nice-dns-route.invalid.` TXT marker through the control socket, then
  resolves through the new forwarder with a fresh TLS session
  (`nice-dns-unbound-start probe-route`, unbound/start.sh:211-234; the cache
  cannot answer it) (lib/recovery.sh:330-390). A route that does not resolve
  is rolled back. A failure after the rename restores the
  previous include the same way; if that also fails the result is
  `escalate` and the forward-zone stays in place. An unchanged route is not
  reloaded. `reconcile_route` finishes an interrupted change
  (lib/recovery.sh:392-418). The Linux adapter uses 127.0.0.1, the macOS
  adapter 172.31.240.252 (lib/platform/linux.sh:15, lib/platform/macos.sh:17).
  Deployments do not mount a route directory yet, so the image default runs
  until a later sub-plan wires the mount [PRIV-ROUTE-IDENTITY]. On macOS
  (Apple container 1.4.1, /bin/bash 3.2.57) the adapter was qualified with
  a throwaway container: `container exec --user unbound` controls Unbound,
  other uids are denied, and a route change is staged, renamed in the
  bind-mounted directory, reloaded, read back and rolled back.
- Proven on the built image by `integration/route-transition`: each listed
  route carries queries only on its port; the route changes with the cache,
  thread, socket and cache-size settings intact; an unchanged route is not
  reloaded; unlisted routes, nameless TLS forwarders, `forward-first: yes`,
  a missing forward-zone and a second root zone are refused; interruption
  before and after the rename and after the reload reconciles; a failed
  activation restores the previous route, and a failed rollback escalates
  with forwarding still in place.
- Measured on the whole chain by `integration/transport-transitions`
  (both proxies x both Pi-hole images, fixture upstream): a route change
  under paced load lost no query (0 timeouts and 0 errors of 80 cached and
  80 fresh; the queries in flight during the ~0.6 s change were answered),
  kept the cache, and reused one upstream session afterwards. A wrong-name
  certificate on the selected route and a bogus signature give SERVFAIL
  through Pi-hole. The run writes the transport receipt
  (`bash tests/run.sh receipt transport`) [EVD-FAILURES-COUNTED].
- The macOS installers edit the build copies: unbound.conf binds 0.0.0.0 and
  allows 172.31.240.248/29 (lib/install.sh:1772-1775), and the route include
  forwards to `172.31.240.252@853` (lib/install.sh:1778-1779).
- Provider identity is mixed today. The default route authenticates
  `tor.cloudflare-dns.com` (unbound/route/forward-route.conf:17). The health script
  used to describe the proxy backends as the onion primary, a 1.1.1.1 backup
  and a 9.9.9.9 fallback via Tor exit. A Quad9 backend there would receive a
  Cloudflare-named TLS session. That breaks [PRIV-ROUTE-IDENTITY]. baseline:
  unverified. The proxy config lives in the sibling repos and was not read
  here. Since the Sub-plan 3 Stage 1 gate the health CLI's recovery comment
  describes the single controller pass (health/nice-dns-health:415-463); the
  routes and their classes are in routes/providers.tsv.
- Unbound validates against the root anchor in
  `auto-trust-anchor-file: "/var/lib/unbound/root.key"`
  (unbound/etc/unbound.conf:30-34). That directory is persistent state owned
  by the unbound user, 0700 (unbound/Containerfile:40-42). The image carries a
  read-only seed. Its trust root is the DS set compiled into unbound-anchor.
  Every root DNSKEY in the dnssec-root package must match one of those DS
  records and is kept. A required KSK (20326, 38696) that the package lacks
  is seeded as its builtin DS line, so the image also builds on the published
  base, whose package carries only KSK-2017. The build fails on a DNSKEY that
  matches no builtin DS, a required tag unknown to both, or an empty tag list
  (unbound/start.sh:102-132, unbound/Containerfile:39). The entrypoint reads
  the anchor path from the effective config. It seeds a missing anchor from
  the seed. It exits with a `FATAL` message, before Unbound starts, when the
  anchor or its directory is unusable: symlinked, not owned by unbound, not
  writable (including a read-only mount), empty, malformed, or without a
  trusted root key (unbound/start.sh:236-260). [SEC-DNSSEC-ANCHOR]
- Proven on the built images by `integration/resolver-state`. Through a
  controlled signer, the product Unbound sets AD on a signed answer, answers
  an insecure delegation without AD, and returns SERVFAIL for a bogus
  signature whose record `+cd` still retrieves
  [SEC-DNSSEC-SIGNED] [SEC-DNSSEC-UNSIGNED] [SEC-DNSSEC-BOGUS].
  Since Sub-plan 4 Task 2.2 /var/lib/unbound is the volume
  nice-dns-unbound-anchor on both platforms (deb/quadlet/unbound.container:21,
  lib/install.sh:2171, mac/start-container.sh:489), so a new container keeps
  the anchor's RFC 5011 state; until then each one re-seeded from the image.
- Resolver management is a Unix socket, `/run/unbound/control.sock`, with
  `control-use-cert: no` and no TCP listener or key files
  (unbound/etc/unbound.conf:166-169). The entrypoint keeps `/run/unbound`
  owned by unbound and closed to others, and refuses any network
  control-interface while control is enabled (unbound/start.sh:263-283). Unbound
  creates the socket with mode 0660. Operators run
  `podman exec --user unbound unbound unbound-control ...`; other uids are
  refused. The nice-dns image deletes any control keys an older published
  base still carries (unbound/Containerfile:32-34) [SEC-CONTROL-LOCAL].
- Unbound does not use IPv6 (`do-ip6: no`, unbound/etc/unbound.conf:19).
  Linux installs disable IPv6 through sysctl (lib/install.sh:1468-1491).
- The Linux pod publishes DNS and the admin UI on the host loopback only:
  127.0.0.1:53 TCP/UDP and 127.0.0.1:8880 (deb/quadlet/nice-dns.pod:17-19)
  [SEC-LISTENERS]. Until Sub-plan 4 Task 2.1 it published :53 with no host
  address, on every host interface, so the host answered DNS for its whole
  network. macOS reaches the stack only over the host-only dnsnet.
- Pod members resolve through `DNS=1.1.1.1` (deb/quadlet/nice-dns.network:5).
  The stated reason is bootstrap (deb/quadlet/nice-dns.pod:7-11). This is
  container-level traffic, not client traffic. Which in-pod processes use it
  at runtime is baseline: unverified [PRIV-BOOTSTRAP-DECLARED].
- The health observations probe fixed public names: `cloudflare.com` and
  `doubleclick.net`, plus `pi.hole` (lib/health.sh:421-423). Route probes pass
  no query name, so the image probe asks its default `.` SOA
  (lib/health.sh:355-408). Its failure dump copies the last 50 log lines of
  every container: `logs --tail 50` on Linux (health/nice-dns-health:314-315)
  and `container logs -n 50` on macOS (health/nice-dns-health:320-321).
  Until Sub-plan 3 Task 2.3 the macOS dump used `--tail`, which Apple
  `container` does not accept, so it held no logs, and it ran
  `container inspect`, whose JSON carries the proxy's BRIDGE environment.
  Now the whole dump passes through redact_bridges, which replaces
  certificates, fingerprints and bridge addresses
  (health/nice-dns-health:260-264, 364) [PRIV-NO-SECRETS]. Whether the log
  lines can contain client query names is baseline: unverified
  [PRIV-NO-QUERY-HISTORY].

### Platform notes

- Linux: Pi-hole, Unbound and the Tor proxy share one Podman pod network
  namespace (`Pod=nice-dns.pod`, deb/quadlet/unbound.container:17), so
  loopback addresses work between them. Unbound listens only on 127.0.0.1
  (unbound/etc/unbound.conf:5).
- macOS: Apple `container` gives each container its own address on `dnsnet`.
  The configs hardcode .250/.251/.252 (mac/start-container.sh:24-26). The
  LaunchAgent refuses a stack whose addresses do not match
  (mac/start-container.sh:231-239, mac/start-container.sh:697-705).

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

- Since Sub-plan 3 Task 2.1, both platform installers end by installing the
  controller, and fail when it does not install (deb/persistent-podman.sh:318,
  mac/persist.sh:43-44).
  - `install` builds a versioned bundle, then checks that the new bundle
    loads (health/nice-dns-health:742). Only then does it replace the
    schedule (health/nice-dns-health:728-807).
  - `uninstall` removes only what the install receipt lists
    (health/nice-dns-health:829-852).
  - Until Task 2.1 no installer installed it; it was installed by hand
    (health/nice-dns-health:14).
  - Deployed hosts still carry the older hand-installed copies. What runs
    there is baseline: unverified.
- Schedule: `tick`, every minute.
  - Linux: a systemd user timer with `OnCalendar=minutely`,
    `AccuracySec=5s` and `Persistent=true` (health/nice-dns-health:613-615).
    The service runs `<bash> <entrypoint> tick` with
    `TimeoutStartSec=540`, inside the lock lease
    (health/nice-dns-health:602-604).
  - macOS: the agent's all-wildcard `StartCalendarInterval`
    (health/nice-dns-health:674-675).
  - Observation mode since Sub-plan 3 Task 2.3: `install --shadow` writes the
    same unit or agent running `tick --shadow` (health/nice-dns-health:593,
    628), which records what it would do and never acts, and schedules no
    bridge refresh; a later shadow install stops and removes one
    (health/nice-dns-health:756-761, 746-750). The receipt records `mode`
    (health/nice-dns-health:785) and `status` prints it
    (health/nice-dns-health:879). A plain install activates the same
    schedule in place. Live shadow behavior is baseline: unverified until
    live/controller-shadow runs.
  - Calendar schedules run after a suspend or sleep, whereas monotonic timers
    and `StartInterval` do not (systemd.timer(5), launchd.plist(5)). Behavior
    on live hosts is baseline: unverified until the Stage 2 gate.
- Since the Stage 2 gate the scheduled pass also reads the policy timers
  from an optional tunables.tsv in the install root (allow-listed keys,
  checked like the libraries; the environment wins)
  (health/nice-dns-health:442-459). The live gate uses it for 30 s timers
  in its extra configurations.
- Grace is `ND_POLICY_GRACE_S` = 300, still settable through
  `NICE_DNS_RESTART_GRACE_SECS` (health/nice-dns-health:462). lib/policy.sh
  counts it from the later of the outage's start and the end of the 120 s
  startup allowance. With one-minute passes, a full outage observed from its
  onset becomes eligible for a restart after five minutes, subject to the
  cooldown.
- The checks are the lib/health.sh observations (health/nice-dns-health:228).
  Until Sub-plan 3 Task 1.1 both platforms read /etc/resolv.conf and queried
  `@127.0.0.1`. Now the platform adapter picks Pi-hole's endpoint: 127.0.0.1
  on Linux (lib/platform/linux.sh:36) and 172.31.240.250 on macOS
  (lib/platform/macos.sh:56, mac/start-container.sh:24). DNS ownership is
  resolv.conf naming only 127.0.0.1 on Linux (lib/platform/linux.sh:75-86).
  On macOS, every enabled network service and scutil's resolver #1 must use
  172.31.240.250 (lib/platform/macos.sh:118-155). The macOS path is proven
  with unit fakes built from captured macOS output. Whether it passes on a
  live Mac is baseline: unverified.
- Since the Sub-plan 3 Stage 1 gate, `run` has no outage timer of its own.
  After logging, it hands its observations to the same controller pass as
  `tick` (health/nice-dns-health:491-503, lib/recovery.sh:741-790). One
  policy, one state, one lock, one cooldown and one restart cap decide
  every action, whichever command the schedule calls. The pass observes,
  decides with lib/policy.sh, acts, and commits the state. Readiness
  (ready or not-ready) is recorded on a later pass. A restart acts only on
  an outage observed in that same pass.
- Before the pass, and outside the lock, the bridges are re-evaluated
  (nd_bridges_refresh) once an observed outage has outlasted the grace. This
  happens at most once an hour (health/nice-dns-health:473-489). Since the
  Stage 2 gate it runs before the pass observes, so the decision never rests
  on observations older than the evaluation. Nothing in
  the controller writes `bridges.env` directly (WF-DNS-004).
- Restart ladder since Sub-plan 3 Task 2.3: the first restart of an outage
  is Tor's (below); a later one of the same outage targets the proxy, the
  service restart directly (lib/policy.sh:263). Since the close-out the later
  step also waits ND_POLICY_LADDER_S (660 s) after the first, the first
  restart's readiness window plus a minute (lib/policy.sh:258-259), so it
  never recreates a Tor that is still bootstrapping. Live on the Mac, a wedged
  runtime made two in-image restarts acknowledge and never become ready; only
  the stack rebuild repairs it.
- Runtime faults: repair-runtime acts only on a fault the platform can
  repair (lib/platform/linux.sh:141, lib/platform/macos.sh:231); any other
  escalates at once (lib/policy.sh:206-207). Rootless Podman has no daemon
  to restart, so Linux escalates runtime-down. Before the pre-merge review
  it re-issued an unsupported repair every cooldown and never escalated.
- The Tor restart is nd_recovery_restart_tor (lib/recovery.sh:638-655):
  - A refreshed bridge set may be waiting for a proxy that has not been
    recreated. Then the restart goes straight to the service restart, which
    reads the new set. The in-image restart would keep the old environment.
  - `request_recovery tor` writes the request into the proxy image's
    `/app/data/control` (lib/recovery.sh:500-551). It counts as done only on
    the image's answer with a newer Tor generation and a different pid
    (lib/recovery.sh:544) [REC-ACK-READINESS].
  - When that answer does not come, or the image cannot give it, or the
    proxy is unreachable, one service restart follows
    (lib/recovery.sh:577-606). It counts only when the container comes back
    with a new start. On Linux it restarts the proxy alone with
    `systemctl --user restart tor-<variant>.service`
    (lib/platform/linux.sh:135). On macOS it is `launchctl kickstart -k` of
    the start-container agent, which recreates the whole stack
    (lib/platform/macos.sh:218).
  - The in-image restart keeps Tor's data. The service restart recreates
    the `--rm` container, which loses it until a volume is mounted
    (Sub-plan 4).
  - The deployed Mac's published proxy image has no `/app/data/control`
    (observed 2026-09-25), so there the request is unsupported and the
    stack restart runs.
  - Since Sub-plan 3 Task 1.3, the old `touch /tmp/tor-restart-flag`,
    logged as "triggered" without any answer, is gone.
- Every action holds the state lock (lib/state.sh:203). Before each change,
  the action checks the lock again (lib/recovery.sh:490). Its waits are
  bounded in wall-clock seconds.
- A Tor restart is ready when an identity route answers and Unbound
  resolves over its TLS-verified route, which is host-side evidence the
  proxy cannot forge (lib/recovery.sh:698-732, DEC-006). An Unbound image
  without nice-dns-unbound-start gives "ready, uncorroborated" (exit 126 or
  127). Since Sub-plan 3 Task 2.3 the macOS adapter reports Apple container's
  missing executable (exit 1) as 127 (lib/platform/macos.sh:28-36). Before
  that, a working restart on macOS was never ready (live run
  20260925T200235Z-e3b4de89).
- The schedules still call `run`; Sub-plan 3 Task 2.1 moves them to `tick`.
- On macOS the start-container agent and bridge-eval share a `mkdir` stack lock
  (mac/start-container.sh:61, mac/start-container.sh:310, mac/start-container.sh:583).
  A holder whose stored PID fails `kill -0` is taken over. After a crash, a reused
  PID in that persistent state file blocks the start for up to 600 s. Two waiters
  can also both take over a dead holder. lib/state.sh now provides the
  controller lock (boot, pid and lease staleness, compare-and-delete;
  lib/state.sh:203). mac/start-container.sh moves to it with the installed
  bundle (Sub-plan 3 Task 2.1) [REC-ACK-READINESS].
- Cache masking: Unbound serves expired answers for up to 24 h
  (unbound/etc/unbound.conf:99-101). dnsmasq has `use-stale-cache=3600`
  (pihole/etc/dnsmasq.conf:58). Until Sub-plan 3 Task 1.1 the `chain-resolves`
  check read `cloudflare.com` through Pi-hole, so it could pass while the
  upstream was down. This is the BL-018 blind spot [EVD-CACHE-NOT-UPSTREAM].
  Reproduced by
  the baseline receipt (run 20260923T214611Z-a97c6844): with tor stopped in
  the proxy container for 120 s, every Linux quadlet cell kept pi-hole, unbound
  and the proxy `healthy` while 0/5 uncached queries were answered and 5/5
  cached ones were. No restart fired. Every macOS cell answered cached names
  the same way. Now `chain-resolves` fails when no route answers an
  authenticated probe and at least one fails (health/nice-dns-health:252-254,
  lib/health.sh:355-408). The Pi-hole answer is a separate `local-cache`
  observation (lib/health.sh:301-305). unit/observations proves the split
  with fakes; on live hosts it is baseline: unverified.
- Linux container health checks, since the Sub-plan 3 close-out, verify the
  chain and only report. The proxy runs the image's route probe through Tor
  (deb/quadlet/tor-haproxy.container:63, deb/quadlet/tor-socat.container:29).
  Unbound needs its control socket to answer and its route to resolve in a
  fresh authenticated session, bypassing the cache
  (deb/quadlet/unbound.container:29). Both use `HealthOnFailure=none`
  (deb/quadlet/tor-haproxy.container:70, deb/quadlet/unbound.container:35):
  the controller is the one actor that restarts them for a chain fault.
  Before, they were `nc -z` port checks with `HealthOnFailure=restart`: green
  through Sub-plan 1's live Tor freeze while Podman restarted Unbound and
  Pi-hole instead. Pi-hole's check is a `pi.hole` lookup that needs an answer
  line and still restarts it (deb/quadlet/pi-hole.container:41,
  deb/quadlet/pi-hole.container:48); the controller has no Pi-hole action.
  Until sub-plan 02 it trusted dig's exit status, which is 0 on a SERVFAIL
  and `dig +short` prints its errors on stdout.
- Unbound and Pi-hole use `Wants=` plus `After=` on the unit before them
  (deb/quadlet/unbound.container:11-12, deb/quadlet/pi-hole.container:8-9).
  They used `Requires=`, under which an explicit restart of the required unit
  restarts its dependents (systemd.unit(5)): the controller's proxy restart
  also restarted Unbound, dropping its cache, and Pi-hole. The Linux service
  restart is now the proxy's alone.
- macOS LaunchAgent: `RunAtLoad` true and `KeepAlive` false
  (mac/org.nice-dns.start-container.plist:9, mac/org.nice-dns.start-container.plist:27).
  It runs at load or login only. What runs after a wake is baseline:
  unverified.
- The macOS fast path exits when the addresses are correct, Pi-hole answers
  and, since Sub-plan 3 Task 2.3, the proxy image's verifying probe answers
  through Tor (mac/start-container.sh:175-206, mac/start-container.sh:636-640).
  Until then a warm cache satisfied it (mac/start-container.sh:629-635): live,
  with Tor frozen, the controller's service fallback was answered "stack
  already healthy" twice and never restarted the proxy. A restart the
  controller decides always rebuilds: nd_platform_restart_proxy leaves
  restart-requested, which fast_path_ok consumes, and a failed kickstart
  withdraws it (lib/platform/macos.sh:218-227),
  and keep_running_stack then refuses to leave the stack alone, so the whole
  stack is rebuilt (a second live run had stopped at "leaving it alone").
  Until Sub-plan 4 Task 1.2 the macOS installers waited on the same
  Pi-hole-only check before pinning DNS; the installers' readiness wait now
  also requires Unbound to resolve over its authenticated route
  (lib/install.sh:773-788).
- A wedged datapath is detected by a probe between containers
  (mac/start-container.sh:272-281). The fix is a runtime restart
  (mac/start-container.sh:649-657).
- The stack is rebuilt once only when Tor never bootstrapped
  (mac/start-container.sh:742-752). If the chain is unhealthy but Tor did
  bootstrap, the script exits without pinning DNS
  (mac/start-container.sh:731-741).

### Platform notes

- Linux: scheduling comes from systemd user units and quadlet
  `Restart=on-failure` (deb/quadlet/tor-haproxy.container:73). The target is
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
- The admin API accepts only the deployment's own password
  [SEC-ADMIN-AUTH].
- Each listener is reachable only by its intended callers
  [SEC-LISTENERS].
- Containers run non-root with only the capabilities they were shown to
  need [SEC-LEAST-PRIV].

### Current baseline (observed in source)

- Only the two root helpers write host DNS: `deb/custom-dns-deb` on Linux
  and `mac/start-container-root.sh` on macOS. They write the pin or the
  state recorded before nice-dns, nothing else
  (deb/custom-dns-deb:119, mac/start-container-root.sh:58).
  No installer code names resolv.conf or network-service DNS, and the
  helpers name no public resolver; a static case checks both
  (tests/integration/dns-transaction.sh) [PRIV-NO-HOST-PUBLIC].
- Before any work, an install refuses (exit 3) when another owner changed
  host DNS after nice-dns pinned it
  (lib/install.sh:528-560): Linux compares
  /etc/resolv.conf against the pin (deb/custom-dns-deb:143-152);
  macOS compares every service the record knows
  (mac/start-container-root.sh:150-169). A service added after
  the install is not a refusal.
- The record is taken once, before the first interruption, in a root-only
  directory, 0600, and kept across reinstalls, so it stays the state before
  nice-dns (deb/custom-dns-deb:154-196,
  mac/start-container-root.sh:114-148). Linux records
  resolv.conf (symlink target, file copy and mode, or missing),
  systemd-resolved's enabled and active state and the ipv6 sysctls; macOS
  records each service's servers. An install from before records is
  `legacy`: its state before nice-dns is unknown [SEC-OWNED-RESTORE].
  On a `legacy` host the Linux record also lists the NetworkManager
  profiles an older installer pinned to 127.0.0.1 with automatic DNS off
  (`nm_pin`); a fresh host's profiles are never claimed
  (deb/custom-dns-deb:75-91, deb/custom-dns-deb:185-187).
- Preparation comes first since Sub-plan 4 Task 1.1: packages, source
  staging, image builds and pulls and a prepare manifest finish before
  anything interrupts the stack or touches host DNS
  (install-deb.sh:51-64,
  install-mac.sh:94-109). Before any pull,
  the deployment being replaced is kept: its `:latest` images under
  `pre-<generation>` tags and a copy of its owned files
  (lib/install.sh:629-690).
- The interruption keeps the host pinned: the stack stops, but host DNS is
  not touched, so it fails closed until the new stack answers
  (lib/install.sh:1380-1406). The controller's
  schedules are held for the transaction (lib/install.sh:738-756).
  macOS builds run in the interruption window (`container build` wedges a
  running dnsnet), without `--pull`; their bases are pulled in preparation
  (lib/install.sh:52, lib/install.sh:1805-1813).
  The builds and the volume hand-over run containers on the default
  network, after which Apple's runtime brings dnsnet containers up with
  their interfaces down, so the runtime is restarted before dnsnet and the
  stack start (lib/install.sh:2112-2127). A macOS rollback stops the builder
  and restarts the runtime the same way before a previous stack comes back,
  and starts the runtime again if that restart failed
  (lib/install.sh:1983-1989, lib/install.sh:876, lib/install.sh:877-886).
- The resolver is pinned only after the new stack answers an ordinary query
  at the pinned address and Unbound resolves over its authenticated route
  (lib/install.sh:773-788,
  lib/install.sh:794-804), and after the installed
  controller passes its self-check (lib/install.sh:822-828).
  Linux: lib/install.sh:1511-1526. macOS:
  lib/install.sh:2003-2027; `mac/persist.sh` loads the
  start-container agent, whose first run pins every service, only after the
  controller installed and its installed copy passed its self-check
  (mac/persist.sh:43-66). The pin is
  then verified (lib/install.sh:831-834).
- Any failure after the interruption began, including Ctrl-C, rolls back
  (lib/install.sh:851-863, lib/install.sh:865-928):
  the new stack goes, the saved files and image tags come back, the
  previous stack and the controller restart, and a first install gives back
  the recorded DNS state (or drops an unused record). A second interrupt
  cannot cut the rollback short. The rollback waits for the previous stack
  and says when it does not answer; host DNS then stays pinned to it (fails
  closed). When a first install's DNS restore does not complete, it says
  that host DNS was not given back and keeps the record for a retry
  (manifest status `rolled-back-dns-not-restored`).
- Uninstall removes the stack, images, bridge service and controller and
  gives back the recorded DNS state
  (lib/install.sh:1533-1583,
  lib/install.sh:2032-2041;
  deb/custom-dns-deb:205-294, mac/start-container-root.sh:171-203).
  The Linux helper puts resolv.conf back first and whole (a new file or
  link renamed over it) while `dns=none` still holds NetworkManager off it;
  if that fails, nothing else changes, the host stays pinned and the record
  stays (deb/custom-dns-deb:199-203). The macOS helper tries every
  service and keeps the record when one fails. A restore that did not
  complete fails the uninstall, which says so after removing the rest
  (lib/install.sh:1587-1592).
  On macOS every change of the host resolver, the pin (`post`) and a
  restore (complete or not), ends with a flush of the system DNS cache:
  getaddrinfo otherwise kept failing names for about 80 s after the stack
  answered them again (mac/start-container-root.sh:68-71,
  mac/start-container-root.sh:227-233).
  A setting another owner changed is left alone. A `legacy` record restores
  the distribution default: the systemd-resolved stub on Linux, `Empty`
  (DHCP) for each pinned macOS service. The recorded legacy profile pins get
  automatic DNS back and are reapplied, before the NetworkManager reload and
  only while still as recorded; with no record at all, the pins found then;
  a profile that cannot be reset fails the restore and keeps the record
  (deb/custom-dns-deb:93-116, deb/custom-dns-deb:273-288). Uninstall claims only that the
  recorded state is back, not that it is private.
- Around the transaction: the sudo credential is kept fresh without
  prompting until the install ends, so a late rollback can still use sudo
  (lib/install.sh:545-554). NetworkManager's `dns=dnsmasq` is overridden by
  the owned `90-nice-dns.conf` drop-in, never by editing NetworkManager.conf
  (lib/install.sh:1596-1618). On a host where the user had no
  subordinate id ranges, preparation runs `podman system migrate` for the
  ranges it added and names any running container that stops
  (lib/install.sh:1263-1271).
- Builds resolve through `--dns 1.1.1.1` (lib/install.sh:48,
  lib/install.sh:52) [PRIV-BOOTSTRAP-DECLARED].
- Since Sub-plan 4 Task 1.3 every pulled image and build base is the
  reviewed digest in release/images.lock, with its platforms, source commit
  and signer (docs/release-inputs.md). Before any interruption an install
  checks the lock, this host's platform and the proxy's interfaces
  (lib/install.sh:973-1024) and, with cosign, the
  signatures (lib/install.sh:1033-1061). The
  quadlet still names `:latest` (deb/quadlet/tor-haproxy.container:14), which activation
  points at the locked image (lib/install.sh:1655-1664).
  Each generation's manifest records the source commit, the local image
  ids, the locked references and the signature results
  (lib/install.sh:237-299).
- The standard and hardened installers share one build policy, one
  preparation and one transaction per platform. Before Sub-plan 4 Task 1.1
  they had drifted (build flags, the bridge-eval agent, fetch-bridges.sh,
  netavark); until Task 1.2 the hardened Linux installer also rewrote every
  NetworkManager connection profile's DNS and never restored it.
- Before Task 1.2: Linux reinstall and uninstall wrote 9.9.9.9, 1.1.1.1 and
  1.0.0.1 into /etc/resolv.conf for the rest of the install (DEC-002's
  accepted window); macOS set every service to `Empty`; uninstall restored
  nothing; Linux pinned without a readiness check; macOS pinned before the
  controller installed.
- The macOS helper boots out and re-bootstraps Mullvad on the agent's
  `pre`/`post` (mac/start-container-root.sh:216-220). That is VPN state the
  installer does not own (ARCH-06); the installer itself never calls `pre`.
- Unbound remote control is a Unix socket at `/run/unbound/control.sock`
  with no keys and no network listener (unbound/etc/unbound.conf:166-169).
  Neither image carries control keys; the hardened-unbound base no longer
  generates them at build [SEC-CONTROL-LOCAL]. The anchor is on a volume
  (WF-DNS-001).
- Since Sub-plan 4 Task 2.1 each deployment has its own Pi-hole admin
  password, in `~/.local/state/nice-dns/secrets/pihole/pihole_webpassword`
  (directory 0700, file 0600). Preparation generates it once or keeps it,
  and refuses a symlink, another owner, a file others can read, an empty
  or a multi-line file rather than replace it (lib/install.sh:330-369;
  install-deb.sh:63, install-deb-hardened.sh:84, install-mac.sh:106,
  install-mac-hardened.sh:121). Linux hands it to podman by path as the
  secret `nice-dns-pihole-webpassword` (lib/install.sh:361), which the
  quadlet mounts for uid 1000 (deb/quadlet/pi-hole.container:33-34).
  macOS mounts the directory read-only at /run/secrets at both launch
  sites (lib/install.sh:2154-2167, mac/start-container.sh:471-484). Both
  images read it through `WEBPASSWORD_FILE` and refuse to start when it is
  missing, unreadable or empty (pihole/nd-start.sh:30-38; the
  hardened base's start.sh, pi-hole-hardened 4574d52). Uninstall removes
  it (lib/install.sh:372-378). Before Task 2.1 the hardened image served
  the admin API with no password and the standard image printed a random
  one to its log on every start [SEC-ADMIN-AUTH] [PRIV-NO-SECRETS].
- Capabilities are per image (deb/persistent-podman.sh:96-97): the standard
  image drops all and adds back nine
  (deb/quadlet/pi-hole-standard.conf:13-14); the hardened image keeps
  NET_BIND_SERVICE with no-new-privileges
  (deb/quadlet/pi-hole-hardened.conf:11-13). macOS runs the standard set for
  both (lib/install.sh:2159). pihole-FTL runs as uid 1000 in both. Pi-hole's
  NTP server and client are off (pihole/etc/pihole.toml:492, 502, 515), so
  it listens on :53, :80 and :443 only (tests/integration/deployment-security.sh)
  [SEC-LEAST-PRIV] [SEC-LISTENERS].
- Since Sub-plan 4 Task 2.2 each deployment keeps its instance state across
  repair, reinstall, proxy and Pi-hole image switches, failed installs and
  upgrades; only uninstall removes it (lib/install.sh:417-432), and only
  once host DNS was given back: a failed or interrupted restore keeps the
  state, the admin password and the current-generation marker for the retry
  or a reinstall (lib/install.sh:1577-1583, called at lib/install.sh:1566 and
  lib/install.sh:2039) [SEC-OWNED-RESTORE]. Tor state: the Linux volume
  nice-dns-tor-<proxy> (deb/quadlet/tor-haproxy.container:20,
  deb/quadlet/tor-socat.container:16), on macOS
  ~/.local/state/nice-dns/tor-<proxy>, now mounted by the installer's run
  too (lib/install.sh:2176, mac/start-container.sh:520). The root anchor:
  WF-DNS-001. The operator's Pi-hole lists (user decision: lists survive,
  configuration comes from the image): gravity.db on the volume
  nice-dns-pihole-lists (pihole/etc/pihole.toml:946,
  deb/quadlet/pi-hole.container:19, lib/install.sh:2157,
  mac/start-container.sh:474). Each image keeps its build's gravity.db as a
  seed; pihole/nd-start.sh uses the volume as it is while the seed ids
  match and otherwise carries the operator's rows into the new seed
  (pihole/nd-start.sh:47, pihole/merge-lists.sql), keeping the previous
  file. macOS creates its volumes and hands them to the image's user in the
  interruption window (lib/install.sh:399-414, lib/install.sh:2011):
  Apple's volumes start root-owned and empty. Checked per entrypoint by
  tests/integration/lifecycle-transitions.sh, whose failed steps must leave
  the previous deployment exactly as it was [SEC-OWNED-RESTORE].
- All four entrypoints refuse to run as root
  (install-deb.sh:13, install-deb-hardened.sh:34,
  install-mac.sh:13, install-mac-hardened.sh:31). The
  macOS agent may run only three helper verbs under sudo
  (mac/start-container.sudoers:7); the installer verbs (snapshot, check,
  restore, status, discard) run under the operator's own sudo.

### Platform notes

- Linux: persistence comes from Podman quadlets under
  `~/.config/containers/systemd` (deb/persistent-podman.sh:91-98) and linger
  (deb/persistent-podman.sh:51-52). The resolver pin is a system oneshot
  (deb/custom-dns-deb.service:6-9).
- macOS: persistence comes from the start-container LaunchAgent installed by
  `mac/persist.sh` (mac/persist.sh:60-75) and helpers in `/usr/local/sbin`
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
- Linux boot selection: `nice-dns-fetch-bridges.service` runs bridge-eval
  in manage mode inside the tor image (deb/persistent-podman.sh:175-179). It
  is a oneshot with `RemainAfterExit=yes` (deb/persistent-podman.sh:165). It
  also runs at install (deb/persistent-podman.sh:303).
  - Since Sub-plan 3 Task 2.2, an `ExecCondition` skips it while
    `bridges.env` holds 3 or more valid bridges
    (deb/persistent-podman.sh:162). Selection therefore stays out of
    startup's critical path when a usable set exists.
- Daily refresh since Task 2.2 (BL-019): the controller's
  `nice-dns-health-bridges.timer` (`OnCalendar=daily`, `Persistent=true`;
  health/nice-dns-health:641) runs `nice-dns-health bridges-refresh`.
  - The image's bridge-eval writes a candidate, never `bridges.env`
    (lib/platform/linux.sh:167-173). It runs outside the state lock, under
    a refresh mutex (lib/recovery.sh:891-919).
  - nd_bridges_apply (lib/recovery.sh:831-870) holds the lock:
    - a candidate with fewer than 3 valid lines is not applied, so the last
      good set stays;
    - normalized equal sets write nothing;
    - `bridges.env` is replaced only if it still holds the set the
      evaluation started from, so a slow run never overwrites a newer one;
    - a changed set is written atomically (0600, `.prev` kept) and restarts
      nothing.
  - The proxy reads the new set at its next natural start. During a
    sustained failure, the Tor restart adopts it through the service restart
    (lib/recovery.sh:924-938, lib/recovery.sh:638-655).
- Exit 1 is tolerated (deb/persistent-podman.sh:183). A missing `BRIDGE1`
  fails loudly (deb/persistent-podman.sh:189).
- The Linux proxy reads `bridges.env` through `EnvironmentFile=` at
  container start (deb/quadlet/tor-haproxy.container:28). A changed selection
  takes effect only on the next container start.
- Health recovery re-evaluates with nd_bridges_refresh, at most once an
  hour, once an observed outage has outlasted the grace
  (health/nice-dns-health:473-489).
  - Until Task 2.2 it ran the raw Moat fetcher
    (deb/persistent-podman.sh:140), which writes an unranked pool into the
    same `bridges.env` (scripts/fetch-bridges.sh:49-51) and could replace an
    evaluated set.
  - The fetcher remains only the installers' and the boot path's source
    when no usable set exists.
- The Linux tor quadlet declares no `Volume=` for Tor data
  (deb/quadlet/tor-haproxy.container:12-28). Whether Tor state survives
  container recreation on Linux is baseline: unverified (ARCH-06).
- macOS daily refresh since Task 2.2: the controller's
  `org.nice-dns.health-bridges` agent (a daily `StartCalendarInterval`,
  which runs on wake; health/nice-dns-health:705). Its probe container runs
  only on `dnsnet`, only while pi-hole, unbound and the proxy run on
  .250/.251/.252, and it holds the start-container agent's stack lock while
  the probe container exists (lib/platform/macos.sh:263-307).
  - `mac/persist.sh` no longer installs the legacy `org.nice-dns.bridge-eval`
    agent. It retires that agent after the controller installs
    (mac/persist.sh:79).
  - Before that, the legacy agent had `RunAtLoad` and `StartInterval` 86400
    (mac/org.nice-dns.bridge-eval.plist:17-19) and wrote `bridges.env`
    directly. It ran on `dnsnet`, and only
  after the stack is up on its own addresses (mac/bridge-eval.sh:102-117). It
  holds the stack lock while its probe container exists
  (mac/bridge-eval.sh:119-135), and it runs the probe on `dnsnet`
  (mac/bridge-eval.sh:153-160). It redacts `cert=`
  in its log (mac/bridge-eval.sh:162). It keeps the existing file on failure
  (mac/bridge-eval.sh:171-174).
- The macOS LaunchAgent refetches only when the pool is missing or
  incomplete (mac/start-container.sh:155-168, mac/start-container.sh:598-606).
  Until the Stage 2 gate it also refetched after a failed bootstrap, writing
  over a usable set without the controller's lock, base check or `.prev`;
  now it keeps the set, and re-selection is the controller's evaluated
  refresh.
  It recreates Tor only when the bridge fingerprint changed
  (mac/start-container.sh:500-516). On a change it drops the guard sample
  and keeps the cache (mac/start-container.sh:121-123). Tor's DataDirectory
  persists (mac/start-container.sh:42, mac/start-container.sh:520).
- The macOS installers run the fetcher without `--force`
  (lib/install.sh:1861). They require at least three bridges
  (lib/install.sh:1881-1884). Since Sub-plan 4 Task 1.1 both pass every
  BRIDGEn to the proxy; the hardened one used to pass only BRIDGE1 and
  BRIDGE2.

### Platform notes

- Linux: bridge-eval runs host-side through `podman run --userns=keep-id`
  (deb/persistent-podman.sh:175). The target adds a daily timer and keeps
  the out-of-band selection model.
- macOS: a second container on another vmnet network wedges `dnsnet`
  (mac/bridge-eval.sh:77-90). Selection must stay on `dnsnet`.
