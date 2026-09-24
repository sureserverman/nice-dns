# shellcheck shell=bash
# Helpers to start/stop the controlled DNS/DNSSEC/DoT fixture (Task 1.2).
# Sourced by test groups. Bash 3.2 compatible. State (keys, certificates,
# anchors, ports, pid) lives in the directory the caller passes, which must be
# under the run's artifact dir; nothing is written into the checkout.
#
#   fx_start <dir> [--tls]   start; --tls adds DoT listeners for the four
#                            certificate variants (good wrongname expired untrusted).
#                            The server exits on its own if orphaned or after
#                            FX_MAX_SECONDS (default 900).
#   fx_port <dir> <name>     port for dns | dot-<variant>
#   fx_stop <dir>            stop the fixture started in <dir>
#   fx_mode <path>           octal permission bits (GNU or BSD stat)

FX_PY="${NICE_DNS_ROOT:?NICE_DNS_ROOT is unset}/tests/fixtures/dnsfixture.py"
FX_VARIANTS="good wrongname expired untrusted"

fx_start() {
  local dir="$1" tls=no args v i
  shift
  while [ $# -gt 0 ]; do
    case "$1" in
      --tls) tls=yes ;;
      *) printf 'fx_start: unknown option %s\n' "$1" >&2; return 2 ;;
    esac
    shift
  done
  if [ -e "$dir" ]; then printf 'fx_start: %s already exists\n' "$dir" >&2; return 2; fi
  mkdir -p "$(dirname "$dir")" && mkdir -m 700 "$dir" || return 1
  set -- serve --state "$dir" --max-seconds "${FX_MAX_SECONDS:-900}"
  if [ "$tls" = yes ]; then
    python3 "$FX_PY" pki --out "$dir/pki" >"$dir/pki.log" 2>&1 || { cat "$dir/pki.log" >&2; return 1; }
    for v in $FX_VARIANTS; do
      set -- "$@" --tls "$v:$dir/pki/$v.pem:$dir/pki/$v.key"
    done
  fi
  args=("$@")
  python3 "$FX_PY" "${args[@]}" >"$dir/fixture.log" 2>&1 </dev/null &
  printf '%s\n' "$!" >"$dir/pid"
  i=0
  while [ ! -f "$dir/ports.tsv" ]; do
    i=$((i + 1))
    if [ "$i" -gt 200 ] || ! kill -0 "$(cat "$dir/pid")" 2>/dev/null; then
      cat "$dir/fixture.log" >&2
      fx_stop "$dir"
      return 1
    fi
    sleep 0.05
  done
  return 0
}

fx_port() {
  awk -F '\t' -v k="$2" '$1 == k { print $2; found = 1 } END { exit !found }' "$1/ports.tsv"
}

fx_stop() {
  local pid i=0
  [ -f "$1/pid" ] || return 0
  pid="$(cat "$1/pid")"
  kill "$pid" 2>/dev/null || { rm -f "$1/pid"; return 0; }
  while kill -0 "$pid" 2>/dev/null; do
    i=$((i + 1))
    if [ "$i" -gt 40 ]; then kill -9 "$pid" 2>/dev/null; break; fi
    sleep 0.05
  done
  wait "$pid" 2>/dev/null
  rm -f "$1/pid"
  return 0
}

fx_mode() {
  stat -c %a "$1" 2>/dev/null || stat -f %Lp "$1"
}
