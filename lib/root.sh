# shellcheck shell=bash
# nd_root_deb / nd_root_mac <verb> [args]: the one way installer code runs a
# step as root (Sub-plan 5): the verb of deb/root-ops or mac/root-ops in the
# tree the install runs from (ND_INST_TREE), under sudo from a terminal.
# The verbs, their arguments and what each one does: those scripts.
#
# On Linux the installed helper is used instead (Stage 2, gui/helper) when it
# is a root-owned file, it is the version the tree's root-ops expects, and the
# tree is one the helper takes (_nd_root_tree_ok): pkexec runs it, and polkit
# asks for an administrator's password, with or without a terminal.
# install-helper, which replaces the helper, and dns, which the install's
# first root step (the ownership check) runs before the helper is refreshed,
# take a helper of any version: dns runs the tree's deb/custom-dns-deb, whose
# verbs every root-ops since the helper's first allows.
# ND_INST_ROOT (the fixture tests' root prefix) also makes "root-owned" mean
# owned by the test user, or by ND_INST_ROOT_OWNER (a uid) when that is set;
# neither is read without ND_INST_ROOT.
ND_ROOT_HELPER_DEB=/usr/libexec/nice-dns-helper

# _nd_root_uid_of <path>: its owner's uid (GNU or BSD stat).
_nd_root_uid_of() { stat -c %u "$1" 2>/dev/null || stat -f %u "$1" 2>/dev/null; }

# _nd_root_mode_of <path>: its permission bits in octal (GNU or BSD stat).
_nd_root_mode_of() { stat -c %a "$1" 2>/dev/null || stat -f %Lp "$1" 2>/dev/null; }

# _nd_root_helper_file_deb: prints the helper's path when it is installed: an
# executable, root-owned regular file.
_nd_root_helper_file_deb() {
  local h="${ND_INST_ROOT:-}$ND_ROOT_HELPER_DEB" want=0
  [ -n "${ND_INST_ROOT:-}" ] && want="${ND_INST_ROOT_OWNER:-$(id -u)}"
  [ -f "$h" ] && [ ! -L "$h" ] && [ -x "$h" ] || return 1
  [ "$(_nd_root_uid_of "$h")" = "$want" ] || return 1
  printf '%s\n' "$h"
}

# _nd_root_helper_version_ok_deb: 0 when the installed helper's --version is
# the one the tree's root-ops expects.
_nd_root_helper_version_ok_deb() {
  local h v w
  h="$(_nd_root_helper_file_deb)" || return 1
  w="$(sed -n 's/^ND_HELPER_VERSION=\([0-9][0-9.]*\)$/\1/p' "$ND_INST_TREE/deb/root-ops" 2>/dev/null | head -n 1)"
  v="$("$h" --version 2>/dev/null)" || return 1
  [ -n "$w" ] && [ "$v" = "$w" ]
}

# _nd_root_tree_ok: 0 when the helper takes ND_INST_TREE (gui/helper
# check_tree): under $HOME, no empty, . or .. component, every directory
# below $HOME down to it a real directory owned by this user or root and
# writable by neither its group nor others, the tree itself this user's. A
# tree outside $HOME (a clone in /tmp) or under umask 002 keeps to sudo.
_nd_root_tree_ok() {
  local t="${ND_INST_TREE:-}" h="${HOME:-}" p me m u
  case "$h" in /?*) ;; *) return 1 ;; esac
  case "$t/" in "$h"/?*) ;; *) return 1 ;; esac
  case "$t/" in *//*|*/./*|*/../*) return 1 ;; esac
  me="$(id -u)"
  [ "$(_nd_root_uid_of "$t")" = "$me" ] || return 1
  p="$t"
  while [ "$p" != "$h" ]; do
    [ -d "$p" ] && [ ! -L "$p" ] || return 1
    u="$(_nd_root_uid_of "$p")" && m="$(_nd_root_mode_of "$p")" || return 1
    [ "$u" = "$me" ] || [ "$u" = 0 ] || return 1
    case "$m" in *[2367]?|*[2367]) return 1 ;; esac
    p="${p%/*}"
  done
}

# _nd_root_helper_deb [any]: prints the helper's path when it can be used.
_nd_root_helper_deb() {
  local h
  h="$(_nd_root_helper_file_deb)" || return 1
  _nd_root_tree_ok || return 1
  [ "${1:-}" = any ] || _nd_root_helper_version_ok_deb || return 1
  printf '%s\n' "$h"
}

# The runner (OD-11). polkit keeps an administrator's authorisation for the
# process that ran pkexec, and for 5 minutes (polkit 124: pkexec names its
# parent as the subject). The installer runs root steps from subshells and
# child scripts, so each would ask again. nd_root_runner_start, called by the
# installer's own shell, starts one process that runs every pkexec of the
# install: polkit asks once, then again after 5 minutes of a long install.
# Requests travel through a private directory (ND_ROOT_RUNNER, exported with
# ND_ROOT_RUNNER_PID so a child script such as deb/persistent-podman.sh uses
# the same runner): the arguments and any stdin as files, an id over the req
# FIFO, the step's output back as files (printed when the step ends: a FIFO
# loses what is written before its reader opens it), its status over a FIFO
# the caller holds open from the start. Both FIFOs are opened read-write, so
# neither side hangs on a dead peer; a caller whose runner died gets status 1. The runner ends with the shell
# that started it (checked every 2 s) or at nd_root_runner_stop. With no
# runner, pkexec runs directly.
nd_root_runner_start() {
  local d parent=$$ ok=""
  if [ -n "${ND_ROOT_RUNNER_PID:-}" ] && kill -0 "$ND_ROOT_RUNNER_PID" 2>/dev/null; then return 0; fi
  d="$(mktemp -d "${TMPDIR:-/tmp}/nice-dns-root.XXXXXXXX")" || return 1
  d="$(cd "$d" && pwd -P)" || return 1
  if ! chmod 700 "$d" || ! mkfifo -m 600 "$d/req" "$d/ready"; then rm -rf "${d:?}"; return 1; fi
  _nd_root_runner_loop "$d" "$parent" </dev/null >/dev/null 2>&1 &
  ND_ROOT_RUNNER="$d" ND_ROOT_RUNNER_PID=$!
  # Requests only once the runner holds req open: a line written to a FIFO
  # no one holds is lost, and its caller would wait for good.
  read -r -t 10 ok 0<>"$d/ready" || ok=""
  if [ "$ok" != ready ]; then nd_root_runner_stop; return 1; fi
  export ND_ROOT_RUNNER ND_ROOT_RUNNER_PID
}

nd_root_runner_stop() {
  [ -n "${ND_ROOT_RUNNER_PID:-}" ] || return 0
  kill "$ND_ROOT_RUNNER_PID" 2>/dev/null || true
  [ -z "${ND_ROOT_RUNNER:-}" ] || rm -rf "${ND_ROOT_RUNNER:?}"
  ND_ROOT_RUNNER="" ND_ROOT_RUNNER_PID=""
}

# _nd_root_runner_loop <dir> <parent pid>: the runner's body.
_nd_root_runner_loop() {
  local d="$1" parent="$2" id a rc in helper="${ND_INST_ROOT:-}$ND_ROOT_HELPER_DEB"
  exec 3<>"$d/req"
  printf 'ready\n' 1<>"$d/ready"
  while kill -0 "$parent" 2>/dev/null; do
    id=""
    read -r -t 2 id <&3 || continue
    case "$id" in r.*) ;; *) continue ;; esac
    case "$id" in *[!A-Za-z0-9.]*) continue ;; esac
    [ -f "$d/$id.args" ] || continue
    set --
    while IFS= read -r -d '' a; do set -- "$@" "$a"; done <"$d/$id.args"
    # The polkit authorisation this process holds is for the helper only.
    if [ "${1:-}" != "$helper" ]; then printf '1\n' 1<>"$d/$id.rc"; continue; fi
    in=/dev/null
    [ ! -f "$d/$id.in" ] || in="$d/$id.in"
    rc=0
    pkexec "$@" <"$in" >"$d/$id.out" 2>"$d/$id.err" || rc=$?
    printf '%s\n' "$rc" 1<>"$d/$id.rc"
  done
  rm -rf "${d:?}"
}

# _nd_root_via_runner <stdin: 0|1> <pkexec args...>: one request; returns
# pkexec's status.
_nd_root_via_runner() {
  local d="$ND_ROOT_RUNNER" want_in="$1" t id rc=""
  shift
  t="$(mktemp "$d/r.XXXXXXXX")" || return 1
  id="${t##*/}"
  printf '%s\0' "$@" >"$t.args"
  [ "$want_in" = 0 ] || cat >"$t.in"
  if ! mkfifo -m 600 "$t.rc"; then rm -f "$t" "$t".*; return 1; fi
  {
    printf '%s\n' "$id" >&9
    until read -r -t 2 rc <&8; do
      kill -0 "$ND_ROOT_RUNNER_PID" 2>/dev/null || { rc=1; break; }
    done
  } 8<>"$t.rc" 9<>"$d/req"
  [ ! -f "$t.out" ] || cat "$t.out"
  [ ! -f "$t.err" ] || cat "$t.err" >&2
  rm -f "$t" "$t".*
  case "$rc" in ''|*[!0-9]*) rc=1 ;; esac
  return "$rc"
}

nd_root_deb() {
  local h rc=0 any="" want_in=0
  case "${1:-}" in install-helper|dns) any=any ;; esac
  if h="$(_nd_root_helper_deb $any)"; then
    [ "${1:-}" = restore ] && [ "${3:-}" = - ] && want_in=1
    if [ -n "${ND_ROOT_RUNNER_PID:-}" ] && [ -p "${ND_ROOT_RUNNER:-}/req" ] && kill -0 "$ND_ROOT_RUNNER_PID" 2>/dev/null; then
      _nd_root_via_runner "$want_in" "$h" --tree "${ND_INST_TREE:?}" "$@" || rc=$?
    else
      pkexec "$h" --tree "${ND_INST_TREE:?}" "$@" || rc=$?
    fi
    # root-ops turns a step's own 126 or 127 into 125, so these are pkexec's.
    case "$rc" in
      126) echo "nice-dns: authorisation cancelled" >&2 ;;
      127) echo "nice-dns: not authorised" >&2 ;;
    esac
    return "$rc"
  fi
  sudo bash "${ND_INST_TREE:?}"/deb/root-ops "$@"
}
nd_root_mac() { sudo bash "${ND_INST_TREE:?}"/mac/root-ops "$@"; }
