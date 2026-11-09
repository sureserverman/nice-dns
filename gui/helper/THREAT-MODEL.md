# nice-dns-helper threat model

Written before the code (Sub-plan 5 Task 2.1) and revised at the Stage 2
gate to the system as built: the helper, the root-ops it runs and the
installer's use of both (lib/root.sh, lib/install.sh). Where this and the
code disagree, one of them is wrong; the review that finds it fixes it.

## What the helper is

A small Rust program that lets the GUI, which has no terminal, run the
installer's root steps. It does not implement any root step. It checks who
is asking and what is asked, builds a clean environment, and `execve`s a
root-held copy of `root-ops` (the Bash allow-list in `deb/root-ops` and
`mac/root-ops`).

| | Linux | macOS |
|---|---|---|
| Helper | `/usr/libexec/nice-dns-helper`, run as `pkexec /usr/libexec/nice-dns-helper ...` | `/usr/local/libexec/nice-dns-helper`, root:wheel mode 4755 |
| Privilege comes from | polkit: the user authenticates as an admin | the setuid bit, no prompt |
| Root-held root-ops | `/usr/libexec/nice-dns/root-ops` | `/usr/local/libexec/nice-dns/root-ops` |
| Owner file | none | `/usr/local/libexec/nice-dns/owner` |

The paths are compiled in. The shipped binary has no flag, variable or file
that changes them. The test seam is a `Sys` trait compiled into every build;
the production implementation returns the constants, and the only other
implementation exists in the `#[cfg(test)]` build.

## Trust boundary

Trusted (root-held, checked before every exec):

- the helper binary itself;
- the compiled-in root-ops file, and its directory and every ancestor up to
  `/`: owned by root, not group- or world-writable; the file is a regular
  non-symlink file, owned by uid 0, mode exactly 0755;
- `/bin/bash` and the system `PATH` (`/usr/sbin:/usr/bin:/sbin:/bin`). These
  are root's own; the helper does not re-verify them.
- on macOS, the owner file (same rules as root-ops' directory chain, plus
  not group/other-writable).

Untrusted, validated, never believed:

- argv: verb, sub-verbs, paths. Every token is compared by exact string
  equality against fixed lists; no prefix match, no splitting;
- the environment: not read at all, except `PKEXEC_UID` on Linux (which
  pkexec sets itself), and it is only a uid that must name an existing
  non-root user;
- everything inherited: file descriptors, signal dispositions and mask,
  interval timers, umask, cwd, resource limits, supplementary groups. Each is
  reset or raised before exec (see "Hardening before exec" for exactly
  which).
- the caller's tree (`--tree`) and the files named to `install-helper`: they
  are the caller's own files. See "What an attacker running as the user
  gains".

## Caller identity

The caller is a uid, never a name or a home taken from the caller.

- Linux: the process must have ruid == euid == 0 (pkexec's shape) and
  `PKEXEC_UID` must be a plain decimal uid (digits only, no sign, no
  spaces, fits in u32, not 0, not `(uid_t)-1`) that the password database
  knows. A root user running the helper without pkexec has no `PKEXEC_UID`
  and is refused: root has no need of the helper.
- macOS: euid == 0 and real uid != 0 (the setuid shape). Then, owner
  decision OD-10: the helper serves only the user who installed it, and
  only while that user is an admin. The root-held file
  `/usr/local/libexec/nice-dns/owner` holds that user's decimal uid and one
  newline. It must be a regular non-symlink file owned by root, not
  group/other-writable, in a root-held directory chain. The real uid must
  equal it, and the user must be in group `admin` (looked up by name with
  `getgrnam`; membership with `getgrouplist`, which includes the primary
  gid).
- `ND_ROOT_USER` and `ND_ROOT_HOME` come from `getpwuid(caller uid)`. A name
  `root-ops` would refuse (empty, `root`, leading `-`, characters outside
  `[A-Za-z0-9._-]`, all digits) or a non-absolute home is refused here, with
  exit 1, before `root-ops` sees it.

## What an attacker running as the user gains

State this plainly, because it decides what the design is worth.

1. **Any process running as the (admin) user can ask the helper for any
   verb.** On macOS the helper is setuid and asks nothing: malware running
   as the user needs no password (OD-10). On Linux polkit asks an
   administrator's password, kept five minutes (`auth_admin_keep`), so the
   attacker needs the password or an open window. The installer makes such
   a window on purpose: one runner process runs every pkexec of an install
   (lib/root.sh, OD-11), and while its grant lasts **any process running as
   the installing user can hand that runner a request** (its directory is
   private to that uid, not to the installer) and get it run as root with no
   prompt, or raise a prompt that looks like the installer's. This is
   accepted and documented, not prevented (OD-14): the same process can
   already make root run its code by editing the install's tree (point 2).
2. **The verb list is not a barrier against the user.** The verbs run a tree
   and bytes the user supplies:
   - `--tree <dir>` is the user's own directory. `root-ops` runs scripts
     from it as root (`bash $T/deb/custom-dns-deb`,
     `bash $T/mac/start-container-root.sh`, `install -m 755 $T/...`). A
     user who controls the tree controls code run as root. The path grammar
     (under home, owned by the caller, no symlink) stops *other* users and
     confused paths; it cannot stop the owner from putting hostile scripts
     there.
   - `restore <owned> -` writes caller-supplied bytes to root-owned files
     that root later executes (`/usr/bin/custom-dns-deb`, the dispatcher
     hooks, `/etc/sudoers.d/start-container`). `visudo -c` checks a sudoers
     file's syntax, not its intent.
   - `install-helper` installs a caller-supplied binary as the privileged
     helper and, from the caller's tree, the root-held copy of `root-ops`
     itself, that is the allow-list (and on Linux the polkit action, which
     must match the tree's file). On macOS that is passwordless: it replaces
     the whole verb barrier.
   So on macOS the setuid helper is, in effect, passwordless root for
   whoever runs as the owner. On Linux it is root for whoever can
   authenticate. That is the same grant `sudo` gives an admin in a terminal
   (`root-ops` says so in its TRUST header). The helper's job is to make
   sure it is no *wider* than that: no other user, no environment trick, no
   path trick, no verb outside the table.
3. What the attacker does **not** gain from the helper alone: root for a
   different uid; root for a non-admin user on macOS; a shell on
   argv (no verb passes a caller string to a shell; but `root-ops` does run
   bash on files in the caller's tree, which is the grant in point 2);
   control of the environment, `PATH`, `LD_*`, `BASH_ENV`, cwd, inherited
   fds, interval timers, signal state or umask root-ops sees; or a resource
   limit low enough to kill root-ops mid-run (see "Hardening before exec").

## What the helper must never do

- Read a path, user name, home, root-ops location or owner-file location
  from the environment, argv or a file the caller controls. (`--tree` and
  the `install-helper` files are argv by design; they are checked, and
  passed on as data.)
- Run anything but `/bin/bash --noprofile --norc <root-ops> <verb> <args>`.
- Pass any environment variable but `PATH`, `ND_ROOT_USER`, `ND_ROOT_HOME`,
  `ND_ROOT_TREE`.
- Exec before every check has passed; exec with a real uid different from
  the effective uid (macOS `/bin/bash` drops euid to the real uid when they
  differ).
- Return 126 or 127 itself (pkexec uses them). A status the verb produces
  under `root-ops` passes through unchanged and can be anything.
- Follow a symlink in a path it validates.
- Contain a build-time or run-time override of the compiled-in paths.

## What root-ops does with what it is given (as built)

The contract Task 2.1 set was narrowed by OD-10 (macOS) and holds as follows.

- It trusts nothing of the environment but the three caller variables (and
  `SUDO_USER` under sudo); as root it unsets everything else first. The
  helper gives it `PATH` and those three only.
- It **does** use `ND_ROOT_TREE` for code root runs and installs: the DNS
  helpers, the dispatcher hooks and units, and, through `install-helper`, the
  root-held `root-ops` copy and the polkit action. Only `root-ops` itself is
  root-held (OD-10). The tree is checked as the caller's and under the
  caller's home; it is not checked against tampering by that caller.
- `install-helper` takes caller file paths, checked for shape (absolute, no
  `.`, `..` or symlink, a regular file); the helper checked them as under
  the home and owned by the caller first, and they can still change between
  that check and the use. The `root-ops` copy is installed under a temporary
  name and renamed; the helper binary is replaced by install(1) (unlink and
  write), and on macOS its setuid bit is set last, after its owner, so no
  setuid file exists with a wrong owner; a running helper keeps its inode.
- The helper's files are removed last: Linux `uninstall`, macOS
  `remove-helper` (the uninstall's last root step), so every earlier step can
  still use the helper. A failed macOS removal fails the uninstall and keeps
  the state for a retry.
- A step's own 126 or 127 leaves `deb/root-ops` as 125, so 126/127 are only
  ever pkexec's (dismissed, not authorised). `version` prints the helper
  version this `root-ops` expects.

The installer side (lib/root.sh) uses the helper only when it is root-owned
(macOS: 4755, its owner file naming this user, who is an admin), is that
version, its root-held `root-ops` is byte for byte the tree's, and the tree
is one the helper takes; `install-helper` and `dns` (macOS `agent`) take any
version. A step the helper refuses (2) or pkexec cannot authorise (127) runs
through sudo when sudo needs no password; anything else keeps to sudo. A
held copy left by a rolled-back install keeps the older tree on sudo until
the next install refreshes it.

## Order of refusals and exit codes

| Order | Check | Exit |
|---|---|---|
| 0 | `--version`, `--help`, `--list-verbs --platform P` (no root, no checks; another `--list-verbs` form exits 2) | 0 |
| 1 | no NUL/newline in any token; `--tree` before the verb; the verb and its fixed-list arguments; `--tree` present and not starting with `-`; `install-helper` files not starting with `-` | 2 |
| 2 | caller identity | 1 |
| 3 | path arguments against the caller's home: tree, `lib/install.sh`, `install-helper` files | 2 |
| 4 | root-ops trust chain | 3 |
| 5 | privilege setup, hardening, `execve` | 3 on failure |

Every refusal is prefixed `nice-dns-helper: `; one about a verb or an argument
names it (an empty argv, a missing `--tree` and a caller refusal say what is
missing instead). A token is shown with NUL, newline and other control
characters escaped, so a refusal is one line.

## Path grammar

Absolute; no empty, `.` or `..` component (so no trailing slash, no `//`);
every prefix is `lstat`ed and none is a symlink; strictly under the caller's
home as the password database gives it (compared per component, so
`/home/alice2` is not under `/home/alice`); every component below the home
is owned by the caller or by root and is not group- or other-writable (the
final component must be owned by the caller itself). The home and everything
above it are the system's and are not judged. `--tree` is a directory that holds `lib/` (a real
directory) with `lib/install.sh` a regular non-symlink file.
`install-helper` arguments are regular files.

## Hardening before exec

In this order, after the privilege step:

1. Real and effective uid and gid root (`setgroups([0])`, `setgid(0)`,
   `setuid(0)`, verified). Fds 0-2 are open (`/dev/null` for a closed one;
   also done at program start, so no later open lands on them).
2. Resource limits the caller could have lowered to make root-ops die
   mid-run: `RLIMIT_NOFILE` is raised to its hard limit (raising the hard
   limit too, as root, up to 1048576 on Linux and `kern.maxfilesperproc` on
   macOS), and `AS`, `DATA`, `NPROC`, `MEMLOCK`, `RSS`, `FSIZE`, `CPU` (and on
   Linux `SIGPENDING`, `MSGQUEUE`) are set to unlimited, or to the hard limit
   where it cannot be raised. `STACK` is raised to at least 8 MiB. `CORE` is
   set to 0 last, and a refusal to set it is fatal. Limits not listed
   (`NICE`, `RTPRIO`, `LOCKS` and the like) are not touched.
3. Every fd from 3 up is closed: on Linux with `close_range` (independent of
   any limit), otherwise (macOS) by closing each number up to the raised
   `NOFILE` limit. There is no enumeration of open fds (`proc_pidinfo` is not
   used), so an fd numbered above the raised limit would survive on macOS; a
   process cannot hold one, since the limit was at least that high when it
   was opened and root has raised both limits to the system maximum.
4. Signal mask empty and every disposition default (Rust ignores SIGPIPE, and
   an ignored signal survives `exec`).
5. `ITIMER_REAL`, `ITIMER_VIRTUAL` and `ITIMER_PROF` zeroed (a pending alarm
   survives `exec`).
6. umask 022; cwd `/`.

The process is then `execve`d with the four-variable environment. The
conversion from plan to C strings (`to_c`) is a pure function and is tested
alone; the `execve` call is tested in a forked child with the privilege step
skipped.

## Residual risks

- **User-controlled tree and bytes become root code** (above). The structural
  fix is for root-ops to run only root-held copies of every script and file it
  installs, and for the GUI to install a new release through a signed,
  root-verified path. Neither is in this task. Until then the macOS helper
  should be understood as "admin user's passwordless root".
- **Check-then-use races** on `--tree` and `install-helper` files: the user
  can swap a file after the helper looked. The checks reject accidents and
  other users; `root-ops` must re-check at use.
- **Home directories that are symlinks** (some immutable-distro layouts,
  `/home -> /var/home`) are refused by the no-symlink rule. A home with a
  trailing slash is refused as malformed.
- **Polkit retention.** `auth_admin_keep` lets a second request within the
  five-minute window skip the prompt, and polkit does not extend it on use.
  The installer's runner (OD-11) shows the prompt once per five minutes of
  an install (a long one asks again, possibly during a rollback); for that
  window any request the runner gets is authorised, from the installer or
  from any process of the same uid (OD-14), and it runs only this helper's
  path.
- **A reused uid inherits the macOS helper.** The owner file names a uid. If
  that user is deleted without an uninstall and the uid is given to a new
  admin, the new admin gets the passwordless helper.
- **Only mode bits are checked.** macOS ACLs and file flags (`uchg`,
  `restricted`) are not looked at, on the root-held chain or on caller paths.
- **A user-owned or group-writable `/usr/local` fails closed.** The root-held
  chain on macOS includes `/usr/local`; an Intel Homebrew install that gave
  it to the user makes the helper refuse to exec (exit 3).
- **Group-writable files under the home are refused.** A tree or file whose
  mode has group or other write (for example created under `umask 002` on a
  distribution with user-private groups) is refused with exit 2 until it is
  `chmod go-w`.
- **Groups.** `getgrouplist` on macOS reflects directory-service membership
  as the C library reports it; if `admin` membership is nested or the list is
  truncated the user is refused (fail closed).
- **Exit codes from root-ops** pass through unchanged. On Linux, where pkexec
  uses 126/127 for a dismissed or refused authorisation, deb/root-ops turns a
  step's own 126/127 into 125; mac/root-ops needs no such mapping.
- **The privileged macOS calls are not exercised by the tests.** The crate's
  whole test suite builds and passes on the Mac (getgrouplist included), but
  setuid, setgroups and the exec as root are only run by the live install
  (Sub-plan 5 Task 2.6).
