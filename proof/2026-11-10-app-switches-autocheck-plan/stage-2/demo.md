# Stage 2 demo — 2026-11-10-app-switches-autocheck-plan

Environment: (see below)

## Not demoed

owner, 2026-11-10: "Skip; Stage 3 demos (Recommended)"

The question put to the owner covered the Stage 1 and Stage 2 gates: the "Works" Outcomes need a reinstall on mint and the mac to be shown, which OD-4 allows only in Stage 3's live run. The owner chose to record this opt-out for both stages; Stage 3's live cells (Task 3.3: the app's own proxy action run on mint with GSK_RENDERER=cairo and on the mac through launchctl asuser) and the close-out evaluator show both apps working.

At this gate the Outcomes stand on test evidence only: Linux window, laptop host under Xvfb (cairo): cargo test 50 + 11 + 9, the seven selector cases driving the real window through --probe and the shared fake nice-dns (exit 0, 3, 126, Not now, a status naming no variant); macOS app, on the mac: KitCheck 141/141 and XCTest 33/33 over the Kit logic (pending choice, questions, placement, Update row), make building and signing the app. Not seen: either app's selectors drawn on a real screen (left to Stage 3).


## Outcome 1
> Works: the Installed section shows a Proxy selector (haproxy, socat) and a Pi-hole selector (standard, hardened) set to what `status` says; on macOS the menu has the same two choices as submenus with a check mark
Verdict: 
Evidence:


## Outcome 2
> Works: picking the other value asks first ("Switch the proxy to socat? The stack is reinstalled from the kept source. This takes a few minutes and DNS stops briefly."); on Switch the action runs with its output in the log pane, the selector shows the new value while it runs, and the next status read confirms it
Verdict: 
Evidence:


## Outcome 3
> Works: the Check for an update button and the update banner behave as before; the Update row's "checked ... ago" now also moves when the schedule ran
Verdict: 
Evidence:


## Outcome 4
> Not now or the dialog dismissed → the selector goes back to the installed value; nothing runs
Verdict: 
Evidence:


## Outcome 5
> The switch fails (exit 3, or a root step not authorised) → the selector goes back to the installed value; the log pane shows the command's stderr and the named exit; a toast says the switch did not happen
Verdict: 
Evidence:


## Outcome 6
> Another action is running → both selectors are disabled until it ends, like every button
Verdict: 
Evidence:


## Outcome 7
> `status` does not name the variant or the flavour, or names a value outside the two → that selector is disabled and shows `unknown`
Verdict: 
Evidence:


## Outcome 8
> Nothing is installed → the not-installed page, as before; no selectors
Verdict: 
Evidence:

