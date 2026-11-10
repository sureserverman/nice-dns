# Task 2.3 — live on mint

Run `20261109T205402Z-2c933b54` (b9127e2): `bash tests/run.sh live gui-linux
--live --targets tests/live/targets.env --platforms linux` — 9/9 passed;
`bash tests/run.sh receipt gui-linux` — cells=1 scenarios=6 errors=0
limits=1 (`receipt.tsv` here).

- **Install** from a clone of HEAD: `nice-dns-gui 0.1.0` at
  `~/.local/bin/nice-dns-gui`, the launcher's Exec names it,
  `desktop-file-validate` exit 0, the icon and the files present;
  `nice-dns-gui --check` over ssh exit 0, naming generation
  `20261109T205421Z-b9127e2fba9e`; DNS resolves.
- **Screenshot** in the user's X session (systemd-run --user): exit 0, the
  PNG fetched and its sha256 matched (`gui-linux-run.png`, 720×860). It was
  taken seconds after the install, so it shows the controller's settle:
  `FAIL [runtime]`, Pi-hole `indeterminate` (its `podman inspect` exited 1
  mid-start). Read by the session. Within 30 s of the final install the
  controller said OK; the README's image (`docs/images/gui-linux.png`) is a
  later screenshot of the same session with the stack healthy.
- **Restart** through `--run-action restart --exit`: exit 0, the pane's last
  line `finished (exit 0)`, DNS resolves afterwards.
- **Update check** through `--run-action update-check --exit`: exit 10, the
  pane's last line `an update is available (exit 10)` (HEAD differs from
  `main`).
- **Uninstall**: the program, launcher, icon and files gone; host DNS given
  back. **Final install**: all back.

Cycle 1 (run `20261109T204231Z-97e60dac`, c46c35f): every step passed but the
update check, which got exit 1, `unknown: the installed source was not a
clean commit`. That is the contract's answer for an install from an archive
(source commit unknown, DEC-023, Sub-plan 3 OD-6). The harness now installs
from a git bundle of HEAD (`command --mode install-git`, b9127e2).

Limit (in the receipt): no person clicked; the hooks run `Ui::run`, the code
a click runs, with no dialog. The restart needs no root, so no polkit prompt.
