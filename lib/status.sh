# shellcheck shell=bash
# lib/status.sh: the `nice-dns status` contract (nice-dns-status/1,
# docs/cli-contract.md). nd_status_rows prints one TSV row per fact:
#   schema  nice-dns-status/1
#   <group> <key> <value>...
# It reads files only: the install's current generation, the controller's
# receipt, state, journal and last observations (observations.tsv, written
# after each pass), the bridge files and the update-check cache. It starts no
# probe, no runtime CLI, no scheduler and nothing that uses the network, so a
# GUI can poll it every few seconds; its whole PATH may be awk, cat, date, tr
# and cut. When nothing is installed the `nice-dns` command adds the
# install hint (the README's install line). A file that is there but cannot
# be read (permissions, an unreachable parent, the wrong kind of file, or
# content that is not what the controller writes) is never read as absent:
# its group gets an `unreadable` row and the status is 2. A value from a
# file is printed without control characters, as health/nice-dns-health
# install_report does. Written for macOS's Bash 3.2.

ND_STATUS_SCHEMA=nice-dns-status/1

# _nd_st_clean: a value from a file, safe in a TSV field (no control
# characters, tabs included; at most 200 characters).
_nd_st_clean() { tr -d '\000-\037\177' | cut -c1-200; }

# _nd_st_row <group> <key> [value...]: one row; every value is cleaned.
_nd_st_row() {
  local g="$1" k="$2" v out
  shift 2
  out="$g	$k"
  for v in "$@"; do out="$out	$(printf '%s' "$v" | _nd_st_clean)"; done
  printf '%s\n' "$out"
}

# _nd_st_field <file> <key>: the second column of the first row keyed <key>.
_nd_st_field() { awk -F '\t' -v k="$2" '$1 == k { print $2; exit }' "$1" 2>/dev/null; }

# _nd_st_epoch <value>: 0 when it is a plain epoch (no leading zero, at most
# 11 digits), which shell arithmetic reads as decimal without overflow.
_nd_st_epoch() { case "$1" in ''|0*|*[!0-9]*|????????????*) return 1 ;; esac; }

# _nd_st_reach <path> <f|d>: 0 readable (a regular file; a directory that is
# no symlink, as nd_state_init requires, and can be listed and entered),
# 1 absent, 2 there but unreadable, of the wrong kind, or behind a parent
# directory that cannot be entered. A FIFO is never opened.
_nd_st_reach() {
  local p="$1" a
  if [ -e "$p" ] || [ -L "$p" ]; then
    case "$2" in
      f) [ -f "$p" ] && [ -r "$p" ] && return 0 ;;
      d) [ -d "$p" ] && [ ! -L "$p" ] && [ -r "$p" ] && [ -x "$p" ] && return 0 ;;
    esac
    return 2
  fi
  a="${p%/*}"
  while [ -n "$a" ] && [ ! -e "$a" ]; do a="${a%/*}"; done
  if [ -n "$a" ] && { [ ! -d "$a" ] || [ ! -x "$a" ]; }; then return 2; fi
  return 1
}

# _nd_st_short <path>: the path as the owner knows it (~/ for $HOME).
# shellcheck disable=SC2088  # a literal ~ for the reader, never expanded
_nd_st_short() { case "$1" in "$HOME"/*) printf '~/%s\n' "${1#"$HOME"/}" ;; *) printf '%s\n' "$1" ;; esac; }

# _nd_st_paths <linux|macos>: sets the locations, the same ones the
# installer (lib/install.sh), the controller (health/nice-dns-health,
# lib/platform/*.sh nd_platform_state_dir) and the nice-dns command use.
_nd_st_paths() {
  local state="${XDG_STATE_HOME:-$HOME/.local/state}" cfg="${XDG_CONFIG_HOME:-$HOME/.config}"
  ND_ST_CONFIG_DIR="${ND_BRIDGE_CONFIG_DIR:-$cfg/nice-dns}"
  case "$1" in
    macos)
      ND_ST_INSTALL_DIR="$HOME/Library/Application Support/nice-dns-install"
      ND_ST_STATE_DIR="${ND_STATE_DIR:-$HOME/Library/Application Support/nice-dns/controller}"
      ND_ST_RECEIPT="$HOME/Library/Application Support/nice-dns-health/install.tsv"
      ND_ST_SCHEDULE="$HOME/Library/LaunchAgents/org.nice-dns.health.plist"
      ND_ST_ADMIN_URL="http://172.31.240.250/admin"
      ND_ST_HELPER=/usr/local/libexec/nice-dns-helper ;;
    *)
      ND_ST_INSTALL_DIR="$state/nice-dns-install"
      ND_ST_STATE_DIR="${ND_STATE_DIR:-$state/nice-dns/controller}"
      ND_ST_RECEIPT="${XDG_DATA_HOME:-$HOME/.local/share}/nice-dns-health/install.tsv"
      ND_ST_SCHEDULE="$cfg/systemd/user/default.target.wants/nice-dns-health.timer"
      ND_ST_ADMIN_URL="http://localhost:8880/admin"
      ND_ST_HELPER=/usr/libexec/nice-dns-helper ;;
  esac
}

# _nd_st_bridges <config dir> <state dir>: the bridges rows (mode, count,
# last_refresh), shared by `nice-dns status` and `nice-dns bridges status`.
# The mode file is read with awk, never sourced (DEC-001). Returns 2 when a
# file it reads is there but cannot be read.
_nd_st_bridges() {
  local cfg="$1" sd="$2" rc=0 bmode=on n=0 refresh=never
  _nd_st_reach "$cfg/bridges-mode.env" f
  case $? in
    0) case "$(awk -F '=' '$1 == "TOR_BRIDGES" { print $2; exit }' "$cfg/bridges-mode.env")" in off) bmode=off ;; esac ;;
    2) _nd_st_row bridges unreadable "cannot read $(_nd_st_short "$cfg/bridges-mode.env")"; rc=2 ;;
  esac
  _nd_st_row bridges mode "$bmode"
  _nd_st_reach "$cfg/bridges.env" f
  case $? in
    0) n="$(awk '/^BRIDGE[0-9]+=/ { n++ } END { print n + 0 }' "$cfg/bridges.env")" ;;
    2) _nd_st_row bridges unreadable "cannot read $(_nd_st_short "$cfg/bridges.env")"; rc=2 ;;
  esac
  _nd_st_row bridges count "$n"
  _nd_st_reach "$sd/bridges.last" f
  case $? in
    0) refresh="$(awk 'NR == 1 { print $1; exit }' "$sd/bridges.last")"; _nd_st_epoch "$refresh" || refresh=never ;;
    2) _nd_st_row bridges unreadable "cannot read $(_nd_st_short "$sd/bridges.last")"; rc=2 ;;
  esac
  _nd_st_row bridges last_refresh "$refresh"
  return "$rc"
}

# nd_status_rows <linux|macos>: prints the rows. Returns 0, 1 when nothing
# is installed, 2 when a file it reads is there but cannot be read (2 wins).
# ND_STATUS_NOW (epoch) and ND_STATUS_STALE_S (seconds, default 300) are for
# tests; a value that is not a plain number is ignored.
nd_status_rows() {
  local plat="${1:-linux}" now stale_s=300 rc=0 st
  local gen="" m="" mode last verdict age obs cache r sd v
  now="${ND_STATUS_NOW:-}"
  _nd_st_epoch "$now" || now="$(date +%s)"
  case "${ND_STATUS_STALE_S:-}" in ''|0*|*[!0-9]*|??????*) ;; *) stale_s="$ND_STATUS_STALE_S" ;; esac
  _nd_st_paths "$plat"
  sd="$ND_ST_STATE_DIR"
  printf 'schema\t%s\n' "$ND_STATUS_SCHEMA"

  # install
  _nd_st_reach "$ND_ST_INSTALL_DIR/current" f; st=$?
  if [ "$st" = 0 ]; then
    gen="$(cat "$ND_ST_INSTALL_DIR/current" 2>/dev/null)"
    case "$gen" in ''|.*|*[!A-Za-z0-9._-]*) st=3 ;; *) m="$ND_ST_INSTALL_DIR/generations/$gen/prepare.tsv" ;; esac
  fi
  if [ "$st" = 0 ]; then _nd_st_reach "$m" f; st=$?; fi
  case "$st" in
    0)
      _nd_st_row install installed yes
      _nd_st_row install generation "$gen"
      _nd_st_row install source_commit "$(_nd_st_field "$m" source_commit)"
      _nd_st_row install branch "$(_nd_st_field "$m" branch)"
      _nd_st_row install variant "$(_nd_st_field "$m" variant)"
      _nd_st_row install pihole "$(_nd_st_field "$m" pihole)"
      _nd_st_row install platform "$(_nd_st_field "$m" platform)"
      _nd_st_row install lock "$(_nd_st_field "$m" lock)" ;;
    1)
      m=""
      _nd_st_row install installed no
      rc=1 ;;
    2)
      _nd_st_row install unreadable "cannot read $(_nd_st_short "${m:-$ND_ST_INSTALL_DIR/current}")"
      m="" rc=2 ;;
    *)
      m=""
      _nd_st_row install unreadable "$(_nd_st_short "$ND_ST_INSTALL_DIR/current") names no generation"
      rc=2 ;;
  esac

  # controller
  _nd_st_reach "$ND_ST_RECEIPT" f
  case $? in
    0) mode="$(_nd_st_field "$ND_ST_RECEIPT" mode)"; _nd_st_row controller mode "${mode:-active}" ;;
    1) _nd_st_row controller mode not-installed ;;
    *) _nd_st_row controller unreadable "cannot read $(_nd_st_short "$ND_ST_RECEIPT")"; rc=2 ;;
  esac
  obs="$sd/observations.tsv"
  last="" verdict=""
  _nd_st_reach "$sd" d; st=$?
  if [ "$st" = 2 ]; then
    _nd_st_row controller unreadable "cannot read $(_nd_st_short "$sd")"; rc=2
  elif [ "$st" = 0 ]; then
    _nd_st_reach "$obs" f; st=$?
    if [ "$st" = 2 ]; then
      _nd_st_row controller unreadable "cannot read $(_nd_st_short "$obs")"; rc=2
    elif [ "$st" = 0 ]; then
      last="$(awk -F '\t' 'NR == 1 && $0 != "schema\tnice-dns-observations/1" { exit } $1 == "pass" { print $2; exit }' "$obs")"
      verdict="$(awk -F '\t' '$1 == "pass" { print $3; exit }' "$obs")"
      if ! _nd_st_epoch "$last"; then
        _nd_st_row controller unreadable "$(_nd_st_short "$obs") is not a pass the controller wrote"; rc=2
        last="" obs=""
      fi
    else
      obs=""
    fi
  else
    obs=""
  fi
  if [ -z "$last" ]; then
    _nd_st_row controller last_pass never
    _nd_st_row controller verdict unknown
    _nd_st_row controller stale never
  else
    age=$((now - last))
    _nd_st_row controller last_pass "$last"
    _nd_st_row controller verdict "$verdict"
    if [ "$age" -lt 0 ]; then _nd_st_row controller stale future
    elif [ "$age" -gt "$stale_s" ]; then _nd_st_row controller stale "$age"
    else _nd_st_row controller stale no; fi
  fi
  if [ -e "$ND_ST_SCHEDULE" ]; then _nd_st_row controller schedule loaded; else _nd_st_row controller schedule stopped; fi

  # obs: the controller's own records, copied as written (control characters
  # other than the tab separators removed; at most 400 characters a row). The
  # newline is printed here: BSD cut adds none to a line that has lost it.
  if [ -n "$obs" ] && [ -n "$last" ]; then
    awk -F '\t' '$1 == "obs"' "$obs" | while IFS= read -r r; do
      printf '%s\n' "$(printf '%s' "$r" | tr -d '\000-\010\012-\037\177' | cut -c1-400)"
    done
  fi

  # route
  _nd_st_reach "$sd/state.tsv" f
  case $? in
    0)
      r="$(_nd_st_field "$sd/state.tsv" route)"
      case "$r" in ''|-) ;; *) _nd_st_row route selected "$r" "$(_nd_st_field "$sd/state.tsv" generation)" ;; esac ;;
    2) _nd_st_row route unreadable "cannot read $(_nd_st_short "$sd/state.tsv")"; rc=2 ;;
  esac

  # bridges
  _nd_st_bridges "$ND_ST_CONFIG_DIR" "$sd" || rc=2

  # update: the cache `nice-dns update --check` writes
  cache="$sd/update-check.tsv"
  _nd_st_reach "$cache" f; st=$?
  if [ "$st" = 0 ] && [ "$(awk 'NR == 1 { print; exit }' "$cache")" = "schema	nice-dns-update-check/1" ]; then
    r="$(_nd_st_field "$cache" result)"
    case "$r" in current|available|unknown) ;; *) r=unknown ;; esac
    _nd_st_row update result "$r"
    _nd_st_row update checked_at "$(_nd_st_field "$cache" checked_at)"
    _nd_st_row update remote_commit "$(_nd_st_field "$cache" remote_commit)"
  elif [ "$st" = 1 ]; then
    _nd_st_row update result unknown never-checked
  else
    _nd_st_row update result unknown unreadable
    _nd_st_row update unreadable "cannot read $(_nd_st_short "$cache")"; rc=2
  fi

  # helper: nice-dns-helper, which actions without a terminal need (Sub-plan
  # 5). Its file is looked at, never run; the version is what the current
  # generation recorded after it installed or found the helper.
  _nd_st_row helper path "$ND_ST_HELPER"
  if [ -f "${ND_INST_ROOT:-}$ND_ST_HELPER" ] && [ -x "${ND_INST_ROOT:-}$ND_ST_HELPER" ]; then
    _nd_st_row helper installed yes
  else
    _nd_st_row helper installed no
  fi
  v=""
  [ -z "$m" ] || v="$(_nd_st_field "$m" helper)"
  _nd_st_row helper version "${v:-unknown}"

  # admin
  _nd_st_row admin url "$ND_ST_ADMIN_URL"
  if [ -n "$m" ]; then
    _nd_st_row admin password_path "$(awk -F '\t' '$1 == "credential" && $2 == "pihole-admin" { print $3; exit }' "$m")"
  fi

  # recent: the last five journal rows (epoch, target, result); an empty
  # field is printed as -
  _nd_st_reach "$sd/recovery.tsv" f
  case $? in
    0)
      awk -F '\t' 'NF >= 4 && $1 ~ /^[0-9]+$/ { r[++n] = $1 "\t" ($3 == "" ? "-" : $3) "\t" ($4 == "" ? "-" : $4) }
        END { for (i = n - 4; i <= n; i++) if (i > 0) print r[i] }' "$sd/recovery.tsv" |
        while IFS='	' read -r e a s; do _nd_st_row recent "$e" "$a" "$s"; done ;;
    2) _nd_st_row recent unreadable "cannot read $(_nd_st_short "$sd/recovery.tsv")"; rc=2 ;;
  esac
  return "$rc"
}
