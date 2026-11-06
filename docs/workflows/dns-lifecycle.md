# nice-dns DNS lifecycle workflows

Behavior contracts for the nice-dns stack. Sub-plan 01, Task 1.1 of the
2026-09-19 stability, latency and security plan.

- Contract sources: the approved design and architecture (ARCH-01 to ARCH-09)
  in the vault at `Portfolio/containers/nice-dns/plans/2026-09-19-stability-latency-security-*.md`.
- Baseline source: this repository at commit
  `bc5faf3bc85ea528d67acd023e3df6110a0cb731`. Citations are `path:line` at that commit.
  The eight-cell baseline receipt measured b85bc9b. The document was first
  written against 337fb15; sub-plan 01 then landed product fixes (c8ecd70,
  fcc3f6c, fc5e6ec, b85bc9b), and the citations were re-derived. Sub-plan 02
  re-pins after each change to a cited file (Task 1.1: 04b98cf, Unbound
  anchor and control; Task 1.3: d6c1a1f, Pi-hole HealthCmd; Stage 1 gate: 80d6c18, control refusal; Task 2.1: 9e71d32, route include; Task 2.3: bc846b2, Unbound WORKDIR; Stage 2 gate: 94a9c60, route resolution check). Sub-plan 03 re-pins the same
  way (Task 1.1: ba144fd, health observations and platform adapters; Task 1.2: e81697f, state directory and boot identity appended to the platform adapters; Task 1.3: 6bf29f3, acknowledged recovery; Stage 1 gate: 4b11779, one controller pass; 20589e8, route recorded on success; Task 2.1: 3a4b4d6, bundle and minute schedules; Task 2.2: d934ed5, bridge lifecycle; Task 2.3: b8b9bb8, shadow install and privacy-safe failure dump; 93a9122, macOS exec reports a missing executable as 127; 674635f, the macOS fallback always rebuilds; 8f10ffe, it rebuilds the whole stack; e6436ad, restart ladder; dca5b57, a stopped macOS container has no generation; Stage 2 gate: 969945e, bridge refresh ownership; 5de0e7d, policy timers from tunables.tsv; close-out: a4eea01, the ladder waits out the first restart's readiness; ca16537, quadlet health checks verify and only report, Wants= not Requires=; c55ea50, probe-route bounded; 778df19, a failed macOS kickstart withdraws its request; 5dff7b7, a Linux adapter comment; 0efca9c, the macOS proxy lookup honours the recovery deadline; pre-merge review: 16d65cb, a runtime fault the platform cannot repair escalates). Sub-plan 4 re-pins the same way (Task 1.1: 509a6de, shared installer preparation in lib/install.sh; 7019cf0, the macOS hardened pi-hole build has no --pull; fdf6179, a first install migrates podman before its builds; Task 1.2: ec2b51c, owned DNS receipts and transactional cutover; Task 1.3: 495241e, immutable release inputs; Stage 1 gate: 58e6472, restores that cannot half-fail; Task 2.1: 57db2a3, private admin credential, host-only DNS, least privilege; Task 2.2: 3148e14, instance state kept across the lifecycle; Task 2.3: 66f1666, legacy profile pins restored and the macOS stack started on a fresh datapath; Stage 2 gate: 3fab8dd, the macOS cache flushed after each resolver change; 7a403df, uninstall removes instance state only after DNS is given back; 66cd340, a macOS rollback stops the builder and restarts the runtime). Sub-plan 5 re-pins the same way (Task 1.2: 3c0308f, Unbound mounts the host route directory and the installers seed it; 0be8182, an unmountable route path fails in preparation; Task 1.3: eaa31a3, a fresh proxy falls back to an exit route; Task 1.4: adf3c1b, a fresh proxy starts Unbound on the exit route; Stage 1 gate: 0e2d2ba, Unbound starts once its route answers, a failed switch keeps the proxy generation, the quadlet is written by rename, the uninstall removes only its own route files; round 2: 6364176, the controller refuses the request id "suspend"; fc63139, a refused route probe ends Unbound's wait at once; Task 2.1: 4acf446, macOS scoped DNS stays on the container bridge; Task 2.2: 3637314, a refresh leaves out bridges that carry streams badly and adopts the set when the running proxy uses one; 34f1d0b, the controller remembers a weak bridge for 30 days; 733cfb1, that memory is written under the controller's pipefail; aa6b7e9, the Linux boot selection's skip really skips). The 2026-10-12 Mullvad findings plan re-pins the same way (Task 1.1: dacb3b4, the installers' comments no longer name the process-substitution one-liner; Stage 1 gate: 13ddba8, Linux builds without --dns, declared resolver literals, the installer drives Mullvad's DNS setting; round 1: 5162e17, Mullvad restore paths and the claims the switch made false; Stage 2 gate: c0af48f, per-device IPv6 hook and install drift; round 1: aeb5494, drift that fails closed; Task 3.1: no cited file changed after aeb5494, contract text written for Mullvad's DNS setting, the per-device IPv6 hook and install drift; Stage 3 gate round 1: 0a90f99, Ethernet and Wi-Fi profiles get ipv6.method disabled, recorded and given back; round 2: 0e4570d, the profile change given back on every path and NetworkManager not answering never read as an answer; round 3: 6ae55f9, no leftover undo list, an uninstall without NetworkManager completes). The 2026-11-05 bridge refresh fix re-pins the same way (774182a, bridge-eval runs as the container's root, not under keep-id). The 2026-11-05 restart policy plan re-pins the same way (Stage 1 gate round 1: d1b1f77, container observations, unit back-off, Pi-hole's check only reports; Stage 2 gate round 1: e3963df, the Pi-hole rule, the paused repair, the crash-loop hold; Stage 3: 0ab8019, awk patterns mawk runs, a frozen Pi-hole's pi.hole timeout counts, the macOS per-container restart not qualified; Stage 3 gate round 1: 5090f6d, only a pi.hole timeout holds Pi-hole's streak; close-out: ae4e67c, a crash loop holds the stack restart for at most 30 minutes). The 2026-11-05 status and update plan re-pins the same way (Stage 1 gate round 1: 8fda2a6, each pass keeps its observations; status reads files only; Task 2.3: 2438546, `nice-dns update` and WF-DNS-005; Stage 2 gate round 1: bc5faf3, the update contract). `check-contracts` fails when a cited file changes
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
- On Linux, IPv6 is off on every host device, set per device each time the
  network stack activates it, not only through `all` and `default`. The
  address family stays: never the kernel's `ipv6.disable=1`, which left
  Mullvad blocked on every boot (incident 2026-07-10, DEC-020). One window
  remains, link-local only: a device whose NetworkManager profile the
  install did not change (a profile made after the install, an in-memory
  external profile such as NetworkManager's own "Wired connection 1", a
  type other than Ethernet or Wi-Fi, or a profile that refused the change)
  sends MLD reports and a duplicate-address check from `::` to ff02::/16 at
  each activation, before the hook switches it off.
- On Linux, a host :53 publish off loopback is detected at runtime and
  reported as security drift (WF-DNS-002) [SEC-LISTENERS].

### Current baseline (observed in source)

- Pi-hole forwards only to Unbound. dnsmasq has `no-resolv`
  (pihole/etc/dnsmasq.conf:27) and `server=127.0.0.1#5335`
  (pihole/etc/dnsmasq.conf:33). FTL upstreams are `127.0.0.1#5335`
  (pihole/etc/pihole.toml:12-14). The Linux quadlet sets
  `DNS1=127.0.0.1#5335` (deb/quadlet/pi-hole.container:39).
- On macOS the installer and LaunchAgent override the upstream to
  `172.31.240.251#5335` (lib/install.sh:2669-2670, mac/start-container.sh:500-501).
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
  stub-zone (unbound/start.sh:144-187, unbound/start.sh:331-334)
  [PRIV-NO-DIRECT] [SEC-TLS-NAME].
- Route selection (ARCH-03 `apply_route`): routes/providers.tsv binds each
  route to its port and TLS name (routes/providers.tsv:13-17). The host
  library records the desired route, stages the include, has the image
  validate it (`nice-dns-unbound-start check-route`: the shape above, then
  `unbound-checkconf` on the complete candidate config,
  unbound/start.sh:191-208), keeps the previous include, renames the staged
  file into place, runs `reload_keep_cache` and reads back the
  `nice-dns-route.invalid.` TXT marker through the control socket, then
  resolves through the new forwarder with a fresh TLS session
  (`nice-dns-unbound-start probe-route`, unbound/start.sh:215-243; the cache
  cannot answer it) (lib/recovery.sh:372-432). A route that does not resolve
  is rolled back. A failure after the rename restores the
  previous include the same way; if that also fails the result is
  `escalate` and the forward-zone stays in place. An unchanged route is not
  reloaded. `reconcile_route` finishes an interrupted change
  (lib/recovery.sh:434-460). The Linux adapter uses 127.0.0.1, the macOS
  adapter 172.31.240.252 (lib/platform/linux.sh:15, lib/platform/macos.sh:19).
  Since Sub-plan 5 Task 1.2 (DEC-010) every deployment mounts that host
  directory read-only at /etc/unbound/route: the Linux quadlet
  (deb/quadlet/unbound.container:27, its path filled in by
  deb/persistent-podman.sh:125-132, which renders the unit to a temporary
  file and renames it, after the route directory is checked and seeded, so
  the directory never holds a unit with an unfilled placeholder) and both
  macOS launch paths
  (lib/install.sh:2682, mac/start-container.sh:512), the same directory
  the controller manages (lib/platform/linux.sh:18,
  lib/platform/macos.sh:22). The installers seed it before Unbound first
  starts with an identity route, cloudflare-exit at generation 1, never the
  compat route (lib/recovery.sh:489-501, lib/install.sh:1997,
  lib/install.sh:2515); an include already there is the controller's and
  is kept [PRIV-ROUTE-IDENTITY]. Since Sub-plan 5 Task 1.4 every launch
  path that starts Unbound first runs the controller's launcher
  `<controller root>/route-start`: the quadlet's ExecStartPre
  (deb/quadlet/unbound.container:51, its path filled in by
  deb/persistent-podman.sh:126; deb/persistent-podman.sh:100-106 and
  deb/persistent-podman.sh:129 drop the line with a warning when the path
  cannot go into a unit), the macOS agent before it creates
  Unbound (mac/start-container.sh:477, called at mac/start-container.sh:508)
  and the macOS installer's first run (lib/install.sh:2676). The launcher is
  written at install before any schedule (health/nice-dns-health:807,
  health/nice-dns-health:1135) and runs `route-start`, which acts only for an
  active install (health/nice-dns-health:1110-1112). Under the controller's
  state lock (lib/recovery.sh:551), when the proxy is fresh (its generation
  hash, lib/health.sh:325, differs from the state's proxy_gen or, here only,
  cannot be read, lib/recovery.sh:556; the policy takes an unreadable
  generation as no evidence, lib/recovery.sh:510-514) it demotes a persisted onion include to the seed
  exit at the next generation, desired first (lib/recovery.sh:532-583); an
  exit route, a busy lock, or Unbound restarting alone on a warm proxy keep
  the route. A missing launcher (a controller installed before Task 1.4:
  reinstalled, it writes one) or a failure never blocks Unbound's start.
  Since the Sub-plan 5 Stage 1 gate (DEC-015) the entrypoint then waits
  until the active route returns a DNS response to one authenticated query,
  any rcode, before it execs Unbound (unbound/start.sh:254-279, called at
  unbound/start.sh:337). The wait is bounded by NICE_DNS_ROUTE_WAIT (default
  240 s, under the quadlet's 300 s health start period; 0 turns it off);
  a route that never answers ends it and Unbound starts as before. A probe
  that is refused rather than unanswered (no forwarder line: an unreadable
  tls-cert-bundle, say) ends the wait at once with the refusal logged
  (unbound/start.sh:265-268); Unbound then judges the configuration itself. Until
  then Unbound asked its only forwarder before the proxy carried a stream
  and waited out its back-off: on Linux 2026-09-30 the first answer came
  29-46 s after a restart with the proxy ready after 11-15 s. Proven by
  tests/integration/route-transition.sh; the live effect is measured by
  live tune-transport.
  The image default (the legacy :853 route)
  now runs only in an image started without the mount. A mounted directory
  without a usable include stops Unbound at start rather than falling back
  (unbound/start.sh:332-334). On macOS
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
  allows 172.31.240.248/29 (lib/install.sh:2265-2268), and the route include
  forwards to `172.31.240.252@853` (lib/install.sh:2271-2272).
- Provider identity is bound per route. Each proxy listener names one
  provider and one TLS name (routes/providers.tsv:14-17, DEC-001), and the
  default route authenticates `tor.cloudflare-dns.com`
  (unbound/route/forward-route.conf:17). Before Sub-plan 2 the health script
  described a single endpoint with an onion primary, a 1.1.1.1 backup and a
  9.9.9.9 fallback via Tor exit; a Quad9 backend there would have received a
  Cloudflare-named TLS session. No nice-dns file describes that fallback now.
  That each proxy image keeps a listener to its one provider is baseline:
  unverified here: the proxy configs live in the sibling repos
  [PRIV-ROUTE-IDENTITY]. The health CLI's recovery comment describes the
  single controller pass (health/nice-dns-health:461-512).
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
  (unbound/start.sh:106-136, unbound/Containerfile:39). The entrypoint reads
  the anchor path from the effective config. It seeds a missing anchor from
  the seed. It exits with a `FATAL` message, before Unbound starts, when the
  anchor or its directory is unusable: symlinked, not owned by unbound, not
  writable (including a read-only mount), empty, malformed, or without a
  trusted root key (unbound/start.sh:281-305). [SEC-DNSSEC-ANCHOR]
- Proven on the built images by `integration/resolver-state`. Through a
  controlled signer, the product Unbound sets AD on a signed answer, answers
  an insecure delegation without AD, and returns SERVFAIL for a bogus
  signature whose record `+cd` still retrieves
  [SEC-DNSSEC-SIGNED] [SEC-DNSSEC-UNSIGNED] [SEC-DNSSEC-BOGUS].
  Since Sub-plan 4 Task 2.2 /var/lib/unbound is the volume
  nice-dns-unbound-anchor on both platforms (deb/quadlet/unbound.container:21,
  lib/install.sh:2681, mac/start-container.sh:511), so a new container keeps
  the anchor's RFC 5011 state; until then each one re-seeded from the image.
- Resolver management is a Unix socket, `/run/unbound/control.sock`, with
  `control-use-cert: no` and no TCP listener or key files
  (unbound/etc/unbound.conf:166-169). The entrypoint keeps `/run/unbound`
  owned by unbound and closed to others, and refuses any network
  control-interface while control is enabled (unbound/start.sh:308-328). Unbound
  creates the socket with mode 0660. Operators run
  `podman exec --user unbound unbound unbound-control ...`; other uids are
  refused. The nice-dns image deletes any control keys an older published
  base still carries (unbound/Containerfile:32-34) [SEC-CONTROL-LOCAL].
- Unbound does not use IPv6 (`do-ip6: no`, unbound/etc/unbound.conf:19).
  Linux installs disable IPv6 through a sysctl.d drop-in for `all`,
  `default` and `lo`, then switch off every existing device
  (lib/install.sh:1712-1732). That alone did not hold: NetworkManager's
  activation of a profile with `ipv6.method auto` set the NIC back to 0 on
  every boot (measured 2026-10-12, BL-050). Since the 2026-10-12 Mullvad
  findings plan an owned NetworkManager dispatcher hook,
  `91-nice-dns-ipv6`, with a copy in `pre-up.d`, sets the activating
  device's own `disable_ipv6` to 1 on pre-up, up and reapply
  (lib/install.sh:1705-1707, deb/91-nice-dns-ipv6:45-65). It skips `lo` and
  Mullvad's `*-mullvad` tunnel, which `default` already covers.
  NetworkManager sends pre-up only after it set up IP, and the Stage 3 gate's
  strict capture (2026-10-12) held 5 frames from the NIC across a boot,
  `nmcli connection up` and a NetworkManager restart: MLD reports and a
  duplicate-address check from `::`. So the install also sets
  `ipv6.method disabled` on each Ethernet and Wi-Fi profile stored on disk
  (a keyfile under /etc, or a netplan profile), and NetworkManager then keeps
  the device's IPv6 off itself (lib/install.sh:1733-1740,
  deb/custom-dns-deb:188-265). On the netplan VM NetworkManager kept the
  change in /etc/netplan/90-NM-<uuid>.yaml; after a reboot the profile still
  read `disabled`, and the strict capture across the reboot, `nmcli
  connection up` and a NetworkManager restart held no IPv6 frame (Stage 3
  gate round 1, 2026-10-12). Loopback, WireGuard (Mullvad's tunnel), VPN,
  bridge and in-memory external profiles are never changed, nor is a profile
  set to `ignore`, which never turns IPv6 on. Loopback and Mullvad's tunnel
  are held off by the `lo` and `default` sysctls. Every other profile left
  unchanged, and one made after the install, keeps the activation window
  above; only the hook closes it (DEC-020). An in-memory external profile is the common
  case on a host whose NIC has no stored profile (NetworkManager's "Wired
  connection 1"); turning it into a stored one is not done. No install path
  writes `ipv6.disable=1`; the grub drop-in earlier versions shipped is
  removed (lib/install.sh:1742-1754).
- The Linux pod publishes DNS and the admin UI on the host loopback only:
  127.0.0.1:53 TCP/UDP and 127.0.0.1:8880 (deb/quadlet/nice-dns.pod:17-19)
  [SEC-LISTENERS]. Until Sub-plan 4 Task 2.1 it published :53 with no host
  address, on every host interface, so the host answered DNS for its whole
  network. macOS reaches the stack only over the host-only dnsnet.
  An install from before that change keeps its wildcard publish; the
  controller now reads the installed quadlets and their drop-ins on every
  pass and reports a :53 publish off loopback as `install-security-drift`
  (lib/platform/linux.sh:358-427; WF-DNS-002). It reads declarations: a pod
  not restarted since an edit runs what it ran, and the admin publish is not
  judged.
- Pod members resolve through aardvark, whose upstream,
  `DNS=1.1.1.1` (declared in release/bootstrap.tsv, literal network-dns), is
  set at deb/quadlet/nice-dns.network:5. The stack's bootstrap does not use it: under
  Mullvad custom DNS it is unreachable and the stack still starts and
  answers (measured 2026-10-12; deb/quadlet/nice-dns.pod:7-11). This is
  container-level traffic, not client traffic. Which in-pod processes use it
  at runtime is baseline: unverified [PRIV-BOOTSTRAP-DECLARED].
- The health observations probe fixed public names: `cloudflare.com` and
  `doubleclick.net`, plus `pi.hole` (lib/health.sh:605-607). Route probes pass
  no query name, so the image probe asks its default `.` SOA
  (lib/health.sh:483-536). Its failure dump copies the last 50 log lines of
  every container: `logs --tail 50` on Linux (health/nice-dns-health:360-361)
  and `container logs -n 50` on macOS (health/nice-dns-health:366-367).
  Until Sub-plan 3 Task 2.3 the macOS dump used `--tail`, which Apple
  `container` does not accept, so it held no logs, and it ran
  `container inspect`, whose JSON carries the proxy's BRIDGE environment.
  Now the whole dump passes through redact_bridges, which replaces
  certificates, fingerprints and bridge addresses
  (health/nice-dns-health:303-307, 364) [PRIV-NO-SECRETS]. Whether the log
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
  (mac/start-container.sh:238-246, mac/start-container.sh:720-728).

## WF-DNS-002 Recovery

### Trigger

A scheduled health observation, a start or login, or a wake finds local
service, upstream or runtime degraded.

### Contract (target, per ARCH)

Sources: ARCH-02, ARCH-03, ARCH-07, design "Health and recovery".

#### Steps

1. Once a minute, `observe` takes a bounded reading: local service, DNS
   ownership, runtime, install drift (Linux), authenticated DNS per route, and
   Unbound's own health (its control socket and its route). Each reading is healthy, unhealthy or indeterminate, with a
   duration and a reason.
2. `decide` uses the readings, the history and the time. It returns one of:
   no-op, switch-route, refresh-bridges, restart-component, repair-runtime,
   escalate.
3. One lock covers destructive actions. State is versioned by generation and
   is never sourced as shell.
4. A full upstream outage becomes eligible for action after a 5-minute grace.
   The grace starts after the startup allowance. A 5-minute cooldown separates
   actions. A usable fallback route prevents a Tor restart. The restarts go Tor,
   then the proxy. Past those two the stack restarts every 30 minutes until a
   route answers; the passes between escalate, and the first escalation of an
   outage writes one failure dump (DEC-021).
5. `request_recovery` records a request ID. It then checks for an
   acknowledgement: a new process or container generation. Readiness is a
   separate, later observation.
6. Unbound failing three checks in a row restarts it (`restart-component
   unbound`), outside the startup allowance and the cooldown. A control failure
   always counts. A route failure counts only with an identity route healthy in
   the same pass, since otherwise the probe is telling the truth about the upstream.
   After two restarts it retries every 30 minutes. A healthy reading ends the
   streak; the restart count ends 30 minutes after the last restart, so a flapping
   probe cannot defeat the cap. Past the ladder's cap in a full outage the stack
   restart covers Unbound. Pi-hole follows the same rule (`restart-component
   pi-hole`). A pass fails it when its container record or `local-service` is
   unhealthy, or when `pi.hole` timed out while an identity route answered:
   FTL answers that name itself, and a hung FTL reads exactly so. A timeout
   with no route answering holds the streak; a container record cannot see
   FTL and does not clear it then. Linux restarts Pi-hole alone;
   macOS rebuilds the stack, since a single container restarted there comes
   back at another address (BL-038).
7. A missing container is started by name. A container read paused in two
   passes in a row is unpaused by name (Linux), after two unpauses every 30
   minutes; macOS has no pause and escalates. A container whose unit restart
   count rises is restarting on its own: the cooldown starts from that
   restart, and for 10 minutes nothing restarts it or the stack. Three rises
   in 10 minutes escalate once (`crash-loop: <name>`) with one failure dump.
   The hold lasts at most 30 minutes from the loop's first rise. After that
   the loop's container is still never restarted by name, but a full outage
   or a container that stays missing restarts the stack, then every 30
   minutes, and the loop escalates every 30 minutes while it lasts
   (DEC-021). The units back off by themselves
   (`RestartSteps=5`, `RestartMaxDelaySec=300s`). If its unit last exited 125 or 126,
   the user service manager is re-executed first, and the pod restarts if the
   start still fails, at most once every 30 minutes. The whole repair has a time
   budget. The journal names what ran.
8. If the controller is absent, the last route stays in place and the control
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
- The controller is the one restart owner: no quadlet of Pi-hole, Unbound or
  the proxy restarts on health, and the controller never adds a restart to a
  container that is restarting on its own. A check that could not run (no working exec, or an image
  without the tool) is indeterminate and acts on nothing.
- Install drift is reported, never repaired unattended. A security drift
  (no recorded install generation, or :53 published off loopback) is
  unhealthy and logged at err at most once a day; no action follows from it
  and nothing is re-rendered (DEC-018) [SEC-LISTENERS].

### Current baseline (observed in source)

- Since Sub-plan 3 Task 2.1, both platform installers end by installing the
  controller, and fail when it does not install (deb/persistent-podman.sh:359,
  mac/persist.sh:58-59).
  - `install` builds a versioned bundle, then checks that the new bundle
    loads (health/nice-dns-health:794). Only then does it replace the
    schedule (health/nice-dns-health:780-862).
  - `uninstall` removes only what the install receipt lists
    (health/nice-dns-health:884-907).
  - Until Task 2.1 no installer installed it; it was installed by hand
    (health/nice-dns-health:14).
  - Deployed hosts still carry the older hand-installed copies. What runs
    there is baseline: unverified.
- Schedule: `tick`, every minute.
  - Linux: a systemd user timer with `OnCalendar=minutely`,
    `AccuracySec=5s` and `Persistent=true` (health/nice-dns-health:665-667).
    The service runs `<bash> <entrypoint> tick` with
    `TimeoutStartSec=540`, inside the lock lease
    (health/nice-dns-health:654-656).
  - macOS: the agent's all-wildcard `StartCalendarInterval`
    (health/nice-dns-health:726-727).
  - Observation mode since Sub-plan 3 Task 2.3: `install --shadow` writes the
    same unit or agent running `tick --shadow` (health/nice-dns-health:645,
    628), which records what it would do and never acts, and schedules no
    bridge refresh; a later shadow install stops and removes one
    (health/nice-dns-health:811-816, 746-750). The receipt records `mode`
    (health/nice-dns-health:840) and `status` prints it
    (health/nice-dns-health:934). A plain install activates the same
    schedule in place. Live shadow behavior is baseline: unverified until
    live/controller-shadow runs.
  - Calendar schedules run after a suspend or sleep, whereas monotonic timers
    and `StartInterval` do not (systemd.timer(5), launchd.plist(5)). Behavior
    on live hosts is baseline: unverified until the Stage 2 gate.
- Since the Stage 2 gate the scheduled pass also reads the policy timers
  from an optional tunables.tsv in the install root (allow-listed keys,
  checked like the libraries; the environment wins)
  (health/nice-dns-health:490-508). The live gate uses it for 30 s timers
  in its extra configurations.
- Grace is `ND_POLICY_GRACE_S` = 300, still settable through
  `NICE_DNS_RESTART_GRACE_SECS` (health/nice-dns-health:511). lib/policy.sh
  counts it from the later of the outage's start and the end of the 120 s
  startup allowance. With one-minute passes, a full outage observed from its
  onset becomes eligible for a restart after five minutes, subject to the
  cooldown.
- The checks are the lib/health.sh observations (health/nice-dns-health:227).
  Until Sub-plan 3 Task 1.1 both platforms read /etc/resolv.conf and queried
  `@127.0.0.1`. Now the platform adapter picks Pi-hole's endpoint: 127.0.0.1
  on Linux (lib/platform/linux.sh:36) and 172.31.240.250 on macOS
  (lib/platform/macos.sh:58, mac/start-container.sh:24). DNS ownership is
  resolv.conf naming only 127.0.0.1 on Linux (lib/platform/linux.sh:77-88).
  On macOS, every enabled network service and scutil's resolver #1 must use
  172.31.240.250 (lib/platform/macos.sh:120-157). The macOS path is proven
  with unit fakes built from captured macOS output. Whether it passes on a
  live Mac is baseline: unverified.
- Since the Sub-plan 3 Stage 1 gate, `run` has no outage timer of its own.
  After logging, it hands its observations to the same controller pass as
  `tick` (health/nice-dns-health:540-555, lib/recovery.sh:983-1039). One
  policy, one state, one lock, one cooldown and one restart cap decide
  every action, whichever command the schedule calls. The pass observes,
  decides with lib/policy.sh, acts, and commits the state. Readiness
  (ready or not-ready) is recorded on a later pass. A restart acts only on
  an outage observed in that same pass.
- Before the pass, and outside the lock, the bridges are re-evaluated
  (nd_bridges_refresh) once an observed outage has outlasted the grace. This
  happens at most once an hour (health/nice-dns-health:522-538). Since the
  Stage 2 gate it runs before the pass observes, so the decision never rests
  on observations older than the evaluation. Nothing in
  the controller writes `bridges.env` directly (WF-DNS-004).
- Restart ladder since Sub-plan 3 Task 2.3: the first restart of an outage
  is Tor's (below); a later one of the same outage targets the proxy, the
  service restart directly (lib/policy.sh:627). Since the close-out the later
  step also waits ND_POLICY_LADDER_S (660 s) after the first, the first
  restart's readiness window plus a minute (lib/policy.sh:622-623), so it
  never recreates a Tor that is still bootstrapping. Live on the Mac, a wedged
  runtime made two in-image restarts acknowledge and never become ready; only
  the stack rebuild repairs it.
- Fresh proxy since Sub-plan 5 Task 1.3 (ARCH-04's startup rule): each pass
  observes the proxy container's generation (`proxy`, a hash of the
  platform's container generation, lib/health.sh:261, run at
  lib/health.sh:602) and the state keeps it (`proxy_gen`,
  lib/state.sh:160). A new boot, or a generation that differs from the
  recorded one, restarts every route streak and drops a selected onion
  route (lib/policy.sh:328-339), so the pass selects the preferred healthy
  exit and the onion returns only after its sustained streak. An exit route
  stays selected; no proxy record, or an indeterminate one, is no evidence
  of a restart. Until then the last route stayed selected across a boot and
  a stack restart went unseen: measured on mint 2026-09-28, cold names after
  restarts took p50 691 ms on the kept onion against 309 ms on the exit.
  A switch that was tried and failed keeps the previous proxy generation
  in the state too (lib/recovery.sh:1018-1032), so the next pass finds the
  proxy fresh again and decides the switch again; before the Sub-plan 5
  Stage 1 gate the failed pass recorded the new generation and the dropped
  onion stayed selected in the state (BL-023).
  Since Task 1.4 the generation comparison also runs before Unbound starts
  (lib/recovery.sh:532-583, see WF-DNS-001; there an unreadable generation
  counts as fresh, in the policy it is no evidence), so a restart no longer waits
  for the next pass on a cold onion: measured on the mac 2026-09-29 before
  it, a restart on the kept onion answered after 56 s and the pass moved to
  the exit 46 s after the restart.
- Runtime faults: repair-runtime acts only on a fault the platform can
  repair (lib/platform/linux.sh:204, lib/platform/macos.sh:280); any other
  escalates at once (lib/policy.sh:514-515). Rootless Podman has no daemon
  to restart, so Linux escalates runtime-down. Before the pre-merge review
  it re-issued an unsupported repair every cooldown and never escalated.
  Since 2026-10-31 (DEC-021) three repairs of missing containers with no
  healthy reading lead to a stack restart, at once and then every 1800 s, and
  the passes between escalate. Before that, each repair reset the cooldown, so a
  container that stayed missing never reached the stack restart. runtime-down
  keeps its repair: a stack restart needs the runtime.
- Unbound (since 2026-10-30, DEC-021). The observation is lib/health.sh:548-587:
  a control call past its deadline is Unbound's own failure only while a plain
  exec in the container answers. Measured on mint with SIGSTOP: control hangs,
  probe-route passes, exec answers in 0 s. The rule is lib/policy.sh:426-446 and
  the action lib/policy.sh:554. The restart is nd_recovery_restart_unbound
  (lib/recovery.sh:795, lib/platform/linux.sh:180, lib/platform/macos.sh:257): a new
  container start is the acknowledgement, a later healthy observation is readiness.
  A timed-out control call stays in the container until that restart, because a
  deadline stops only the local client: at most about 30 in a retry interval.
  On Linux it is unbound.service alone; on macOS it rebuilds the stack (BL-038).
- Past the restart cap (since 2026-10-30, DEC-021) a full outage restarts the stack
  every `ND_POLICY_RETRY_S`, 1800 s (lib/policy.sh:611, lib/recovery.sh:803,
  lib/platform/linux.sh:194, lib/platform/macos.sh:264). The first escalation of an
  outage writes one dump (health/nice-dns-health:1156, lib/recovery.sh:808).
- A missing container is started by name since 2026-10-30
  (lib/platform/linux.sh:226): `start pi-hole.service` did nothing while Pi-hole ran.
  Exit 126 from a stale systemd/private and exit 125 from a reset podman were
  reproduced on mint; `daemon-reexec` and a pod restart repaired them with no reboot.
  What made the socket stale on 2026-10-29 is baseline: unverified.
- The Tor restart is nd_recovery_restart_tor (lib/recovery.sh:862-879):
  - A refreshed bridge set may be waiting for a proxy that has not been
    recreated. Then the restart goes straight to the service restart, which
    reads the new set. The in-image restart would keep the old environment.
  - `request_recovery tor` writes the request into the proxy image's
    `/app/data/control` (lib/recovery.sh:659-710). It counts as done only on
    the image's answer with a newer Tor generation and a different pid
    (lib/recovery.sh:703) [REC-ACK-READINESS]. The ids "legacy" and
    "suspend" are refused (lib/recovery.sh:642-645): the image answers with
    them for restarts it made itself.
  - When that answer does not come, or the image cannot give it, or the
    proxy is unreachable, one service restart follows
    (lib/recovery.sh:736-765). It counts only when the container comes back
    with a new start. On Linux it restarts the proxy alone with
    `systemctl --user restart tor-<variant>.service`
    (lib/platform/linux.sh:172). On macOS it is `launchctl kickstart -k` of
    the start-container agent, which recreates the whole stack
    (lib/platform/macos.sh:243).
  - The in-image restart keeps Tor's data. The service restart recreates
    the `--rm` container, which loses it until a volume is mounted
    (Sub-plan 4).
  - The deployed Mac's published proxy image has no `/app/data/control`
    (observed 2026-09-25), so there the request is unsupported and the
    stack restart runs.
  - Since Sub-plan 3 Task 1.3, the old `touch /tmp/tor-restart-flag`,
    logged as "triggered" without any answer, is gone.
- Every action holds the state lock (lib/state.sh:232). Before each change,
  the action checks the lock again (lib/recovery.sh:649). Its waits are
  bounded in wall-clock seconds.
- A Tor restart is ready when an identity route answers and Unbound
  resolves over its TLS-verified route, which is host-side evidence the
  proxy cannot forge (lib/recovery.sh:937-973, DEC-006). An Unbound image
  without nice-dns-unbound-start gives "ready, uncorroborated" (exit 126 or
  127). Since Sub-plan 3 Task 2.3 the macOS adapter reports Apple container's
  missing executable (exit 1) as 127 (lib/platform/macos.sh:30-38). Before
  that, a working restart on macOS was never ready (live run
  20260925T200235Z-e3b4de89).
- The schedules still call `run`; Sub-plan 3 Task 2.1 moves them to `tick`.
- On macOS the start-container agent and bridge-eval share a `mkdir` stack lock
  (mac/start-container.sh:68, mac/start-container.sh:317, mac/start-container.sh:606).
  A holder whose stored PID fails `kill -0` is taken over. After a crash, a reused
  PID in that persistent state file blocks the start for up to 600 s. Two waiters
  can also both take over a dead holder. lib/state.sh now provides the
  controller lock (boot, pid and lease staleness, compare-and-delete;
  lib/state.sh:232). mac/start-container.sh moves to it with the installed
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
  authenticated probe and at least one fails (health/nice-dns-health:259-261,
  lib/health.sh:483-536). The Pi-hole answer is a separate `local-cache`
  observation (lib/health.sh:429-433). unit/observations proves the split
  with fakes; on live hosts it is baseline: unverified.
- Linux container health checks, since the Sub-plan 3 close-out, verify the
  chain and only report. The proxy runs the image's route probe through Tor
  (deb/quadlet/tor-haproxy.container:64, deb/quadlet/tor-socat.container:29).
  Unbound needs its control socket to answer and its route to resolve in a
  fresh authenticated session, bypassing the cache
  (deb/quadlet/unbound.container:37). Both use `HealthOnFailure=none`
  (deb/quadlet/tor-haproxy.container:71, deb/quadlet/unbound.container:43):
  the controller is the one actor that restarts them for a chain fault.
  Before, they were `nc -z` port checks that Podman restarted on: green
  through Sub-plan 1's live Tor freeze while Podman restarted Unbound and
  Pi-hole instead. Pi-hole's check is a `pi.hole` lookup that needs an answer
  line (deb/quadlet/pi-hole.container:41). Since the 2026-11-05 restart
  policy plan it only reports too (deb/quadlet/pi-hole.container:52), and
  the controller owns Pi-hole's restart (lib/policy.sh:465-491,
  lib/recovery.sh:799): the service alone on Linux
  (lib/platform/linux.sh:188-190), the stack kickstart on macOS
  (lib/platform/macos.sh:259-261). A paused container is unpaused
  (lib/policy.sh:449-463, lib/platform/linux.sh:229-238), and a crash loop
  escalates once while the controller holds its own restarts, for at most
  30 minutes, after which the stack restart follows DEC-021
  (lib/policy.sh:516-522). Every container unit backs off between restarts
  (deb/quadlet/pi-hole.container:62-63, deb/quadlet/unbound.container:59-60,
  deb/quadlet/tor-haproxy.container:81-82, deb/quadlet/tor-socat.container:44-45).
  Live on mint and the mac, 2026-11-05 (container-faults receipt
  20261105T190652Z-fbcf098f): a frozen Pi-hole, a paused Unbound, a crash
  loop and a stopped Unbound each recovered with no human action.
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
  through Tor (mac/start-container.sh:182-213, mac/start-container.sh:659-663).
  Until then a warm cache satisfied it (mac/start-container.sh:652-658): live,
  with Tor frozen, the controller's service fallback was answered "stack
  already healthy" twice and never restarted the proxy. A restart the
  controller decides always rebuilds: nd_platform_restart_proxy leaves
  restart-requested, which fast_path_ok consumes, and a failed kickstart
  withdraws it (lib/platform/macos.sh:243-252),
  and keep_running_stack then refuses to leave the stack alone, so the whole
  stack is rebuilt (a second live run had stopped at "leaving it alone").
  Until Sub-plan 4 Task 1.2 the macOS installers waited on the same
  Pi-hole-only check before pinning DNS; the installers' readiness wait now
  also requires Unbound to resolve over its authenticated route
  (lib/install.sh:965-980).
- A wedged datapath is detected by a probe between containers
  (mac/start-container.sh:279-288). The fix is a runtime restart
  (mac/start-container.sh:672-680).
- The stack is rebuilt once only when Tor never bootstrapped
  (mac/start-container.sh:765-775). If the chain is unhealthy but Tor did
  bootstrap, the script exits without pinning DNS
  (mac/start-container.sh:754-764). "Bootstrapped" is the image's line
  `Tor bootstrapped successfully`, read from the container's log
  (mac/start-container.sh:132-134). Since Sub-plan 5 Task 1.4 the proxy
  images print it only once a SOCKS stream through Tor works, to the exit
  resolver or the onion (tor-socat 69efd1f, tor-haproxy 0aa5063: probes in
  the background, Tor's log kept on the data volume with the previous
  run's; tor-socat d183207, tor-haproxy ba35ab5: the restart watcher starts
  before that wait, so a controller restart request during it is
  acknowledged; tor-socat 4ce8bd3, tor-haproxy 853a92b: after a host sleep that froze
  the container VM, wall time minus uptime grows, and a tor that has run at
  least 120 s (by uptime since its spawn, so a wall clock step adds none and
  an unknown age keeps tor; tor-socat 2e0623d, tor-haproxy c0481ca, which
  also keep the watcher alive without a generation file)
  whose exit and onion streams both fail within 6 s, once a bridge accepts a
  TCP connect, is respawned and acknowledged as request "suspend"; a native
  Linux suspend is not seen; measured on the Mac 2026-10-01: after a 60 s
  sleep no stream for 10-20 s, a respawned tor carried one about 1 s after
  it started), proven on images built from those commits
  (tests/fixtures/transport.sh, integration transport-socat and
  transport-haproxy). Before, the line followed Tor's "Bootstrapped 100%",
  which Tor reports from cached state: on the Mac 2026-09-29 it came 2 s
  after a start and no circuit worked for about 2 minutes. The images
  pinned in release/images.lock (tor-socat v2.12, tor-haproxy v2.16 since
  2026-11-06) carry those commits.
- Since the 2026-10-12 Mullvad findings plan each pass also reads the
  install (BL-045). The Linux `install-drift` observation
  (lib/health.sh:349-361) asks the platform adapter
  (lib/platform/linux.sh:410-427). The adapter reads files only. It is
  unhealthy with a reason starting `install-security-drift:` when no
  generation is recorded or the installed quadlets declare :53 off
  loopback, and indeterminate while an install is under way. No policy reads
  the observation (lib/health.sh:47-54). The pass logs a security drift at
  err, to syslog and the rolling log, at most once a day per reason
  (health/nice-dns-health:1046-1059, called at health/nice-dns-health:1210).
  `nice-dns-health status` prints the generation, source commit, lock, each
  container's image against the generation's and the :53 publishes;
  `nice-dns-health drift` prints the same and exits 0 current, 1 drift (an
  image off the generation's or not running), 2 security drift, 3 not
  checked (health/nice-dns-health:997-1040). Both read files and
  `podman inspect` only: nothing re-renders or restarts (DEC-018).
  The pass's report reaches only a host whose controller came from an
  install with this change, and that install records a generation; an
  install from before generations, often with no controller at all, reports
  nothing until it is reinstalled, and only `drift` run from a current
  checkout reads it by hand [SEC-LISTENERS].

### Platform notes

- Linux: scheduling comes from systemd user units and quadlet
  `Restart=on-failure` (deb/quadlet/tor-haproxy.container:74). The target is
  one installed controller entrypoint that the timer calls (ARCH-03).
- macOS: the LaunchAgent is the only start-time recovery path. It uses sudo
  for a fixed set of helper verbs only (mac/start-container.sudoers:7). The
  target must include post-wake scheduling. Timer intervals that match
  across platforms do not prove the same wake behavior (ARCH-07).

## WF-DNS-003 Install and restore

### Trigger

An operator runs `install-deb.sh`, `install-deb-hardened.sh`, `install-mac.sh`
or `install-mac-hardened.sh` with a variant, a reinstall, or `uninstall`; or
the `nice-dns` command, which runs those scripts.

### Contract (target, per ARCH)

Sources: ARCH-06, ARCH-08, design "Installers and persistence".

#### Steps

1. Prepare: fetch or build images from recorded immutable inputs. Validate
   them before touching the working DNS.
2. Snapshot only the DNS state the installer owns. This includes
   platform-specific settings and symlinks, and on Linux each device's IPv6
   switch and the `ipv6.method` of each Ethernet and Wi-Fi profile the
   install disables (DEC-020). It excludes unrelated VPN and network
   configuration, with one exception: Mullvad's DNS setting (step 6).
3. Activate the candidate. Test the deployed DNS path. Switch the host
   resolver only after readiness.
4. On failure, restore the prior working deployment and the owned-state
   snapshot. Uninstall restores the snapshot exactly; a setting another
   owner changed since is left alone and named.
5. Keep Tor state, operator settings, credentials and resolver cache across
   repair and upgrade.
6. Linux with Mullvad installed: record Mullvad's DNS setting before any
   change. Switch it to Mullvad's default only when a loopback-only custom
   setting has nothing answering and no stack runs, so preparation can
   resolve. Set it to custom 127.0.0.1 right after the pin, and verify the
   pin once Mullvad's own rewrite has settled. A rollback or a failed
   preparation restores the setting this install found. Uninstall restores
   the setting from before nice-dns, while the setting is still custom
   127.0.0.1. A setting that cannot be read stops the install before any
   change (DEC-019).
7. A successful install publishes the `nice-dns` command and keeps its source
   under `~/.local/share/nice-dns/source`, each by rename, so a failed install
   leaves the earlier copies. If the command's directory is off `PATH`, the last
   line of the output says how to add it; no shell profile is edited. An
   uninstall that gave host DNS back removes both last. One that did not keeps
   them for the retry.
8. `nice-dns reinstall` takes the variant, flavour and branch from the current
   generation's manifest; flags override them. A checkout uses itself. The
   installed command clones the branch, and a failed clone changes nothing and
   names `--local`, which uses the kept source. A branch named with `--branch`
   always comes from a clone, because an install script in a checkout ignores
   its branch argument. Nothing recorded means not installed. `nice-dns update`
   is this step gated by a check (WF-DNS-005): it runs only when the recorded
   branch has a newer commit than the recorded clean source commit (or with
   `--force`), always from a clone of that branch, with the same choices.
9. `nice-dns restart` holds the controller's schedules, waits for its state lock
   so a pass already running cannot overlap, restarts the stack, waits for the
   restart to be done (on macOS the agent has taken the request and finished, so
   the old stack cannot answer for the new one), then waits for DNS. The schedules
   are released on every exit, including a signal. It runs no resolver command;
   on macOS the agent's rebuild re-pins DNS and bounces Mullvad, as it does for
   the controller.

#### Invariants

- No lifecycle step points the host resolver at public DNS
  [PRIV-NO-HOST-PUBLIC] [PRIV-NO-DIRECT].
- Only owned state is changed, and it is restored exactly
  [SEC-OWNED-RESTORE].
- Build and bootstrap network use is declared and never becomes a client
  path. Every public resolver written into the product is declared; Linux
  builds name none and resolve through the host's resolver
  [PRIV-BOOTSTRAP-DECLARED].
- Every root-run file and setting the installer changes is owned. The
  uninstall removes or restores it, or leaves one another owner changed
  since and says so [SEC-OWNED-RESTORE].
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
  (deb/custom-dns-deb:369, mac/start-container-root.sh:69). One other
  writer on a Linux host with Mullvad: Mullvad itself, while the install
  has switched it to its default DNS (step 6; the Mullvad baseline below).
  No installer code names resolv.conf or network-service DNS, and the
  helpers name no public resolver; a static case checks both
  (tests/integration/dns-transaction.sh) [PRIV-NO-HOST-PUBLIC].
- Before any work, an install refuses (exit 3) when another owner changed
  host DNS after nice-dns pinned it
  (lib/install.sh:710-746): Linux compares
  /etc/resolv.conf against the pin (deb/custom-dns-deb:393-402);
  macOS compares every service the record knows
  (mac/start-container-root.sh:201-220). A service added after
  the install is not a refusal.
- The record is taken once, before the first interruption, in a root-only
  directory, 0600, and kept across reinstalls, so it stays the state before
  nice-dns (deb/custom-dns-deb:404-450,
  mac/start-container-root.sh:165-199). Linux records
  resolv.conf (symlink target, file copy and mode, or missing),
  systemd-resolved's enabled and active state and the ipv6 sysctls; macOS
  records each service's servers. An install from before records is
  `legacy`: its state before nice-dns is unknown [SEC-OWNED-RESTORE].
  Since the 2026-10-12 Mullvad findings plan a Linux first install also
  records each device's own `disable_ipv6` in `ipv6-devices.tsv` beside the
  record, only while no nice-dns switch is in force (lib/install.sh:1697-1704,
  deb/91-nice-dns-ipv6:52-64). The hook and its `pre-up.d` copy are owned
  files (deb/custom-dns-deb:57-66), and the restore gives each recorded
  device its value back after the hook is gone
  (deb/custom-dns-deb:75-89, deb/custom-dns-deb:535). Each Ethernet and
  Wi-Fi profile the install disabled has its method recorded in
  `ipv6-profiles.tsv`, beside the record and only while the record exists:
  the method found at the first install, or one the owner set since, which
  a reinstall finds in place of `disabled` (deb/custom-dns-deb:205-276). The
  restore puts the recorded method back while the profile still reads
  `disabled`, leaves one another owner changed and says so, and skips one
  that no longer exists. When a profile cannot be read or reset
  (NetworkManager not answering) it keeps the record and fails, so a retry
  gives it back. Without nmcli (NetworkManager removed, its profiles with
  it) it names the recorded profiles and completes; a malformed row is
  named and skipped (deb/custom-dns-deb:320-367, deb/custom-dns-deb:533-534, deb/custom-dns-deb:559). A reinstall that
  rolls back gives back what its own profile step changed, and the record
  as it was before it; a profile the previous deployment had disabled stays
  so. Every profile step starts with no undo list, and a successful install
  drops its own, so a later rollback never undoes an earlier install (lib/install.sh:1089-1094, deb/custom-dns-deb:278-318, lib/install.sh:2005-2008). On a netplan host NetworkManager keeps the change in
  /etc/netplan/90-NM-<uuid>.yaml: the method comes back, the file is
  rewritten by NetworkManager, not restored byte for byte.
  On a `legacy` host the Linux record also lists the NetworkManager
  profiles an older installer pinned to 127.0.0.1 with automatic DNS off
  (`nm_pin`); a fresh host's profiles are never claimed
  (deb/custom-dns-deb:110-126, deb/custom-dns-deb:439-441).
- Preparation comes first since Sub-plan 4 Task 1.1: packages, source
  staging, image builds and pulls and a prepare manifest finish before
  anything interrupts the stack or touches host DNS (one exception: a Linux
  install on a Mullvad host whose loopback-only custom DNS answers nothing
  switches Mullvad to its default DNS first, BL-048)
  (install-deb.sh:58-75,
  install-mac.sh:95-111). Before any pull,
  the deployment being replaced is kept: its `:latest` images under
  `pre-<generation>` tags and a copy of its owned files
  (lib/install.sh:819-880).
- The interruption keeps the host pinned: the stack stops, but host DNS is
  not touched, so it fails closed until the new stack answers (on a Linux
  host whose Mullvad the preparation switched to its default DNS, Mullvad's
  resolver holds until the pin instead; step 6)
  (lib/install.sh:1599-1627). The controller's
  schedules are held for the transaction (lib/install.sh:928-946).
  macOS builds run in the interruption window (`container build` wedges a
  running dnsnet), without `--pull`; their bases are pulled in preparation
  (lib/install.sh:57, lib/install.sh:2298-2306).
  The builds and the volume hand-over run containers on the default
  network, after which Apple's runtime brings dnsnet containers up with
  their interfaces down, so the runtime is restarted before dnsnet and the
  stack start (lib/install.sh:2617-2632). A macOS rollback stops the builder
  and restarts the runtime the same way before a previous stack comes back,
  and starts the runtime again if that restart failed
  (lib/install.sh:2486-2492, lib/install.sh:1073, lib/install.sh:1074-1083).
- The resolver is pinned only after the new stack answers an ordinary query
  at the pinned address and Unbound resolves over its authenticated route
  (lib/install.sh:965-980,
  lib/install.sh:986-993), and after the installed
  controller passes its self-check (lib/install.sh:1011-1017).
  Linux: lib/install.sh:1990-2010. macOS:
  lib/install.sh:2506-2531; `mac/persist.sh` loads the
  start-container agent, whose first run pins every service, only after the
  controller installed and its installed copy passed its self-check
  (mac/persist.sh:58-81). The pin is
  then verified (lib/install.sh:1023-1031).
- Any failure after the interruption began, including Ctrl-C, rolls back
  (lib/install.sh:1048-1060, lib/install.sh:1062-1135):
  the new stack goes, the saved files and image tags come back, the
  previous stack and the controller restart, and a first install gives back
  the recorded DNS state (or drops an unused record). A second interrupt
  cannot cut the rollback short. The rollback waits for the previous stack
  and says when it does not answer; host DNS then stays pinned to it (fails
  closed). When a first install's DNS restore does not complete, it says
  that host DNS was not given back and keeps the record for a retry
  (manifest status `rolled-back-dns-not-restored`).
- Uninstall removes the stack, images, bridge service, controller and, on
  macOS, a debug monitor set up by hand, and gives back the recorded DNS state
  (lib/install.sh:2017-2076,
  lib/install.sh:2536-2545;
  deb/custom-dns-deb:459-563, mac/start-container-root.sh:222-255).
  The Linux helper puts resolv.conf back first and whole (a new file or
  link renamed over it) while `dns=none` still holds NetworkManager off it;
  if that fails, nothing else changes, the host stays pinned and the record
  stays (deb/custom-dns-deb:453-457). The macOS helper tries every
  service and keeps the record when one fails. A restore that did not
  complete fails the uninstall, which says so after removing the rest
  (lib/install.sh:2080-2085).
  On macOS every change of the host resolver, the pin (`post`) and a
  restore (complete or not), ends with a flush of the system DNS cache:
  getaddrinfo otherwise kept failing names for about 80 s after the stack
  answered them again (mac/start-container-root.sh:119-122,
  mac/start-container-root.sh:279-286). Since Sub-plan 5 Task 2.1 the pin
  also keeps scoped DNS on the container bridge: every pinned service gets
  its own scoped resolver, and a query scoped to Wi-Fi or Ethernet left
  through that interface, in cleartext to the LAN gateway, for an address
  only the bridge reaches (live mac 2026-10-02: networkserviceproxy, about 5
  a minute). `post` has pf pass DNS to 172.31.240.248/29 on the bridge and
  drop it on every other interface, then kills the states toward the subnet
  (a packet that matches a state skips the rules); without a bridge to the
  stack it loads nothing; a restore lifts the anchor
  (mac/start-container-root.sh:75-113) [PRIV-NO-DIRECT].
  A setting another owner changed is left alone. A `legacy` record restores
  the distribution default: the systemd-resolved stub on Linux, `Empty`
  (DHCP) for each pinned macOS service. The recorded legacy profile pins get
  automatic DNS back and are reapplied, before the NetworkManager reload and
  only while still as recorded; with no record at all, the pins found then;
  a profile that cannot be reset fails the restore and keeps the record
  (deb/custom-dns-deb:154-186, deb/custom-dns-deb:536-553). NetworkManager
  not answering is such a failure, never "changed since": the restore keeps
  the record, and a legacy snapshot that cannot list the pins refuses.
  Without nmcli the pins are named and the restore completes
  (deb/custom-dns-deb:128-135; Stage 3 gate class sweep, 2026-10-12). Uninstall claims only that the
  recorded state is back, not that it is private.
- Around the transaction: the sudo credential is kept fresh without
  prompting until the install ends, so a late rollback can still use sudo
  (lib/install.sh:731-740). NetworkManager's `dns=dnsmasq` is overridden by
  the owned `90-nice-dns.conf` drop-in, never by editing NetworkManager.conf
  (lib/install.sh:2089-2111). On a host where the user had no
  subordinate id ranges, preparation runs `podman system migrate` for the
  ranges it added and names any running container that stops
  (lib/install.sh:1478-1486).
- Linux builds take no `--dns` and resolve through the host's resolver as
  it stands in preparation (lib/install.sh:53); macOS builds resolve
  through `--dns 1.1.1.1` (release/bootstrap.tsv, literal build-dns;
  lib/install.sh:57). Every public resolver the product names is declared
  there [PRIV-BOOTSTRAP-DECLARED].
- Since Sub-plan 4 Task 1.3 every pulled image and build base is the
  reviewed digest in release/images.lock, with its platforms, source commit
  and signer (docs/release-inputs.md). Before any interruption an install
  checks the lock, this host's platform and the proxy's interfaces
  (lib/install.sh:1180-1231) and, with cosign, the
  signatures (lib/install.sh:1240-1268). The
  quadlet still names `:latest` (deb/quadlet/tor-haproxy.container:14), which activation
  points at the locked image (lib/install.sh:2148-2157).
  Each generation's manifest records the source commit, the local image
  ids, the locked references and the signature results
  (lib/install.sh:242-307).
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
  `pre`/`post` (mac/start-container-root.sh:268-272). That is VPN state the
  installer does not own (ARCH-06); the installer itself never calls `pre`.
- Linux drives Mullvad's DNS setting since the 2026-10-12 Mullvad findings
  plan (BL-048, DEC-019; lib/install.sh:1757-1775). Connected Mullvad
  rewrote the pin within milliseconds unless its setting was custom
  127.0.0.1, and with that setting and nothing answering the host had no DNS
  (measured 2026-10-12, Mullvad 2026.3). With `mullvad` installed, once the
  source is staged (install-deb.sh:64, install-deb-hardened.sh:85) the
  install reads `mullvad dns get` and refuses (exit 1) on output it does not
  know (lib/install.sh:1788-1801). It records the setting it found and the
  one from before nice-dns in `generations/<gen>/mullvad-dns.tsv`, 0600. A
  found custom 127.0.0.1 inherits the previous generation's earlier setting
  or, with no record, stands in as Mullvad's default. It switches to the
  default only when the setting is loopback-only custom, no nice-dns stack
  runs and none of its servers answers (lib/install.sh:1890-1921). After
  the pin it sets custom 127.0.0.1 (lib/install.sh:1925-1930, called at
  lib/install.sh:1985); the pin check then retries up to 5 times, 1 s
  apart (lib/install.sh:1019-1031). A failed preparation, including a signal,
  and a rollback put back the setting the install found
  (lib/install.sh:1854-1866, lib/install.sh:1095-1098). Uninstall restores
  the setting from before nice-dns while it is still custom 127.0.0.1, and
  otherwise leaves the owner's setting alone; with no record it sets the
  default. A setting or record it cannot read fails the uninstall
  (lib/install.sh:1937-1958, called at lib/install.sh:2048). If the host
  then does not resolve, it names `mullvad reconnect`
  (lib/install.sh:1964-1969). Whether the resolver record taken while
  Mullvad was connected resolves after an uninstall with Mullvad
  disconnected is baseline: unverified [SEC-OWNED-RESTORE]
  [PRIV-NO-HOST-PUBLIC].
- Unbound remote control is a Unix socket at `/run/unbound/control.sock`
  with no keys and no network listener (unbound/etc/unbound.conf:166-169).
  Neither image carries control keys; the hardened-unbound base no longer
  generates them at build [SEC-CONTROL-LOCAL]. The anchor is on a volume
  (WF-DNS-001).
- Since Sub-plan 4 Task 2.1 each deployment has its own Pi-hole admin
  password, in `~/.local/state/nice-dns/secrets/pihole/pihole_webpassword`
  (directory 0700, file 0600). Preparation generates it once or keeps it,
  and refuses a symlink, another owner, a file others can read, an empty
  or a multi-line file rather than replace it (lib/install.sh:338-377;
  install-deb.sh:74, install-deb-hardened.sh:95, install-mac.sh:108,
  install-mac-hardened.sh:123). Linux hands it to podman by path as the
  secret `nice-dns-pihole-webpassword` (lib/install.sh:369), which the
  quadlet mounts for uid 1000 (deb/quadlet/pi-hole.container:33-34).
  macOS mounts the directory read-only at /run/secrets at both launch
  sites (lib/install.sh:2659-2672, mac/start-container.sh:490-503). Both
  images read it through `WEBPASSWORD_FILE` and refuse to start when it is
  missing, unreadable or empty (pihole/nd-start.sh:30-38; the
  hardened base's start.sh, pi-hole-hardened 4574d52). Uninstall removes
  it (lib/install.sh:380-386). Before Task 2.1 the hardened image served
  the admin API with no password and the standard image printed a random
  one to its log on every start [SEC-ADMIN-AUTH] [PRIV-NO-SECRETS].
- Capabilities are per image (deb/persistent-podman.sh:135-136): the standard
  image drops all and adds back nine
  (deb/quadlet/pi-hole-standard.conf:13-14); the hardened image keeps
  NET_BIND_SERVICE with no-new-privileges
  (deb/quadlet/pi-hole-hardened.conf:11-13). macOS runs the standard set for
  both (lib/install.sh:2664). pihole-FTL runs as uid 1000 in both. Pi-hole's
  NTP server and client are off (pihole/etc/pihole.toml:492, 502, 515), so
  it listens on :53, :80 and :443 only (tests/integration/deployment-security.sh)
  [SEC-LEAST-PRIV] [SEC-LISTENERS].
- Since Sub-plan 5 Task 1.2 Unbound's route directory (WF-DNS-001) is
  instance state too. Every entrypoint checks it before any change: a
  relative path or one a Volume= or `-v` mount cannot carry, a symlink and
  a directory others can write are refused
  (lib/install.sh:454-467; install-deb.sh:61, install-deb-hardened.sh:82,
  install-mac.sh:98, install-mac-hardened.sh:113). It is an owned path, so
  a failed install puts it back or removes the one it created
  (lib/install.sh:796, lib/install.sh:809), and only an uninstall that gave
  host DNS back removes it: the files nice-dns manages there, then the
  directory when that emptied it; anything else under the path stays
  (lib/install.sh:485-495). Checked per entrypoint
  by tests/integration/route-mount.sh [SEC-OWNED-RESTORE].
- Since Sub-plan 4 Task 2.2 each deployment keeps its instance state across
  repair, reinstall, proxy and Pi-hole image switches, failed installs and
  upgrades; only uninstall removes it (lib/install.sh:483-509), and only
  once host DNS was given back: a failed or interrupted restore keeps the
  state, the admin password and the current-generation marker for the retry
  or a reinstall (lib/install.sh:2069-2076, called at lib/install.sh:2058 and
  lib/install.sh:2543) [SEC-OWNED-RESTORE]. Tor state: the Linux volume
  nice-dns-tor-<proxy> (deb/quadlet/tor-haproxy.container:20,
  deb/quadlet/tor-socat.container:16), on macOS
  ~/.local/state/nice-dns/tor-<proxy>, now mounted by the installer's run
  too (lib/install.sh:2687, mac/start-container.sh:543). The root anchor:
  WF-DNS-001. The operator's Pi-hole lists (user decision: lists survive,
  configuration comes from the image): gravity.db on the volume
  nice-dns-pihole-lists (pihole/etc/pihole.toml:946,
  deb/quadlet/pi-hole.container:19, lib/install.sh:2662,
  mac/start-container.sh:493). Each image keeps its build's gravity.db as a
  seed; pihole/nd-start.sh uses the volume as it is while the seed ids
  match and otherwise carries the operator's rows into the new seed
  (pihole/nd-start.sh:47, pihole/merge-lists.sql), keeping the previous
  file. macOS creates its volumes and hands them to the image's user in the
  interruption window (lib/install.sh:410-425, lib/install.sh:2514):
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
  `~/.config/containers/systemd` (deb/persistent-podman.sh:119-137) and linger
  (deb/persistent-podman.sh:51-52). The resolver pin is a system oneshot
  (deb/custom-dns-deb.service:6-9).
- macOS: persistence comes from the start-container LaunchAgent installed by
  `mac/persist.sh` (mac/persist.sh:75-90) and helpers in `/usr/local/sbin`
  (mac/persist.sh:39-51). It requires macOS 26+ on arm64
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
   Exception: when the running proxy uses a bridge the new selection leaves
   out for stream quality (step 7), the refresh applies it at once through
   the service restart, one fail-closed gap at most per refresh.
5. On macOS, selection runs on `dnsnet` only.
6. Evidence and logs redact bridge certificates.
7. A selection leaves out every bridge the running Tor has judged weak:
   at least 20 stream uses and under 90% stream success (its path-bias use
   counters), and keeps leaving it out for 30 days. Fewer than 3 bridges
   after that applies nothing.

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
  in manage mode inside the tor image (deb/persistent-podman.sh:216-220). It
  is a oneshot with `RemainAfterExit=yes` (deb/persistent-podman.sh:202). It
  also runs at install (deb/persistent-podman.sh:344).
  - Since Sub-plan 3 Task 2.2, an `ExecCondition` skips it while
    `bridges.env` holds 3 or more valid bridges
    (deb/persistent-podman.sh:199). Selection therefore stays out of
    startup's critical path when a usable set exists.
  - Until Sub-plan 5 Task 2.2 (aa6b7e9) that skip never happened: the
    condition exited 1, which `SuccessExitStatus=0 1` also covers, so
    systemd counted it as a pass and every install and boot reselected
    bridges over the controller's set (reproduced on mint 2026-10-05). It
    now exits 2, and the install's restart is skipped (mint, same day).
- Daily refresh since Task 2.2 (BL-019): the controller's
  `nice-dns-health-bridges.timer` (`OnCalendar=daily`, `Persistent=true`;
  health/nice-dns-health:693) runs `nice-dns-health bridges-refresh`.
  - The image's bridge-eval writes a candidate, never `bridges.env`
    (lib/platform/linux.sh:303-309). It runs outside the state lock, under
    a refresh mutex (lib/recovery.sh:1231-1287).
  - nd_bridges_apply (lib/recovery.sh:1080-1119) holds the lock:
    - a candidate with fewer than 3 valid lines is not applied, so the last
      good set stays;
    - normalized equal sets write nothing;
    - `bridges.env` is replaced only if it still holds the set the
      evaluation started from, so a slow run never overwrites a newer one;
    - a changed set is written atomically (0600, `.prev` kept) and restarts
      nothing itself (the refresh around it may, below).
  - Since Sub-plan 5 Task 2.2, nd_bridges_refresh first reads the running
    proxy's Tor state (`/app/data/tor/state`) and leaves out of the
    candidate every bridge with at least 20 uses and under 90% stream
    success (lib/recovery.sh:1140-1229, lib/recovery.sh:1243-1253). The
    controller remembers each such bridge in `bridges.weak` (state
    directory, 0600, fingerprints only) and leaves it out for 30 days
    (`ND_BRIDGE_WEAK_DAYS`) from its last judgement, because the macOS agent
    deletes Tor's state when the bridge set changes
    (mac/start-container.sh:128, mac/start-container.sh:536). When the
    running Tor is still configured with a left-out bridge (`listed=1`) and
    a set is pending, it adopts the set through the service restart
    (lib/recovery.sh:1267-1284). While the proxy is in a crash loop that
    restart is held and journaled `bridges held`; the set stays pending and
    the proxy reads it at its next start (lib/recovery.sh:1272-1276,
    lib/recovery.sh:1289-1296). With no readable state and no memory,
    nothing is filtered.
  - The proxy reads the new set at its next natural start. During a
    sustained failure, the Tor restart adopts it through the service restart
    (lib/recovery.sh:1301-1315, lib/recovery.sh:862-879).
- Exit 1 is tolerated (deb/persistent-podman.sh:224). A missing `BRIDGE1`
  fails loudly (deb/persistent-podman.sh:230).
- The Linux proxy reads `bridges.env` through `EnvironmentFile=` at
  container start (deb/quadlet/tor-haproxy.container:28). A changed selection
  takes effect only on the next container start.
- Health recovery re-evaluates with nd_bridges_refresh, at most once an
  hour, once an observed outage has outlasted the grace
  (health/nice-dns-health:522-538).
  - Until Task 2.2 it ran the raw Moat fetcher
    (deb/persistent-podman.sh:174), which writes an unranked pool into the
    same `bridges.env` (scripts/fetch-bridges.sh:49-51) and could replace an
    evaluated set.
  - The fetcher remains only the installers' and the boot path's source
    when no usable set exists.
- Since Sub-plan 4 Task 2.2 (3148e14), each Linux tor quadlet keeps Tor
  data in a named volume (deb/quadlet/tor-haproxy.container:20,
  deb/quadlet/tor-socat.container:16), so Tor state, its path-bias
  counters included, survives the container's recreation (observed on mint
  2026-10-04: guards sampled since 2026-09-18).
- macOS daily refresh since Task 2.2: the controller's
  `org.nice-dns.health-bridges` agent (a daily `StartCalendarInterval`,
  which runs on wake; health/nice-dns-health:757). Its probe container runs
  only on `dnsnet`, only while pi-hole, unbound and the proxy run on
  .250/.251/.252, and it holds the start-container agent's stack lock while
  the probe container exists (lib/platform/macos.sh:312-356).
  - `mac/persist.sh` no longer installs the legacy `org.nice-dns.bridge-eval`
    agent. It retires that agent after the controller installs
    (mac/persist.sh:94).
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
  incomplete (mac/start-container.sh:162-175, mac/start-container.sh:621-629).
  Until the Stage 2 gate it also refetched after a failed bootstrap, writing
  over a usable set without the controller's lock, base check or `.prev`;
  now it keeps the set, and re-selection is the controller's evaluated
  refresh.
  It recreates Tor only when the bridge fingerprint changed
  (mac/start-container.sh:523-539). On a change it drops the guard sample
  and keeps the cache (mac/start-container.sh:128-130). Tor's DataDirectory
  persists (mac/start-container.sh:42, mac/start-container.sh:543).
- The macOS installers run the fetcher without `--force`
  (lib/install.sh:2354). They require at least three bridges
  (lib/install.sh:2374-2377). Since Sub-plan 4 Task 1.1 both pass every
  BRIDGEn to the proxy; the hardened one used to pass only BRIDGE1 and
  BRIDGE2.

### Platform notes

- Linux: bridge-eval runs host-side through `podman run --user 0:0`
  (deb/persistent-podman.sh:216). The target adds a daily timer and keeps
  the out-of-band selection model.
- macOS: a second container on another vmnet network wedges `dnsnet`
  (mac/bridge-eval.sh:77-90). Selection must stay on `dnsnet`.

## WF-DNS-005 Status and update

### Trigger

The host owner, a script or a GUI runs `nice-dns status [--tsv]`, or
`nice-dns update [--check] [--force]`; the health controller finishes a pass.

### Contract (target, per ARCH)

Sources: the 2026-11-05 GUI, update, bridges toggle and restart master plan,
Sub-plan 3; docs/cli-contract.md is the contract the GUIs pin to.

#### Steps

1. After a pass has decided, the controller keeps its observations and the
   pass verdict (`OK`, `FAIL [...]`, `INDETERMINATE [...]`) in
   `observations.tsv` in its state directory, by rename; a shadow pass keeps
   `shadow/observations.tsv`. A pass that dies before deciding leaves the
   previous file.
2. `status` reads the install record, the controller's receipt, that file,
   its state and journal, the bridge files and the update cache, and prints
   `nice-dns-status/1` rows. A pass older than 300 s is stale and still
   printed.
3. `update --check` asks the recorded branch for its newest commit and keeps
   the answer for `status`: `current`, `available` (the commits differ,
   usually the branch is newer) or `unknown`. A check of another branch keeps
   nothing.
4. `update` without `--check` installs a different commit through WF-DNS-003
   step 8, with the recorded choices, then checks again; the last line of its
   output is the answer (docs/cli-contract.md).

#### Invariants

- `status` is file-only: no probe, no runtime CLI, no scheduler, no network.
- `status` never reads a file it cannot read as absent; it says `unreadable`
  and exits 2.
- `status` prints the admin password's path, never the password, and no
  bridge line [PRIV-NO-SECRETS].
- `update` never widens the recorded choices: the recorded branch, variant
  and flavour unless an option names others.
- An `unknown` check installs nothing, and the update's install is the
  installer's transaction: a failure keeps or restores the running stack and
  never rewrites the host resolver to public DNS [PRIV-NO-HOST-PUBLIC].

### Current baseline (observed in source)

- The controller keeps a decided pass by rename, after nd_recovery_tick
  returns 0 (health/nice-dns-health:283-299, called at
  health/nice-dns-health:552 for `run` and health/nice-dns-health:1214 for
  `tick`). `nice-dns-health status` lists its `container:` records
  (health/nice-dns-health:972).
- lib/status.sh nd_status_rows prints the rows (lib/status.sh:90-246); every
  file it opens goes through _nd_st_reach (lib/status.sh:45-58); epochs are
  plain numbers (lib/status.sh:39); a pass dated after the clock is
  `stale future` (lib/status.sh:167); the admin row is the credential's path
  (lib/status.sh:232).
- `nice-dns status` sources that library from the checkout or the kept source
  and adds the install hint (nice-dns:503-562).
- The check is the only network call, bounded by `timeout 55`
  (nice-dns:414), and writes the cache by rename into an existing controller
  state directory only, for the recorded branch only (nice-dns:368-381,
  nice-dns:392-430). `update` refuses `--local`, installs nothing on
  `unknown` (nice-dns:470), prints `already current` (nice-dns:480) and
  otherwise runs cmd_reinstall from a clone of the checked branch, then checks
  again (nice-dns:444-497).

### Platform notes

- Linux and macOS read the same rows from their own paths (lib/status.sh
  _nd_st_paths); the admin URL differs (port 8880 on localhost against
  Pi-hole's bridge address on macOS).
- `timeout` exists on both (measured: /usr/bin/timeout on this laptop and on
  the macOS 27.2 target) and is the check's hard bound, 55 s; without it git's
  low-speed limit ends only a transfer that has started.
