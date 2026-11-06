# Stage 1 demo — 2026-11-05-gui-update-bridges-restart-sub-02-bridges-off-images-plan

Environment: Linux host, rootless podman 2026-11-06 ~10:20–10:25 GMT, every podman command run as
`systemd-run --user --wait --pipe --quiet podman <args>` (XDG_RUNTIME_DIR=/run/user/1000).
Images built the way they ship from the branch heads:
- `/home/user/dev/containers/tor-haproxy` branch `bridges-off`, HEAD f0038d3, clean tree → `podman build -t localhost/demo-tor-haproxy:bridges-off` (rc=0, image d5837dbdb6f1)
- `/home/user/dev/containers/tor-socat` branch `bridges-off`, HEAD f30938d, clean tree → `podman build -t localhost/demo-tor-socat:bridges-off` (rc=0, image 1ad97f278095)

Long-running containers were started as `systemd-run --user --collect --unit=demo-X podman run --name demo-X ...`
(a first try with `podman run -d` under `systemd-run --wait` died with exit 143: the transient unit's teardown
killed conmon; harness artefact, not product). Default podman network only; all demo-* containers removed
afterwards (`podman ps -a --filter name=demo-` empty; no demo-* user units left); live tor-haproxy/unbound/pi-hole
untouched and still healthy. Only the user docs (README.md, doc/DOCKERHUB.md) were read; no source, no diff.
Plan goal command run from the nice-dns repo: `goal rc=0`.

Fill in Verdict and Evidence under each Outcome. Do not edit the quoted lines.

## Outcome 1
> Works: with `TOR_BRIDGES=off` the supervisor logs `direct (no bridges)`, launches Tor with `UseBridges 0` and no `Bridge` lines, and the route probes answer once bootstrapped.
Verdict: holds
Evidence:
- `podman run --name demo-hap-off -e TOR_BRIDGES=off localhost/demo-tor-haproxy:bridges-off` and the same for `demo-soc-off` on the socat image. `podman logs` of both, 18 s later:
  ```
  Waiting for Tor to bootstrap...
  tor-supervisor: spawned tor pid=9 generation=1 direct (no bridges)
  tor-supervisor: bootstrapped after 7 s, a stream works after 8 s (exit)
  Tor bootstrapped successfully.
  ```
- Process list inside each (`podman exec <ctr> sh -c 'for p in /proc/[0-9]*; ... cmdline'`): Tor runs as `tor UseBridges 0`. There is no `Bridge` argument and no `lyrebird` process. `/etc/tor/torrc` (grep for bridge/ClientTransportPlugin) has `UseBridges 1` and the obfs4 transport line, but no `Bridge` lines. The command-line `UseBridges 0` overrides it, and no transport is spawned.
- Route probes, haproxy (all exit 0):
  `port=853 name=tor.cloudflare-dns.com result=ok rcode=NOERROR ms=1040`,
  `port=18531 name=tor.cloudflare-dns.com result=ok rcode=NOERROR ms=1160`,
  `port=18532 name=one.one.one.one result=ok rcode=NOERROR ms=290`,
  `port=18533 name=dns.quad9.net result=ok rcode=NOERROR ms=1070`.
- Route probes, socat (all exit 0): 853 ok 3250 ms, 18531 ok 970 ms, 18532 ok 440 ms, 18533 ok 450 ms.

## Outcome 2
> `TOR_BRIDGES` unset or `on` → today's path: at least one bridge required, the same refusal message.
Verdict: holds
Evidence:
- `podman run --rm --name demo-<img>-o2 [ -e TOR_BRIDGES=on ] localhost/demo-tor-<img>:bridges-off` with no BRIDGEn. Run for both images, with the variable unset and with `on`. All four print the following and exit 1:
  ```
  Waiting for Tor to bootstrap...
  ERROR: no usable bridges (supply BRIDGE1.. at runtime, or enable bridge-eval)
  tor-supervisor: REFUSING to launch tor on invalid/empty bridges
  exit=1
  ```
- Today's images, same command, nothing set: `docker.io/sureserver/tor-haproxy:latest` (v2.15) and `docker.io/sureserver/tor-socat:v2.10`. Both give byte-identical lines and `exit=1`.
- With a bridge, on mode follows today's path. `-e TOR_BRIDGES=on -e BRIDGE1="obfs4 217.182.78.247:52234 FF98… iat-mode=0"` (the README's line), and the same with TOR_BRIDGES unset, log `WARNING: only 1 bridge(s); Tor Conflux needs 3 — running without it.` and `spawned tor pid=15 generation=1 with 1 bridge(s)`. Tor runs as `tor Bridge obfs4 217.182.78.247:52234 …` with `/usr/bin/lyrebird` running. It bootstrapped in 5 s. Probes `853 … result=ok` and `18532 … result=ok` on both images.

## Outcome 3
> `TOR_BRIDGES` is anything else → exit 1 with `TOR_BRIDGES must be on or off`.
Verdict: holds
Evidence:
- `podman run --rm --name demo-<img>-o3 -e "TOR_BRIDGES=<v>" …` on both images:
  - `OFF` → `ERROR: TOR_BRIDGES must be on or off (got 'OFF')`, exit=1
  - `yes` → `… (got 'yes')`, exit=1
  - `0` → `… (got '0')`, exit=1
  - `' off'` (leading space) → `… (got ' off')`, exit=1
  - `off;id` → `… (got 'off;id')`, exit=1
  - The refusal comes before `Waiting for Tor to bootstrap...`, so Tor is never started.
- Edge: `TOR_BRIDGES=` (set but empty) is treated as unset/`on`. It prints the Outcome 2 bridge refusal and exits 1. See Minor 1.

## Outcome 4
> `off` with `BRIDGEn` or `BRIDGE_EVAL` set → one log line each saying they are ignored.
Verdict: holds
Evidence:
- `-e TOR_BRIDGES=off -e BRIDGE1=<obfs4 192.0.2.1…> -e BRIDGE2=<obfs4 192.0.2.2…> -e BRIDGE_EVAL=auto`, both images:
  ```
  tor-supervisor: bridges off: BRIDGE1..16 ignored
  tor-supervisor: bridges off: BRIDGE_EVAL=auto ignored
  Waiting for Tor to bootstrap...
  tor-supervisor: spawned tor pid=9 generation=1 direct (no bridges)
  ```
  Tor ran `tor UseBridges 0`. The probe gave `853 … result=ok`, even though the given bridges were unreachable TEST-NET addresses.
- `-e TOR_BRIDGES=off -e BRIDGE3=…` only: one line, `bridges off: BRIDGE1..16 ignored`, on both images.
- `-e TOR_BRIDGES=off -e BRIDGE_EVAL=force` only: one line, `bridges off: BRIDGE_EVAL=force ignored`, on both images.
- `-e TOR_BRIDGES=off -e BRIDGE_EVAL=off`: one line, `bridges off: BRIDGE_EVAL=off ignored`, on both images. See Minor 2.
- The ignore lines are logged once, at start. They do not repeat after a restart request: the log after `restart request o4-restart accepted` shows only the respawn `direct (no bridges)`.

## Outcome 5
> The in-image restart contract respawns Tor the same way in both modes.
Verdict: holds
Evidence:
Same user steps in each mode, on both images. Steps: write an id to a temp file in `/app/data/control` and `mv` it to `tor-restart-request`, as the image user (uid 1000, app). Then touch `/tmp/tor-restart-flag` (legacy). Read `tor-restart-ack`, `tor-generation` and the Tor cmdline.
- Off mode (demo-hap-off, demo-soc-off):
  - Request `demo-off-1`. Ack is `request_id demo-off-1 / status respawned / generation 2 / tor_pid 308` (haproxy) and `… 296` (socat). `tor-generation` matches.
  - Log: `restart request demo-off-1 accepted` → `restart flag observed, sending SIGTERM to tor` → `tor exited as part of planned restart, respawning` → `spawned tor pid=… generation=2 direct (no bridges)`.
  - Tor is again `tor UseBridges 0`. Probes 853/18532 ok afterwards.
  - Legacy touch, with a stale `/tmp/bridges-current.env` holding a BRIDGE1 line written first (the socat README says off ignores it). Ack is `request_id legacy / respawned / generation 3`. Log `spawned … generation=3 direct (no bridges)`. Tor is still `tor UseBridges 0`, with no lyrebird.
  - Haproxy 18531 probe right after: ok 3170 ms. Socat 18531 probe right after: `result=no-answer … error=timeout` (onion circuit not yet built). Retried ~20 s later: ok 2410 ms, and 853 ok, twice. This matches the README: an ack means respawned, not bootstrapped.
- On mode (demo-haproxy-on, demo-socat-on; `TOR_BRIDGES=on`, README bridge line):
  - Request `demo-on-1`. Ack is `demo-on-1 / respawned / generation 2 / tor_pid 236` (haproxy) and `… 228` (socat).
  - Log: the same four lines, ending `spawned tor pid=… generation=2 with 1 bridge(s)` after the Conflux warning.
  - Tor is again `tor Bridge obfs4 217.182.78.247:52234 …` with lyrebird.
  - Legacy touch: ack `legacy / respawned / generation 3`, Tor still bridged. Probes 853 ok on both after the restarts.
- The flow (accept → SIGTERM → respawn → ack → generation+1) is identical in both modes. Only the spawn-mode suffix differs, and each mode respawns into its own mode.
- Side observation, the same for any mode and not specific to this stage: my first socat legacy touch landed between SIGTERM and respawn of `demo-on-1`. It was absorbed into that restart, with no `legacy` ack and no extra generation. The same touch while idle was acknowledged normally.

## Findings

Blocking: none.

Material: none.

Minor:
1. `TOR_BRIDGES=` (present but empty) is treated as the default `on`, not refused. Outcome 3 says "anything else → exit 1", and the Hub table says "any other value refuses to start". A user whose templating leaves the variable empty gets the bridged path silently: the bridge refusal without bridges, or a bridged run with them. This is defensible as "unset", but the docs do not say so.
2. `TOR_BRIDGES=off -e BRIDGE_EVAL=off` logs `bridges off: BRIDGE_EVAL=off ignored`. Logging that the default "off" is ignored is harmless noise.
3. Documentation nit, user-visible: both READMEs still say "This image uses obfs4 bridges … There is a pair of them in this image". The image refuses to start with no BRIDGEn, and the Hub doc says BRIDGEn is required unless `TOR_BRIDGES=off`. The two docs contradict each other. The same refusal comes from today's released images, so this is pre-existing.

Verdict: PASS. All five Outcomes hold on both images, with Minor residuals only.
