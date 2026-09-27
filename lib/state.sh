# shellcheck shell=bash
# nice-dns controller state (ARCH-02 state.sh, ARCH-03 commit_state). Sourced;
# Bash 3.2 compatible (macOS /bin/bash), safe under set -u, BSD and GNU
# userland (no flock: the lock is an atomic symlink).
#
#   nd_state_init                         create the state directory (0700)
#   nd_state_load                         print the validated state (0; 2 bad)
#   nd_state_lock                         take the mutation lock; print its token
#                                         (0; 3 held by a live actor; 2 bad dir)
#   nd_state_lock_held <token>            0 when <token> holds the lock
#   nd_state_unlock <token>               release (1 when <token> does not hold it)
#   nd_state_commit <token> <expected_generation> <file>
#                                         write <file> as generation expected+1;
#                                         print the new generation (0; 2 invalid
#                                         state or dir; 4 conflict: the stored
#                                         generation is not <expected>; 5 the
#                                         token does not hold the lock)
#   nd_state_stage <name> <cmd...>        run cmd WITHOUT the lock, then publish
#                                         its stdout as staged/<name> under a
#                                         short lock (cmd's status; 3 busy)
#
# The state directory (nd_platform_state_dir, or ND_STATE_DIR) is a real
# directory owned by the caller with no group or other permissions. It holds:
#   state.tsv         the committed state (below), 0600
#   .state.tsv.tmp.*  a commit in progress; ignored, removed by the next commit
#   lock              the mutation lock: a symlink whose target is
#                     nd-lock:<pid>:<boot_id>:<acquired_epoch>:<token>
#   lock.cad.*        a lock moved aside for a moment by compare-and-delete
#   staging/ staged/  nd_state_stage's output
#
# state.tsv is data; it is validated with awk and never sourced or evaluated:
#   schema          nice-dns-controller-state/1   (first line)
#   generation      N                (written by nd_state_commit only)
#   boot_id         the boot the state was last updated in, or -
#   updated         epoch of the last decision, or -
#   started         epoch the controller started in this boot, or -
#   route           the selected identity route, or -
#   outage_since    epoch of the first full-outage observation, or -
#   outage_restarts restarts issued during the current outage
#   last_action     - no-op switch-route refresh-bridges restart-component
#                   repair-runtime escalate
#   last_action_at  epoch, or -
#   recovery_at     epoch of the last restart or repair (the cooldown), or -
#   streak <route> <ok> <fail> <unknown>
#                   consecutive healthy / unhealthy / not-healthy observations
# Every key appears exactly once; streak rows once per route; nothing else.
#
# The lock belongs to the process that runs the controller ($$; subshells
# share it). A lock is stale, and is removed by compare-and-delete, when it was taken
# in another boot, its process is gone, or it is older than the lease
# (ND_STATE_LEASE_S, default 600). An acquisition time in the future (the
# wall clock moved back) never expires a lease. A reclaimed holder's token no
# longer holds the lock, so it can neither commit nor release. Long work (a
# bridge evaluation) runs through nd_state_stage and never holds the lock.
# Reaping and release both remove the lock by compare-and-delete: an atomic
# rename aside, a check of the value, and a restore when it changed hands.
# Known limit: if a third actor takes the free lock in the instant between the
# rename and the restore, two actors hold it; the restore failure is logged
# and generation-checked commits still refuse the stale writer.

ND_STATE_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"

if ! declare -F nd_platform_state_dir >/dev/null; then
  case "${ND_PLATFORM:-$(uname -s)}" in
    linux|Linux)
      # shellcheck source=lib/platform/linux.sh
      . "$ND_STATE_LIB_DIR/platform/linux.sh" ;;
    macos|Darwin)
      # shellcheck source=lib/platform/macos.sh
      . "$ND_STATE_LIB_DIR/platform/macos.sh" ;;
    *) printf 'state.sh: unsupported platform %s\n' "${ND_PLATFORM:-$(uname -s)}" >&2; return 1 ;;
  esac
fi

_ND_S_SCHEMA='nice-dns-controller-state/1'

_nd_state_dir() { nd_platform_state_dir; }

_nd_state_boot() {
  local b="${ND_BOOT_ID:-$(nd_platform_boot_id)}"
  case "$b" in ''|*[!A-Za-z0-9._-]*) printf 'unknown\n' ;; *) printf '%s\n' "$b" ;; esac
}

# _nd_state_private <path>: no group or other permission bits.
_nd_state_private() {
  [ -z "$(find "$1" -maxdepth 0 \( -perm -0040 -o -perm -0020 -o -perm -0010 -o -perm -0004 -o -perm -0002 -o -perm -0001 \) 2>/dev/null)" ]
}

# _nd_state_dir_ok <dir>: prints why not.
_nd_state_dir_ok() {
  if [ -L "$1" ]; then printf 'state directory %s is a symlink\n' "$1"; return 1; fi
  if [ ! -d "$1" ]; then printf 'state directory %s is missing\n' "$1"; return 1; fi
  if [ -z "$(find "$1" -maxdepth 0 -user "$(id -u)" 2>/dev/null)" ]; then
    printf 'state directory %s is not owned by uid %s\n' "$1" "$(id -u)"; return 1
  fi
  if ! _nd_state_private "$1"; then printf 'state directory %s is accessible by group or others\n' "$1"; return 1; fi
  return 0
}

nd_state_init() {
  local d msg
  d="$(_nd_state_dir)"
  if [ ! -e "$d" ] && [ ! -L "$d" ]; then (umask 077 && mkdir -p "$d") || { printf 'cannot create %s\n' "$d" >&2; return 2; }; fi
  msg="$(_nd_state_dir_ok "$d")" || { printf '%s\n' "$msg" >&2; return 2; }
}

# _nd_state_check <file> <with_generation 1|0>: validate; problems on stderr.
# With 0, a generation row is allowed and ignored.
_nd_state_check() {
  awk -F '\t' -v need="$2" -v schema="$_ND_S_SCHEMA" '
    function bad(m) { print "state line " NR ": " m > "/dev/stderr"; err = 1 }
    function num(v) { return v ~ /^[0-9]+$/ && length(v) <= 15 }
    function epoch(v) { return v == "-" || num(v) }
    function rid(v) { return v ~ /^[a-z0-9]+(-[a-z0-9]+)*$/ && length(v) <= 64 }
    /\r/ { bad("carriage return"); next }
    NR == 1 { if ($0 != "schema\t" schema) bad("the first line must be schema<TAB>" schema); next }
    $1 == "streak" {
      if (NF != 5) { bad("streak needs route, ok, fail and unknown"); next }
      if (!rid($2)) bad("bad streak route")
      if (!num($3) || !num($4) || !num($5)) bad("bad streak counts")
      if ($2 in st) bad("duplicate streak " $2)
      st[$2] = 1; next
    }
    NF != 2 { bad("expected key<TAB>value"); next }
    {
      k = $1; v = $2
      if (k in seen) bad("duplicate key " k)
      seen[k] = 1
      if (k == "generation") ok = num(v)
      else if (k == "boot_id") ok = v == "-" || (v ~ /^[A-Za-z0-9._-]+$/ && length(v) <= 64)
      else if (k == "updated" || k == "started" || k == "outage_since" || k == "last_action_at" || k == "recovery_at") ok = epoch(v)
      else if (k == "route") ok = v == "-" || rid(v)
      else if (k == "outage_restarts") ok = num(v)
      else if (k == "last_action") ok = v ~ /^(-|no-op|switch-route|refresh-bridges|restart-component|repair-runtime|escalate)$/
      else { bad("unknown key " k); next }
      if (!ok) bad("bad value for " k)
    }
    END {
      if (NR == 0) bad("empty state")
      n = split("boot_id updated started route outage_since outage_restarts last_action last_action_at recovery_at", req, " ")
      for (i = 1; i <= n; i++) if (!(req[i] in seen)) bad("missing key " req[i])
      if (need == 1 && !("generation" in seen)) bad("missing key generation")
      exit err ? 2 : 0
    }' "$1"
}

_nd_state_default() {
  printf 'schema\t%s\ngeneration\t0\nboot_id\t-\nupdated\t-\nstarted\t-\nroute\t-\n' "$_ND_S_SCHEMA"
  printf 'outage_since\t-\noutage_restarts\t0\nlast_action\t-\nlast_action_at\t-\nrecovery_at\t-\n'
}

nd_state_load() {
  local d f msg
  d="$(_nd_state_dir)"
  msg="$(_nd_state_dir_ok "$d")" || { printf '%s\n' "$msg" >&2; return 2; }
  f="$d/state.tsv"
  if [ -L "$f" ]; then printf '%s is a symlink\n' "$f" >&2; return 2; fi
  if [ ! -e "$f" ]; then _nd_state_default; return 0; fi
  if [ ! -f "$f" ]; then printf '%s is not a regular file\n' "$f" >&2; return 2; fi
  _nd_state_check "$f" 1 || return 2
  cat "$f"
}

_nd_state_generation() { nd_state_load | awk -F '\t' '$1 == "generation" { print $2 }'; }

# _nd_lock_stale <value>: 0 when the lock <value> may be removed (uses
# _ND_LK_NOW and _ND_LK_BOOT). A value that is not ours is stale.
_nd_lock_stale() {
  local tag pid boot acq lease="${ND_STATE_LEASE_S:-600}" IFS=:
  # Only [A-Za-z0-9._:-] is split below, so no glob can expand.
  case "$1" in *[!A-Za-z0-9._:-]*) return 0 ;; esac
  # shellcheck disable=SC2086
  set -- $1
  tag="${1:-}" pid="${2:-}" boot="${3:-}" acq="${4:-}"
  [ "$tag" = nd-lock ] && [ -n "${5:-}" ] || return 0
  case "$pid" in ''|*[!0-9]*) return 0 ;; esac
  [ "$boot" != "$_ND_LK_BOOT" ] && return 0
  kill -0 "$pid" 2>/dev/null || return 0
  case "$acq" in ''|*[!0-9]*) return 0 ;; esac
  [ "$acq" -le "$_ND_LK_NOW" ] && [ $((_ND_LK_NOW - acq)) -gt "$lease" ] && return 0
  return 1
}

# _nd_lock_cad <dir> <value>: compare-and-delete. Move the lock aside
# atomically, then remove it only if it held <value>; a lock that changed
# hands in between is put back. 0 removed; 1 the lock was not <value> (or
# is gone).
_nd_lock_cad() {
  local d="$1" want="$2" aside got
  aside="$d/lock.cad.$$.$RANDOM"
  mv "$d/lock" "$aside" 2>/dev/null || return 1
  got="$(readlink "$aside" 2>/dev/null)" || got=""
  if [ "$got" = "$want" ]; then rm -f "$aside"; return 0; fi
  # Not the observed value: another actor took the lock after it was read.
  # Restore it; if a third actor already holds a new lock, say so.
  if [ -n "$got" ] && ! ln -s "$got" "$d/lock" 2>/dev/null; then
    printf 'state lock: %s was displaced while %s was restored\n' "$got" "$(readlink "$d/lock" 2>/dev/null)" >&2
  fi
  rm -f "$aside"
  return 1
}

nd_state_lock() {
  local d msg cur tok val
  d="$(_nd_state_dir)"
  msg="$(_nd_state_dir_ok "$d")" || { printf '%s\n' "$msg" >&2; return 2; }
  _ND_LK_NOW="$(date +%s)" _ND_LK_BOOT="$(_nd_state_boot)"
  tok="$$-$_ND_LK_NOW-$RANDOM$RANDOM"
  val="nd-lock:$$:$_ND_LK_BOOT:$_ND_LK_NOW:$tok"
  if ln -s "$val" "$d/lock" 2>/dev/null; then printf '%s\n' "$tok"; return 0; fi
  if [ -e "$d/lock" ] && [ ! -L "$d/lock" ]; then printf '%s/lock is not a lock symlink\n' "$d" >&2; return 2; fi
  cur="$(readlink "$d/lock" 2>/dev/null)" || cur=""
  if [ -n "$cur" ] && _nd_lock_stale "$cur" && _nd_lock_cad "$d" "$cur" \
     && ln -s "$val" "$d/lock" 2>/dev/null; then
    printf '%s\n' "$tok"; return 0
  fi
  cur="$(readlink "$d/lock" 2>/dev/null)" || cur=""
  printf 'state lock is held: %s\n' "${cur:-unreadable}" >&2
  return 3
}

nd_state_lock_held() {
  local d cur
  d="$(_nd_state_dir)"
  [ -n "${1:-}" ] || return 1
  cur="$(readlink "$d/lock" 2>/dev/null)" || return 1
  case "$cur" in nd-lock:*:*:*:"$1") return 0 ;; esac
  return 1
}

nd_state_unlock() {
  local d cur
  d="$(_nd_state_dir)"
  nd_state_lock_held "${1:-}" || { printf 'the lock is not held by token %s\n' "${1:-}" >&2; return 1; }
  cur="$(readlink "$d/lock" 2>/dev/null)" || return 1
  _nd_lock_cad "$d" "$cur" || { printf 'the lock changed hands before release\n' >&2; return 1; }
}

nd_state_commit() {
  local tok="${1:-}" exp="${2:-}" f="${3:-}" d msg cur t
  d="$(_nd_state_dir)"
  msg="$(_nd_state_dir_ok "$d")" || { printf '%s\n' "$msg" >&2; return 2; }
  case "$exp" in ''|*[!0-9]*) printf 'expected generation must be a number, got %s\n' "$exp" >&2; return 2 ;; esac
  nd_state_lock_held "$tok" || { printf 'commit refused: token %s does not hold the state lock\n' "$tok" >&2; return 5; }
  [ -f "$f" ] && [ ! -L "$f" ] || { printf 'next state %s is not a regular file\n' "$f" >&2; return 2; }
  _nd_state_check "$f" 0 || return 2
  cur="$(_nd_state_generation)" || return 2
  if [ "$cur" != "$exp" ]; then
    printf 'commit conflict: stored generation is %s, expected %s\n' "$cur" "$exp" >&2
    return 4
  fi
  rm -f "$d"/.state.tsv.tmp.*
  t="$d/.state.tsv.tmp.$$"
  { printf 'schema\t%s\ngeneration\t%s\n' "$_ND_S_SCHEMA" $((exp + 1))
    awk -F '\t' 'NR > 1 && $1 != "generation"' "$f"; } | (umask 077 && cat >"$t") || { rm -f "$t"; return 2; }
  mv -f "$t" "$d/state.tsv" || { rm -f "$t"; return 2; }
  printf '%s\n' $((exp + 1))
}

nd_state_stage() {
  local name="${1:-}" d msg out rc tok i=0
  shift
  case "$name" in ''|*[!a-z0-9-]*) printf 'bad staging name %s\n' "$name" >&2; return 2 ;; esac
  d="$(_nd_state_dir)"
  msg="$(_nd_state_dir_ok "$d")" || { printf '%s\n' "$msg" >&2; return 2; }
  (umask 077 && mkdir -p "$d/staging" "$d/staged") || return 2
  out="$d/staging/.$name.$$"
  (umask 077 && "$@" >"$out"); rc=$?
  if [ "$rc" -ne 0 ]; then rm -f "$out"; return "$rc"; fi
  while ! tok="$(nd_state_lock 2>/dev/null)"; do
    i=$((i + 1))
    if [ "$i" -ge 20 ]; then rm -f "$out"; printf 'state lock stayed busy; %s not published\n' "$name" >&2; return 3; fi
    sleep 0.5
  done
  mv -f "$out" "$d/staged/$name"; rc=$?
  nd_state_unlock "$tok"
  return "$rc"
}
