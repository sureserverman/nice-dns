# Plan demo — 2026-11-20-macos-ssh-followups-plan

Environment: the mac over plain ssh, tree 013d653 at ~/nd-bl068/nice-dns. The evaluator wrote its sheet to the session scratchpad during the plan-scope run; each section is copied here unchanged.

Evaluator: demo evaluator, 2026-11-20. Route: plain `ssh mac` (`launchctl managername` = Background, uid 501). No source or diff read. No uninstall, no `container system start`, no build, no bootout run.

Baseline 18:29:23Z: Mode active; 1 `com.apple.container.apiserver` (pid 92892); pi-hole/unbound/tor-socat healthy; `dig @172.31.240.250 cloudflare.com` answered.

Fill in Verdict and Evidence under each Outcome. Do not edit the quoted lines.

# Stage 1

## Outcome 1
> Works: an uninstall over ssh where sudo works, or where the helper does every root step, runs as before
Verdict: not shown here

Evidence: none. The owner did not authorise an uninstall of the live mac. Showing it needs owner approval for an uninstall plus reinstall of the mac, or a spare Mac.

## Outcome 2
> An uninstall over ssh where a root step needs sudo and sudo cannot ask for a password → it stops before anything changes and says to run it over `ssh -t` or from Terminal; DNS and the stack stay as they were
Verdict: not shown here

Evidence: none (the plan already marks it so). Showing it needs a Mac account without NOPASSWD sudo and without a usable helper.

## Outcome 3
> An install or reinstall whose runtime does not stop when asked → the install fails at that step and says the runtime did not stop, instead of starting the stack on the old datapath; the rollback brings back the previous stack
Verdict: not shown here

Evidence: none (the plan already marks it so). Showing it needs a runtime that ignores a stop, which this mac cannot be made to do on purpose.

## Outcome 4
> A hand-run `nice-dns-health tick` over ssh while the runtime is down → the controller kicks the start-container agent, the runtime comes back in the login session and no second runtime starts
Verdict: holds

Evidence: this is the same drill as Outcome 6, below.
- 18:31:54Z `ssh mac '~/.local/bin/nice-dns-health tick'` (runtime down, 0 apiservers): `action repair-runtime / target runtime-down / result acknowledged / generation 1176`, rc 0.
- 18:32:15Z `launchctl list`: `org.nice-dns.start-container` running (pid 99834); `com.apple.container.apiserver` pid 99903, count 1.
- 18:32:23Z `launchctl print gui/501/com.apple.container.apiserver`: `state = running`, `domain = gui/501`, pid 99903. `launchctl print user/501/...`: "Bad request." (no runtime in another domain).
- Journal: `requested  repair of runtime-down: kickstart org.nice-dns.start-container for runtime-down (exit 0)` at 18:32:13Z, then `acknowledged  runtime-down: the runtime answers` at 18:32:15Z.
- Agent log (~/Library/Logs/nice-dns.log): 18:32:13 "starting nice-dns runtime (variant=socat)", "container system not ready, retry 1/10", "Launching container-apiserver...", 18:32:18 "container system ready". So the agent started the runtime, not the controller.
- One tick was enough (1 of the 3 allowed).

# Stage 2

## Outcome 5
> Works: a reinstall over plain ssh from the branch says the runtime stopped and started again, and DNS answers at 172.31.240.250 afterwards
Verdict: holds

Evidence:
- 18:29:32Z–18:31:07Z `ssh mac 'cd nd-bl068/nice-dns && bash install-mac.sh socat'` (no -t): rc 0, 425 lines.
- Install output: after the new containers were prepared, "Launching container-apiserver... / Testing access... / Verifying machine API server is running..." then "• Container runtime restarted, so the stack starts on a fresh network datapath."; "Chain is resolving, and Unbound resolves over its authenticated route."; "▸ Generation 20261120T182933Z-nogit0000000 is active (previous: 20261120T182324Z-nogit0000000)."; "All done. DNS is set to 172.31.240.250 (pi-hole)."
- 18:31:24Z: the apiserver pid changed from 92892 to 97388 (a real restart), count 1, `domain = gui/501`; containers started 18:30:36–37Z; 3/3 `dig @172.31.240.250 example.com` answered; `networksetup -getdnsservers` on Wi-Fi and Ethernet = 172.31.240.250; Mode active, all three healthy.

## Outcome 6
> Works: with the runtime stopped, a hand-run `nice-dns-health tick` over plain ssh brings it back through the start-container agent; `launchctl list` over ssh still shows one `com.apple.container.apiserver`, and DNS answers again
Verdict: holds

Evidence:
- 18:31:37Z `ssh mac '~/.local/bin/nice-dns-health stop'`: "LaunchAgents unloaded.", rc 0.
- 18:31:37Z `ssh mac 'sudo -n launchctl asuser $(id -u) sudo -n -u $USER /opt/homebrew/bin/container system stop'`: stopped the 3 containers and the gui/501 services, rc 0.
- 18:31:45Z: apiserver count 0; `container ls` gave "XPC connection error: Connection invalid"; `dig @172.31.240.250` timed out (exit 9).
- 18:31:54Z: hand tick, giving repair-runtime acknowledged (details in Outcome 4).
- 18:32:15Z and 18:33:24Z: `launchctl list | grep -c com.apple.container.apiserver` = 1 (pid 99903) both times.
- Agent log: the stack was rebuilt on .250/.251/.252 at 18:32:20, "tor bootstrapped" and "chain resolving" at 18:33:18, "done" at 18:33:19.
- 18:33:24Z: the first `dig @172.31.240.250 example.com` answer, about 90 s after the tick. `cloudflare.com` also answered.
- 18:33:29Z `ssh mac '~/.local/bin/nice-dns-health start'`: "LaunchAgents loaded.", rc 0.
- 18:33:32Z: the first scheduled tick was a no-op ("fresh proxy ... route cloudflare-exit stays selected"). Journal: `ready  observed working 77s after the acknowledgement`.

## Findings (non-blocking)

- Minor: the Outcome 5 wording asks the install to say the runtime "stopped and started again". The install says "Container runtime restarted". It has no separate "stopped" line. The meaning holds, and the pid change confirms a real restart.
- Minor: while the schedule was held (after `nice-dns-health stop`), the first line of `nice-dns-health status` still read "Mode: active". I did not check whether the LaunchAgent section of status showed the hold.
- Minor (noise): the agent log printed "Error: network dnsnet already exists" during the repair rebuild. The next line handles it ("dnsnet already exists"), and the rebuild succeeded.

## Final state of the mac (18:33:40Z)

DNS answers at 172.31.240.250 (apple.com resolved). Mode: active; the schedule is restored (org.nice-dns.health* loaded). One `com.apple.container.apiserver`, in gui/501. pi-hole, unbound and tor-socat are healthy. No `nice-dns restart` was needed.
