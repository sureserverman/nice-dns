# shellcheck shell=bash
# lib/status.sh: the `nice-dns status` contract (nice-dns-status/1,
# docs/cli-contract.md). nd_status_rows prints one TSV row per fact:
#   schema  nice-dns-status/1
#   <group> <key> <value>...
# It reads files only: the install's current generation, the controller's
# receipt, state, journal and last observations (observations.tsv, written
# after each pass), the bridge files and the update-check cache. It runs no
# probe, no container runtime, no scheduler and no network call, so a GUI can
# poll it every few seconds; its whole PATH may be awk, sed, cat, date, tr and
# cut. A value from a file is printed without control characters, as
# health/nice-dns-health install_report does. Written for macOS's Bash 3.2.

ND_STATUS_SCHEMA=nice-dns-status/1

# _nd_st_clean: a value from a file, safe in a TSV field (no control
# characters, tabs included; at most 200 bytes).
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

# _nd_st_paths <linux|macos>: sets the locations, the same ones the
# installer (lib/install.sh), the controller (health/nice-dns-health,
# lib/platform/*.sh nd_platform_state_dir) and the nice-dns command use.
_nd_st_paths() {
  local state="${XDG_STATE_HOME:-$HOME/.local/state}" cfg="${XDG_CONFIG_HOME:-$HOME/.config}"
  ND_ST_CONFIG_DIR="$cfg/nice-dns"
  case "$1" in
    macos)
      ND_ST_INSTALL_DIR="$HOME/Library/Application Support/nice-dns-install"
      ND_ST_STATE_DIR="${ND_STATE_DIR:-$HOME/Library/Application Support/nice-dns/controller}"
      ND_ST_RECEIPT="$HOME/Library/Application Support/nice-dns-health/install.tsv"
      ND_ST_SCHEDULE="$HOME/Library/LaunchAgents/org.nice-dns.health.plist"
      ND_ST_ADMIN_URL="http://172.31.240.250/admin"
      ND_ST_CURL="curl -fsSL https://raw.githubusercontent.com/sureserverman/nice-dns/main/install-mac.sh -o install-mac.sh && bash install-mac.sh" ;;
    *)
      ND_ST_INSTALL_DIR="$state/nice-dns-install"
      ND_ST_STATE_DIR="${ND_STATE_DIR:-$state/nice-dns/controller}"
      ND_ST_RECEIPT="${XDG_DATA_HOME:-$HOME/.local/share}/nice-dns-health/install.tsv"
      ND_ST_SCHEDULE="$cfg/systemd/user/default.target.wants/nice-dns-health.timer"
      ND_ST_ADMIN_URL="http://localhost:8880/admin"
      ND_ST_CURL="curl -fsSL https://raw.githubusercontent.com/sureserverman/nice-dns/main/install-deb.sh -o install-deb.sh && bash install-deb.sh" ;;
  esac
}

# nd_status_rows <linux|macos>: prints the rows. Returns 0, 1 when nothing
# is installed, 2 when the controller's state directory cannot be read.
# ND_STATUS_NOW (epoch) and ND_STATUS_STALE_S (default 300) are for tests.
nd_status_rows() {
  local plat="${1:-linux}" now stale_s="${ND_STATUS_STALE_S:-300}" rc=0
  local gen="" m="" mode last verdict age obs n refresh bmode cache r
  now="${ND_STATUS_NOW:-$(date +%s)}"
  _nd_st_paths "$plat"
  printf 'schema\t%s\n' "$ND_STATUS_SCHEMA"

  # install
  [ -f "$ND_ST_INSTALL_DIR/current" ] && gen="$(cat "$ND_ST_INSTALL_DIR/current" 2>/dev/null)"
  [ -n "$gen" ] && m="$ND_ST_INSTALL_DIR/generations/$gen/prepare.tsv"
  if [ -n "$m" ] && [ -f "$m" ]; then
    _nd_st_row install installed yes
    _nd_st_row install generation "$gen"
    _nd_st_row install source_commit "$(_nd_st_field "$m" source_commit)"
    _nd_st_row install branch "$(_nd_st_field "$m" branch)"
    _nd_st_row install variant "$(_nd_st_field "$m" variant)"
    _nd_st_row install pihole "$(_nd_st_field "$m" pihole)"
    _nd_st_row install platform "$(_nd_st_field "$m" platform)"
    _nd_st_row install lock "$(_nd_st_field "$m" lock)"
  else
    m=""
    _nd_st_row install installed no
    _nd_st_row install hint "$ND_ST_CURL"
    rc=1
  fi

  # controller
  if [ -f "$ND_ST_RECEIPT" ]; then
    mode="$(_nd_st_field "$ND_ST_RECEIPT" mode)"
    _nd_st_row controller mode "${mode:-active}"
  else
    _nd_st_row controller mode not-installed
  fi
  obs="$ND_ST_STATE_DIR/observations.tsv"
  if [ -e "$ND_ST_STATE_DIR" ] && { [ ! -d "$ND_ST_STATE_DIR" ] || [ ! -r "$ND_ST_STATE_DIR" ] || [ ! -x "$ND_ST_STATE_DIR" ]; }; then
    _nd_st_row controller unreadable "cannot read $ND_ST_STATE_DIR"
    rc=2
  elif [ -e "$obs" ] && [ ! -r "$obs" ]; then
    _nd_st_row controller unreadable "cannot read $obs"
    rc=2
  fi
  last="" verdict=""
  if [ -r "$obs" ]; then
    last="$(awk -F '\t' '$1 == "pass" { print $2; exit }' "$obs")"
    verdict="$(awk -F '\t' '$1 == "pass" { print $3; exit }' "$obs")"
  fi
  case "$last" in ''|*[!0-9]*) last="" ;; esac
  if [ -z "$last" ]; then
    _nd_st_row controller last_pass never
    _nd_st_row controller verdict unknown
    _nd_st_row controller stale never
  else
    age=$((now - last))
    _nd_st_row controller last_pass "$last"
    _nd_st_row controller verdict "$verdict"
    if [ "$age" -gt "$stale_s" ]; then _nd_st_row controller stale "$age"; else _nd_st_row controller stale no; fi
  fi
  if [ -e "$ND_ST_SCHEDULE" ]; then _nd_st_row controller schedule loaded; else _nd_st_row controller schedule stopped; fi

  # obs: the controller's own records, copied as written (each field cleaned)
  if [ -r "$obs" ]; then
    awk -F '\t' '$1 == "obs"' "$obs" | while IFS= read -r r; do
      printf '%s\n' "$r" | tr -d '\000-\010\012-\037\177' | cut -c1-400
    done
  fi

  # route
  if [ -r "$ND_ST_STATE_DIR/state.tsv" ]; then
    r="$(_nd_st_field "$ND_ST_STATE_DIR/state.tsv" route)"
    [ -z "$r" ] || _nd_st_row route selected "$r" "$(_nd_st_field "$ND_ST_STATE_DIR/state.tsv" generation)"
  fi

  # bridges
  bmode=on
  if [ -r "$ND_ST_CONFIG_DIR/bridges-mode.env" ]; then
    case "$(awk -F '=' '$1 == "TOR_BRIDGES" { print $2; exit }' "$ND_ST_CONFIG_DIR/bridges-mode.env")" in off) bmode=off ;; esac
  fi
  _nd_st_row bridges mode "$bmode"
  n=0
  [ -r "$ND_ST_CONFIG_DIR/bridges.env" ] && n="$(awk '/^BRIDGE[0-9]+=/ { n++ } END { print n + 0 }' "$ND_ST_CONFIG_DIR/bridges.env")"
  _nd_st_row bridges count "$n"
  refresh=""
  [ -r "$ND_ST_STATE_DIR/bridges.last" ] && refresh="$(awk 'NR == 1 { print $1; exit }' "$ND_ST_STATE_DIR/bridges.last")"
  case "$refresh" in ''|*[!0-9]*) refresh=never ;; esac
  _nd_st_row bridges last_refresh "$refresh"

  # update: the cache `nice-dns update --check` writes
  cache="$ND_ST_STATE_DIR/update-check.tsv"
  if [ -r "$cache" ] && [ "$(awk 'NR == 1 { print; exit }' "$cache")" = "schema	nice-dns-update-check/1" ]; then
    r="$(_nd_st_field "$cache" result)"
    case "$r" in current|available|unknown) ;; *) r=unknown ;; esac
    _nd_st_row update result "$r"
    _nd_st_row update checked_at "$(_nd_st_field "$cache" checked_at)"
    _nd_st_row update remote_commit "$(_nd_st_field "$cache" remote_commit)"
  else
    _nd_st_row update result unknown never-checked
  fi

  # admin
  _nd_st_row admin url "$ND_ST_ADMIN_URL"
  if [ -n "$m" ]; then
    _nd_st_row admin password_path "$(awk -F '\t' '$1 == "credential" && $2 == "pihole-admin" { print $3; exit }' "$m")"
  fi

  # recent: the last five journal rows (epoch, target, result)
  if [ -r "$ND_ST_STATE_DIR/recovery.tsv" ]; then
    awk -F '\t' 'NF >= 4 && $1 ~ /^[0-9]+$/ { r[++n] = $1 "\t" $3 "\t" $4 }
      END { for (i = n - 4; i <= n; i++) if (i > 0) print r[i] }' "$ND_ST_STATE_DIR/recovery.tsv" |
      while IFS='	' read -r e a s; do _nd_st_row recent "$e" "$a" "$s"; done
  fi
  return "$rc"
}
