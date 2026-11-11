# Stage 1 demo — 2026-11-10-app-switches-autocheck-plan

Environment: (see below)

## Not demoed

owner, 2026-11-10: "Skip; Stage 3 demos (Recommended)"

The question put to the owner: the Stage 1 and Stage 2 gates each need an evaluator demo on a real machine, and the "Works" Outcomes (a switch, a hardened build, the scheduled check) can only be shown by reinstalling on mint and the mac, which OD-4 allows only in Stage 3's live run. The owner chose to record this opt-out for the Stage 1 and 2 demos; Stage 3's live cells (tests/live/switch-autocheck.sh, Task 3.3) and the close-out evaluator show the switches, the hardened build, the scheduled check and both apps on mint and the mac.

At this gate the Outcomes stand on fixture evidence only (the plan's evidence claim for Stage 1 is synthetic): integration nice-dns-cli 73/73 (switch, Already, not installed, no kept source, exit 3, usage, update auto), install-prepare 35/35 (hardened base from the tree, no checkout beside it), release-inputs 13/13, scheduling 16/16 (the 12-hour schedule, stop/start/uninstall, the bounded check and its unknown cache), all on this laptop's host, under gawk and under mawk.


## Outcome 1
> Works: `nice-dns switch proxy socat` (or `haproxy`) and `nice-dns switch pihole hardened` (or `standard`) reinstall the kept source with that one choice changed; the last line says what now runs and that DNS answers; `nice-dns status` shows the new `variant` or `pihole`, and the same `source_commit` as before
Verdict: 
Evidence:


## Outcome 2
> Works: a switch to hardened builds the base from the nice-dns tree on a machine that has no pi-hole-hardened checkout
Verdict: 
Evidence:


## Outcome 3
> Works: twice a day the controller runs the check; `nice-dns status` shows its result and time in the `update` rows, and `update auto loaded`
Verdict: 
Evidence:


## Outcome 4
> The choice asked for is the one installed → `Already <choice>; nothing changed.`, exit 0, nothing is reinstalled
Verdict: 
Evidence:


## Outcome 5
> Nothing is installed → `nice-dns is not installed; run nice-dns install` on stderr, exit 1
Verdict: 
Evidence:


## Outcome 6
> No kept source (an install older than the kept source) → stderr names the missing directory and `nice-dns reinstall`; exit 1; the stack is untouched
Verdict: 
Evidence:


## Outcome 7
> The install fails (a build or pull fails, DNS does not come back) → the installer restores the running stack; stderr says the switch did not happen and the old choice still runs; exit 3
Verdict: 
Evidence:


## Outcome 8
> A wrong or missing word (`switch proxy nginx`, `switch`) → a usage line on stderr, exit 2, nothing runs
Verdict: 
Evidence:


## Outcome 9
> The scheduled check cannot reach GitHub or runs past 60 s → the cache says `unknown`, with the time; nothing else changes; the next slot tries again
Verdict: 
Evidence:


## Outcome 10
> The schedules were stopped with `nice-dns-health stop` → `update auto stopped`; no check runs until `start`
Verdict: 
Evidence:

